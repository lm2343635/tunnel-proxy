import Foundation
import Combine
import Darwin

/// Publishes the SSH tunnel's download and upload rates. App-managed sessions
/// share counters with the ProxyCommand relay. Legacy shell-launched sessions
/// can still be sampled through their SSH process's TCP sequence numbers.
@MainActor
final class SpeedMonitor: ObservableObject {
    @Published private(set) var downText: String = "0 KB/s"
    @Published private(set) var upText: String = "0 KB/s"

    /// Live down/up byte-rate values (bytes per second), for the tiles that show
    /// numeric throughput without re-parsing the formatted text.
    @Published private(set) var downRate: Double = 0
    @Published private(set) var upRate: Double = 0

    /// A rolling window of recent per-second throughput samples, oldest first.
    /// Drives the Connection tab's sparkline. Capped at `historyCapacity`.
    @Published private(set) var history: [SpeedSample] = []
    private let historyCapacity = 60
    /// The rolling-window size, exposed so charts can pin their x-domain to the
    /// full width (bars fill from the left, then scroll).
    var historyCapacityValue: Int { historyCapacity }

    /// Invoked once per sampling tick with the bytes transferred since the last
    /// tick and the elapsed interval. `TrafficRecorder` subscribes to persist a
    /// usage time-series — reusing these deltas means no second sampling pass and
    /// inherits the reconnect/wrap-safety guarantees below. Fires only when a
    /// valid delta exists (both this and the previous sample present); a tick that
    /// only seeds the baseline, or where the tunnel is down, does not fire.
    var onDelta: ((_ down: UInt64, _ up: UInt64, _ elapsed: TimeInterval) -> Void)?

    private var socksPort: Int = 1080
    private var timer: Timer?
    private var sampling = false
    private let engine: TunnelEngine
    private var samplingGeneration = 0
    private var previous: TransportSample?
    private var prevAt: Date?

    init(engine: TunnelEngine) { self.engine = engine }

    // MARK: - Control

    /// Begin monitoring the tunnel serving `socksPort` (mirrors the
    /// "Show network speed" preference being switched on).
    func start(socksPort: Int) {
        updateSocksPort(socksPort)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        samplingGeneration &+= 1
        previous = nil
        prevAt = nil
        showZero()
        history.removeAll()
    }

    /// Follow a SOCKS port change from Settings.
    func updateSocksPort(_ port: Int) {
        guard port != socksPort else { return }
        socksPort = port
        samplingGeneration &+= 1
        previous = nil
        prevAt = nil
    }

    // MARK: - Sampling

    private func tick() {
        guard !sampling else { return }
        sampling = true
        let port = socksPort
        let generation = samplingGeneration
        let now = Date()
        Task.detached(priority: .utility) { [weak self, engine] in
            let sample: TransportSample?
            if let counters = await engine.transportCounters() {
                sample = counters.read().map { .managed(counters, down: $0.down, up: $0.up) }
            } else {
                let connections = Self.tunnelConnections(socksPort: port)
                sample = connections.isEmpty ? nil : .legacy(connections)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sampling = false
                guard self.timer != nil, self.samplingGeneration == generation else { return }
                defer {
                    self.previous = sample
                    self.prevAt = now
                }
                guard let sample, let previous = self.previous,
                      let delta = sample.delta(since: previous), let prevAt = self.prevAt else {
                    self.showZero()
                    self.record(down: 0, up: 0)
                    return
                }
                let elapsed = now.timeIntervalSince(prevAt)
                guard elapsed > 0 else { return }

                let down = Double(delta.down) / elapsed
                let up = Double(delta.up) / elapsed
                self.downRate = down
                self.upRate = up
                self.downText = Self.format(bytesPerSec: down)
                self.upText = Self.format(bytesPerSec: up)
                self.record(down: down, up: up)
                self.onDelta?(delta.down, delta.up, elapsed)
            }
        }
    }

    private func showZero() {
        if downText != "0 KB/s" { downText = "0 KB/s" }
        if upText != "0 KB/s" { upText = "0 KB/s" }
        downRate = 0
        upRate = 0
    }

    /// Append one throughput sample to the rolling window, evicting the oldest
    /// when full so the sparkline always shows the most recent `historyCapacity`.
    private func record(down: Double, up: Double) {
        history.append(SpeedSample(down: down, up: up))
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
    }

    // MARK: - Kernel TCP table

    /// A TCP connection 4-tuple (foreign address kept as two raw 8-byte halves).
    struct ConnKey: Hashable {
        let faddrHi: UInt64, faddrLo: UInt64
        let lport: UInt16, fport: UInt16
    }
    struct SeqCounters {
        let rcvNxt: UInt32, sndMax: UInt32
    }

    private enum TransportSample {
        case managed(SSHTransportCounters, down: UInt64, up: UInt64)
        case legacy([ConnKey: SeqCounters])

        func delta(since previous: Self) -> (down: UInt64, up: UInt64)? {
            switch (self, previous) {
            case let (.managed(session, down, up), .managed(oldSession, oldDown, oldUp)):
                guard session === oldSession, down >= oldDown, up >= oldUp else { return nil }
                return (down - oldDown, up - oldUp)
            case let (.legacy(connections), .legacy(oldConnections)):
                var down: UInt64 = 0, up: UInt64 = 0
                var hasBaseline = false
                for (key, current) in connections {
                    guard let old = oldConnections[key] else { continue }
                    hasBaseline = true
                    down += UInt64(current.rcvNxt &- old.rcvNxt)
                    up += UInt64(current.sndMax &- old.sndMax)
                }
                return hasBaseline ? (down, up) : nil
            default:
                return nil
            }
        }
    }

