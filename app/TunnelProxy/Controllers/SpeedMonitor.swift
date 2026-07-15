import Foundation
import Combine

/// Samples system-wide network throughput and publishes human-readable
/// download / upload rates for the menu bar. Rates are computed from the delta
/// of per-interface byte counters between ticks (excludes loopback).
@MainActor
final class SpeedMonitor: ObservableObject {
    @Published private(set) var downText: String = "0 KB/s"
    @Published private(set) var upText: String = "0 KB/s"

    private var timer: Timer?
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastSample: Date?

    func start() {
        guard timer == nil else { return }
        // Seed counters so the first tick shows a real delta, not a huge spike.
        let (bin, bout) = Self.byteCounters()
        lastIn = bin
        lastOut = bout
        lastSample = Date()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        let (bin, bout) = Self.byteCounters()
        let elapsed = now.timeIntervalSince(lastSample ?? now)
        guard elapsed > 0 else { return }

        // Guard against counter wrap / interface reset (delta would go negative).
        let dIn = bin >= lastIn ? Double(bin - lastIn) : 0
        let dOut = bout >= lastOut ? Double(bout - lastOut) : 0

        downText = Self.format(bytesPerSec: dIn / elapsed)
        upText = Self.format(bytesPerSec: dOut / elapsed)

        lastIn = bin
        lastOut = bout
        lastSample = now
    }

    // MARK: - Counters

    /// Sum received/sent bytes across all active non-loopback interfaces.
    private static func byteCounters() -> (inBytes: UInt64, outBytes: UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }               // skip loopback
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = cur.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            totalIn += UInt64(stats.ifi_ibytes)
            totalOut += UInt64(stats.ifi_obytes)
        }
        return (totalIn, totalOut)
    }

    // MARK: - Formatting

    /// Compact rate string, e.g. "0 KB/s", "82 KB/s", "1.4 MB/s".
    static func format(bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1024 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        return String(format: "%.1f MB/s", mb)
    }
}
