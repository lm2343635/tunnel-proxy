import Darwin
import Network

enum LabSSHSocket {
    static func isOwned(_ endpoint: NWEndpoint?, by ssh: LabProcessIdentity) -> Bool {
        guard case let .hostPort(host, port)? = endpoint, host == .ipv4(.loopback),
              ssh.hasExecutable(LabRelaySelection.sshExecutable) else { return false }
        let descriptorSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(ssh.pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes <= 4096 * descriptorSize else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / descriptorSize + 16)
        let received = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(ssh.pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard received > 0 else { return false }
        return descriptors.prefix(Int(received) / descriptorSize).contains { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return false }
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(ssh.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_family == AF_INET, socket.psi.soi_kind == SOCKINFO_TCP else { return false }
            let tcp = socket.psi.soi_proto.pri_tcp
            let addresses = tcp.tcpsi_ini
            let loopback = UInt32(INADDR_LOOPBACK).bigEndian
            return tcp.tcpsi_state == 4
                && addresses.insi_laddr.ina_46.i46a_addr4.s_addr == loopback
                && addresses.insi_faddr.ina_46.i46a_addr4.s_addr == loopback
                && UInt16(truncatingIfNeeded: addresses.insi_lport) == LabRelaySelection.sshSOCKSPort.bigEndian
                && UInt16(truncatingIfNeeded: addresses.insi_fport) == port.rawValue.bigEndian
        } && ssh.isCurrent
    }
}
