import Foundation
import Darwin

// Compile with the production model, planner and engine; isolate all writable
// app paths so these checks cannot overwrite a running app's config or log.
enum AppPaths {
    static let supportDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROUTING_TEST_ROOT"]!)
    static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    static var logURL: URL { supportDirectory.appendingPathComponent("tunnel.log") }
    static var privoxyConfigURL: URL { supportDirectory.appendingPathComponent("privoxy.conf") }
    static var bundledPrivoxy: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROUTING_TEST_PRIVOXY"] ?? "/nonexistent") }
    static var askpassHelper: URL? { nil }
    @discardableResult static func ensureSupportDirectory() -> Bool {
        (try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)) != nil
    }
}
enum KeychainStore { static func deleteSecret(for id: UUID) {} }

@main struct RoutingHarness {
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(rc == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    static func main() async throws {
        struct Failure: Error { let message: String }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }
            print("PASS: \(message)")
            fflush(stdout)
        }
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","name":"old","host":"example.com","port":22,"username":"test","authMethod":"agent","keyPath":"","hasStoredSecret":false}"#.data(using: .utf8)!
        let server = try JSONDecoder().decode(ServerProfile.self, from: old)
        try check(server.effectiveRouting.mode == .automatic, "old profiles default to automatic")
        let roundTrip = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(server))
        try check(roundTrip == server, "profile round trip preserves legacy data")
        var config = TunnelConfig()
        config.socksPort = 19080; config.httpProxyPort = 19118
        if CommandLine.arguments.contains("--live") {
            config.socksPort = freePort(); config.httpProxyPort = freePort()
        }
        let system: [String: Any] = ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":7890,
                                    "HTTPSEnable":1,"HTTPSProxy":"127.0.0.1","HTTPSPort":7890,
                                    "SOCKSEnable":1,"SOCKSProxy":"localhost","SOCKSPort":config.socksPort]
        let routes = SSHRoutePlanner.candidates(settings: .init(), config: config, proxies: system, interface: "en0")
        try check(routes.count == 2 && routes[0].proxyPort == 7890 && routes[1].interface == "en0", "deduplicate system proxies, exclude owned listeners, proxy before direct")
        try check(SSHRoutePlanner.candidates(settings: .init(mode: .proxy), config: config, proxies: [:], interface: "en0").isEmpty, "proxy-only never falls back to direct")
        try check(SSHRoutePlanner.candidates(settings: .init(mode: .direct), config: config, proxies: system, interface: "utun7").isEmpty, "direct never silently uses a virtual interface")
        for invalid in ["-oProxyCommand=touch", "host';touch /tmp/x;#", "$(whoami)", "a\nhost", "host name"] {
            try check(!SSHRoutePlanner.validHost(invalid), "reject unsafe host: \(invalid.debugDescription)")
        }
        let manual = SSHRoutingSettings(mode: .proxy, detectSystemProxy: false, proxyHost: "127.0.0.1", proxyPort: 7891, proxyKind: .socks5)
        let socks = SSHRoutePlanner.candidates(settings: manual, config: config, proxies: [:], interface: "en0")
        try check(socks.count == 1 && socks[0].proxyCommand.contains("'5'"), "manual SOCKS5 emits the correct transport")
        guard CommandLine.arguments.contains("--live") else { return }
        let env = ProcessInfo.processInfo.environment
        let host = env["ROUTING_TEST_HOST"]!
        let port = Int(env["ROUTING_TEST_PORT"]!)!
        let discovered = SSHRoutePlanner.candidates(settings: .init(), config: config)
        try check(discovered.contains { $0.proxyHost != nil }, "discover current local VPN proxy")
        guard let proxy = discovered.first(where: { $0.proxyHost != nil }), let direct = discovered.first(where: { $0.interface != nil }) else { fatalError("Need proxy and physical interface") }
        try check(SSHRoutePlanner.probe(proxy, host: host, port: port), "SSH key exchange through VPN proxy")
        try check(SSHRoutePlanner.probe(direct, host: host, port: port), "SSH key exchange through physical interface")
        try check(!SSHRoutePlanner.probe(.init(proxyHost: "127.0.0.1", proxyPort: 9), host: host, port: port), "unavailable proxy fails discovery")
        var live = ServerProfile()
        live.host = host; live.port = port; live.username = env["ROUTING_TEST_USER"] ?? "root"
        live.authMethod = .keyFile; live.keyPath = env["ROUTING_TEST_KEY"]!
        live.routing = .init(mode: .automatic, detectSystemProxy: false, proxyPort: 9)
        config.servers = [live]
        let engine = TunnelEngine()
        do {
        let health = await engine.connect(config: config, server: live, secret: nil, watchdog: false)
        let status = await engine.routingStatus()
        try check(health == .proxyOK && !status.3, "dead proxy falls back to authenticated direct tunnel + bundled HTTP proxy")
        await engine.stop()
        let stopped = await engine.checkHealth()
        let stoppedStatus = await engine.routingStatus()
        try check(stopped == .down && !stoppedStatus.2, "stop disables automatic recovery and tears down owned children")
        live.routing = .init(mode: .proxy, detectSystemProxy: false, proxyHost: proxy.proxyHost!, proxyPort: proxy.proxyPort, proxyKind: proxy.kind)
        let proxiedHealth = await engine.connect(config: config, server: live, secret: nil, watchdog: false)
        let proxiedStatus = await engine.routingStatus()
        try check(proxiedHealth == .proxyOK && proxiedStatus.3, "authenticated SSH pipeline works through explicit proxy")
        await engine.stop()
        // Simulate VPN shutdown using an owned local CONNECT relay, without
        // stopping the user's VPN or disrupting any other application.
        let relayPort = freePort()
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        relay.arguments = ["tests/http-connect-fixture.py", String(relayPort), host, String(port), direct.interface!]
        relay.standardOutput = FileHandle.nullDevice
        let relayLog = AppPaths.supportDirectory.appendingPathComponent("relay.log")
        FileManager.default.createFile(atPath: relayLog.path, contents: nil)
        relay.standardError = try FileHandle(forWritingTo: relayLog)
        try relay.run()
        defer { if relay.isRunning { relay.terminate() } }
        for _ in 0..<50 {
            if PortInspector.holder(ofPort: relayPort)?.pid == relay.processIdentifier { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(PortInspector.holder(ofPort: relayPort)?.pid == relay.processIdentifier, "test CONNECT relay is ready")
        live.routing = .init(mode: .automatic, detectSystemProxy: false, proxyPort: relayPort)
        config.watchdogInterval = 15
        let beforeShutdown = await engine.connect(config: config, server: live, secret: nil, watchdog: true)
        let beforeStatus = await engine.routingStatus()
        try check(beforeShutdown == .proxyOK && beforeStatus.3, "automatic mode initially selects working CONNECT relay")
        relay.terminate()
        relay.waitUntilExit()
        var recovered = false
        for _ in 0..<45 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let state = await engine.routingStatus()
            if await engine.checkHealth() == .proxyOK, !state.3 {
                recovered = true
                break
            }
        }
        try check(recovered, "proxy shutdown automatically reconnects over physical direct network")
        await engine.stop()
        live.routing = .init(mode: .automatic, detectSystemProxy: false, proxyHost: proxy.proxyHost!, proxyPort: proxy.proxyPort, proxyKind: proxy.kind)
        // Authentication failure must not try another route or retry indefinitely.
        live.username = "tunnelproxy-nonexistent-test-user"
        live.routing?.mode = .automatic
        let deniedHealth = await engine.connect(config: config, server: live, secret: nil, watchdog: true)
        let denied = await engine.routingStatus()
        try check(deniedHealth == .down && !denied.2 && denied.1 != nil, "authentication failure halts automatic fallback and retries")
        await engine.stop()
        // A stop while the route probe is suspended must not revive a session.
        live.username = env["ROUTING_TEST_USER"] ?? "root"
        let pending = Task { await engine.connect(config: config, server: live, secret: nil, watchdog: true) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await engine.stop()
        _ = await pending.value
        let cancelled = await engine.checkHealth()
        try check(cancelled == .down, "stop during discovery cannot revive SSH")
        } catch {
            await engine.stop()
            throw error
        }
    }
}
