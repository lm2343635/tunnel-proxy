import Foundation
import Network
import NetworkExtension

enum LabSOCKSRequest {
    enum Rejection: String, Error {
        case headerLimit = "Header limit"
        case unknownProtocol = "Unknown proxy protocol"
        case plainHTTP = "HTTP method other than CONNECT"
        case requestLine = "Malformed CONNECT request line"
        case httpVersion = "Unsupported CONNECT HTTP version"
        case authority = "Invalid CONNECT authority"
        case literalIP = "Literal IP authority"
        case port = "Port outside HTTPS scope"
        case domain = "Domain outside scope"
    }

    // Parse CONNECT alone. Ordinary HTTP URIs and headers are never decoded.
    static func command(for line: Data) -> Result<Data, Rejection> {
        let methods = ["GET ", "POST ", "HEAD ", "PUT ", "PATCH ", "DELETE ", "OPTIONS ",
                       "TRACE ", "PROPFIND ", "REPORT "]
        guard line.starts(with: Data("CONNECT ".utf8)) else {
            return .failure(methods.contains { line.starts(with: Data($0.utf8)) } ? .plainHTTP : .unknownProtocol)
        }
        guard let line = String(data: line, encoding: .ascii) else { return .failure(.requestLine) }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.requestLine) }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .failure(.httpVersion)
        }
        let authority = parts[1]
        if authority.hasPrefix("[") {
            guard let bracket = authority.firstIndex(of: "]"),
                  IPv6Address(String(authority.dropFirst().prefix(upTo: bracket))) != nil,
                  authority.suffix(from: authority.index(after: bracket)).hasPrefix(":"),
                  UInt16(authority.suffix(from: authority.index(after: bracket)).dropFirst()) != nil else {
                return .failure(.authority)
            }
            return .failure(.literalIP)
        }
        let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard hostAndPort.count == 2, !hostAndPort[0].isEmpty,
              UInt16(hostAndPort[1]) != nil else { return .failure(.authority) }
        let host = hostAndPort[0].lowercased()
        if IPv4Address(host) != nil { return .failure(.literalIP) }
        let domains = ["claude.ai", "claude.com", "anthropic.com"]
        guard host.utf8.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return .failure(.authority) }
        guard hostAndPort[1] == "443" else { return .failure(.port) }
        guard domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            return .failure(.domain)
        }
        return .success(Data([5, 1, 0, 3, UInt8(host.utf8.count)] + host.utf8 + [1, 187]))
    }
}

final class ClaudeCONNECTRelay {
    enum Stage: String {
        case capacity = "Flow capacity"
        case openingClient = "Open client flow"
        case readingHeader = "Read proxy request"
        case sshConnection = "Connect to SSH listener"
        case sshIdentity = "Verify SSH socket owner"
        case socksMethod = "SOCKS method"
        case socksRequest = "SOCKS CONNECT"
        case proxyResponse = "Write proxy response"
        case readingClient = "Read client payload"
        case sendingSSH = "Write SSH payload"
        case readingSSH = "Read SSH payload"
        case sendingClient = "Write client payload"
    }

    enum Event {
        case connected, bidirectional
        case bytesSent(Int), bytesReceived(Int)
        case unsupported(LabSOCKSRequest.Rejection)
        case failed(Stage)
        case finished(connected: Bool)
    }

    private static let maxHeader = 16 * 1024
    private static let maxChunk = 64 * 1024
    private static let headerEnd = Data([13, 10, 13, 10])
    private static let lineEnd = Data([13, 10])
    private static let relayQueue = DispatchQueue(label: "com.xwkj.tunnelproxy.lab.connect")

    private let flow: NEAppProxyTCPFlow
    private let ssh: LabProcessIdentity
    private let onEvent: (Event) -> Void
    private let connection = NWConnection(host: .ipv4(.loopback), port: 1080, using: .tcp)
    private var header = Data()
    private var closed = false
    private var connected = false
    private var sent = false
    private var received = false
    private var stage = Stage.openingClient

    init(flow: NEAppProxyTCPFlow, ssh: LabProcessIdentity, onEvent: @escaping (Event) -> Void) {
        self.flow = flow
        self.ssh = ssh
        self.onEvent = onEvent
    }

