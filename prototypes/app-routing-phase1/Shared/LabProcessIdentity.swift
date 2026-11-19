import Darwin
import Foundation

struct LabProcessIdentity: Codable, Equatable {
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func inspect(_ pid: pid_t) -> (identity: Self, parent: pid_t)? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid) else { return nil }
        let identity = Self(pid: pid, startedSeconds: info.pbi_start_tvsec,
                            startedMicroseconds: info.pbi_start_tvusec)
        return (identity, pid_t(info.pbi_ppid))
    }

    var isCurrent: Bool { Self.inspect(pid)?.identity == self }

    func hasExecutable(_ expected: String) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return isCurrent && proc_pidpath(pid, &path, UInt32(path.count)) > 0
            && String(cString: path) == expected && isCurrent
    }

    func lineage(from source: pid_t) -> [Self]? {
        var current = source
        var lineage: [Self] = []
        for _ in 0..<24 {
            guard let process = Self.inspect(current) else { return nil }
            lineage.append(process.identity)
            if process.identity == self { return lineage }
            guard current != pid else { return nil }
            current = process.parent
        }
        return nil
    }
}

struct LabRelaySelection: Codable {
    static let claudeExecutable = "/Applications/Claude.app/Contents/MacOS/Claude"
    static let sshExecutable = "/usr/bin/ssh"
    static let proxyPort: UInt16 = 7890
    static let sshSOCKSPort: UInt16 = 1080
    let claude: LabProcessIdentity
    let ssh: LabProcessIdentity

    static var selected: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        func pid(for prefix: String) -> pid_t? {
            let matches = arguments.filter { $0.hasPrefix(prefix) }
            guard matches.count == 1, let match = matches.first else { return nil }
            return pid_t(match.dropFirst(prefix.count))
        }
        guard let claudePID = pid(for: "--relay-claude-pid="),
              let sshPID = pid(for: "--relay-ssh-pid="),
              let claude = LabProcessIdentity.inspect(claudePID)?.identity,
              let ssh = LabProcessIdentity.inspect(sshPID)?.identity,
              claude.hasExecutable(Self.claudeExecutable),
              ssh.hasExecutable(Self.sshExecutable) else { return nil }
        return Self(claude: claude, ssh: ssh)
    }
}
