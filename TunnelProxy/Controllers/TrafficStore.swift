import Foundation
import SQLite3

/// On-disk persistence for traffic statistics, backed by the system SQLite
/// (`libsqlite3`, no third-party dependency). Stores per-connection **sessions**
/// and per-hour / per-day **rollup buckets** — raw per-tick samples are *not*
/// persisted (the recorder accumulates them in memory and only writes rollups),
/// which keeps the file tiny and range queries cheap.
///
/// Thread-safe: all access is serialized on a private queue, so the recorder can
/// call `flush`/`prune` from background tasks while the UI queries on the main
/// thread. `SQLITE_TRANSIENT` is used for all bound text so SQLite copies it.
final class TrafficStore {

    /// Retention limits (see plan → Retention). Buckets are tiny (one row each),
    /// so we keep a generous window; sessions are capped by count.
    enum Retention {
        static let hourlyDays = 90
        static let dailyDays = 3650       // ~10 years of daily rows is trivial
        static let maxSessions = 2000
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.xwkj.tunnelproxy.trafficstore")
    private let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = AppPaths.trafficStoreURL) {
        self.path = url.path
        AppPaths.ensureSupportDirectory()
        queue.sync {
            if sqlite3_open(path, &db) != SQLITE_OK {
                NSLog("TrafficStore: failed to open \(path): \(lastError)")
                db = nil
                return
            }
            exec("PRAGMA journal_mode=WAL;")
            exec("PRAGMA synchronous=NORMAL;")
            createSchema()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS buckets (
            start INTEGER NOT NULL,        -- unix seconds, bucket boundary
            granularity TEXT NOT NULL,     -- 'hour' | 'day'
            down INTEGER NOT NULL DEFAULT 0,
            up INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (start, granularity)
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            server_id TEXT,
            server_name TEXT NOT NULL DEFAULT '',
            started_at INTEGER NOT NULL,
            ended_at INTEGER,              -- NULL while open
            down INTEGER NOT NULL DEFAULT 0,
            up INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_buckets_gran_start ON buckets(granularity, start);")
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);")
    }

    // MARK: - Writes

    /// Add `down`/`up` bytes to the (hour, day) buckets containing `start`s.
    /// `deltas` are pre-bucketed by the recorder: keyed by bucket boundary.
    func addToBuckets(_ deltas: [BucketDelta]) {
        guard !deltas.isEmpty else { return }
        queue.sync {
            exec("BEGIN;")
            for d in deltas {
                let sql = """
                INSERT INTO buckets (start, granularity, down, up)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(start, granularity)
                DO UPDATE SET down = down + excluded.down, up = up + excluded.up;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(stmt, 1, Int64(d.start.timeIntervalSince1970))
                sqlite3_bind_text(stmt, 2, d.granularity.rawValue, -1, Self.transient)
                sqlite3_bind_int64(stmt, 3, Int64(bitPattern: d.down))
                sqlite3_bind_int64(stmt, 4, Int64(bitPattern: d.up))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            exec("COMMIT;")
        }
    }

    /// Insert or update a session row (upsert on id).
    func upsertSession(_ s: TrafficSession) {
        queue.sync {
            let sql = """
            INSERT INTO sessions (id, server_id, server_name, started_at, ended_at, down, up)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                server_id = excluded.server_id,
                server_name = excluded.server_name,
                ended_at = excluded.ended_at,
                down = excluded.down,
                up = excluded.up;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, s.id.uuidString, -1, Self.transient)
            if let sid = s.serverID {
                sqlite3_bind_text(stmt, 2, sid.uuidString, -1, Self.transient)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, s.serverName, -1, Self.transient)
            sqlite3_bind_int64(stmt, 4, Int64(s.startedAt.timeIntervalSince1970))
            if let end = s.endedAt {
                sqlite3_bind_int64(stmt, 5, Int64(end.timeIntervalSince1970))
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_int64(stmt, 6, Int64(bitPattern: s.down))
            sqlite3_bind_int64(stmt, 7, Int64(bitPattern: s.up))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Queries

    /// Buckets of `granularity` with `start` in `[from, to)`, optionally filtered
    /// to one server (server filtering applies to sessions only — buckets are not
    /// per-server, so `serverID` is ignored here and honored in `sessions`).
    func buckets(granularity: TrafficGranularity, from: Date, to: Date) -> [TrafficBucket] {
        queue.sync {
            let sql = """
            SELECT start, down, up FROM buckets
            WHERE granularity = ? AND start >= ? AND start < ?
            ORDER BY start ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, granularity.rawValue, -1, Self.transient)
            sqlite3_bind_int64(stmt, 2, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 3, Int64(to.timeIntervalSince1970))
            var out: [TrafficBucket] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let start = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
                let down = UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                let up = UInt64(bitPattern: sqlite3_column_int64(stmt, 2))
                out.append(TrafficBucket(start: start, granularity: granularity, down: down, up: up))
            }
            return out
        }
    }

    /// Sessions that overlap `[from, to)`, newest first, optionally one server.
    func sessions(from: Date, to: Date, serverID: UUID? = nil, limit: Int = 500) -> [TrafficSession] {
        queue.sync {
            var sql = """
            SELECT id, server_id, server_name, started_at, ended_at, down, up
            FROM sessions
            WHERE started_at < ? AND (ended_at IS NULL OR ended_at >= ?)
            """
            if serverID != nil { sql += " AND server_id = ?" }
            sql += " ORDER BY started_at DESC LIMIT ?;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            sqlite3_bind_int64(stmt, idx, Int64(to.timeIntervalSince1970)); idx += 1
            sqlite3_bind_int64(stmt, idx, Int64(from.timeIntervalSince1970)); idx += 1
            if let sid = serverID {
                sqlite3_bind_text(stmt, idx, sid.uuidString, -1, Self.transient); idx += 1
            }
            sqlite3_bind_int(stmt, idx, Int32(limit))

            var out: [TrafficSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0),
                      let uuid = UUID(uuidString: String(cString: idC)) else { continue }
                let serverID: UUID? = sqlite3_column_text(stmt, 1).flatMap {
                    UUID(uuidString: String(cString: $0))
                }
                let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let started = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3)))
                let ended: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
                let down = UInt64(bitPattern: sqlite3_column_int64(stmt, 5))
                let up = UInt64(bitPattern: sqlite3_column_int64(stmt, 6))
                out.append(TrafficSession(id: uuid, serverID: serverID, serverName: name,
                                          startedAt: started, endedAt: ended, down: down, up: up))
            }
            return out
        }
    }

    /// Totals for `[from, to)`, summed from the buckets of the **same
    /// granularity** the chart uses, so totals always agree with the range-clipped
    /// bars (a session straddling the range edge would otherwise inflate the
    /// total). Buckets are not per-server, so this is not server-filtered — the
    /// server picker scopes the session list only.
    func totals(granularity: TrafficGranularity, from: Date, to: Date) -> TrafficTotals {
        queue.sync {
            let sql = """
            SELECT COALESCE(SUM(down),0), COALESCE(SUM(up),0) FROM buckets
            WHERE granularity = ? AND start >= ? AND start < ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return TrafficTotals() }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, granularity.rawValue, -1, Self.transient)
            sqlite3_bind_int64(stmt, 2, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 3, Int64(to.timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return TrafficTotals() }
            return TrafficTotals(down: UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                                 up: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)))
        }
    }

    /// Timestamp of the earliest recorded data, for "Recording since …".
    func earliestDate() -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT MIN(start) FROM buckets;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
        }
    }

    // MARK: - Maintenance

    /// Drop buckets older than the retention windows and trim old sessions.
    /// `now` is passed in (not read from a clock) so the recorder controls it.
    func prune(now: Date) {
        queue.sync {
            let hourlyCutoff = Int64(now.addingTimeInterval(-Double(Retention.hourlyDays) * 86400).timeIntervalSince1970)
            let dailyCutoff = Int64(now.addingTimeInterval(-Double(Retention.dailyDays) * 86400).timeIntervalSince1970)
            exec("DELETE FROM buckets WHERE granularity='hour' AND start < \(hourlyCutoff);")
            exec("DELETE FROM buckets WHERE granularity='day'  AND start < \(dailyCutoff);")
            // Keep only the most recent N sessions.
            exec("""
            DELETE FROM sessions WHERE id NOT IN (
                SELECT id FROM sessions ORDER BY started_at DESC LIMIT \(Retention.maxSessions)
            );
            """)
        }
    }

    /// Wipe all recorded data ("Clear statistics…").
    func clear() {
        queue.sync {
            exec("DELETE FROM buckets;")
            exec("DELETE FROM sessions;")
            exec("VACUUM;")
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("TrafficStore exec failed: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    private var lastError: String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }
}

/// A pre-bucketed delta the recorder hands to `addToBuckets`.
struct BucketDelta {
    let start: Date
    let granularity: TrafficGranularity
    let down: UInt64
    let up: UInt64
}