    func start() {
        Self.relayQueue.async { [self] in
            guard !closed else { return }
            Self.relayQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !connected else { return }
                finish(.failed(stage))
            }
            Self.relayQueue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.finish() }
            let completion: (Error?) -> Void = { [weak self] error in
                Self.relayQueue.async { [weak self] in
                    guard let self, !closed else { return }
                    if error == nil {
                        stage = .readingHeader
                        readHeader()
                    } else {
                        finish(.failed(.openingClient))
                    }
                }
            }
            if #available(macOS 15.0, *) {
                flow.open(withLocalFlowEndpoint: nil, completionHandler: completion)
            } else {
                flow.open(withLocalEndpoint: nil, completionHandler: completion)
            }
        }
    }

    func cancel() { Self.relayQueue.async { [self] in finish() } }

    private func readHeader() {
        flow.readData { [weak self] data, error in
            Self.relayQueue.async { [weak self] in
                guard let self, !closed else { return }
                guard error == nil, let data, !data.isEmpty else { finish(.failed(.readingHeader)); return }
                guard data.count <= Self.maxChunk else { finish(.unsupported(.headerLimit)); return }
                header.append(data)
                guard let end = header.range(of: Self.headerEnd) else {
                    if header.count >= Self.maxHeader { finish(.unsupported(.headerLimit)) } else { readHeader() }
                    return
                }
                guard end.upperBound <= Self.maxHeader, let firstLine = header.range(of: Self.lineEnd) else {
                    finish(.unsupported(.headerLimit))
                    return
                }
                switch LabSOCKSRequest.command(for: header.prefix(firstLine.lowerBound)) {
                case .success(let request):
                    let remainder = Data(header.dropFirst(end.upperBound))
                    header.removeAll()
                    openSOCKS(request, remainder: remainder)
                case .failure(let reason):
                    finish(.unsupported(reason))
                }
            }
        }
    }

    private func openSOCKS(_ request: Data, remainder: Data) {
        stage = .sshConnection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !closed else { return }
            switch state {
            case .ready:
                stage = .sshIdentity
                verifyPeer { [weak self] in self?.negotiate(request, remainder: remainder) }
            case .failed, .cancelled:
                finish(.failed(stage))
            default:
                break
            }
        }
        connection.start(queue: Self.relayQueue)
    }

    private func verifyPeer(retries: Int = 10, completion: @escaping () -> Void) {
        guard !closed else { return }
        if LabSSHSocket.isOwned(connection.currentPath?.localEndpoint, by: ssh) {
            completion()
        } else if retries > 0 {
            Self.relayQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.verifyPeer(retries: retries - 1, completion: completion)
            }
        } else {
            finish(.failed(.sshIdentity))
        }
    }

    private func negotiate(_ request: Data, remainder: Data) {
        stage = .socksMethod
        send(Data([5, 1, 0]), stage: .socksMethod) { [weak self] in
            self?.receive(2) { [weak self] method in
                guard let self else { return }
                guard method == Data([5, 0]) else { finish(.failed(.socksMethod)); return }
                guard LabSSHSocket.isOwned(connection.currentPath?.localEndpoint, by: ssh) else {
                    finish(.failed(.sshIdentity))
                    return
                }
                stage = .socksRequest
                send(request, stage: .socksRequest) { [weak self] in self?.readSOCKSReply(remainder: remainder) }
            }
        }
    }

    private func readSOCKSReply(remainder: Data) {
        receive(4) { [weak self] reply in
            guard let self else { return }
            guard reply.prefix(3) == Data([5, 0, 0]) else { finish(.failed(.socksRequest)); return }
            switch reply[3] {
            case 1: receive(6) { [weak self] _ in self?.respond(remainder: remainder) }
            case 4: receive(18) { [weak self] _ in self?.respond(remainder: remainder) }
            case 3:
                receive(1) { [weak self] length in
                    self?.receive(Int(length[0]) + 2) { [weak self] _ in self?.respond(remainder: remainder) }
                }
            default: finish(.failed(.socksRequest))
            }
        }
    }

    private func respond(remainder: Data) {
        connected = true
        stage = .proxyResponse
        onEvent(.connected)
        let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        flow.write(response) { [weak self] error in
            Self.relayQueue.async { [weak self] in
                guard let self, !closed else { return }
                guard error == nil else { finish(.failed(.proxyResponse)); return }
                readSSH()
                if remainder.isEmpty { readClient() } else { sendClient(remainder) }
            }
        }
    }

    private func readClient() {
        flow.readData { [weak self] data, error in
            Self.relayQueue.async { [weak self] in
                guard let self, !closed else { return }
                guard error == nil else { finish(.failed(.readingClient)); return }
                guard let data, !data.isEmpty else { finish(); return }
                guard data.count <= Self.maxChunk else { finish(.failed(.readingClient)); return }
                sendClient(data)
            }
        }
    }

    private func sendClient(_ data: Data) {
        send(data, stage: .sendingSSH) { [weak self] in
            guard let self else { return }
            onEvent(.bytesSent(data.count))
            if !sent {
                sent = true
                if received { onEvent(.bidirectional) }
            }
            readClient()
        }
    }

    private func readSSH() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxChunk) { [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            guard error == nil else { finish(.failed(.readingSSH)); return }
            guard let data, !data.isEmpty else { finish(); return }
            flow.write(data) { [weak self] error in
                Self.relayQueue.async { [weak self] in
                    guard let self, !closed else { return }
                    guard error == nil else { finish(.failed(.sendingClient)); return }
                    onEvent(.bytesReceived(data.count))
                    if !received {
                        received = true
                        if sent { onEvent(.bidirectional) }
                    }
                    if complete { finish() } else { readSSH() }
                }
            }
        }
    }

    private func send(_ data: Data, stage: Stage, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !closed else { return }
            if error == nil { completion() } else { finish(.failed(stage)) }
        })
    }

    private func receive(_ count: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !closed else { return }
            guard error == nil, let data, data.count == count else { finish(.failed(stage)); return }
            completion(data)
        }
    }

    private func finish(_ reason: Event? = nil) {
        guard !closed else { return }
        closed = true
        header.removeAll()
        connection.stateUpdateHandler = nil
        connection.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        if let reason { onEvent(reason) }
        onEvent(.finished(connected: connected))
    }
}
