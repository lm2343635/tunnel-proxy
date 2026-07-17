import Foundation
import Darwin

/// Natively manages the tunnel pipeline that the shell scripts used to run:
///
///   ssh -N -D <socksPort> <host>   (SOCKS5 proxy)
///        │
///        ▼
///   privoxy (bundled)  forward-socks5 / 127.0.0.1:<socksPort>  (HTTP proxy on <httpPort>)
///
/// Both children are owned by this process (foreground, not forked), so quitting
/// the app or calling `stop()` tears them down cleanly. A background watchdog
/// probes the SOCKS port and relaunches ssh if it drops.
///
/// This type is an actor: connect/stop/watchdog all mutate child-process state,
/// and serializing them avoids races (e.g. a watchdog relaunch colliding with a
/// user-initiated stop).
actor TunnelEngine {

    enum Health: Equatable {
        case proxyOK        // HTTP proxy reachable end-to-end
        case tunnelOnly     // SOCKS up but HTTP proxy failed
        case down           // nothing reachable
    }

    private var sshProcess: Process?
    private var privoxyProcess: Process?
    private var watchdogTask: Task<Void, Never>?
    private var config = TunnelConfig()
    private var server = ServerProfile()
    /// Secret (password or key passphrase) for the active server, if any.
    private var secret: String?

    private let sshPath = "/usr/bin/ssh"
    private let curlPath = "/usr/bin/curl"

    // MARK: - Lifecycle

    /// Start (or restart) the full pipeline for a given server. The secret, when
    /// present, is fed to ssh via a bundled SSH_ASKPASS helper.
    func connect(config: TunnelConfig, server: ServerProfile, secret: String?, watchdog: Bool) async -> Health {
        self.config = config
        self.server = server
        self.secret = secret
        log("Starting SSH tunnel to \(server.sshDestination)…")

        stopWatchdog()
        startSSH()
        // Give ssh a moment to establish the dynamic forward.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        startPrivoxy()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let health = await checkHealth()
        switch health {
        case .proxyOK: log("Tunnel + proxy started successfully")
        case .tunnelOnly: log("Tunnel OK but proxy failed")
        case .down: log("Tunnel failed to start")
        }

        // Only arm the watchdog when something actually came up. Arming it on a
        // `.down` connect leaves a background task relaunching ssh into the same
        // (often occupied) port forever — the endless-loop bug. On `.down` we tear
        // down whatever partially started so we don't leak a half-open ssh/privoxy.
        if watchdog, health != .down {
            startWatchdog()
        } else if health == .down {
            terminate(&privoxyProcess, name: "privoxy")
            terminate(&sshProcess, name: "ssh")
        }
        return health
    }

    /// Tear down watchdog, privoxy, and ssh.
    func stop() {
        stopWatchdog()
        terminate(&privoxyProcess, name: "privoxy")
        terminate(&sshProcess, name: "ssh")
        log("Tunnel and proxy stopped")
    }

    // MARK: - SSH

    private func startSSH() {
        terminate(&sshProcess, name: "ssh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)

        var args = [
            "-N",                                   // no remote command
            "-o", "StrictHostKeyChecking=no",
            // Keepalive tuned for lossy carrier (China Telecom) links: probe often
            // enough to keep NAT/CGNAT mappings alive (they recycle idle flows ~60s),
            // but tolerate a wide burst-loss window before declaring the link dead.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=6",          // ~90s of loss tolerated, not 30s
            "-o", "TCPKeepAlive=yes",               // OS-level keepalive as a backstop
            // Do NOT compress: on high-loss links -C amplifies latency sensitivity and
            // buys little for already-encrypted/compressed HTTPS traffic.
            "-o", "Compression=no",
            "-o", "IPQoS=throughput",               // avoid low-latency DSCP throttling
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-p", "\(server.port)",
            "-D", "\(config.socksPort)",
        ]

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()

        switch server.authMethod {
        case .agent:
            // Non-interactive: rely on agent/default keys, never prompt.
            args += ["-o", "BatchMode=yes"]
        case .keyFile:
            if !server.keyPath.isEmpty {
                args += ["-i", (server.keyPath as NSString).expandingTildeInPath,
                         "-o", "IdentitiesOnly=yes"]
            }
            if let secret, !secret.isEmpty {
                // Encrypted key: feed the passphrase via the askpass helper.
                configureAskpass(&args, &env)
            } else {
                args += ["-o", "BatchMode=yes"]
            }
        case .password:
            // Force password auth and feed it via the askpass helper.
            args += [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
            ]
            configureAskpass(&args, &env)
        }

        args.append(server.sshDestination)
        p.arguments = args
        p.environment = env
        redirectOutput(of: p, tag: "ssh")
        do {
            try p.run()
            sshProcess = p
        } catch {
            log("Failed to launch ssh: \(error.localizedDescription)")
        }
    }

    /// Wire ssh to read the secret from our bundled askpass helper. ssh calls the
    /// program in SSH_ASKPASS when it needs a password/passphrase; the helper
    /// echoes back what we place in TP_ASKPASS_SECRET.
    private func configureAskpass(_ args: inout [String], _ env: inout [String: String]) {
        guard let helper = AppPaths.askpassHelper,
              FileManager.default.isExecutableFile(atPath: helper.path),
              let secret else {
            log("askpass helper unavailable; ssh may fail to authenticate")
            return
        }
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"   // use askpass even with a TTY
        env["TP_ASKPASS_SECRET"] = secret
        env["DISPLAY"] = env["DISPLAY"] ?? ":0" // older ssh requires DISPLAY set
        // Detach from any controlling terminal so ssh uses askpass, not the tty.
        args += ["-o", "BatchMode=no"]
    }

    // MARK: - Privoxy (bundled)

    private func startPrivoxy() {
        terminate(&privoxyProcess, name: "privoxy")
        guard let privoxy = AppPaths.bundledPrivoxy,
              FileManager.default.isExecutableFile(atPath: privoxy.path) else {
            log("Bundled privoxy not found")
            return
        }
        // Write a fresh config each connect.
        let conf = """
        listen-address 127.0.0.1:\(config.httpProxyPort)
        forward-socks5 / 127.0.0.1:\(config.socksPort) .
        # Keep privoxy quiet and self-contained.
        toggle 1
        enable-remote-toggle 0
        """
        AppPaths.ensureSupportDirectory()
        do {
            try conf.write(to: AppPaths.privoxyConfigURL, atomically: true, encoding: .utf8)
        } catch {
            log("Failed to write privoxy config: \(error.localizedDescription)")
            return
        }

        let p = Process()
        p.executableURL = privoxy
        // --no-daemon so we own the process; pass our generated config.
        p.arguments = ["--no-daemon", AppPaths.privoxyConfigURL.path]
        redirectOutput(of: p, tag: "privoxy")
        do {
            try p.run()
            privoxyProcess = p
        } catch {
            log("Failed to launch privoxy: \(error.localizedDescription)")
        }
    }

    // MARK: - Health checks

    /// Probe the pipeline. Mirrors the scripts' curl checks.
    func checkHealth() async -> Health {
        // HTTP proxy end-to-end: expect an auth error body from Anthropic.
        if let out = await curl([
            "-s", "--max-time", "5",
            "-x", "http://127.0.0.1:\(config.httpProxyPort)",
            "https://api.anthropic.com/v1/models",
        ]), out.contains("authentication_error") {
            return .proxyOK
        }
        // SOCKS-only: can we resolve an exit IP through the tunnel?
        if let out = await curl([
            "-s", "--max-time", "5",
            "--socks5-hostname", "127.0.0.1:\(config.socksPort)",
            "https://api.ipify.org",
        ]), out.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil {
            return .tunnelOnly
        }
        return .down
    }

    /// Fetch the current exit IP through the HTTP proxy, or nil if unreachable.
    func exitIP() async -> String? {
        guard let out = await curl([
            "-s", "--max-time", "5",
            "-x", "http://127.0.0.1:\(config.httpProxyPort)",
            "https://api.ipify.org",
        ]) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
            ? trimmed : nil
    }

    /// Round-trip latency to the active SSH server, in milliseconds, or nil if it
    /// can't be reached. Measured as a TCP connect time to `host:port` — the same
    /// endpoint the tunnel rides on — which needs no live control socket and works
    /// for any auth method. Runs off the actor's executor via a detached task.
    func latencyMS() async -> Int? {
        let host = server.host
        let port = server.port
        guard !host.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            Self.tcpConnectMS(host: host, port: port, timeout: 3)
        }.value
    }

    /// Blocking TCP-connect timing to `host:port`. Returns elapsed milliseconds on
    /// a successful connect, nil on failure/timeout. Uses a non-blocking socket +
    /// `poll` so a dead host times out instead of hanging.
    nonisolated private static func tcpConnectMS(host: String, port: Int, timeout: TimeInterval) -> Int? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Non-blocking connect so we can bound the wait with poll().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc == 0 {
            return Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        guard errno == EINPROGRESS else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        guard ready > 0 else { return nil }   // 0 = timeout, <0 = error

        // Connected only if SO_ERROR is clear.
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0, soError == 0 else { return nil }
        return Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private func curl(_ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: curlPath)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            continuation.resume(returning: String(data: data, encoding: .utf8))
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let interval = UInt64(max(1, config.watchdogInterval)) * 1_000_000_000
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self.watchdogTick()
            }
        }
        log("Watchdog started (every \(config.watchdogInterval)s)")
    }

    /// Consecutive failed SOCKS probes. On a lossy carrier link a *single* probe
    /// can fail from transient packet loss while the tunnel is actually fine; hard-
    /// reconnecting on one miss is what makes the proxy feel like it "drops every
    /// minute". Require two misses in a row before tearing ssh down.
    private var consecutiveProbeFailures = 0

    private func watchdogTick() async {
        // Probe SOCKS directly; if it's down, consider relaunching ssh.
        let ok = await socksProbeOK()
        if ok {
            consecutiveProbeFailures = 0
            return
        }
        consecutiveProbeFailures += 1
        if consecutiveProbeFailures < 2 {
            log("Watchdog probe missed (\(consecutiveProbeFailures)/2) — waiting for confirmation")
            return
        }

        // The SOCKS probe can't tell "our tunnel died" from "a foreign process is
        // squatting on the port" — both fail identically. Before relaunching, ask
        // who holds the port. If a *foreign* process holds it, relaunching would
        // just spin (`bind: Address already in use`), so stop instead of looping.
        let port = config.socksPort
        let ourPID = sshProcess?.processIdentifier
        let holder = await Task.detached { PortInspector.holder(ofPort: port) }.value
        if let holder {
            // Reconnect-race guard: our own live/expected ssh child is not foreign.
            let isOurLiveChild = (ourPID != nil && holder.pid == ourPID)
            if !holder.isOurs && !isOurLiveChild {
                log("Tunnel down, but port \(port) is held by “\(holder.command)” (PID \(holder.pid)) — not reconnecting")
                stopWatchdog()
                return
            }
        }
        log("Tunnel down, reconnecting…")
        startSSH()
        consecutiveProbeFailures = 0
    }

    /// One SOCKS liveness probe through the tunnel. Short timeout so a stalled
    /// probe doesn't stretch the watchdog cycle on a slow link.
    private func socksProbeOK() async -> Bool {
        await curl([
            "-s", "--max-time", "4",
            "--socks5-hostname", "127.0.0.1:\(config.socksPort)",
            "https://api.ipify.org",
        ])?.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Process helpers

    private func terminate(_ process: inout Process?, name: String) {
        guard let p = process else { return }
        if p.isRunning {
            p.terminate()
            // Give it a beat; force-kill if still alive.
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
    }

    /// Append a child's stdout/stderr into the shared log file.
    private func redirectOutput(of process: Process, tag: String) {
        AppPaths.ensureSupportDirectory()
        let logPath = AppPaths.logURL.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: AppPaths.logURL) else { return }
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
    }

    // MARK: - Logging

    nonisolated func log(_ message: String) {
        let line = "\(Self.timestamp())  \(message)\n"
        AppPaths.ensureSupportDirectory()
        let url = AppPaths.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
