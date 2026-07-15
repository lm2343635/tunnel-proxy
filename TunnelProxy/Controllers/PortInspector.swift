import Foundation

/// Discovers which process (if any) is listening on a local TCP port and can
/// force-quit it. Used to detect the "Address already in use" conflict that
/// otherwise only surfaces as a bind failure in the log (`ssh -D` on the SOCKS
/// port, bundled privoxy on the HTTP port).
///
/// All calls are synchronous (they shell out to `lsof`/`kill`); run them off the
/// MainActor via `Task.detached`, the same way `TunnelController` invokes
/// `networksetup`.
enum PortInspector {

    /// A process holding (listening on) a local TCP port.
    struct Holder: Equatable {
        let port: Int
        let pid: Int32
        /// Short command name for display, e.g. "privoxy", "ssh".
        let command: String
        /// Full executable path, when `lsof` reports it. Used for `isOurs`.
        let path: String
        /// True when `path` is a process of the kind this app spawns (our bundled
        /// privoxy or the system ssh). A heuristic for softening prompt copy and
        /// letting the watchdog reclaim its own leftovers — it does NOT prove the
        /// process is *our current live child*, so never auto-kill on it alone.
        var isOurs: Bool
    }

    private static let lsofPath = "/usr/sbin/lsof"

    /// Return the process listening on `port`, or nil if the port is free or the
    /// listener can't be determined (treated as "unknown" → callers fall back to
    /// attempting the bind).
    static func holder(ofPort port: Int) -> Holder? {
        // `-Fcpn`: field output — one field per line, prefixed by a type char.
        //   p<pid>  c<command>  n<name/path>   (stable, unlike the columnar form)
        let result = ProcessRunner.run(
            lsofPath,
            ["-nP", "-Fcpn", "-iTCP:\(port)", "-sTCP:LISTEN"],
            timeout: 10)
        // lsof exits non-zero (1) when nothing matches — that's "port free", not
        // an error. Only bail if it produced no parseable output at all.
        guard !result.stdout.isEmpty else { return nil }

        var pid: Int32?
        var command = ""
        var path = ""
        for rawLine in result.stdout.split(separator: "\n") {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)          // new process record starts
            case "c": command = value
            case "n":
                // The listen address line, e.g. "127.0.0.1:8118". `lsof` reports
                // the socket address in `n`, not the executable path, so we can't
                // derive `path` from it. Path comes from a separate probe below.
                break
            default: break
            }
        }
        guard let pid else { return nil }

        // `lsof -Fcpn -iTCP` gives the socket address in `n`, not the binary path.
        // Resolve the executable path from the pid to drive `isOurs` reliably.
        path = executablePath(ofPID: pid)
        return Holder(port: port, pid: pid, command: command, path: path,
                      isOurs: isOursPath(path, command: command))
    }

    /// Resolve a pid's executable path via `lsof -a -p <pid> -Fn -d txt` (the
    /// text/binary fd). Empty string if it can't be determined.
    private static func executablePath(ofPID pid: Int32) -> String {
        let result = ProcessRunner.run(
            lsofPath, ["-a", "-p", "\(pid)", "-d", "txt", "-Fn"], timeout: 10)
        // The first `n` field for the txt fd is the program binary.
        for rawLine in result.stdout.split(separator: "\n") {
            if rawLine.first == "n" {
                return String(rawLine.dropFirst())
            }
        }
        return ""
    }

    /// True when the path is one of the executables this app launches: the
    /// bundled privoxy, or the system ssh at `/usr/bin/ssh`.
    private static func isOursPath(_ path: String, command: String) -> Bool {
        if let ours = AppPaths.bundledPrivoxy?.path, path == ours { return true }
        if path == "/usr/bin/ssh" { return true }
        return false
    }

    // MARK: - Force quit

    enum KillOutcome: Equatable {
        case freed                  // process gone (or port no longer held)
        case needsAdmin             // EPERM — root-owned, can't kill without sudo
        case failed(String)         // other failure
    }

    /// Send SIGTERM, wait a short grace period, escalate to SIGKILL. Mirrors the
    /// grace loop in `TunnelEngine.terminate`. Returns once the process is gone or
    /// the grace elapses. Run off the MainActor.
    static func forceQuit(pid: Int32) -> KillOutcome {
        if kill(pid, SIGTERM) != 0 {
            let err = errno
            if err == ESRCH { return .freed }          // already gone
            if err == EPERM { return .needsAdmin }      // root-owned
            return .failed(String(cString: strerror(err)))
        }
        // Grace period, then SIGKILL if still alive (mirror TunnelEngine's 3s).
        let deadline = Date().addingTimeInterval(3)
        while isAlive(pid) && Date() < deadline {
            usleep(50_000)
        }
        if isAlive(pid) {
            if kill(pid, SIGKILL) != 0 {
                let err = errno
                if err == ESRCH { return .freed }
                if err == EPERM { return .needsAdmin }
                return .failed(String(cString: strerror(err)))
            }
        }
        return .freed
    }

    /// True if `pid` still exists (signal 0 probes without delivering).
    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM      // exists but not ours to signal
    }
}
