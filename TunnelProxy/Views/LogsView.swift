import SwiftUI

/// Live log viewer that tails the tunnel log. Redesigned as a tiled surface: a
/// header with a filter field, auto-scroll toggle, and Clear; the log fills a
/// tile below; a status row reports line count + the log path. `LogTailer` +
/// severity mapping are unchanged.
struct LogsView: View {
    @EnvironmentObject var controller: TunnelController
    @StateObject private var tailer = LogTailer()

    @State private var filter = ""
    @State private var autoScroll = true

    private var filtered: [LogLine] {
        guard !filter.isEmpty else { return tailer.lines }
        return tailer.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            logTile
            statusRow
        }
        .padding(DS.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { tailer.start(path: logPath) }
        .onDisappear { tailer.stop() }
    }

    private var header: some View {
        TabHeader(title: "Logs") {
            TextField("Filter…", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 220)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.tile))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DS.tileBorder, lineWidth: 1))

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))

            Button { tailer.clear() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 12))
                    Text("Clear").font(.system(size: 12.5))
                }
                .foregroundStyle(DS.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.tile))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DS.tileBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var logTile: some View {
        Tile(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { line in
                            Text(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(for: line.severity))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: tailer.lines.count) { _, _ in
                    if autoScroll, let last = filtered.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(DS.ringGreen).frame(width: 8, height: 8)
            Text("Streaming · \(filtered.count) lines")
                .font(.system(size: 11)).foregroundStyle(DS.secondaryText)
            Spacer()
            Text(logPath).font(.system(size: 11)).foregroundStyle(DS.tertiaryText)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 4)
    }

    private var logPath: String { controller.logURL.path }

    private func color(for severity: LogLine.Severity) -> Color {
        switch severity {
        case .info: return DS.primaryText
        case .success: return DS.textGreen
        case .warn: return DS.warning
        case .error: return DS.dangerText
        }
    }
}
