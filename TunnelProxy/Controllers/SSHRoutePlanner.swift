import Foundation
import SystemConfiguration
import Darwin

enum SSHRouteMode: String, Codable, CaseIterable, Identifiable {
    case automatic, direct, proxy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .direct: return String(localized: "Direct")
        case .proxy: return String(localized: "Via proxy")
        }
    }
}

enum SSHProxyKind: String, Codable, CaseIterable, Identifiable {
    case http, socks5
    var id: String { rawValue }
    var label: String { self == .http ? "HTTP CONNECT" : "SOCKS5" }
}

struct SSHRoutingSettings: Codable, Equatable {
    var mode: SSHRouteMode = .automatic
    var detectSystemProxy = true
    var proxyHost = "127.0.0.1"
    var proxyPort = 7890
    var proxyKind: SSHProxyKind = .http
    var validationError: String? {
        guard mode != .direct, !detectSystemProxy else { return nil }
        guard SSHRoutePlanner.validHost(proxyHost), (1...65535).contains(proxyPort) else {
            return String(localized: "Enter a valid proxy host and port")
        }
        return nil
    }
}

struct SSHConnectionRoute: Equatable {
    var proxyHost: String?
    var proxyPort: Int = 0
    var kind: SSHProxyKind = .http
    var interface: String?
    var label: String {
        if let host = proxyHost { return String(localized: "Via proxy") + " · \(host):\(proxyPort)" }
        return String(localized: "Physical network direct") + (interface.map { " · \($0)" } ?? "")
    }
    /// OpenSSH executes ProxyCommand using a shell. Quote every value, including
    /// expanded target placeholders; reject unsafe hostnames at the model boundary.
    var proxyCommand: String {
        var args = ["/usr/bin/nc", "-G", "10"]
        if let host = proxyHost {
            args += ["-X", kind == .http ? "connect" : "5", "-x", "\(host.contains(":") ? "[\(host)]" : host):\(proxyPort)"]
        } else if let interface {
            args += ["-b", interface]
        }
        return (args.map(SSHRoutePlanner.shellQuote) + ["'%h'", "'%p'"]).joined(separator: " ")
    }
}

enum SSHRoutePlanner {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func validHost(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.count < 254 &&
        value.range(of: #"^[A-Za-z0-9._:%-]+$"#, options: .regularExpression) != nil
    }

    /// Do not feed our own SOCKS/HTTP listeners back into SSH. This is especially
    /// important after the app has enabled its system-wide SOCKS proxy.
    static func candidates(settings: SSHRoutingSettings, config: TunnelConfig,
                           proxies: [String: Any]? = nil, interface: String? = nil) -> [SSHConnectionRoute] {
        var routes: [SSHConnectionRoute] = []
        if settings.mode != .direct {
            if settings.detectSystemProxy {
                let system = proxies ?? (SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:])
                for (enable, hostKey, portKey, kind) in [
                    ("HTTPEnable", "HTTPProxy", "HTTPPort", SSHProxyKind.http),
                    ("HTTPSEnable", "HTTPSProxy", "HTTPSPort", SSHProxyKind.http),
                    ("SOCKSEnable", "SOCKSProxy", "SOCKSPort", SSHProxyKind.socks5)
                ] {
                    guard (system[enable] as? NSNumber)?.boolValue == true,
                          let host = system[hostKey] as? String,
                          let port = (system[portKey] as? NSNumber)?.intValue else { continue }
                    routes.append(.init(proxyHost: host, proxyPort: port, kind: kind))
                }
            } else {
                routes.append(.init(proxyHost: settings.proxyHost, proxyPort: settings.proxyPort, kind: settings.proxyKind))
            }
            routes = routes.filter {
                guard let host = $0.proxyHost, validHost(host), (1...65535).contains($0.proxyPort) else { return false }
                let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) || host.hasPrefix("127.")
                return !(loopback && [config.socksPort, config.httpProxyPort].contains($0.proxyPort))
            }
        }
        // TUN-only VPNs sometimes leave system proxy settings empty. Discover
        // conventional loopback endpoints without scanning the LAN or reusing
        // our own listeners. Validate the full SSH path later, before use.
        if settings.mode != .direct, settings.detectSystemProxy, proxies == nil {
            for (port, kind) in [(7890, SSHProxyKind.http), (7891, .socks5), (1080, .socks5), (10808, .socks5), (10809, .http)] {
                if ![config.socksPort, config.httpProxyPort].contains(port), loopbackListening(port: port) {
                    routes.append(.init(proxyHost: "127.0.0.1", proxyPort: port, kind: kind))
                }
            }
        }
        var unique: [SSHConnectionRoute] = []
        for route in routes where !unique.contains(route) { unique.append(route) }
        if settings.mode != .proxy {
            // PrimaryInterface comes from the physical IPv4 service, unlike the
            // target's route which may be captured by a TUN/VPN host route.
            let physical = interface ?? primaryInterface()
            if let physical, !physical.hasPrefix("utun"), !physical.hasPrefix("tun"), physical != "lo0" {
                unique.append(.init(interface: physical))
            }
        }
        return unique
    }

    private static func loopbackListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&event, 1, 150) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }

    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "TunnelProxy.routes" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return state["PrimaryInterface"] as? String
    }

    /// A no-credentials key exchange tests the target, not merely the proxy's
    /// listening socket. Host-key verification deliberately fails against an
    /// empty known-hosts file after receiving the server key. No host trust or
    /// authentication state is changed by discovery.
    static func probe(_ route: SSHConnectionRoute, host: String, port: Int) -> Bool {
        guard validHost(host) else { return false }
        let result = ProcessRunner.run("/usr/bin/ssh", [
            "-v", "-F", "/dev/null", "-o", "ProxyCommand=\(route.proxyCommand)",
            "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "PubkeyAuthentication=no", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-p", String(port), host
        ], timeout: 11)
        return result.stderr.contains("Server host key:")
    }
}
