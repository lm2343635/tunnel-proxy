import Foundation

enum LabProtocol {
    static let providerID = "com.xwkj.tunnelproxy.lab.proxy"
    static let probeID = "com.xwkj.tunnelproxy.lab.probe"
    static let sessionKey = "labSession"
    static let versionKey = "labVersion"
    static let addressKey = "labAddress"
    static let portKey = "labPort"
    static let relayKey = "labRelay"
    static let version = 5
}

struct LabEndpoint {
    let address: String
    let port: UInt16

    private static let remoteAddress = "198.18.0.10"
    private static let remotePort: UInt16 = 28443
    private static let loopbackAddress = "127.0.0.1"

    init?(address: String, port: UInt16) {
        guard (address == Self.remoteAddress && port == Self.remotePort)
            || (address == Self.loopbackAddress && (port >= 49152 || port == LabRelaySelection.proxyPort))
        else { return nil }
        self.address = address
        self.port = port
    }

    static var selected: Self? {
        let prefix = "--loopback-port="
        let options = ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("--loopback-port") }
        guard let option = options.first else { return Self(address: remoteAddress, port: remotePort) }
        guard options.count == 1, option.hasPrefix(prefix),
              let port = UInt16(option.dropFirst(prefix.count)), port >= 49152 else { return nil }
        return Self(address: loopbackAddress, port: port)
    }

    var description: String { "\(address):\(port)" }
}

struct LabSession: Codable, Equatable {
    let id: UUID
    let version: Int
}

struct FlowCounts: Codable {
    var tcp = 0
    var udp = 0
    var probeMatches = 0
    var probeAuditTokenPresent = 0
    var claudeMain = 0
    var claudeHelper = 0
    var claudeUnverified = 0
    var relayMainConnected = 0
    var relayHelperConnected = 0
    var relayMainBidirectional = 0
    var relayHelperBidirectional = 0
    var relayMainActive = 0
    var relayHelperActive = 0
    var relayMainSentBytes = 0
    var relayMainReceivedBytes = 0
    var relayHelperSentBytes = 0
    var relayHelperReceivedBytes = 0
    var relayUnsupported = 0
    var relayFailures = 0
    var relayRejectionReasons: [String: Int] = [:]
    var relayFailureStages: [String: Int] = [:]
    var otherSources = 0
}

struct LabSnapshot: Codable {
    let session: LabSession
    let counts: FlowCounts
}
