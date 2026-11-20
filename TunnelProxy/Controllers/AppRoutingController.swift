import Foundation
import NetworkExtension
import SystemExtensions
import Combine

@MainActor
final class AppRoutingController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var rules: RoutingRules
    @Published private(set) var status: RoutingStatus?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private let rulesKey = "appRoutingRules"
    private var manager: NETransparentProxyManager?
    private var session: UUID?
    private var activation: OSSystemExtensionRequest?
    private var activationResult: CheckedContinuation<Bool, Never>?
    private var outstandingHeartbeat = false
    private var enableCanceled = false
    private var controlSequence: UInt64 = 0
    private let historyStore = RoutingHistoryStore()
    private let historyOwner: UUID
    private var historySyncInProgress = false
    private var lastHistoryMaintenance: Date?
    @Published private(set) var historySyncFailed = false

    struct History {
        var page = RoutingHistoryStore.Page()
        var hasLoaded = false
        var isLoading = false
        var failed = false
        var request: UUID?
    }

    @Published private(set) var histories: [RoutingAppIdentity: History] = [:]

    override init() {
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: "appRoutingHistoryOwner").flatMap(UUID.init(uuidString:)) ?? UUID()
        historyOwner = owner
        defaults.set(owner.uuidString, forKey: "appRoutingHistoryOwner")
        let data = defaults.data(forKey: "appRoutingRules")
        rules = data.flatMap { try? JSONDecoder().decode(RoutingRules.self, from: $0) } ?? RoutingRules()
        super.init()
    }

    var confirmed: Bool {
        guard let status else { return false }
        return status.session == session && status.version == rules.version
            && manager?.connection.status == .connected
    }

    var canCancelApproval: Bool { activationResult != nil }

    func adopt() async {
        do {
            guard let existing = try await savedManager(),
                  let configuration = existing.protocolConfiguration as? NETunnelProviderProtocol,
                  let id = configuration.providerConfiguration?[AppRoutingProtocol.sessionKey] as? String,
                  let decoded = UUID(uuidString: id) else { return }
            manager = existing
            session = decoded
        } catch {
            message = routingText("Routing state unknown")
        }
    }

    func enable(using peer: RoutingSOCKSPeer?) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        enableCanceled = false
        // macOS refuses to activate a system extension from an app outside
        // /Applications, and only says so deep inside the request (as an
        // untranslated string the user cannot act on). Check first and say what
        // to do instead of asking for an approval that is doomed to fail.
        guard Self.isInstalled else {
            message = routingText("Move Tunnel Proxy into the Applications folder to enable app routing")
            return false
        }
        message = routingText("Preparing app routing")
        guard await approve(), !enableCanceled else { return false }
        do {
            let existing = try await savedManager()
            guard !enableCanceled else { return false }
            if let existing, existing.connection.status == .connected {
                manager = existing
                let configuration = existing.protocolConfiguration as? NETunnelProviderProtocol
                let id = configuration?.providerConfiguration?[AppRoutingProtocol.sessionKey] as? String
                session = id.flatMap(UUID.init(uuidString:))
                let owner = configuration?.providerConfiguration?[AppRoutingProtocol.historyOwnerKey] as? String
                if session != nil, owner == historyOwner.uuidString {
                    let updated = try await applyCurrentRules(to: existing, peer: peer)
                    if updated { return true }
                }
            }
            let manager = existing ?? NETransparentProxyManager()
            // Restart only this app's stale configuration.
            if manager.connection.status != .disconnected && manager.connection.status != .invalid {
                (manager.connection as? NETunnelProviderSession)?.stopTunnel()
                guard await wait(for: .disconnected, on: manager) else {
                    message = routingText("Routing state unknown")
                    return false
                }
            }
            let id = UUID()
            let settings = NETunnelProviderProtocol()
            settings.providerBundleIdentifier = AppRoutingProtocol.providerIdentifier
            settings.serverAddress = "Tunnel Proxy"
            settings.providerConfiguration = try providerConfiguration(id)
            manager.localizedDescription = "Tunnel Proxy App Routing"
            manager.protocolConfiguration = settings
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
            guard !enableCanceled else {
                _ = await remove(manager)
                return false
            }
            try await manager.loadFromPreferences()
            guard !enableCanceled else {
                _ = await remove(manager)
                return false
            }
            guard let connection = manager.connection as? NETunnelProviderSession else {
                throw NSError(domain: "TunnelProxy.AppRouting", code: 1)
            }
            self.manager = manager
            session = id
            try connection.startTunnel()
            guard await wait(for: .connected, on: manager), !enableCanceled else {
                _ = await remove(manager)
                message = routingText("Could not start app routing")
                return false
            }
            guard await send(rules: rules, peer: peer) else {
                _ = await remove(manager)
                message = routingText("Routing state unknown")
                return false
            }
            return true
        } catch {
            if let manager { _ = await remove(manager) }
            message = routingText("Could not start app routing") + " · " + error.localizedDescription
            return false
        }
    }

    func disable() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        await syncHistory()
        do {
            if let manager = try await savedManager(), !(await remove(manager)) { return false }
            status = nil
            session = nil
            manager = nil
            message = nil
            return true
        } catch {
            message = routingText("Routing state unknown")
            return false
        }
    }

    func heartbeat(peer: RoutingSOCKSPeer?) async {
        guard !busy, !outstandingHeartbeat, session != nil else { return }
        outstandingHeartbeat = true
        defer { outstandingHeartbeat = false }
        if await send(rules: nil, peer: peer) {
            Task { await self.syncHistory() }
        }
    }

    private func syncHistory() async {
        guard !historySyncInProgress, let session,
              let connection = manager?.connection as? NETunnelProviderSession,
              connection.status == .connected else { return }
        historySyncInProgress = true
        defer { historySyncInProgress = false }
        var acknowledgements: [UUID] = []
        let store = historyStore

        // Bound each drain so recording cannot delay the routing heartbeat.
        for _ in 0..<9 {
            let request = RoutingHistoryRequest(historySession: session, historyAcknowledgements: acknowledgements)
            guard let payload = try? JSONEncoder().encode(request),
                  let data = await exchange(payload, via: connection),
                  let reply = try? JSONDecoder().decode(RoutingHistoryReply.self, from: data) else {
                if self.session == session { historySyncFailed = true }
                return
            }
            guard self.session == session else { return }
            if reply.events.isEmpty {
                historySyncFailed = false
                return
            }
            do {
                try await Task.detached(priority: .utility) { try store.append(reply.events) }.value
            } catch {
                historySyncFailed = true
                return
            }
            guard self.session == session else { return }
            historySyncFailed = false
            acknowledgements = reply.events.map(\.id)
        }
        // The next drain may receive the last batch again. Inserts are idempotent.
    }

    func maintainHistory() {
        let now = Date()
        if let lastHistoryMaintenance, now.timeIntervalSince(lastHistoryMaintenance) < 60 { return }
        lastHistoryMaintenance = now
        let store = historyStore
        Task.detached(priority: .utility) {
            do { try store.append([], now: now) }
            catch { NSLog("App Routing history maintenance failed") }
        }
    }

    func loadHistory(for app: RoutingAppIdentity, earlier: Bool = false) async {
        guard rules.apps.contains(where: { $0.id == app }) else { return }
        var history = histories[app] ?? History()
        guard !history.isLoading else { return }
        history.page.events.removeAll { $0.time < RoutingHistoryStore.cutoff() }
        let oldest = history.page.events.last
        if earlier && (!history.page.hasEarlier || oldest == nil) { return }

        let request = UUID()
        history.request = request
        history.isLoading = true
        histories[app] = history
        let store = historyStore
        let read = Task.detached(priority: .utility) {
            try store.read(app, through: earlier ? nil : oldest, before: earlier ? oldest : nil)
        }
        do {
            let page = try await read.value
            if earlier {
                history.page.events.append(contentsOf: page.events)
                history.page.hasEarlier = page.hasEarlier
            } else {
                history.page = page
            }
            history.hasLoaded = true
            history.failed = false
        } catch {
            history.failed = true
        }
        history.isLoading = false
        guard histories[app]?.request == request else { return }
        history.request = nil
        histories[app] = history
    }

    func save(_ app: RoutingApp, peer: RoutingSOCKSPeer?) async {
        guard !busy else { return }
        if let index = rules.apps.firstIndex(where: { $0.id == app.id }) {
            var updated = app
            updated.isEnabled = rules.apps[index].isEnabled
            rules.apps[index] = updated
        } else {
            rules.apps.append(app)
        }
        await commit(peer: peer)
    }

    func setEnabled(_ enabled: Bool, for identity: RoutingAppIdentity, peer: RoutingSOCKSPeer?) async {
        guard !busy, let index = rules.apps.firstIndex(where: { $0.id == identity }),
              rules.apps[index].isEnabled != enabled else { return }
        rules.apps[index].isEnabled = enabled
        await commit(peer: peer)
    }

    func delete(_ identity: RoutingAppIdentity, peer: RoutingSOCKSPeer?) async {
        guard !busy else { return }
        rules.apps.removeAll { $0.id == identity }
        histories.removeValue(forKey: identity)
        await commit(peer: peer)
    }

    private func commit(peer: RoutingSOCKSPeer?) async {
        rules.version = UUID()
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: rulesKey) }
        guard let manager, session != nil else { message = routingText("Rules saved"); return }
        busy = true
        defer { busy = false }
        do {
            if try await applyCurrentRules(to: manager, peer: peer) { return }
        } catch {}
        message = routingText("Rules saved; activation unconfirmed")
    }

    private func providerConfiguration(_ id: UUID) throws -> [String: Any] {
        [AppRoutingProtocol.sessionKey: id.uuidString,
         AppRoutingProtocol.historyOwnerKey: historyOwner.uuidString,
         AppRoutingProtocol.rulesKey: try JSONEncoder().encode(rules.providerRules)]
    }

    private func applyCurrentRules(to manager: NETransparentProxyManager, peer: RoutingSOCKSPeer?) async throws -> Bool {
        guard let session, let settings = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        settings.providerConfiguration = try providerConfiguration(session)
        manager.protocolConfiguration = settings
        try await manager.saveToPreferences()
        return await send(rules: rules, peer: peer)
    }

    private func send(rules update: RoutingRules?, peer: RoutingSOCKSPeer?) async -> Bool {
        guard let session, let connection = manager?.connection as? NETunnelProviderSession,
              connection.status == .connected,
              let payload = try? JSONEncoder().encode(RoutingControl(session: session,
                    version: update?.version, rules: update?.providerRules, tunnel: peer)) else {
            status = nil
            return false
        }
        controlSequence &+= 1
        let sequence = controlSequence
        let reply = await exchange(payload, via: connection)
        guard self.session == session, sequence == controlSequence else { return false }
        guard let reply, let value = try? JSONDecoder().decode(RoutingStatus.self, from: reply),
              value.session == session else {
            status = nil
            message = routingText("Routing state unknown")
            return false
        }
        status = value
        guard value.version == rules.version else {
            message = routingText("Rules saved; activation unconfirmed")
            return false
        }
        message = value.tunnelReady ? nil : routingText("Waiting for the SSH tunnel")
        return true
    }

    private func exchange(_ payload: Data, via connection: NETunnelProviderSession) async -> Data? {
        await withCheckedContinuation { continuation in
            let completion = DispatchOnce { continuation.resume(returning: $0) }
            do {
                try connection.sendProviderMessage(payload) { completion.finish($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { completion.finish(nil) }
            } catch {
                completion.finish(nil)
            }
        }
    }

    private func savedManager() async throws -> NETransparentProxyManager? {
        let matches = try await NETransparentProxyManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == AppRoutingProtocol.providerIdentifier
        }
        guard matches.count <= 1 else { throw NSError(domain: "TunnelProxy.AppRouting", code: 2) }
        return matches.first
    }

    private func remove(_ manager: NETransparentProxyManager) async -> Bool {
        (manager.connection as? NETunnelProviderSession)?.stopTunnel()
        do {
            try await manager.removeFromPreferences()
            let removed = try await savedManager() == nil
            if removed {
                session = nil
                self.manager = nil
                status = nil
            }
            return removed
        } catch {
            message = routingText("Routing state unknown")
            return false
        }
    }

    private func wait(for target: NEVPNStatus, on manager: NETransparentProxyManager) async -> Bool {
        for _ in 0..<60 {
            if manager.connection.status == target { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func approve() async -> Bool {
        await withCheckedContinuation { continuation in
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: AppRoutingProtocol.providerIdentifier, queue: .main)
            activation = request
            activationResult = continuation
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func cancelApproval() {
        guard busy else { return }
        enableCanceled = true
        if activationResult != nil {
            completeApproval(false, status: "Extension approval canceled")
        } else {
            message = routingText("Extension approval canceled")
        }
    }

    private func completeApproval(_ approved: Bool, status: String?) {
        let continuation = activationResult
        activationResult = nil
        activation = nil
        message = status.map(routingText)
        continuation?.resume(returning: approved)
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            if activation === request { message = routingText("Awaiting approval in System Settings") }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            guard activation === request else { return }
            completeApproval(result == .completed, status: result == .completed ? nil : "Restart required to enable app routing")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard activation === request else { return }
            let description = error.localizedDescription
            let outsideApplications = description.contains("/Applications")
            completeApproval(false, status: outsideApplications
                             ? "Move Tunnel Proxy into the Applications folder to enable app routing"
                             : "App routing extension could not be enabled")
            if !outsideApplications {
                message = (message ?? "") + " · " + description
            }
        }
    }

    /// A system extension can only be activated by an app in `/Applications`.
    private static var isInstalled: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    nonisolated static func inspectApp(_ url: URL) -> RoutingApp? {
        let bundle = url.resolvingSymlinksInPath()
        guard bundle.pathExtension.lowercased() == "app",
              let identity = RoutingSigning.identity(of: bundle) else { return nil }
        let name = (Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundle.deletingPathExtension().lastPathComponent
        let root = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return nil }
        var helpers = Set<RoutingAppIdentity>()
        for case let item as URL in items {
            let lower = item.pathExtension.lowercased()
            let bundleHelper = ["app", "xpc", "appex"].contains(lower)
            let binaryHelper = item.path.contains("/Contents/Helpers/")
                && (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
                && FileManager.default.isExecutableFile(atPath: item.path)
            if (bundleHelper || binaryHelper), let signed = RoutingSigning.identity(of: item), signed != identity {
                helpers.insert(signed)
            }
        }
        return RoutingApp(identity: identity, name: name, directory: bundle,
                          bundledHelpers: helpers.sorted { ($0.team, $0.identifier) < ($1.team, $1.identifier) })
    }
}

private final class DispatchOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Data?) -> Void)?

    init(_ completion: @escaping (Data?) -> Void) { self.completion = completion }

    func finish(_ value: Data?) {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?(value)
    }
}
