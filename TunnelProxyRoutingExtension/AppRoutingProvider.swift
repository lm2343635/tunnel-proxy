import Foundation
import Network
import NetworkExtension

final class AppRoutingProvider: NETransparentProxyProvider {
    private struct State {
        let session: UUID
        var rules: RoutingRules
        var peer: RoutingSOCKSPeer?
        var lastHeartbeat: UInt64?
        var relays: [UUID: RoutingTCPRelay] = [:]
        var events: [RoutingEvent] = []
    }

    private let lock = NSLock()
    private var state: State?
    private var timer: DispatchSourceTimer?
    private let heartbeatLimit: UInt64 = 15_000_000_000

    override func startProxy(options: [String: Any]? = nil,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
              let data = configuration.providerConfiguration?[AppRoutingProtocol.rulesKey] as? Data,
              let rules = try? JSONDecoder().decode(RoutingRules.self, from: data),
              let sessionText = configuration.providerConfiguration?[AppRoutingProtocol.sessionKey] as? String,
              let session = UUID(uuidString: sessionText) else {
            completionHandler(NSError(domain: AppRoutingProtocol.providerIdentifier, code: 1))
            return
        }
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            networkRule(.TCP),
            networkRule(.UDP)
        ]
        lock.withLock { state = State(session: session, rules: rules) }
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let self {
                if error == nil {
                    startWatchdog()
                } else {
                    lock.withLock { if self.state?.session == session { self.state = nil } }
                }
            }
            completionHandler(error)
        }
    }

    private func networkRule(_ networkProtocol: NENetworkRule.`Protocol`) -> NENetworkRule {
        if #available(macOS 15, *) {
            return NENetworkRule(remoteNetworkEndpoint: nil,
                                 remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                                 protocol: networkProtocol, direction: .outbound)
        }
        return NENetworkRule(remoteNetwork: nil,
                             remotePrefix: 0, localNetwork: nil, localPrefix: 0,
                             protocol: networkProtocol, direction: .outbound)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let actions = lock.withLock {
            let active = state.map { Array($0.relays.values) } ?? []
            let watchdog = timer
            timer = nil
            state = nil
            return (active, watchdog)
        }
        actions.1?.cancel()
        for relay in actions.0 { relay.cancel() }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let message = try? JSONDecoder().decode(RoutingControl.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        let validated = message.tunnel.flatMap { $0.port != 0 && $0.isCurrent ? $0 : nil }
        var cancelled: [RoutingTCPRelay] = []
        let status = lock.withLock { () -> RoutingStatus? in
            guard state?.session == message.session else { return nil }
            if let rules = message.rules, message.version == rules.version { state?.rules = rules }
            if state?.peer != validated {
                cancelled = state.map { Array($0.relays.values) } ?? []
                state?.relays.removeAll()
            }
            state?.peer = validated
            state?.lastHeartbeat = DispatchTime.now().uptimeNanoseconds
            guard let state else { return nil }
            let events = message.eventApp.map { id in state.events.filter { $0.application == id } } ?? []
            return RoutingStatus(session: state.session, version: state.rules.version,
                                 tunnelReady: validated != nil, events: events)
        }
        for relay in cancelled { relay.cancel() }
        completionHandler?(status.flatMap { try? JSONEncoder().encode($0) })
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow { return routeTCP(tcp) }
        // Endpoint-bearing UDP arrives via its protocol-specific callback.
        return blockUnresolved(flow)
    }

    private func routeTCP(_ flow: NEAppProxyTCPFlow) -> Bool {
        let endpoint: Network.NWEndpoint
        if #available(macOS 15, *) {
            endpoint = flow.remoteFlowEndpoint
        } else {
            guard let legacy = flow.remoteEndpoint as? NWHostEndpoint,
                  let port = Network.NWEndpoint.Port(legacy.port) else { return blockUnresolved(flow) }
            endpoint = .hostPort(host: .init(legacy.hostname), port: port)
        }
        guard let plan = plan(flow, remote: endpoint) else { return blockUnresolved(flow) }
        if plan.decision == .direct {
            record(plan, result: .direct, reason: plan.reason)
            return false
        }
        guard plan.decision == .proxy, let command = plan.destination.socksCommand else {
            return block(flow, plan: plan, reason: plan.reason ?? "Destination unavailable")
        }
        let id = UUID()
        let relay = lock.withLock { () -> RoutingTCPRelay? in
            guard let state, state.session == plan.session, state.relays.count < 256,
                  let peer = currentPeer(state) else { return nil }
            let relay = RoutingTCPRelay(flow: flow, command: command, peer: peer, peerIsCurrent: { [weak self] in
                guard let self else { return false }
                return lock.withLock { self.state.flatMap(self.currentPeer) == peer }
            }, onEvent: { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected: record(plan, result: .proxy, reason: nil)
                case .blocked(let reason): record(plan, result: .blocked, reason: reason)
                case .finished:
                    lock.withLock { if self.state?.session == plan.session { self.state?.relays.removeValue(forKey: id) } }
                }
            })
            self.state?.relays[id] = relay
            return relay
        }
        guard let relay else { return block(flow, plan: plan, reason: "Tunnel identity not verified") }
        relay.start()
        return true
    }

    override func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteEndpoint endpoint: TPRoutingLegacyEndpoint) -> Bool {
        guard let host = endpoint as? NWHostEndpoint,
              let port = Network.NWEndpoint.Port(host.port) else { return blockUnresolved(flow) }
        return routeUDP(flow, remote: .hostPort(host: .init(host.hostname), port: port))
    }

    fileprivate func routeUDP(_ flow: NEAppProxyUDPFlow, remote: Network.NWEndpoint) -> Bool {
        guard let plan = plan(flow, remote: remote) else { return blockUnresolved(flow) }
        if plan.decision == .direct {
            record(plan, result: .direct, reason: plan.reason)
            return false
        }
        return block(flow, plan: plan, reason: plan.reason ?? "UDP cannot use the SSH tunnel")
    }

    private struct FlowPlan {
        let session: UUID
        let application: RoutingAppIdentity
        let destination: RoutingDestination
        let decision: RoutingDecision
        let reason: String?
    }

    private func plan(_ flow: NEAppProxyFlow, remote: Network.NWEndpoint) -> FlowPlan? {
        guard let selection = lock.withLock({ state.map { ($0.session, $0.rules.apps) } }),
              let app = RoutingAttribution.application(for: flow.metaData, in: selection.1),
              let destination = RoutingDestination(hostname: flow.remoteHostname, endpoint: remote) else { return nil }
        let local = destination.isLocal
        let decision = local ? .direct : app.policy.decision(hostname: destination.name, domains: app.domains)
        let reason = local ? "Local network" : (decision == .blocked ? "Hostname unavailable" : nil)
        return FlowPlan(session: selection.0, application: app.identity, destination: destination,
                        decision: decision, reason: reason)
    }

    private func block(_ flow: NEAppProxyFlow, plan: FlowPlan, reason: String) -> Bool {
        close(flow)
        record(plan, result: .blocked, reason: reason)
        return true
    }

    private func blockUnresolved(_ flow: NEAppProxyFlow) -> Bool {
        guard let selection = lock.withLock({ state.map { ($0.session, $0.rules.apps) } }),
              let app = RoutingAttribution.application(for: flow.metaData, in: selection.1),
              app.policy != .directAll else { return false }
        close(flow)
        remember(RoutingEvent(application: app.identity, destination: "", decision: .blocked,
                              reason: "Destination unavailable"), in: selection.0)
        return true
    }

    private func close(_ flow: NEAppProxyFlow) {
        let error = NSError(domain: "TunnelProxy.AppRouting", code: 1)
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }

    private func record(_ plan: FlowPlan, result: RoutingDecision, reason: String?) {
        remember(RoutingEvent(application: plan.application, destination: plan.destination.display,
                              decision: result, reason: reason), in: plan.session)
    }

    private func remember(_ event: RoutingEvent, in session: UUID) {
        lock.withLock {
            guard state?.session == session else { return }
            if let events = state?.events,
               events.lazy.filter({ $0.application == event.application }).count >= 50,
               let first = events.firstIndex(where: { $0.application == event.application }) {
                state?.events.remove(at: first)
            }
            state?.events.append(event)
        }
    }

    private func currentPeer(_ state: State) -> RoutingSOCKSPeer? {
        guard let last = state.lastHeartbeat,
              DispatchTime.now().uptimeNanoseconds - last < heartbeatLimit else { return nil }
        return state.peer
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let expired = lock.withLock { () -> [RoutingTCPRelay] in
                guard let state = self.state, state.peer != nil, self.currentPeer(state) == nil else { return [] }
                self.state?.peer = nil
                self.state?.relays.removeAll()
                return Array(state.relays.values)
            }
            for relay in expired { relay.cancel() }
        }
        lock.withLock {
            self.timer?.cancel()
            self.timer = timer
            timer.resume()
        }
    }
}

#if compiler(>=6.0)
@available(macOS 15.0, *)
extension AppRoutingProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint: Network.NWEndpoint) -> Bool {
        routeUDP(flow, remote: initialRemoteFlowEndpoint)
    }
}
#endif
