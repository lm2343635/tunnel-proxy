import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Statistics tab: recorded traffic volume over time. Redesigned as Control-Center
/// tiles — range + server filters, three headline stat tiles, a usage chart tile,
/// and a sessions tile with a pinned "recording since" footer. Data loading is
/// unchanged from the original (`reload`, `TrafficStore`, CSV export).
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
        VStack(alignment: .leading, spacing: 12) {
            header
            totalsRow
            chartTile
            sessionsTile
        }
        .padding(DS.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: serverFilter) { _, _ in reload() }
        .onReceive(controller.recorder.$revision) { _ in reload() }
    }

    // MARK: - Header

    private var header: some View {
        TabHeader(title: "Statistics") {
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            if !controller.config.servers.isEmpty {
                Picker("", selection: $serverFilter) {
                    Text("All servers").tag(UUID?.none)
                    ForEach(controller.config.servers) { s in
                        Text(s.displayName).tag(Optional(s.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
        }
    }

    // MARK: - Totals

    private var totalsRow: some View {
        HStack(spacing: 12) {
            statTile("Downloaded", ByteFormat.string(totals.down), DS.dataBlue)
            statTile("Uploaded", ByteFormat.string(totals.up), DS.dataGreen)
            statTile("Total", ByteFormat.string(totals.total), DS.primaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statTile(_ caption: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        Tile(padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 4) {
                TileCaption(caption)
                Text(value)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(color)
            }
        }
    }

    // MARK: - Chart

    private var chartTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TileCaption("Usage over time")
                    Spacer()
                    legend
                }
                if buckets.isEmpty {
                    emptyChart
                } else {
                    chart.frame(height: 110)
                }
            }
        }
        .frame(height: 160)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendSwatch(DS.dataBlue, "Down")
            legendSwatch(DS.dataGreen, "Up")
        }
    }

    private func legendSwatch(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(DS.secondaryText)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(buckets) { b in
                BarMark(x: .value("Time", b.start, unit: chartUnit),
                        y: .value("Down", Double(b.down)))
                    .foregroundStyle(by: .value("Direction", "Down"))
                    .cornerRadius(4)
                BarMark(x: .value("Time", b.start, unit: chartUnit),
                        y: .value("Up", Double(b.up)))
                    .foregroundStyle(by: .value("Direction", "Up"))
                    .cornerRadius(4)
            }
        }
        .chartForegroundStyleScale(["Down": DS.dataBlue, "Up": DS.dataGreen])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(ByteFormat.string(UInt64(max(0, bytes))))
                            .font(.system(size: 10))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: 10.5))
            }
        }
    }

    private var emptyChart: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(DS.fieldFill)
            .frame(height: 110)
            .overlay(Text("No traffic recorded for this range")
                .font(.system(size: 12)).foregroundStyle(DS.secondaryText))
    }

    // MARK: - Sessions

    private var sessionsTile: some View {
        Tile(padding: EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)) {
            VStack(spacing: 0) {
                HStack {
                    TileCaption("Sessions")
                    Spacer()
                    Button(action: exportCSV) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                            Text("Export CSV").font(.system(size: 12))
                        }
                        .foregroundStyle(DS.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(buckets.isEmpty && sessions.isEmpty)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DS.tileBorder).frame(height: 1)
                }

                if sessions.isEmpty {
                    Text("No sessions in this range")
                        .font(.system(size: 12)).foregroundStyle(DS.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, s in
                                sessionRow(s)
                                if idx < sessions.count - 1 {
                                    Rectangle().fill(DS.tileBorder).frame(height: 1)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Circle().fill(controller.recordStats ? DS.ringGreen : DS.meterOff)
                        .frame(width: 7, height: 7)
                    Text(recordingStatus).font(.system(size: 11)).foregroundStyle(DS.secondaryText)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) {
                    Rectangle().fill(DS.tileBorder).frame(height: 1)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func sessionRow(_ s: TrafficSession) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.isOpen ? DS.ringGreen : DS.secondaryText).frame(width: 8, height: 8)
            Text(sessionTimeLabel(s))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 150, alignment: .leading)
            Text(s.serverName.isEmpty ? String(localized: "Unknown") : s.serverName)
                .font(.system(size: 12)).foregroundStyle(DS.secondaryText)
            Spacer()
            Text("↓ \(ByteFormat.string(s.down))")
                .font(.system(size: 12)).foregroundStyle(DS.dataBlue)
                .frame(width: 90, alignment: .trailing)
            Text("↑ \(ByteFormat.string(s.up))")
                .font(.system(size: 12)).foregroundStyle(DS.dataGreen)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private var recordingStatus: String {
        if !controller.recordStats { return String(localized: "Recording is off") }
        if let earliest {
            return String(localized: "Recording since \(earliest.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "No data recorded yet")
    }

    // MARK: - Data

    private var chartUnit: Calendar.Component { range == .today ? .hour : .day }

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

    /// "HH:MM:SS–HH:MM:SS" (or "…" while the session is still open).
    private func sessionTimeLabel(_ s: TrafficSession) -> String {
        let f = Date.FormatStyle(date: .omitted, time: .standard)
        let start = s.startedAt.formatted(f)
        let end = s.endedAt.map { $0.formatted(f) } ?? "…"
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
