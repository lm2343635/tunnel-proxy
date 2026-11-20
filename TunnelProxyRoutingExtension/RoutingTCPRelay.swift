import Foundation
import Network
import NetworkExtension

protocol RoutingClientFlow: AnyObject {
    func openForRouting(_ completion: @escaping (Error?) -> Void)
    func readData(completionHandler: @escaping (Data?, Error?) -> Void)
    func write(_ data: Data, withCompletionHandler completionHandler: @escaping @Sendable (Error?) -> Void)
    func closeReadWithError(_ error: Error?)
    func closeWriteWithError(_ error: Error?)
}

extension NEAppProxyTCPFlow: RoutingClientFlow {
    func openForRouting(_ completion: @escaping (Error?) -> Void) {
        if #available(macOS 15, *) {
            open(withLocalFlowEndpoint: nil, completionHandler: completion)
        } else {
            open(withLocalEndpoint: nil, completionHandler: completion)
        }
    }
}

// All mutable relay state and upstream callbacks are confined to Self.queue.
final class RoutingTCPRelay: @unchecked Sendable {
    enum Event { case connected, blocked(String), finished }

    private static let queue = DispatchQueue(label: "com.xwkj.tunnelproxy.approuting.tcp")
    private static let chunk = 64 * 1024
    private let flow: RoutingClientFlow
    private let destination: RoutingDestination
    private let inspectHello: Bool
    private let ownsSocket: (Network.NWEndpoint?) -> Bool
    private let peerIsCurrent: () -> Bool
    private let onEvent: (Event, RoutingTCPDetails) -> Void
    private let connection: NWConnection
    private var details: RoutingTCPDetails
    private var sniffing = false
    private var reading = false
    private var writing = false
    private var pending = Data()
    private var connected = false
    private var closed = false
    private var clientEOF = false
    private var finSent = false
    private var sshEOF = false

    init(flow: RoutingClientFlow, destination: RoutingDestination, sniff: Bool, process: String,
         port: UInt16, ownsSocket: @escaping (Network.NWEndpoint?) -> Bool,
         peerIsCurrent: @escaping () -> Bool, onEvent: @escaping (Event, RoutingTCPDetails) -> Void) {
        self.flow = flow
        self.destination = destination
        inspectHello = sniff
        self.ownsSocket = ownsSocket
        self.peerIsCurrent = peerIsCurrent
        self.onEvent = onEvent
        details = RoutingTCPDetails(originalEndpoint: String(describing: Network.NWEndpoint.hostPort(
            host: destination.address, port: destination.port)), process: process, nameSource: destination.nameSource)
        connection = NWConnection(host: .ipv4(.loopback), port: .init(rawValue: port)!, using: .tcp)
    }

