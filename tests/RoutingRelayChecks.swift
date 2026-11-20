import Darwin
import Foundation
import Network

// The extension owns the flow on its serial queue. Supply deterministic reads
// and use a real loopback SOCKS socket to exercise the production relay.
private final class FixtureFlow: RoutingClientFlow {
    var inputs: [Data]
    var delayedFirst: Bool
    var opened = false
    var reads = 0
    var received = Data()
    private var outstanding = false
    private var waitingForGreeting: (() -> Void)?

    init(_ inputs: [Data], delayedFirst: Bool) {
        self.inputs = inputs
        self.delayedFirst = delayedFirst
    }

    func openForRouting(_ completion: @escaping (Error?) -> Void) {
        precondition(!opened)
        opened = true
        completion(nil)
    }

    func readData(completionHandler: @escaping (Data?, Error?) -> Void) {
        precondition(opened && !outstanding)
        outstanding = true
        reads += 1
        let next = inputs.isEmpty ? Data() : inputs.removeFirst()
        if delayedFirst && reads == 1 {
            waitingForGreeting = {
                self.outstanding = false
                completionHandler(next, nil)
            }
        } else {
            outstanding = false
            completionHandler(next, nil)
        }
    }

    func write(_ data: Data, withCompletionHandler completionHandler: @escaping @Sendable (Error?) -> Void) {
        received.append(data)
        waitingForGreeting?()
        waitingForGreeting = nil
        completionHandler(nil)
    }
    func closeReadWithError(_ error: Error?) {}
    func closeWriteWithError(_ error: Error?) {}
}

