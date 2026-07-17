import SwiftUI

/// Live log viewer that tails `LOG_FILE`. Filter box, follow/auto-scroll toggle,
/// and clear — matches the Logs SVG mockup.
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
        VStack(spacing: 0) {
            toolbar
            Divider()
            logBody
            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { tailer.start(path: logPath) }
        .onDisappear { tailer.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Filter…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
            Button {
                tailer.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
        .padding(10)
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { line in
                        Text(line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(for: line.severity))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: tailer.lines.count) { _, _ in
                if autoScroll, let last = filtered.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Streaming · \(filtered.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(logPath).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(8)
    }

    private var logPath: String {
        controller.logURL.path
    }

    private func color(for severity: LogLine.Severity) -> Color {
        switch severity {
        case .info: return .primary
        case .success: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}
