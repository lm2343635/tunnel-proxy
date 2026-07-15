import Foundation
import Combine

/// Turns `SpeedMonitor`'s per-tick byte deltas into a durable usage time-series.
///
/// Pipeline (see plan → Recording pipeline):
///   SpeedMonitor.onDelta → accumulate into the open session + hour/day buckets
///   → flush to `TrafficStore` every ~`flushInterval` (and on disconnect/quit)
///   → prune old data.
///
/// Correctness is inherited from `SpeedMonitor`: it only emits deltas when both
/// consecutive samples share a 4-tuple, so watchdog reconnects contribute 0 and
/// never spike, and its counters are u32-wrap-safe. This type never re-reads the
/// TCP table — it only consumes those deltas.
@MainActor
final class TrafficRecorder: ObservableObject {

    /// Set from the Settings toggle; when false the recorder ignores deltas and
    /// keeps no open session.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled { closeSession(at: Date()) }
        }
    }

    /// Bumped after every flush so the Statistics window can refresh live.
    @Published private(set) var revision: Int = 0

    let store: TrafficStore

    private let flushInterval: TimeInterval = 12
    private var flushTimer: Timer?
    private var calendar = Calendar.current

    /// Accumulated-but-unwritten bucket deltas, keyed by (granularity, start).
    private var pendingBuckets: [BucketKey: (down: UInt64, up: UInt64)] = [:]

    /// The currently open session, mutated as deltas arrive.
    private var session: TrafficSession?
    /// Whether the underlying connection is up (gates session open/close).
    private var connected = false

    private struct BucketKey: Hashable {
        let start: Date
        let granularity: TrafficGranularity
    }

    init(store: TrafficStore = TrafficStore()) {
        self.store = store
    }

    // MARK: - Wiring

    /// Attach to a `SpeedMonitor`; its per-tick deltas start feeding this recorder.
    func attach(to monitor: SpeedMonitor) {
        monitor.onDelta = { [weak self] down, up, elapsed in
            // onDelta is invoked on the main actor (SpeedMonitor.tick runs there).
            MainActor.assumeIsolated { self?.ingest(down: down, up: up, elapsed: elapsed) }
        }
        startFlushTimer()
    }

    // MARK: - Connection state

    /// Called by `TunnelController` when the connection state changes. Opens a
    /// session on first connect and closes it when the tunnel goes down.
    func setConnected(_ isConnected: Bool, serverID: UUID?, serverName: String) {
        guard isConnected != connected else {
            // Server may have changed while staying connected: rotate the session.
            if isConnected, isEnabled, session?.serverID != serverID {
                closeSession(at: Date())
                openSession(serverID: serverID, serverName: serverName, at: Date())
            }
            return
        }
        connected = isConnected
        if isConnected {
            if isEnabled { openSession(serverID: serverID, serverName: serverName, at: Date()) }
        } else {
            closeSession(at: Date())
        }
    }

    // MARK: - Ingest

    private func ingest(down: UInt64, up: UInt64, elapsed: TimeInterval) {
        guard isEnabled, connected, (down > 0 || up > 0) else { return }
        let now = Date()

        // Session totals.
        if session == nil {
            // Deltas arrived before an explicit open (e.g. recording toggled on
            // mid-connection): open one now.
            openSession(serverID: nil, serverName: "", at: now)
        }
        session?.down &+= down
        session?.up &+= up

        // Bucket the delta by its own timestamp (clock-jump safe — we never do
        // arithmetic relative to "the current hour", we truncate `now`).
        for gran in TrafficGranularity.allCases {
            let start = gran.bucketStart(for: now, calendar: calendar)
            let key = BucketKey(start: start, granularity: gran)
            var acc = pendingBuckets[key] ?? (0, 0)
            acc.down &+= down
            acc.up &+= up
            pendingBuckets[key] = acc
        }
    }

    // MARK: - Sessions

    private func openSession(serverID: UUID?, serverName: String, at date: Date) {
        session = TrafficSession(id: UUID(), serverID: serverID, serverName: serverName,
                                 startedAt: date, endedAt: nil, down: 0, up: 0)
        if let s = session { store.upsertSession(s) }
    }

    private func closeSession(at date: Date) {
        guard var s = session else { return }
        flush()                       // persist any pending bucket bytes first
        s.endedAt = date
        session = s
        store.upsertSession(s)
        session = nil
    }

    // MARK: - Flush

    private func startFlushTimer() {
        flushTimer?.invalidate()
        let t = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    /// Write pending bucket deltas and the open session to disk, then prune.
    /// Cheap and idempotent — safe to call on a timer, on disconnect, and on quit.
    func flush() {
        let now = Date()
        if !pendingBuckets.isEmpty {
            let deltas = pendingBuckets.map {
                BucketDelta(start: $0.key.start, granularity: $0.key.granularity,
                            down: $0.value.down, up: $0.value.up)
            }
            pendingBuckets.removeAll(keepingCapacity: true)
            store.addToBuckets(deltas)
        }
        if let s = session { store.upsertSession(s) }
        store.prune(now: now)
        revision &+= 1
    }

    /// Final flush on app termination (call from `applicationWillTerminate`).
    func shutdown() {
        closeSession(at: Date())
        flush()
        flushTimer?.invalidate()
        flushTimer = nil
    }

    // MARK: - Maintenance

    /// Wipe all recorded statistics.
    func clearAll() {
        session = nil
        pendingBuckets.removeAll()
        store.clear()
        revision &+= 1
    }
}