enum RoutingRelayChecks {
    private static func length(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(truncatingIfNeeded: n)] }

    private static func hello(name: String = "test.example", ech: Bool = false, visibleSNI: Bool = true) -> Data {
        let bytes = Array(name.utf8)
        let entry = [0] + length(bytes.count) + bytes
        let sni = length(entry.count) + entry
        var fields: [UInt8] = visibleSNI ? [0, 0] + length(sni.count) + sni : []
        if ech { fields += [0xfe, 0x0d, 0, 1, 0] }
        var body: [UInt8] = [3, 3] + Array(repeating: 0, count: 32)
        body += [0, 0, 2, 0x13, 1, 1, 0]
        body += length(fields.count) + fields
        let handshake = [1, 0] + length(body.count) + body
        // Split the handshake header itself across TLS records.
        return [handshake.prefix(2), handshake.dropFirst(2)].reduce(into: Data()) { output, part in
            output.append(contentsOf: [22, 3, 3] + length(part.count) + part)
        }
    }

    static func parser() {
        let valid = hello()
        precondition(RoutingSniffer.sniffTLS(valid) == .hostname("test.example"))
        for cut in 0..<valid.count { precondition(RoutingSniffer.sniffTLS(valid.prefix(cut)) == .needMoreData) }
        // GREASE ECH keeps the plaintext name next to the 0xfe0d extension.
        precondition(RoutingSniffer.sniffTLS(hello(ech: true)) == .hostname("test.example"))
        // Real ECH leaves no usable name at all.
        precondition(RoutingSniffer.sniffTLS(hello(ech: true, visibleSNI: false)) == .echOrGrease)
        precondition(RoutingSniffer.sniffTLS(hello(name: "192.0.2.12")) == .notApplicable)
        precondition(RoutingSniffer.sniffTLS(Data("GET /".utf8)) == .notApplicable)
        var malformed = valid
        malformed[malformed.count - "test.example".count - 1] = 255
        precondition(RoutingSniffer.sniffTLS(malformed) == .notApplicable)
        var oversized = Data([22, 3, 3, 0x40, 0, 1, 0, 0x40, 0])
        oversized.append(Data(repeating: 0, count: RoutingSniffer.window))
        precondition(RoutingSniffer.sniffTLS(oversized) == .notApplicable)
        print("PASS: TLS SNI, split records and reads, ECH/GREASE, bounds and malformed inputs")
    }

    static func relays() {
        for scenario in Scenario.allCases { run(scenario) }
    }

    private static func readExactly(_ fd: Int32, _ length: Int) -> Data {
        var result = Data()
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: length - result.count)
            let count = Darwin.read(fd, &bytes, bytes.count)
            precondition(count > 0, "short fixture read")
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }

    private enum Scenario: CaseIterable { case sni, serverFirst, ech, earlyEOF, knownName, cancelled, stalled }

    private static func run(_ scenario: Scenario) {
        let stall = scenario == .stalled
        let delayed = scenario == .serverFirst
        let byIP = delayed || scenario == .ech || scenario == .earlyEOF
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(address.sin_len)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                precondition(bind(listener, $0, size) == 0, "fixture needs loopback access")
                precondition(getsockname(listener, $0, &size) == 0)
            }
        }
        precondition(listen(listener, 1) == 0)
        let endpoint = NWEndpoint.hostPort(host: "192.0.2.12", port: 443)
        let destination = RoutingDestination(hostname: scenario == .knownName ? "test.example" : nil, endpoint: endpoint)!
        let prefix = hello(ech: scenario == .ech, visibleSNI: scenario != .ech) + Data(repeating: 0x55, count: 18_000)
        let tail = Data("next application bytes".utf8)
        let flow = FixtureFlow(scenario == .earlyEOF ? [] : [prefix, tail], delayedFirst: delayed)
        let done = DispatchSemaphore(value: 0)
        var connected = false
        var failure: String?
        let relay = RoutingTCPRelay(flow: flow, destination: destination, sniff: scenario != .knownName, process: "fixture",
                                    port: UInt16(bigEndian: address.sin_port), ownsSocket: { _ in true },
                                    peerIsCurrent: { true }) { event, details in
            switch event {
            case .connected:
                connected = true
                precondition(details.addressType == (byIP ? 1 : 3))
                let expectedSources: [Scenario: String] = [.serverFirst: "SNI timeout", .ech: "ECH or GREASE",
                                                          .earlyEOF: "No usable SNI", .knownName: "remoteHostname"]
                precondition(details.nameSource == (expectedSources[scenario] ?? "TLS SNI"))
            case .blocked(let reason):
                failure = reason
                if stall { precondition(details.stage == "SOCKS CONNECT") }
            case .finished: done.signal()
            }
        }
        relay.start()
        defer { withExtendedLifetime(relay) {} }
        var listening = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        precondition(poll(&listening, 1, 5000) == 1)
        let fd = accept(listener, nil, nil)
        precondition(fd >= 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        precondition(readExactly(fd, 3) == Data([5, 1, 0]))
        precondition(write(fd, [UInt8](arrayLiteral: 5, 0), 2) == 2)
        var expected = Data([5, 1, 0])
        if byIP { expected.append(contentsOf: [1, 192, 0, 2, 12]) }
        else {
            expected.append(contentsOf: [3, 12])
            expected.append(Data("test.example".utf8))
        }
        expected.append(contentsOf: [1, 187]) // original port 443
        precondition(readExactly(fd, expected.count) == expected)
        if scenario == .cancelled { relay.cancel() }
        else if !stall {
            let reply: [UInt8] = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0, 42]
            precondition(write(fd, reply, reply.count) == reply.count)
            if scenario != .earlyEOF { precondition(readExactly(fd, prefix.count + tail.count) == prefix + tail) }
            var byte: UInt8 = 0
            precondition(read(fd, &byte, 1) == 0, "expected client FIN after final byte")
            shutdown(fd, SHUT_WR)
        }
        precondition(done.wait(timeout: .now() + 15) == .success)
        if scenario == .cancelled {
            precondition(!connected && failure == "Tunnel disconnected" && flow.reads == 1)
        } else if stall {
            precondition(!connected && failure == "Connection setup timed out" && flow.reads == 1)
        } else {
            precondition(connected && failure == nil && flow.received == Data([42]))
        }
        print("PASS: loopback SOCKS relay — \(scenario)")
    }
}
