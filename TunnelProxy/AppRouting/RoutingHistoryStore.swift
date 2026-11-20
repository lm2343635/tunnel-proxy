import Foundation
import Security
import SQLite3

struct RoutingHistoryStore: Sendable {
    static let pageSize = 50
    static let perAppLimit = 1_000
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    struct Page: Sendable {
        var events: [RoutingEvent] = []
        var hasEarlier = false
    }

    private enum Failure: Error {
        case containerUnavailable
        case database(Int32)
        case invalidEvent
    }

    private let location: URL?
    private let filename: String
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(location: URL? = nil, filename: String = "routing-history.sqlite") {
        self.location = location
        self.filename = filename
    }

    static func cutoff(at now: Date = .now) -> Date {
        now.addingTimeInterval(-retention)
    }

    func append(_ events: [RoutingEvent], owner: UUID? = nil, now: Date = .now) throws {
        let url = try databaseURL()
        try withDatabase(at: url, writable: true) { db in
            try execute(db, "PRAGMA secure_delete = ON")
            try execute(db, """
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY NOT NULL,
                    owner TEXT NOT NULL,
                    team TEXT NOT NULL,
                    application TEXT NOT NULL,
                    time REAL NOT NULL,
                    payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS events_by_app ON events(owner, team, application, time DESC, id DESC);
                CREATE INDEX IF NOT EXISTS events_by_owner ON events(owner, time, id);
                CREATE INDEX IF NOT EXISTS events_by_time ON events(time);
                """)
            let cutoff = Self.cutoff(at: now)
            let encoder = JSONEncoder()
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try statement(db, "INSERT OR IGNORE INTO events VALUES (?, ?, ?, ?, ?, ?)") { insert in
                    for event in events where event.time >= cutoff {
                        try bind(insert, 1, event.id.uuidString)
                        try bind(insert, 2, owner?.uuidString ?? "")
                        try bind(insert, 3, event.application.team)
                        try bind(insert, 4, event.application.identifier)
                        try check(sqlite3_bind_double(insert, 5, event.time.timeIntervalSince1970))
                        let payload = String(decoding: try encoder.encode(event), as: UTF8.self)
                        try bind(insert, 6, payload)
                        try check(sqlite3_step(insert), expected: SQLITE_DONE)
                        try check(sqlite3_reset(insert))
                    }
                }
                try statement(db, "DELETE FROM events WHERE time < ?") { delete in
                    try check(sqlite3_bind_double(delete, 1, cutoff.timeIntervalSince1970))
                    try check(sqlite3_step(delete), expected: SQLITE_DONE)
                }
                try statement(db, """
                    DELETE FROM events WHERE id IN (
                        SELECT id FROM events WHERE owner = ? AND team = ? AND application = ?
                        ORDER BY time DESC, id DESC LIMIT -1 OFFSET ?
                    )
                    """) { trim in
                    for app in Set(events.map(\.application)) {
                        try bind(trim, 1, owner?.uuidString ?? "")
                        try bind(trim, 2, app.team)
                        try bind(trim, 3, app.identifier)
                        try check(sqlite3_bind_int(trim, 4, Int32(Self.perAppLimit)))
                        try check(sqlite3_step(trim), expected: SQLITE_DONE)
                        try check(sqlite3_reset(trim))
                    }
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// Refresh from the newest event through the oldest loaded event. Earlier
    /// pages use an exclusive cursor so inserts above it cannot shift the page.
    func read(_ app: RoutingAppIdentity, through: RoutingEvent? = nil,
              before: RoutingEvent? = nil, now: Date = .now) throws -> Page {
        let url = try databaseURL()
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Page()
        }
        return try withDatabase(at: url, writable: false) { db in
            let cursorClause = before == nil ? "" : "AND (time, id) < (?, ?)"
            let sql = """
                SELECT payload FROM events
                WHERE owner = '' AND team = ? AND application = ? AND time >= ? \(cursorClause)
                ORDER BY time DESC, id DESC LIMIT ?
                """
            return try statement(db, sql) { select in
                try bind(select, 1, app.team)
                try bind(select, 2, app.identifier)
                try check(sqlite3_bind_double(select, 3, Self.cutoff(at: now).timeIntervalSince1970))
                if let before {
                    try check(sqlite3_bind_double(select, 4, before.time.timeIntervalSince1970))
                    try bind(select, 5, before.id.uuidString)
                }
                let limit = through == nil ? Self.pageSize : Self.perAppLimit
                try check(sqlite3_bind_int(select, before == nil ? 4 : 6, Int32(limit + 1)))
                let decoder = JSONDecoder()
                var page = Page()
                while true {
                    let step = sqlite3_step(select)
                    if step == SQLITE_DONE { return page }
                    try check(step, expected: SQLITE_ROW)
                    let event = try decode(select, with: decoder)
                    if page.events.count == limit || (page.events.count >= Self.pageSize && through.map({
                        (event.time.timeIntervalSince1970, event.id.uuidString)
                            < ($0.time.timeIntervalSince1970, $0.id.uuidString)
                    }) == true) {
                        page.hasEarlier = true
                        return page
                    }
                    page.events.append(event)
                }
            }
        }
    }

    func pending(for owner: UUID, acknowledging ids: [UUID], now: Date = .now) throws -> [RoutingEvent] {
        let url = try databaseURL()
        // The writer initializes the schema before accepting any sync request.
        return try withDatabase(at: url, writable: true) { db in
            if !ids.isEmpty {
                try execute(db, "PRAGMA secure_delete = ON")
                try execute(db, "BEGIN IMMEDIATE")
                do {
                    try statement(db, "DELETE FROM events WHERE owner = ? AND id = ?") { delete in
                        try bind(delete, 1, owner.uuidString)
                        for id in ids.prefix(RoutingHistoryRequest.batchSize) {
                            try bind(delete, 2, id.uuidString)
                            try check(sqlite3_step(delete), expected: SQLITE_DONE)
                            try check(sqlite3_reset(delete))
                        }
                    }
                    try execute(db, "COMMIT")
                } catch {
                    try? execute(db, "ROLLBACK")
                    throw error
                }
            }
            return try statement(db, """
                SELECT payload FROM events WHERE owner = ? AND time >= ? ORDER BY time, id LIMIT ?
                """) { select in
                try bind(select, 1, owner.uuidString)
                try check(sqlite3_bind_double(select, 2, Self.cutoff(at: now).timeIntervalSince1970))
                try check(sqlite3_bind_int(select, 3, Int32(RoutingHistoryRequest.batchSize)))
                let decoder = JSONDecoder()
                var events: [RoutingEvent] = []
                while true {
                    let step = sqlite3_step(select)
                    if step == SQLITE_DONE { return events }
                    try check(step, expected: SQLITE_ROW)
                    events.append(try decode(select, with: decoder))
                }
            }
        }
    }

    private func decode(_ statement: OpaquePointer, with decoder: JSONDecoder) throws -> RoutingEvent {
        guard let payload = sqlite3_column_text(statement, 0) else { throw Failure.invalidEvent }
        return try decoder.decode(RoutingEvent.self, from: Data(String(cString: payload).utf8))
    }

    private func databaseURL() throws -> URL {
        if let location { return location }
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              let group = groups.first(where: { $0.hasSuffix("." + AppRoutingProtocol.providerIdentifier) }),
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure.containerUnavailable
        }
        return directory.appendingPathComponent(filename)
    }

    private func withDatabase<Value>(at url: URL, writable: Bool, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        try check(sqlite3_open_v2(url.path, &database, flags, nil))
        guard let database else { throw Failure.database(SQLITE_CANTOPEN) }
        try check(sqlite3_busy_timeout(database, 1_000))
        return try body(database)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func statement<Value>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        var prepared: OpaquePointer?
        defer { if let prepared { sqlite3_finalize(prepared) } }
        try check(sqlite3_prepare_v2(db, sql, -1, &prepared, nil))
        guard let prepared else { throw Failure.database(SQLITE_ERROR) }
        return try body(prepared)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, Self.transient))
    }

    private func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        guard code == expected else { throw Failure.database(code) }
    }
}
