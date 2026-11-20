import Foundation

enum RoutingHistoryChecks {
    struct Failure: Error { let message: String }

    static func run(in directory: URL) throws {
        let location = directory.appendingPathComponent("history.sqlite")
        let outboxLocation = directory.appendingPathComponent("outbox.sqlite")
        let history = RoutingHistoryStore(location: location)
        let outbox = RoutingHistoryStore(location: outboxLocation)
        let claude = RoutingAppIdentity(team: "test", identifier: "claude")
        let chrome = RoutingAppIdentity(team: "test", identifier: "chrome")
        let owner = UUID()
        let anotherOwner = UUID()
        let request = RoutingHistoryRequest(historySession: UUID(), historyAcknowledgements: [])
        let message = try JSONEncoder().encode(request)
        try check((try? JSONDecoder().decode(RoutingControl.self, from: message)) == nil,
                  "an older provider cannot interpret a history request as a control heartbeat")
        let now = Date.now

        func event(_ app: RoutingAppIdentity, _ host: String, time: Date? = nil) -> RoutingEvent {
            RoutingEvent(application: app, destination: host, decision: .blocked, reason: "Timed out", time: time ?? now)
        }

        let empty = try history.read(claude)
        try check(empty.events.isEmpty, "a fresh history is empty")

        let first = event(claude, "first.example")
        let blocked = event(claude, "2001:db8::1")
        let chromeEvents = (0...RoutingHistoryStore.perAppLimit).map {
            event(chrome, "host\($0).example", time: now.addingTimeInterval(Double($0 / 100 - 12)))
        }
        try history.append([first, blocked, first] + chromeEvents)

        let reopened = RoutingHistoryStore(location: location)
        let claudePage = try reopened.read(claude)
        try check(Set(claudePage.events.map(\.id)) == [first.id, blocked.id], "history survives reopen and deduplicates retries")
        try check(claudePage.events.contains { $0.destination == "2001:db8::1" && $0.reason == "Timed out" },
                  "history round-trips the destination and failure reason")

        let latest = try reopened.read(chrome)
        let cursor = try require(latest.events.last)
        let added = event(chrome, "new.example", time: now.addingTimeInterval(1))
        try history.append([added])
        let earlier = try reopened.read(chrome, before: cursor)
        let loaded = try reopened.read(chrome, through: earlier.events.last)
        let beforeAll = event(chrome, "cursor.example", time: now.addingTimeInterval(-60))
        let all = try reopened.read(chrome, through: beforeAll)
        let byCursor = (chromeEvents + [added]).sorted {
            ($0.time, $0.id.uuidString) > ($1.time, $1.id.uuidString)
        }
        try check(latest.events.count == 50 && latest.hasEarlier && earlier.events.count == 50,
                  "history pages contain 50 events")
        try check(Set(latest.events.map(\.id)).isDisjoint(with: earlier.events.map(\.id))
                  && loaded.events.count == 101 && loaded.events.contains { $0.id == added.id },
                  "new arrivals preserve the earlier-page cursor and loaded range")
        try check(all.events.map(\.id) == byCursor.prefix(RoutingHistoryStore.perAppLimit).map(\.id)
                  && !all.hasEarlier, "the per-app cap evicts only that app’s oldest events")

        try outbox.append([first, blocked], owner: owner)
        try outbox.append([event(chrome, "other-user.example")], owner: anotherOwner)
        let pending = try RoutingHistoryStore(location: outboxLocation).pending(for: owner, acknowledging: [])
        try history.append(pending)
        let otherPending = try outbox.pending(for: anotherOwner, acknowledging: pending.map(\.id))
        let retried = try outbox.pending(for: owner, acknowledging: [])
        let afterAck = try outbox.pending(for: owner, acknowledging: pending.map(\.id))
        try check(Set(pending.map(\.id)) == [first.id, blocked.id] && retried.map(\.id) == pending.map(\.id) && afterAck.isEmpty && otherPending.count == 1,
                  "the durable outbox only delivers and acknowledges the requesting owner’s events")

        let future = now.addingTimeInterval(RoutingHistoryStore.retention + 60)
        let expired = try reopened.read(claude, now: future)
        try history.append([], now: future)
        let pruned = try reopened.read(claude, now: now)
        try check(expired.events.isEmpty && pruned.events.isEmpty, "expiry hides old rows before physical pruning")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("PASS: \(message)")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "Missing history cursor") }
        return value
    }
}
