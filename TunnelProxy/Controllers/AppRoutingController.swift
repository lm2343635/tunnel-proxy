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
    private var eventApp: RoutingAppIdentity?

    override init() {
        let data = UserDefaults.standard.data(forKey: "appRoutingRules")
        rules = data.flatMap { try? JSONDecoder().decode(RoutingRules.self, from: $0) } ?? RoutingRules()
        super.init()
    }

    var confirmed: Bool {
        guard let status else { return false }
        return status.session == session && status.version == rules.version
            && manager?.connection.status == .connected
    }

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
                if session != nil {
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
        _ = await send(rules: nil, peer: peer)
    }

    func observeEvents(for identity: RoutingAppIdentity?) {
        eventApp = identity
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
                    version: update?.version, rules: update?.providerRules, tunnel: peer, eventApp: eventApp)) else {
            status = nil
            return false
        }
        controlSequence &+= 1
        let sequence = controlSequence
        let reply: Data? = await withCheckedContinuation { continuation in
            let completion = DispatchOnce { continuation.resume(returning: $0) }
            do {
                try connection.sendProviderMessage(payload) { completion.finish($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { completion.finish(nil) }
            } catch {
                completion.finish(nil)
            }
        }
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
            completeApproval(false, status: "App routing extension could not be enabled")
            message = (message ?? "") + " · " + error.localizedDescription
        }
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
