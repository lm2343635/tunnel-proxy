import Darwin
import Foundation
import Network

struct RoutingProcess: Equatable, Codable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func inspect(_ pid: pid_t) -> (identity: Self, parent: pid_t)? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid) else { return nil }
        return (Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec),
                pid_t(info.pbi_ppid))
    }

    var isCurrent: Bool { Self.inspect(pid)?.identity == self }

    var executable: URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard isCurrent, proc_pidpath(pid, &path, UInt32(path.count)) > 0, isCurrent else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    }
}

struct RoutingSOCKSPeer: Codable, Equatable {
    let ssh: RoutingProcess
    let host: RoutingProcess
    let port: UInt16

    var isCurrent: Bool {
        ssh.executable?.path == "/usr/bin/ssh" && host.isCurrent
            && RoutingProcess.inspect(ssh.pid)?.parent == host.pid
    }

    func ownsSocket(_ endpoint: Network.NWEndpoint?) -> Bool {
        guard case let .hostPort(address, localPort)? = endpoint,
              address == .ipv4(.loopback), isCurrent else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let expected = proc_pidinfo(ssh.pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard expected > 0, expected <= 4096 * stride else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(expected) / stride + 16)
        let length = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(ssh.pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard length > 0 else { return false }
        return descriptors.prefix(Int(length) / stride).contains { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return false }
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(ssh.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_family == AF_INET, socket.psi.soi_kind == SOCKINFO_TCP else { return false }
            let tcp = socket.psi.soi_proto.pri_tcp
            let endpoints = tcp.tcpsi_ini
            let loopback = UInt32(INADDR_LOOPBACK).bigEndian
            return tcp.tcpsi_state == 4
                && endpoints.insi_laddr.ina_46.i46a_addr4.s_addr == loopback
                && endpoints.insi_faddr.ina_46.i46a_addr4.s_addr == loopback
                && UInt16(truncatingIfNeeded: endpoints.insi_lport) == port.bigEndian
                && UInt16(truncatingIfNeeded: endpoints.insi_fport) == localPort.rawValue.bigEndian
        } && isCurrent
    }
}
