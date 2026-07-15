import Foundation

/// Value types for traffic recording & statistics. Bytes are the tunnel's own
/// on-wire bytes (compressed, since `ssh -C`), matching `SpeedMonitor` — see
/// `TrafficRecorder` for how these are produced.

/// The granularity of a rollup bucket.
enum TrafficGranularity: String, Codable, CaseIterable {
    case hour
    case day

    /// Truncate `date` to this bucket's start, in the given calendar (local tz).
    func bucketStart(for date: Date, calendar: Calendar) -> Date {
        switch self {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}

/// One rollup bucket: total down/up bytes within `[start, start + granularity)`.
struct TrafficBucket: Identifiable, Equatable {
    var start: Date
    var granularity: TrafficGranularity
    var down: UInt64
    var up: UInt64

    var id: Date { start }
    var total: UInt64 { down &+ up }
}

/// One connected span. Open while `endedAt == nil`; totals accumulate live.
struct TrafficSession: Identifiable, Equatable {
    var id: UUID
    var serverID: UUID?
    var serverName: String
    var startedAt: Date
    var endedAt: Date?
    var down: UInt64
    var up: UInt64

    var total: UInt64 { down &+ up }
    var isOpen: Bool { endedAt == nil }
}

/// Aggregate totals for a query range.
struct TrafficTotals: Equatable {
    var down: UInt64 = 0
    var up: UInt64 = 0
    var total: UInt64 { down &+ up }
}

/// Human-readable byte-count formatting for cumulative totals, e.g. "0 B",
/// "812 KB", "2.4 GB". Companion to `SpeedMonitor.format(bytesPerSec:)` which
/// formats *rates*.
enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        let kb = b / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        if gb < 1024 { return String(format: "%.2f GB", gb) }
        let tb = gb / 1024
        return String(format: "%.2f TB", tb)
    }
}
