import Darwin
import Foundation
import Network

struct RoutingDestination {
    let name: String?
    let nameSource: String
    let address: Network.NWEndpoint.Host
    let port: Network.NWEndpoint.Port

    init?(hostname: String?, endpoint: Network.NWEndpoint) {
        guard case let .hostPort(address, port) = endpoint, port.rawValue > 0 else { return nil }
        self.address = address
        self.port = port
        if let hostname = hostname.flatMap(RoutingDomain.normalize) {
            name = hostname
            nameSource = "remoteHostname"
        } else if case .name(let value, _) = address {
            name = RoutingDomain.normalize(value)
            nameSource = name == nil ? "IP" : "Endpoint"
        } else {
            name = nil
            nameSource = "IP"
        }
    }

    var display: String { name ?? String(describing: address) }

    func socksCommand(recoveredName: String? = nil) -> Data? {
        let target: [UInt8]
        if let name = name ?? recoveredName {
            let bytes = Array(name.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
            target = [3, UInt8(bytes.count)] + bytes
        } else {
            switch address {
            case .ipv4(let ip): target = [1] + ip.rawValue
            case .ipv6(let ip):
                if let mapped = Self.mappedIPv4(ip.rawValue) { target = [1] + mapped }
                else { target = [4] + ip.rawValue }
            case .name: return nil
            @unknown default: return nil
            }
        }
        return Data([5, 1, 0] + target + [UInt8(port.rawValue >> 8), UInt8(truncatingIfNeeded: port.rawValue)])
    }

    var isLocal: Bool {
        if let name, name == "localhost" || name.hasSuffix(".localhost") { return true }
        switch address {
        case .ipv4(let ip): return Self.isLocalIPv4(ip.rawValue)
        case .ipv6(let ip):
            let bytes = ip.rawValue
            if let mapped = Self.mappedIPv4(bytes) { return Self.isLocalIPv4(mapped) }
            if ip == .loopback || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
            if bytes[0] == 0xff { return (1...2).contains(bytes[1] & 0x0f) }
            return Self.onLink(bytes, family: AF_INET6)
        case .name: return false
        @unknown default: return false
        }
    }

    private static func isLocalIPv4(_ bytes: Data) -> Bool {
        if bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254)
            || bytes == Data([255, 255, 255, 255]) || bytes.prefix(3) == Data([224, 0, 0]) { return true }
        if (224...239).contains(bytes[0]) { return false }
        return onLink(bytes, family: AF_INET)
    }

    private static func mappedIPv4(_ bytes: Data) -> Data? {
        guard bytes.prefix(12) == Data(Array(repeating: 0, count: 10) + [255, 255]) else { return nil }
        return Data(bytes.suffix(4))
    }

    private static func onLink(_ target: Data, family: Int32) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return false }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let node = cursor {
            let item = node.pointee
            cursor = item.ifa_next
            guard item.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.ifa_addr, let mask = item.ifa_netmask,
                  Int32(address.pointee.sa_family) == family else { continue }
            let bytes: Data
            let maskBytes: Data
            if family == AF_INET {
                guard let offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr) else { continue }
                bytes = addressBytes(address, offset: offset, count: 4)
                maskBytes = addressBytes(mask, offset: offset, count: 4)
            } else {
                guard let offset = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr) else { continue }
                bytes = addressBytes(address, offset: offset, count: 16)
                maskBytes = addressBytes(mask, offset: offset, count: 16)
            }
            guard maskBytes.contains(where: { $0 != 0 }) else { continue }
            if zip(zip(target, bytes), maskBytes).allSatisfy({ pair, mask in
                pair.0 & mask == pair.1 & mask
            }) { return true }
        }
        return false
    }

    private static func addressBytes(_ address: UnsafePointer<sockaddr>, offset: Int, count: Int) -> Data {
        let available = max(0, min(count, Int(address.pointee.sa_len) - offset))
        guard available > 0 else { return Data(repeating: 0, count: count) }
        var bytes = Data(bytes: UnsafeRawPointer(address).advanced(by: offset), count: available)
        bytes.append(Data(repeating: 0, count: count - available))
        return bytes
    }
}