    func start() {
        Self.queue.async { [self] in
            guard !closed else { return }
            Self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                if self?.connected == false { self?.finish(reason: "Connection setup timed out") }
            }
            // Accept the application's connection first, then dial. The app's
            // connect() stays pending until the flow is opened, so a flow opened
            // only after the SOCKS handshake (a loopback connect plus two SSH
            // round trips) can already have been abandoned by the client — which
            // surfaces as "Could not open the application connection" on busy
            // apps that open several connections at once.
            openFlow()
        }
    }

    func cancel() { Self.queue.async { [self] in finish(reason: "Tunnel disconnected") } }

    private func openFlow() {
        guard peerIsCurrent() else { finish(reason: "Tunnel disconnected"); return }
        details.stage = "Opening app flow"
        flow.openForRouting { [weak self] error in
            Self.queue.async { [weak self] in
                guard let self, !closed else { return }
                guard error == nil else { finish(reason: "Could not open the application connection"); return }
                if inspectHello {
                    sniffing = true
                    details.stage = "Reading TLS hello"
                    Self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                        if self?.sniffing == true { self?.endSniff(source: "SNI timeout") }
                    }
                    readClient()
                } else { connect() }
            }
        }
    }

    private func endSniff(source: String, hostname: String? = nil) {
        guard sniffing, !closed else { return }
        sniffing = false
        details.nameSource = source
        details.recoveredName = hostname
        connect()
    }

    private func connect() {
        guard peerIsCurrent() else { finish(reason: "Tunnel identity not verified"); return }
        details.stage = "Connecting to SOCKS"
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !closed else { return }
            switch state {
            case .ready: verifyPeer()
            case .waiting, .failed: finish(reason: connected ? "Tunnel disconnected" : "SSH connection unavailable")
            default: break
            }
        }
        connection.start(queue: Self.queue)
    }

    private func verifyPeer(retries: Int = 10) {
        guard !closed else { return }
        details.stage = "Verifying tunnel"
        guard peerIsCurrent() else { finish(reason: "Tunnel identity not verified"); return }
        if ownsSocket(connection.currentPath?.localEndpoint) {
            negotiate()
        } else if retries > 0 {
            Self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.verifyPeer(retries: retries - 1)
            }
        } else { finish(reason: "Tunnel identity not verified") }
    }

    private func negotiate() {
        details.stage = "SOCKS greeting"
        send(Data([5, 1, 0])) { [weak self] in
            self?.receive(2) { [weak self] data in
                guard let self else { return }
                guard data == Data([5, 0]) else { finish(reason: "SSH rejected SOCKS negotiation"); return }
                guard peerIsCurrent(), ownsSocket(connection.currentPath?.localEndpoint) else {
                    finish(reason: "Tunnel identity not verified")
                    return
                }
                guard let command = destination.socksCommand(recoveredName: details.recoveredName) else {
                    finish(reason: "Destination unavailable")
                    return
                }
                details.stage = "SOCKS CONNECT"
                send(command) { [weak self] in
                    self?.details.addressType = command[3]
                    self?.readReply()
                }
            }
        }
    }

    private func readReply() {
        receive(4) { [weak self] reply in
            guard let self else { return }
            guard reply[0] == 5, reply[2] == 0 else { finish(reason: "Malformed SOCKS reply"); return }
            guard reply[1] == 0 else {
                details.replyCode = reply[1]
                finish(reason: "SSH could not reach the destination")
                return
            }
            switch reply[3] {
            case 1: readBoundAddress(6)
            case 4: readBoundAddress(18)
            case 3: receive(1) { [weak self] data in
                guard data[0] > 0 else { self?.finish(reason: "Malformed SOCKS reply"); return }
                self?.readBoundAddress(Int(data[0]) + 2)
            }
            default: finish(reason: "Malformed SOCKS reply")
            }
        }
    }

    private func readBoundAddress(_ length: Int) {
        receive(length) { [weak self] _ in
            guard let self else { return }
            beginForwarding()
        }
    }

    private func beginForwarding() {
        guard peerIsCurrent() else { finish(reason: "Tunnel disconnected"); return }
        connected = true
        details.stage = "Forwarding"
        onEvent(.connected, details)
        readSSH()
        pumpClient()
    }

    private func readClient() {
        guard !reading, !clientEOF else { return }
        reading = true
        flow.readData { [weak self] data, error in
            Self.queue.async { [weak self] in
                guard let self, !closed else { return }
                reading = false
                guard error == nil, peerIsCurrent() else { finish(reason: "Tunnel disconnected"); return }
                if let data, !data.isEmpty {
                    // One read in flight at a time already bounds retained data;
                    // a single callback can legitimately carry more than 64 KiB
                    // (the flow's receive buffer is not ours to size), so it must
                    // never be treated as an error — aborting on it killed busy
                    // HTTP/2 connections mid-transfer.
                    pending.append(data)
                } else {
                    clientEOF = true
                    flow.closeReadWithError(nil)
                }
                if sniffing {
                    switch RoutingSniffer.sniffTLS(pending) {
                    case .hostname(let name): endSniff(source: "TLS SNI", hostname: name)
                    case .echOrGrease: endSniff(source: "ECH or GREASE")
                    case .needMoreData where !clientEOF: readClient()
                    default: endSniff(source: "No usable SNI")
                    }
                } else { pumpClient() }
            }
        }
    }

    // While CONNECT is pending no new read is issued. One late read may
    // append to a partial hello; one read is outstanding at a time.
    private func pumpClient() {
        guard connected, !closed, !writing else { return }
        if !pending.isEmpty {
            let data = pending
            pending = Data()
            writing = true
            send(data) { [weak self] in
                self?.writing = false
                self?.pumpClient()
            }
        } else if clientEOF {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] error in
                guard let self, !closed else { return }
                finSent = true
                if error != nil || sshEOF { finish() }
            })
        } else { readClient() }
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
        if finSent { finish() }
    }

    private func receive(_ count: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !closed else { return }
            guard error == nil, let data, data.count == count else {
                finish(reason: details.stage == "SOCKS greeting"
                       ? "Connection closed during SOCKS greeting" : "Connection closed during SOCKS CONNECT")
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
        if let reason { onEvent(.blocked(reason), details) }
        onEvent(.finished, details)
    }
}