    /// Read `net.inet.tcp.pcblist_n` and return the sequence counters of every
    /// non-loopback connection owned by the process listening on `socksPort`.
    /// Blocking (~2 ms); call off the main thread.
    ///
    /// Buffer layout (validated against this kernel and netstat -anv): an
    /// xinpgen header, then per-socket groups of items, each item prefixed by
    /// {u32 len, u32 kind} and 8-byte aligned. A group starts with its INPCB.
    /// The kernel's structs are packed; field offsets below were verified by
    /// hexdump against known connections:
    ///   INPCB  (kind 0x010): fport@16 BE, lport@18 BE, vflag@44, faddr@48(16B)
    ///   SOCKET (kind 0x001): so_last_pid@68
    ///   TCPCB  (kind 0x020): snd_max@52, rcv_nxt@80
    nonisolated private static func tunnelConnections(socksPort: Int) -> [ConnKey: SeqCounters] {
        guard let port = UInt16(exactly: socksPort), port != 0 else { return [:] }
        var len = 0
        guard sysctlbyname("net.inet.tcp.pcblist_n", nil, &len, nil, 0) == 0, len > 24 else { return [:] }
        len += len / 8 + 1024                       // slack: table may grow between calls
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctlbyname("net.inet.tcp.pcblist_n", &buf, &len, nil, 0) == 0 else { return [:] }

        struct Entry {
            var key = ConnKey(faddrHi: 0, faddrLo: 0, lport: 0, fport: 0)
            var vflag: UInt8 = 0
            var pid: Int32 = 0
            var seq: SeqCounters?
            var haveInp = false
        }

        var entries: [Entry] = []
        entries.reserveCapacity(512)
        buf.withUnsafeBytes { raw in
            var cur = Entry()
            var off = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))  // skip xinpgen
            while off + 8 <= len {
                let l = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
                let kind = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                if l < 8 || off + l > len { break }
                switch kind {
                case 0x010 where l >= 64:            // XSO_INPCB — starts a group
                    if cur.haveInp { entries.append(cur) }
                    cur = Entry()
                    cur.key = ConnKey(
                        faddrHi: raw.loadUnaligned(fromByteOffset: off + 48, as: UInt64.self),
                        faddrLo: raw.loadUnaligned(fromByteOffset: off + 56, as: UInt64.self),
                        lport: UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: off + 18, as: UInt16.self)),
                        fport: UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: off + 16, as: UInt16.self)))
                    cur.vflag = raw.loadUnaligned(fromByteOffset: off + 44, as: UInt8.self)
                    cur.haveInp = true
                case 0x001 where l >= 72:            // XSO_SOCKET
                    cur.pid = raw.loadUnaligned(fromByteOffset: off + 68, as: Int32.self)
                case 0x020 where l >= 84:            // XSO_TCPCB
                    cur.seq = SeqCounters(
                        rcvNxt: raw.loadUnaligned(fromByteOffset: off + 80, as: UInt32.self),
                        sndMax: raw.loadUnaligned(fromByteOffset: off + 52, as: UInt32.self))
                default:
                    break                            // rcvbuf/sndbuf/stats/trailer: skip
                }
                off += (l + 7) & ~7                  // items are ROUNDUP64-spaced
            }
            if cur.haveInp { entries.append(cur) }
        }

        // The tunnel process = whoever listens on the SOCKS port.
        var listener: Int32 = -1
        for e in entries where e.key.lport == port && e.key.fport == 0 {
            listener = e.pid
        }
        guard listener > 0 else { return [:] }

        func isRemote(_ e: Entry) -> Bool {
            if e.vflag & 0x1 != 0 {                  // INP_IPV4: addr in bytes 12–15
                let addr = UInt32(truncatingIfNeeded: e.key.faddrLo >> 32)
                if addr == 0 { return false }        // unbound / listener
                let firstOctet = UInt8(truncatingIfNeeded: e.key.faddrLo >> 32)
                return firstOctet != 127             // 127/8 loopback
            }
            if e.vflag & 0x2 != 0 {                  // INP_IPV6
                if e.key.faddrHi == 0 && e.key.faddrLo == 0 { return false }          // ::
                if e.key.faddrHi == 0 && e.key.faddrLo == 0x0100_0000_0000_0000 { return false } // ::1
                return true
            }
            return false
        }

        var result: [ConnKey: SeqCounters] = [:]
        for e in entries where e.pid == listener && e.seq != nil && isRemote(e) {
            result[e.key] = e.seq
        }
        return result
    }

    // MARK: - Formatting

    /// Compact rate string, e.g. "0KB/s", "82KB/s", "1.02MB/s". No space before
    /// the unit so the menu bar column stays as narrow as possible.
    static func format(bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1 { return "0KB/s" }
        if kb < 1024 { return "\(Int(kb.rounded()))KB/s" }
        let mb = kb / 1024
        return String(format: "%.2fMB/s", mb)
    }
}

/// One 1-Hz throughput sample: down/up rates in bytes per second. Identifiable by
/// a monotonic sequence so `Chart` can plot the rolling window on an index axis
/// without needing wall-clock timestamps.
struct SpeedSample: Identifiable, Equatable {
    private static var counter: UInt64 = 0
    let id: UInt64
    let down: Double
    let up: Double

    @MainActor
    init(down: Double, up: Double) {
        Self.counter &+= 1
        self.id = Self.counter
        self.down = down
        self.up = up
    }
}
