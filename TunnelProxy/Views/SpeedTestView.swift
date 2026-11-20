import Charts
import SwiftUI

struct SpeedTestView: View {
    @EnvironmentObject private var controller: TunnelController
    @ObservedObject var test: TunnelSpeedTest
    @State private var showHistory = false
    private let downloadColor = Color(red: 0.37, green: 0.66, blue: 1)
    private let uploadColor = Color(red: 0.28, green: 0.83, blue: 0.58)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gridGap) {
                header
                Tile(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 14) {
                        phase
                        HStack(spacing: 36) {
                            metric(.download, final: test.download, color: downloadColor)
                            metric(.upload, final: test.upload, color: uploadColor)
                        }
                        chart
                        if test.isRunning {
                            ProgressView(value: (test.phaseProgress + (test.direction == .download ? 1 : 0)) / 2)
                                .accessibilityLabel(Text("Speed test progress"))
                        }
                    }
                }
                history
            }.padding(DS.contentPadding)
        }
        .sheet(isPresented: $showHistory) { historySheet }

    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tunnel Speed Test").font(.largeTitle.weight(.bold))
                if let target = test.target {
                    Text(verbatim: "\(target.server) · \(target.route) · \(target.endpoint)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if test.isRunning {
                Button("Cancel Speed Test", role: .destructive) { test.cancel() }
                    .buttonStyle(.bordered)
            } else {
                primaryAction.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if controller.selectedServer == nil {
            Button("Open Servers") { controller.requestedTab = .servers }
        } else if !controller.isConnected {
            Button("Go to Connection") { controller.requestedTab = .connection }
        } else {
            Button(test.target == nil ? "Start Speed Test" : "Test Again") { controller.startSpeedTest() }
        }
    }

    private var phase: some View {
        HStack {
            if test.isRunning && test.status == nil {
                Label(test.direction == .download ? "Testing download…" : "Testing upload…", systemImage: "circle.fill")
                    .foregroundStyle(DS.accent)
                Spacer()
                Text(verbatim: test.direction == .upload ? "1 / 2" : "2 / 2")
                    .monospacedDigit().foregroundStyle(.secondary)
            } else if let status = test.status {
                VStack(alignment: .leading, spacing: 4) {
                    if (test.download == nil) != (test.upload == nil) { Text("Partial result") }
                    Text(verbatim: status).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !test.isRunning, !controller.canStartSpeedTest {
                Text(setupHint).foregroundStyle(.secondary)
            }
        }.font(.callout.weight(.semibold))
    }

    private var setupHint: LocalizedStringKey {
        if controller.selectedServer == nil { return "Add an SSH server to run a speed test." }
        return "Connect to an SSH server first."
    }

    private func metric(_ direction: SpeedTestDirection, final: Double?, color: Color) -> some View {
        let active = test.isRunning && test.direction == direction
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: direction.label).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: number(final ?? (active ? test.currentRate : nil)))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                    .foregroundStyle(color)
                Text("Mbps").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart(test.samples) { sample in
            LineMark(x: .value("Elapsed time", sample.seconds), y: .value("Mbps", sample.mbps))
                .foregroundStyle(by: .value("Direction", sample.direction.label))
            PointMark(x: .value("Elapsed time", sample.seconds), y: .value("Mbps", sample.mbps))
                .foregroundStyle(by: .value("Direction", sample.direction.label))
                .symbolSize(16)
        }
        .chartForegroundStyleScale([
            SpeedTestDirection.download.label: downloadColor,
            SpeedTestDirection.upload.label: uploadColor
        ])
        .chartXScale(domain: 0...max(10, test.samples.last?.seconds ?? 0))
        .chartYScale(domain: 0...max(10, (test.samples.map(\.mbps).max() ?? 0) * 1.1))
        .chartXAxisLabel("Elapsed time (s)")
        .chartYAxisLabel("Mbps")
        .frame(height: 195)
        .accessibilityLabel(Text("Live speed chart"))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speed Test History").font(.headline)
                Spacer()
                Button("View All") { showHistory = true }.disabled(test.history.isEmpty)
            }
            if test.history.isEmpty {
                Text("No speed test history yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        ForEach(test.history.prefix(3)) { record in historyCard(record) }
                    }
                    VStack {
                        ForEach(test.history.prefix(3)) { record in historyCard(record) }
                    }
                }
            }
        }
    }

    private func historyCard(_ record: SpeedTestRecord) -> some View {
        Tile(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.date, format: .dateTime.month().day().hour().minute()).font(.callout.weight(.semibold))
                Text(verbatim: "\(record.server) · \(record.route)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(verbatim: "↓ \(number(record.download))").foregroundStyle(downloadColor)
                    Text(verbatim: "↑ \(number(record.upload))").foregroundStyle(uploadColor)
                    Text("Mbps").foregroundStyle(.secondary)
                }.font(.caption.monospacedDigit())
                if record.isPartial { Text("Partial result").font(.caption).foregroundStyle(.secondary) }
                if record.shortSample { Text("Short sample").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Speed Test History").font(.title2.bold())
                Spacer()
                Button("Done") { showHistory = false }.keyboardShortcut(.cancelAction)
            }
            List(test.history) { record in
                VStack(alignment: .leading, spacing: 4) {
                    historyCard(record)
                    Text(verbatim: record.endpoint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(20).frame(minWidth: 500, minHeight: 360)
    }

    private func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }
}
