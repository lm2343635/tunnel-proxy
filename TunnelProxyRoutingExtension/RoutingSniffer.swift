import Foundation

enum RoutingSniffer {
    static let window = 16 * 1024

    enum Result: Equatable {
        case hostname(String), echOrGrease, notApplicable, needMoreData
    }

    // A TLS handshake may span records. Inspect only a bounded prefix and
    // require the entire extension list before trusting any visible SNI.
    static func sniffTLS(_ data: Data) -> Result {
        let bytes = Array(data.prefix(window))
        let incomplete: Result = bytes.count == window ? .notApplicable : .needMoreData
        var offset = 0
        var hello = [UInt8]()
        while offset < bytes.count {
            guard bytes[offset] == 22 else { return .notApplicable }
            guard bytes.count - offset >= 5 else { return incomplete }
            let length = Int(bytes[offset + 3]) * 256 + Int(bytes[offset + 4])
            guard bytes[offset + 1] == 3, length > 0, length <= window else { return .notApplicable }
            offset += 5
            let end = min(offset + length, bytes.count)
            hello.append(contentsOf: bytes[offset..<end])
            if let type = hello.first, type != 1 { return .notApplicable }
            if hello.count >= 4 {
                let size = Int(hello[1]) << 16 | Int(hello[2]) << 8 | Int(hello[3])
                guard size <= window - 4 else { return .notApplicable }
                if hello.count >= 4 + size { return parse(hello[4..<(4 + size)]) }
            }
            offset = end
        }
        return incomplete
    }

    private struct Reader {
        var remaining: ArraySlice<UInt8>

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count <= remaining.count else { return nil }
            let field = remaining.prefix(count)
            remaining = remaining.dropFirst(count)
            return field
        }

        mutating func number(_ width: Int) -> Int? {
            take(width)?.reduce(0) { $0 * 256 + Int($1) }
        }

        mutating func vector(_ width: Int) -> ArraySlice<UInt8>? {
            guard let length = number(width) else { return nil }
            return take(length)
        }
    }

    private static func parse(_ hello: ArraySlice<UInt8>) -> Result {
        var reader = Reader(remaining: hello)
        guard reader.take(34) != nil, let session = reader.vector(1), session.count <= 32,
              let suites = reader.vector(2), !suites.isEmpty, suites.count.isMultiple(of: 2),
              let compression = reader.vector(1), !compression.isEmpty,
              let extensions = reader.vector(2), reader.remaining.isEmpty else { return .notApplicable }
        var fields = Reader(remaining: extensions)
        var hostname: String?
        var sawEncryptedHello = false
        while !fields.remaining.isEmpty {
            guard let type = fields.number(2), let value = fields.vector(2) else { return .notApplicable }
            // ECH (0xfe0d) does not hide the SNI extension that sits next to it:
            // clients that only *grease* ECH — Chromium and BoringSSL stacks,
            // which is what most desktop apps use — still send the plaintext
            // hostname. Bailing out here would throw away the only name we have
            // and force the flow onto its already-resolved IP, so record the
            // extension and keep reading; it is only a dead end when the hello
            // carries no SNI at all.
            if type == 0xfe0d { sawEncryptedHello = true; continue }
            if type == 0 {
                var sni = Reader(remaining: value)
                guard hostname == nil, let list = sni.vector(2), sni.remaining.isEmpty else { return .notApplicable }
                var names = Reader(remaining: list)
                guard names.number(1) == 0, let raw = names.vector(2), names.remaining.isEmpty,
                      raw.allSatisfy({ (33...126).contains($0) }),
                      let name = String(bytes: raw, encoding: .ascii),
                      let normalized = RoutingDomain.normalize(name) else { return .notApplicable }
                hostname = normalized
            }
        }
        if let hostname { return .hostname(hostname) }
        return sawEncryptedHello ? .echOrGrease : .notApplicable
    }
}
