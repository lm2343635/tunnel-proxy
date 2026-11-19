import Foundation
import Network
import NetworkExtension

final class RoutingTCPRelay {
    enum Event { case connected, blocked(String), finished }

    private static let queue = DispatchQueue(label: "com.xwkj.tunnelproxy.approuting.tcp")
    private static let chunk = 64 * 1024
    private let flow: NEAppProxyTCPFlow
    private let command: Data
    private let peer: RoutingSOCKSPeer
    private let peerIsCurrent: () -> Bool
    private let onEvent: (Event) -> Void
    private let connection: NWConnection
    private var connected = false
    private var closed = false
    private var clientEOF = false
    private var sshEOF = false

    init(flow: NEAppProxyTCPFlow, command: Data, peer: RoutingSOCKSPeer,
         peerIsCurrent: @escaping () -> Bool, onEvent: @escaping (Event) -> Void) {
        self.flow = flow
        self.command = command
        self.peer = peer
        self.peerIsCurrent = peerIsCurrent
        self.onEvent = onEvent
        connection = NWConnection(host: .ipv4(.loopback), port: .init(rawValue: peer.port)!, using: .tcp)
    }

    func start() {
        Self.queue.async { [self] in
            guard !closed else { return }
            Self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                if self?.connected == false { self?.finish(reason: "SSH connection timed out") }
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !closed else { return }
                switch state {
                case .ready: verifyPeer()
                case .waiting, .failed: finish(reason: "SSH connection unavailable")
                default: break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    func cancel() { Self.queue.async { [self] in finish() } }

    private func verifyPeer(retries: Int = 10) {
        guard !closed else { return }
        guard peerIsCurrent() else { finish(reason: "Tunnel identity not verified"); return }
        if peer.ownsSocket(connection.currentPath?.localEndpoint) {
            negotiate()
        } else if retries > 0 {
            Self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.verifyPeer(retries: retries - 1)
            }
        } else {
            finish(reason: "Tunnel identity not verified")
        }
    }

    private func negotiate() {
        send(Data([5, 1, 0])) { [weak self] in
            self?.receive(2) { [weak self] data in
                guard let self else { return }
                guard data == Data([5, 0]) else { finish(reason: "SSH rejected SOCKS negotiation"); return }
                guard peerIsCurrent(), peer.ownsSocket(connection.currentPath?.localEndpoint) else {
                    finish(reason: "Tunnel identity not verified")
                    return
                }
                send(command) { [weak self] in self?.readReply() }
            }
        }
    }

    private func readReply() {
        receive(4) { [weak self] reply in
            guard let self else { return }
            guard reply.prefix(3) == Data([5, 0, 0]) else {
                finish(reason: "SSH could not reach the destination")
                return
            }
            switch reply[3] {
            case 1: receive(6) { [weak self] _ in self?.openFlow() }
            case 4: receive(18) { [weak self] _ in self?.openFlow() }
            case 3:
                receive(1) { [weak self] data in
                    self?.receive(Int(data[0]) + 2) { [weak self] _ in self?.openFlow() }
                }
            default: finish(reason: "SSH rejected SOCKS negotiation")
            }
        }
    }

    private func openFlow() {
        guard peerIsCurrent() else { finish(reason: "Tunnel disconnected"); return }
        let completion: (Error?) -> Void = { [weak self] error in
            Self.queue.async { [weak self] in
                guard let self, !closed else { return }
                guard error == nil else { finish(reason: "Could not open the application connection"); return }
                connected = true
                onEvent(.connected)
                readClient()
                readSSH()
            }
        }
        if #available(macOS 15, *) {
            flow.open(withLocalFlowEndpoint: nil, completionHandler: completion)
        } else {
            flow.open(withLocalEndpoint: nil, completionHandler: completion)
        }
    }

    private func readClient() {
        flow.readData { [weak self] data, error in
            Self.queue.async { [weak self] in
                guard let self, !closed else { return }
                guard error == nil, peerIsCurrent() else { finish(reason: "Tunnel disconnected"); return }
                guard let data, !data.isEmpty else {
                    clientEOF = true
                    flow.closeReadWithError(nil)
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { [weak self] error in
                        guard let self, !closed else { return }
                        if error != nil || sshEOF { finish() }
                    })
                    return
                }
                guard data.count <= Self.chunk else { finish(reason: "Application data exceeded the relay buffer"); return }
                send(data) { [weak self] in self?.readClient() }
            }
        }
    }

    private func readSSH() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            guard error == nil, peerIsCurrent() else { finish(reason: "Tunnel disconnected"); return }
            guard let data, !data.isEmpty else { finishSSHRead(); return }
            flow.write(data) { [weak self] error in
                Self.queue.async { [weak self] in
                    guard let self, !closed else { return }
                    if error != nil { finish() }
                    else if complete { finishSSHRead() }
                    else { readSSH() }
                }
            }
        }
    }

    private func finishSSHRead() {
        sshEOF = true
        flow.closeWriteWithError(nil)
        if clientEOF { finish() }
    }

    private func receive(_ count: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !closed else { return }
            guard error == nil, let data, data.count == count else {
                finish(reason: "SSH rejected SOCKS negotiation")
                return
            }
            completion(data)
        }
    }

    private func send(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !closed else { return }
            if error == nil { completion() } else { finish(reason: "Tunnel disconnected") }
        })
    }

    private func finish(reason: String? = nil) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let error = NSError(domain: "TunnelProxy.AppRouting", code: 1)
        flow.closeReadWithError(reason == nil ? nil : error)
        flow.closeWriteWithError(reason == nil ? nil : error)
        if let reason { onEvent(.blocked(reason)) }
        onEvent(.finished)
    }
}
