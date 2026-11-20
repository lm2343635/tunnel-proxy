import Foundation
import Network
import NetworkExtension

final class AppRoutingProvider: NETransparentProxyProvider {
    private struct State {
        let session: UUID
        let historyOwner: UUID?
        var rules: RoutingRules
        var peer: RoutingSOCKSPeer?
        var lastHeartbeat: UInt64?
        var relays: [UUID: RoutingTCPRelay] = [:]
    }

    private let lock = NSLock()
    private let history = RoutingHistoryWriter()
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
        let owner = (configuration.providerConfiguration?[AppRoutingProtocol.historyOwnerKey] as? String)
            .flatMap(UUID.init(uuidString:))
        lock.withLock { state = State(session: session, historyOwner: owner, rules: rules) }
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let self {
                if error == nil {
                    startWatchdog()
                    history.flush(prune: true)
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
        history.flush(completion: completionHandler)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if let request = try? JSONDecoder().decode(RoutingHistoryRequest.self, from: messageData) {
            let owner = lock.withLock { state?.session == request.historySession ? state?.historyOwner : nil }
            guard let owner else { completionHandler?(nil); return }
            history.transfer(for: owner, acknowledging: request.historyAcknowledgements, completion: completionHandler)
            return
        }
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
            return RoutingStatus(session: state.session, version: state.rules.version,
                                 tunnelReady: validated != nil)
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
        guard plan.decision == .proxy, plan.destination.socksCommand() != nil else {
            return block(flow, plan: plan, reason: plan.reason ?? "Destination unavailable")
        }
        let id = UUID()
        let relay = lock.withLock { () -> RoutingTCPRelay? in
            guard let state, state.session == plan.session, state.relays.count < 256,
                  let peer = currentPeer(state) else { return nil }
            let relay = RoutingTCPRelay(flow: flow, destination: plan.destination,
                                        sniff: plan.sniff, process: flow.metaData.sourceAppSigningIdentifier,
                                        port: peer.port, ownsSocket: peer.ownsSocket, peerIsCurrent: { [weak self] in
                guard let self else { return false }
                return lock.withLock { self.state.flatMap(self.currentPeer) == peer }
            }, onEvent: { [weak self] event, details in
                guard let self else { return }
                switch event {
                case .connected: record(plan, result: .proxy, reason: nil, tcp: details)
                case .blocked(let reason): record(plan, result: .blocked, reason: reason, tcp: details)
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
        let sniff: Bool
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
                        decision: decision, sniff: !local && app.policy == .proxyAll && destination.name == nil, reason: reason)
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

    private func record(_ plan: FlowPlan, result: RoutingDecision, reason: String?, tcp: RoutingTCPDetails? = nil) {
        remember(RoutingEvent(application: plan.application, destination: tcp?.recoveredName ?? plan.destination.display,
                              decision: result, reason: reason, tcp: tcp), in: plan.session)
    }

    private func remember(_ event: RoutingEvent, in session: UUID) {
        lock.withLock {
            guard state?.session == session, let owner = state?.historyOwner else { return }
            history.enqueue(event, for: owner)
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
            history.flush(prune: true)
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

private final class RoutingHistoryWriter: @unchecked Sendable {
    private struct PendingEvent {
        let owner: UUID
        let event: RoutingEvent
    }

    private let store = RoutingHistoryStore(filename: "routing-history-outbox.sqlite")
    private let queue = DispatchQueue(label: "com.xwkj.tunnelproxy.routing-history", qos: .utility)
    private let lock = NSLock()
    private let capacity = 4_096
    private var pending: [PendingEvent] = []
    private var writeScheduled = false
    private var droppedEvents = false
    // Accessed only on the writer queue.
    private var lastPrune: Date?
    private var writeFailed = false

    func enqueue(_ event: RoutingEvent, for owner: UUID) {
        let schedule = lock.withLock {
            guard pending.count < capacity else { droppedEvents = true; return false }
            pending.append(PendingEvent(owner: owner, event: event))
            guard !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.write() }
        }
    }

    func flush(prune: Bool = false, completion: (() -> Void)? = nil) {
        queue.async {
            self.write(prune: prune)
            completion?()
        }
    }

    func transfer(for owner: UUID, acknowledging ids: [UUID], completion: ((Data?) -> Void)?) {
        queue.async {
            self.write(prune: true)
            do {
                let events = try self.store.pending(for: owner, acknowledging: ids)
                completion?(try JSONEncoder().encode(RoutingHistoryReply(events: events)))
            } catch {
                completion?(nil)
            }
        }
    }

    private func write(prune: Bool = false) {
        let (batch, dropped) = lock.withLock {
            let result = (pending, droppedEvents)
            pending.removeAll(keepingCapacity: true)
            writeScheduled = false
            droppedEvents = false
            return result
        }
        if dropped { NSLog("App Routing history queue reached capacity") }
        let now = Date()
        let pruneDue = prune && lastPrune.map { now.timeIntervalSince($0) >= 60 } != false
        guard !batch.isEmpty || pruneDue else { return }
        do {
            if batch.isEmpty {
                try store.append([], now: now)
            } else {
                for (owner, items) in Dictionary(grouping: batch, by: \.owner) {
                    try store.append(items.map(\.event), owner: owner, now: now)
                }
            }
            lastPrune = now
            writeFailed = false
        } catch {
            if !writeFailed { NSLog("App Routing history write failed") }
            writeFailed = true
            lock.withLock { pending.insert(contentsOf: batch.suffix(capacity - pending.count), at: 0) }
        }
    }
}
