import Foundation
import Network
import Darwin

enum ProxyMode: String, CaseIterable, Identifiable {
    case local, appRouting, global

    var id: Self { self }
    var label: String {
        switch self {
        case .local: return routingText("Local Proxy Only")
        case .appRouting: return routingText("Per-App Routing")
        case .global: return routingText("Global Proxy")
        }
    }
}

func routingText(_ key: String) -> String {
    NSLocalizedString(key, tableName: "AppRouting", comment: "")
}

enum AppRoutePolicy: String, CaseIterable, Codable, Identifiable {
    case proxyAll, directAll, proxyListed, directListed

    var id: Self { self }
    var usesDomains: Bool { self == .proxyListed || self == .directListed }

    var label: String {
        switch self {
        case .proxyAll: return routingText("Proxy All")
        case .directAll: return routingText("Direct All")
        case .proxyListed: return routingText("Proxy Listed Domains")
        case .directListed: return routingText("Direct Listed Domains")
        }
    }

    func decision(hostname: String?, domains: [String]) -> RoutingDecision {
        switch self {
        case .proxyAll: return .proxy
        case .directAll: return .direct
        case .proxyListed:
            guard let hostname else { return .blocked }
            return contains(hostname, domains) ? .proxy : .direct
        case .directListed:
            guard let hostname else { return .proxy }
            return contains(hostname, domains) ? .direct : .proxy
        }
    }

    private func contains(_ hostname: String, _ domains: [String]) -> Bool {
        domains.contains { hostname == $0 || hostname.hasSuffix("." + $0) }
    }
}

enum RoutingDecision: String, Codable {
    case direct, proxy, blocked

    var label: String {
        switch self {
        case .direct: return routingText("Direct")
        case .proxy: return routingText("Proxy")
        case .blocked: return routingText("Blocked")
        }
    }
}

struct RoutingAppIdentity: Codable, Equatable, Hashable {
    let team: String
    let identifier: String

    var isClaudeDesktop: Bool {
        team == "Q6L2SF6YDW" && identifier == "com.anthropic.claudefordesktop"
    }
}

struct RoutingApp: Codable, Equatable, Identifiable {
    let identity: RoutingAppIdentity
    let name: String
    let directory: URL
    let bundledHelpers: [RoutingAppIdentity]
    var policy: AppRoutePolicy = .proxyAll
    var domains: [String] = []
    var isEnabled = true

    var id: RoutingAppIdentity { identity }
}

extension RoutingApp {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(RoutingAppIdentity.self, forKey: .identity)
        name = try values.decode(String.self, forKey: .name)
        directory = try values.decode(URL.self, forKey: .directory)
        bundledHelpers = try values.decode([RoutingAppIdentity].self, forKey: .bundledHelpers)
        policy = try values.decode(AppRoutePolicy.self, forKey: .policy)
        domains = try values.decode([String].self, forKey: .domains)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

enum RoutingDomain {
    static func normalize(_ value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253,
              IPv4Address(name) == nil, IPv6Address(name) == nil,
              !name.contains(where: { "/\\:@?#%* \t\r\n".contains($0) }),
              let url = URL(string: "https://" + name),
              let encoded = (url as NSURL).host?.lowercased(),
              encoded.utf8.count <= 253,
              encoded.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return encoded
    }
}

struct RoutingRules: Codable, Equatable {
    var version = UUID()
    var apps: [RoutingApp] = []

    var providerRules: Self {
        Self(version: version, apps: apps.filter(\.isEnabled))
    }
}

struct RoutingEvent: Codable, Identifiable {
    let id: UUID
    let time: Date
    let application: RoutingAppIdentity
    let destination: String
    let decision: RoutingDecision
    let reason: String?

    init(application: RoutingAppIdentity, destination: String, decision: RoutingDecision, reason: String?) {
        id = UUID()
        time = Date()
        self.application = application
        self.destination = destination
        self.decision = decision
        self.reason = reason
    }
}

struct RoutingControl: Codable {
    let session: UUID
    let version: UUID?
    let rules: RoutingRules?
    let tunnel: RoutingSOCKSPeer?
    let eventApp: RoutingAppIdentity?
}

struct RoutingStatus: Codable {
    let session: UUID
    let version: UUID
    let tunnelReady: Bool
    let events: [RoutingEvent]
}

enum AppRoutingProtocol {
    static let providerIdentifier = "com.xwkj.tunnelproxy.approuting"
    static let rulesKey = "AppRoutingRules"
    static let sessionKey = "AppRoutingSession"
}
