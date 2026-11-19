import AppKit
import NetworkExtension
import SwiftUI
import SystemExtensions

@main
struct LabApp: App {
    @NSApplicationDelegateAdaptor(LabController.self) private var lab

    var body: some Scene {
        Window("App Routing Lab", id: "lab") {
            LabView(lab: lab)
        }
    }
}

private struct LabView: View {
    @ObservedObject var lab: LabController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let endpoint = lab.endpoint {
                if lab.relay == nil {
                    Text("Observes TCP and UDP to \(endpoint.description). The system handles all flows.")
                } else {
                    Text("Relays scoped Claude HTTPS CONNECT traffic at \(endpoint.description) through SSH.")
                }
            } else {
                Text("Invalid laboratory endpoint or process selection.")
            }
            HStack {
                Button("Request extension approval") { lab.requestExtension(.activate) }
                    .disabled(lab.session != nil)
                Button("Start observation") { lab.start() }
                    .disabled(!lab.extensionApproved || lab.session != nil || lab.endpoint == nil)
                Button("Read provider") { lab.readProvider() }
                    .disabled(lab.session == nil)
            }
            HStack {
                Button("Stop and remove lab configuration") { lab.removeConfiguration() }
                Button("Deactivate extension") { lab.requestExtension(.deactivate) }
                    .disabled(lab.session != nil)
            }
            LabeledContent("Extension", value: lab.extensionStatus)
            LabeledContent("Connection", value: lab.connectionStatus)
            if let snapshot = lab.snapshot {
                LabeledContent("Confirmed rule version", value: String(snapshot.session.version))
                LabeledContent("TCP / UDP handed to system",
                               value: "\(snapshot.counts.tcp) / \(snapshot.counts.udp)")
                LabeledContent("Probe signing identifier matches",
                               value: String(snapshot.counts.probeMatches))
                LabeledContent("Matching flows with audit token",
                               value: String(snapshot.counts.probeAuditTokenPresent))
                LabeledContent("Verified Claude main flows", value: String(snapshot.counts.claudeMain))
                LabeledContent("Verified Claude Helper flows", value: String(snapshot.counts.claudeHelper))
                LabeledContent("Unverified Claude claims", value: String(snapshot.counts.claudeUnverified))
                LabeledContent("Other source flows", value: String(snapshot.counts.otherSources))
                if lab.relay != nil {
                    LabeledContent("SSH CONNECT main / Helper",
                                   value: "\(snapshot.counts.relayMainConnected) / \(snapshot.counts.relayHelperConnected)")
                    LabeledContent("SSH bidirectional main / Helper",
                                   value: "\(snapshot.counts.relayMainBidirectional) / \(snapshot.counts.relayHelperBidirectional)")
                    LabeledContent("SSH open main / Helper",
                                   value: "\(snapshot.counts.relayMainActive) / \(snapshot.counts.relayHelperActive)")
                    LabeledContent("SSH main bytes sent / received",
                                   value: "\(snapshot.counts.relayMainSentBytes) / \(snapshot.counts.relayMainReceivedBytes)")
                    LabeledContent("SSH Helper bytes sent / received",
                                   value: "\(snapshot.counts.relayHelperSentBytes) / \(snapshot.counts.relayHelperReceivedBytes)")
                    LabeledContent("Unsupported / failed",
                                   value: "\(snapshot.counts.relayUnsupported) / \(snapshot.counts.relayFailures)")
                    LabeledContent("Rejection reasons", value: summary(snapshot.counts.relayRejectionReasons))
                    LabeledContent("Failure stages", value: summary(snapshot.counts.relayFailureStages))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, alignment: .leading)
        .disabled(lab.configurationBusy)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            lab.updateConnection()
        }
    }

    private func summary(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "None" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

final class LabController: NSObject, ObservableObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    enum ExtensionAction {
        case activate
        case deactivate
    }

    @Published private(set) var extensionApproved = false
    @Published private(set) var extensionStatus = "Approval required"
    @Published private(set) var connectionStatus = "Idle"
    @Published private(set) var session: LabSession?
    @Published private(set) var snapshot: LabSnapshot?
    @Published private(set) var configurationBusy = false
    let relay = LabRelaySelection.selected
    var endpoint: LabEndpoint? {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--relay-") }) else {
            return LabEndpoint.selected
        }
        guard relay != nil else { return nil }
        return LabEndpoint(address: "127.0.0.1", port: LabRelaySelection.proxyPort)
    }

    private var request: OSSystemExtensionRequest?
    private var action: ExtensionAction?
    private var manager: NETransparentProxyManager?
    private var readID: UUID?

    func requestExtension(_ action: ExtensionAction) {
        guard request == nil, session == nil else { return }
        extensionApproved = false
        let request: OSSystemExtensionRequest
        switch action {
        case .activate:
            request = .activationRequest(forExtensionWithIdentifier: LabProtocol.providerID, queue: .main)
        case .deactivate:
            request = .deactivationRequest(forExtensionWithIdentifier: LabProtocol.providerID, queue: .main)
        }
        self.request = request
        self.action = action
        request.delegate = self
        extensionStatus = "Request submitted"
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === self.request else { return }
        extensionStatus = "Awaiting approval in System Settings"
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === self.request else { return }
        extensionApproved = result == .completed && action == .activate
        if result == .willCompleteAfterReboot {
            extensionStatus = "Restart required"
        } else {
            extensionStatus = extensionApproved ? "Approved" : "Deactivated"
        }
        self.request = nil
        action = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request === self.request else { return }
        extensionStatus = "Request failed (\(errorCode(error)))"
        self.request = nil
        action = nil
    }

    func start() {
        guard extensionApproved, session == nil, !configurationBusy, let endpoint else { return }
        configurationBusy = true
        connectionStatus = "Preparing configuration"
        loadConfiguration { [self] existing in
            let manager = existing ?? NETransparentProxyManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = LabProtocol.providerID
            configuration.serverAddress = endpoint.address
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "App Routing Lab"
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.saveToPreferences { error in
                DispatchQueue.main.async { [self] in
                    if let error {
                        configurationFailed(error)
                    } else {
                        reloadAndStart(manager, endpoint: endpoint)
                    }
                }
            }
        }
    }

    private func reloadAndStart(_ manager: NETransparentProxyManager, endpoint: LabEndpoint) {
        manager.loadFromPreferences { error in
            DispatchQueue.main.async { [self] in
                configurationBusy = false
                if let error {
                    configurationFailed(error)
                    return
                }
                guard let connection = manager.connection as? NETunnelProviderSession else {
                    connectionStatus = "Provider session unavailable"
                    return
                }
                self.manager = manager
                let session = LabSession(id: UUID(), version: LabProtocol.version)
                do {
                    var options: [String: NSObject] = [
                        LabProtocol.sessionKey: session.id.uuidString as NSString,
                        LabProtocol.versionKey: NSNumber(value: session.version),
                        LabProtocol.addressKey: endpoint.address as NSString,
                        LabProtocol.portKey: NSNumber(value: endpoint.port)
                    ]
                    if let relay {
                        options[LabProtocol.relayKey] = try JSONEncoder().encode(relay) as NSData
                    }
                    try connection.startTunnel(options: options)
                    self.session = session
                    connectionStatus = "Start requested. Read the provider after connection."
                } catch {
                    configurationFailed(error)
                }
            }
        }
    }

    func updateConnection() {
        guard session != nil, let connection = manager?.connection else { return }
        if connection.status != .connected { snapshot = nil }
        switch connection.status {
        case .connected:
            connectionStatus = snapshot == nil ? "Connected. Provider confirmation pending." : "Provider confirmed"
        case .connecting: connectionStatus = "Connecting"
        case .disconnecting: connectionStatus = "Disconnecting"
        case .reasserting: connectionStatus = "Reasserting"
        case .disconnected: connectionStatus = "Disconnected. Remove lab configuration to retry."
        case .invalid: connectionStatus = "Configuration unavailable"
        @unknown default: connectionStatus = "Unknown connection status"
        }
    }

    func readProvider() {
        guard let session, let connection = manager?.connection as? NETunnelProviderSession,
              connection.status == .connected, readID == nil else { return }
        snapshot = nil
        let id = UUID()
        readID = id
        do {
            try connection.sendProviderMessage(JSONEncoder().encode(session)) { data in
                DispatchQueue.main.async { [self] in
                    guard readID == id else { return }
                    readID = nil
                    guard self.session == session, connection.status == .connected else { return }
                    if let data, let reply = try? JSONDecoder().decode(LabSnapshot.self, from: data),
                       reply.session == session {
                        snapshot = reply
                    }
                    updateConnection()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, readID == id else { return }
                readID = nil
                updateConnection()
            }
        } catch {
            readID = nil
            updateConnection()
        }
    }

    func removeConfiguration() {
        guard !configurationBusy else { return }
        configurationBusy = true
        snapshot = nil
        readID = nil
        manager?.connection.stopVPNTunnel()
        session = nil
        connectionStatus = "Removing lab configuration"
        loadConfiguration { [self] manager in
            guard let manager else {
                configurationRemoved()
                return
            }
            manager.connection.stopVPNTunnel()
            manager.removeFromPreferences { error in
                DispatchQueue.main.async { [self] in
                    if let error {
                        configurationFailed(error)
                    } else {
                        configurationRemoved()
                    }
                }
            }
        }
    }

    private func loadConfiguration(_ completion: @escaping (NETransparentProxyManager?) -> Void) {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async { [self] in
                if let error {
                    configurationFailed(error)
                    return
                }
                let matches = (managers ?? []).filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                        == LabProtocol.providerID
                }
                guard matches.count <= 1 else {
                    configurationBusy = false
                    connectionStatus = "Multiple lab profiles. Resolve them in System Settings."
                    return
                }
                completion(matches.first)
            }
        }
    }

    private func configurationRemoved() {
        manager = nil
        configurationBusy = false
        connectionStatus = "Lab configuration removed"
    }

    private func configurationFailed(_ error: Error) {
        configurationBusy = false
        connectionStatus = "Configuration request failed (\(errorCode(error)))"
    }

    private func errorCode(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.connection.stopVPNTunnel()
    }
}
