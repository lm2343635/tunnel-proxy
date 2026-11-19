import Foundation
import Network
import NetworkExtension

final class ProxyProvider: NETransparentProxyProvider {
    private struct State {
        let session: LabSession
        let relay: LabRelaySelection?
        var counts = FlowCounts()
        var connections: [UUID: ClaudeCONNECTRelay] = [:]
    }

    private let stateLock = NSLock()
    private var state: State?

    override func startProxy(options: [String: Any]? = nil,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let id = (options?[LabProtocol.sessionKey] as? String).flatMap(UUID.init(uuidString:)),
              let version = options?[LabProtocol.versionKey] as? Int,
              version == LabProtocol.version,
              let address = options?[LabProtocol.addressKey] as? String,
              let rawPort = options?[LabProtocol.portKey] as? Int,
              let port = UInt16(exactly: rawPort),
              let endpoint = LabEndpoint(address: address, port: port) else {
            completionHandler(NSError(domain: LabProtocol.providerID, code: 1))
            return
        }

        let relay = (options?[LabProtocol.relayKey] as? Data).flatMap {
            try? JSONDecoder().decode(LabRelaySelection.self, from: $0)
        }
        if endpoint.port == LabRelaySelection.proxyPort {
            guard let relay,
                  relay.claude.hasExecutable(LabRelaySelection.claudeExecutable),
                  relay.ssh.hasExecutable(LabRelaySelection.sshExecutable) else {
                completionHandler(NSError(domain: LabProtocol.providerID, code: 2))
                return
            }
        } else if options?[LabProtocol.relayKey] != nil {
            completionHandler(NSError(domain: LabProtocol.providerID, code: 3))
            return
        }

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: endpoint.address)
        settings.includedNetworkRules = [probeRule(endpoint, protocol: relay == nil ? .any : .TCP)]
        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil, let self {
                self.stateLock.withLock {
                    self.state = State(session: LabSession(id: id, version: version), relay: relay)
                }
            }
            completionHandler(error)
        }
    }

    private func probeRule(_ endpoint: LabEndpoint, protocol networkProtocol: NENetworkRule.`Protocol`) -> NENetworkRule {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            return NENetworkRule(
                remoteNetworkEndpoint: .hostPort(host: .init(endpoint.address),
                                                 port: .init(rawValue: endpoint.port)!),
                remotePrefix: 32, localNetworkEndpoint: nil, localPrefix: 0,
                protocol: networkProtocol, direction: .outbound
            )
        }
        #endif

        return NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: endpoint.address,
                                                            port: String(endpoint.port)),
                             remotePrefix: 32, localNetwork: nil, localPrefix: 0,
                             protocol: networkProtocol, direction: .outbound)
    }

    override func stopProxy(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        let active = stateLock.withLock {
            let active = state.map { Array($0.connections.values) } ?? []
            state = nil
            return active
        }
        for connection in active { connection.cancel() }
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let relay = stateLock.withLock { state?.relay }
        if let relay { return acceptRelay(flow, selection: relay) }
        record(flow)
        return false
    }

    private func acceptRelay(_ flow: NEAppProxyFlow, selection: LabRelaySelection) -> Bool {
        guard let tcp = flow as? NEAppProxyTCPFlow, isProxyEndpoint(tcp),
              let source = ClaudeFlowSource(rawValue: flow.metaData.sourceAppSigningIdentifier),
              let token = flow.metaData.sourceAppAuditToken,
              token.count == MemoryLayout<audit_token_t>.size else { return false }
        let pid = audit_token_to_pid(token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) })
        guard let lineage = selection.claude.lineage(from: pid),
              source.verify(auditToken: token),
              selection.claude.lineage(from: pid) == lineage else { return false }

        let id = UUID()
        return stateLock.withLock {
            guard let session = state?.session, state?.relay?.claude == selection.claude else { return false }
            if source == .main { state?.counts.claudeMain += 1 } else { state?.counts.claudeHelper += 1 }
            guard let count = state?.connections.count, count < 32 else {
                state?.counts.relayFailures += 1
                state?.counts.relayFailureStages[ClaudeCONNECTRelay.Stage.capacity.rawValue, default: 0] += 1
                tcp.closeReadWithError(nil)
                tcp.closeWriteWithError(nil)
                return true
            }
            let connection = ClaudeCONNECTRelay(flow: tcp, ssh: selection.ssh) { [weak self] event in
                self?.recordRelay(event, source: source, session: session, id: id)
            }
            state?.connections[id] = connection
            connection.start()
            return true
        }
    }

    private func isProxyEndpoint(_ flow: NEAppProxyTCPFlow) -> Bool {
        if #available(macOS 15.0, *) {
            guard case let .hostPort(host, port) = flow.remoteFlowEndpoint else { return false }
            return host == .ipv4(.loopback) && port.rawValue == LabRelaySelection.proxyPort
        }
        guard let host = flow.remoteEndpoint as? NWHostEndpoint else { return false }
        return host.hostname == "127.0.0.1" && host.port == String(LabRelaySelection.proxyPort)
    }

    private func recordRelay(_ event: ClaudeCONNECTRelay.Event, source: ClaudeFlowSource, session: LabSession, id: UUID) {
        stateLock.withLock {
            guard state?.session == session else { return }
            switch (event, source) {
            case (.connected, .main):
                state?.counts.relayMainConnected += 1
                state?.counts.relayMainActive += 1
            case (.connected, .helper):
                state?.counts.relayHelperConnected += 1
                state?.counts.relayHelperActive += 1
            case (.bidirectional, .main): state?.counts.relayMainBidirectional += 1
            case (.bidirectional, .helper): state?.counts.relayHelperBidirectional += 1
            case (.bytesSent(let count), .main): state?.counts.relayMainSentBytes += count
            case (.bytesSent(let count), .helper): state?.counts.relayHelperSentBytes += count
            case (.bytesReceived(let count), .main): state?.counts.relayMainReceivedBytes += count
            case (.bytesReceived(let count), .helper): state?.counts.relayHelperReceivedBytes += count
            case (.unsupported(let reason), _):
                state?.counts.relayUnsupported += 1
                state?.counts.relayRejectionReasons[reason.rawValue, default: 0] += 1
            case (.failed(let stage), _):
                state?.counts.relayFailures += 1
                state?.counts.relayFailureStages[stage.rawValue, default: 0] += 1
            case (.finished(let wasConnected), _):
                if wasConnected {
                    if source == .main { state?.counts.relayMainActive -= 1 }
                    else { state?.counts.relayHelperActive -= 1 }
                }
                state?.connections.removeValue(forKey: id)
            }
        }
    }

    private func record(_ flow: NEAppProxyFlow) {
        guard let session = stateLock.withLock({ state?.relay == nil ? state?.session : nil }) else { return }
        let identifier = flow.metaData.sourceAppSigningIdentifier
        let auditToken = flow.metaData.sourceAppAuditToken
        let claudeSource = ClaudeFlowSource(rawValue: identifier)
        let verifiedClaude = claudeSource?.verify(auditToken: auditToken) ?? false

        stateLock.withLock {
            guard state?.session == session else { return }
            switch flow {
            case is NEAppProxyTCPFlow: state?.counts.tcp += 1
            case is NEAppProxyUDPFlow: state?.counts.udp += 1
            default: return
            }
            if identifier == LabProtocol.probeID {
                state?.counts.probeMatches += 1
                if auditToken != nil {
                    state?.counts.probeAuditTokenPresent += 1
                }
            } else if let claudeSource {
                switch (claudeSource, verifiedClaude) {
                case (.main, true): state?.counts.claudeMain += 1
                case (.helper, true): state?.counts.claudeHelper += 1
                case (_, false): state?.counts.claudeUnverified += 1
                }
            } else {
                state?.counts.otherSources += 1
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let request = try? JSONDecoder().decode(LabSession.self, from: messageData)
        let snapshot: LabSnapshot? = stateLock.withLock {
            guard let state, request == state.session else { return nil }
            return LabSnapshot(session: state.session, counts: state.counts)
        }
        completionHandler?(snapshot.flatMap { try? JSONEncoder().encode($0) })
    }
}

#if compiler(>=6.0)
@available(macOS 15.0, *)
extension ProxyProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint: Network.NWEndpoint) -> Bool {
        record(flow)
        return false
    }
}
#endif
