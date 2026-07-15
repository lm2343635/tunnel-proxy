import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Statistics window: recorded traffic volume over time. Mirrors the mockup in
/// `plan/mockups/statistics.svg` — range picker + server filter, headline totals,
/// a stacked down/up usage chart, a session list, and a status bar with export.
struct StatisticsView: View {
    @EnvironmentObject var controller: TunnelController

    @State private var range: StatsRange = .today
    @State private var serverFilter: UUID?           // nil = all servers
    @State private var buckets: [TrafficBucket] = []
    @State private var sessions: [TrafficSession] = []
    @State private var totals = TrafficTotals()
    @State private var earliest: Date?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    totalsRow
                    chartSection
                    sessionsSection
                }
                .padding(16)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: serverFilter) { _, _ in reload() }
        // Live-refresh as the recorder flushes.
        .onReceive(controller.recorder.$revision) { _ in reload() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer()

            if !controller.config.servers.isEmpty {
                Picker("Server", selection: $serverFilter) {
                    Text("All").tag(UUID?.none)
                    ForEach(controller.config.servers) { s in
                        Text(s.displayName).tag(Optional(s.id))
                    }
                }
                .frame(maxWidth: 200)
            }
        }
        .padding(10)
    }

    // MARK: - Totals

    private var totalsRow: some View {
        HStack(spacing: 12) {
            totalCard("Downloaded", ByteFormat.string(totals.down), .blue)
            totalCard("Uploaded", ByteFormat.string(totals.up), .green)
            totalCard("Total", ByteFormat.string(totals.total), .primary)
        }
    }

    private func totalCard(_ title: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage over time").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if buckets.isEmpty {
                emptyChart
            } else {
                Chart {
                    ForEach(buckets) { b in
                        BarMark(
                            x: .value("Time", b.start, unit: chartUnit),
                            y: .value("Down", Double(b.down))
                        )
                        .foregroundStyle(by: .value("Direction", "Down"))
                        BarMark(
                            x: .value("Time", b.start, unit: chartUnit),
                            y: .value("Up", Double(b.up))
                        )
                        .foregroundStyle(by: .value("Direction", "Up"))
                    }
                }
                .chartForegroundStyleScale(["Down": Color.blue, "Up": Color.green])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(ByteFormat.string(UInt64(max(0, bytes))))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
        }
    }

    private var emptyChart: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
            .frame(height: 200)
            .overlay(
                Text("No traffic recorded for this range")
                    .font(.callout).foregroundStyle(.secondary)
            )
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if sessions.isEmpty {
                Text("No sessions in this range")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(sessions) { s in sessionRow(s) }
            }
        }
    }

    private func sessionRow(_ s: TrafficSession) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.isOpen ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(sessionTimeLabel(s))
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(s.serverName.isEmpty ? String(localized: "Unknown") : s.serverName)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text("↓ \(ByteFormat.string(s.down))")
                .font(.system(size: 11.5)).foregroundStyle(.blue)
                .frame(width: 90, alignment: .trailing)
            Text("↑ \(ByteFormat.string(s.up))")
                .font(.system(size: 11.5)).foregroundStyle(.green)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(controller.recordStats ? .green : .gray).frame(width: 8, height: 8)
            Text(recordingStatus).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                exportCSV()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(buckets.isEmpty && sessions.isEmpty)
        }
        .padding(8)
    }

    private var recordingStatus: String {
        if !controller.recordStats {
            return String(localized: "Recording is off")
        }
        if let earliest {
            return String(localized: "Recording since \(earliest.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "No data recorded yet")
    }

    // MARK: - Data

    private var chartUnit: Calendar.Component {
        range == .today ? .hour : .day
    }

    private func reload() {
        let range = self.range
        let serverFilter = self.serverFilter
        let store = controller.recorder.store
        let (from, to) = range.interval()
        let gran: TrafficGranularity = range == .today ? .hour : .day
        loading = true
        Task.detached(priority: .userInitiated) {
            let buckets = store.buckets(granularity: gran, from: from, to: to)
            let sessions = store.sessions(from: from, to: to, serverID: serverFilter)
            let totals = store.totals(granularity: gran, from: from, to: to)
            let earliest = store.earliestDate()
            await MainActor.run {
                self.buckets = buckets
                self.sessions = sessions
                self.totals = totals
                self.earliest = earliest
                self.loading = false
            }
        }
    }

    private func sessionTimeLabel(_ s: TrafficSession) -> String {
        let start = s.startedAt.formatted(date: .omitted, time: .shortened)
        let end = s.endedAt?.formatted(date: .omitted, time: .shortened) ?? "…"
        return "\(start)–\(end)"
    }

    // MARK: - Export

    private func exportCSV() {
        var csv = "bucket_start,granularity,down_bytes,up_bytes\n"
        let iso = ISO8601DateFormatter()
        for b in buckets {
            csv += "\(iso.string(from: b.start)),\(b.granularity.rawValue),\(b.down),\(b.up)\n"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tunnel-traffic-\(range.rawValue).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.data(using: .utf8)?.write(to: url)
        }
    }
}

/// Time ranges offered by the Statistics window.
enum StatsRange: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }

    /// The `[from, to)` interval this range covers, in the current calendar.
    func interval(now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let end = now
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), end)
        case .week:
            let from = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
            return (from, end)
        case .month:
            let from = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? now
            return (from, end)
        case .all:
            return (Date(timeIntervalSince1970: 0), end)
        }
    }
}
