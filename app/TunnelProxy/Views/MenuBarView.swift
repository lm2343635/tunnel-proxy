import SwiftUI

/// The popover shown when the menu bar icon is clicked. Mirrors the SVG mockups:
/// status header, connection details, primary Connect/Disconnect action, and toggles.
struct MenuBarView: View {
    @EnvironmentObject var controller: TunnelController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            details
            Divider().padding(.vertical, 8)
            primaryButton
            toggles
            Divider().padding(.vertical, 8)
            menuItems
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { controller.onAppear() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.label)
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(spacing: 6) {
            serverPicker
            if let ip = controller.exitIP {
                detailRow("Exit IP", ip)
            }
            if let last = controller.lastConnected, controller.exitIP == nil {
                detailRow("Last connected", last.formatted(date: .abbreviated, time: .shortened))
            }
            detailRow("Watchdog", controller.watchdogEnabled
                        ? String(localized: "On") : String(localized: "Off"),
                      valueColor: controller.watchdogEnabled ? .green : .secondary)
        }
    }

    @ViewBuilder
    private var serverPicker: some View {
        HStack {
            Text("Server").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if controller.config.servers.isEmpty {
                Text("None").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { controller.config.selectedServerID ?? controller.config.servers.first?.id },
                    set: { if let id = $0 { controller.selectServer(id) } }
                )) {
                    ForEach(controller.config.servers) { server in
                        Text(server.displayName).tag(Optional(server.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(controller.isBusy || isConnected)
            }
        }
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            Text(isConnected ? "Disconnect" : "Connect")
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(isConnected ? .red : .accentColor)
        .disabled(controller.isBusy || !controller.isConfigured || !controller.privoxyAvailable)
        .padding(.bottom, 4)
    }

    private var toggles: some View {
        VStack(spacing: 8) {
            switchRow("Auto-reconnect (watchdog)", isOn: $controller.watchdogEnabled)
            switchRow("Show network speed", isOn: $controller.showSpeed)
            // Intent binding: the setter runs the toggle action only on a real
            // change, so a programmatic state sync never re-issues networksetup.
            switchRow("macOS SOCKS proxy", isOn: Binding(
                get: { controller.systemSocksOn },
                set: { newValue in
                    guard newValue != controller.systemSocksOn else { return }
                    controller.systemSocksOn = newValue
                    Task { await controller.toggleSystemSocks(on: newValue) }
                }
            ))
            switchRow("Launch at login", isOn: $controller.launchAtLogin)
        }
        .font(.system(size: 12))
        .padding(.top, 4)
    }

    private var menuItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("View Logs…") {
                openWindow(id: "logs")
                activateApp()
            }
                .buttonStyle(.plain)
            Button("Settings…") {
                openSettings()
                activateApp()
            }
                .buttonStyle(.plain)
            if controller.config.servers.isEmpty {
                warning(Text("⚠︎ Add an SSH server in Settings to connect."))
            } else if !controller.isConfigured {
                warning(Text("⚠︎ ") + Text(controller.config.connectError
                                            ?? String(localized: "Check server settings")))
            } else if !controller.privoxyAvailable {
                warning(Text("⚠︎ Bundled proxy missing — reinstall the app."))
            }
            Button("Quit") {
                Task { await controller.disconnect(); NSApplication.shared.terminate(nil) }
            }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    // MARK: - Helpers

    /// Bring the app (and the just-opened window) to the front. As an
    /// `LSUIElement` menu bar agent the app isn't active by default, so opened
    /// windows appear behind other apps unless we explicitly activate.
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        // The window is created asynchronously by openWindow/openSettings, so
        // raise it on the next runloop tick once it exists. Pick the topmost
        // key-capable, visible window (the one just opened).
        DispatchQueue.main.async {
            let target = NSApp.windows.first { $0.canBecomeKey && $0.isVisible }
            target?.makeKeyAndOrderFront(nil)
        }
    }

    /// A settings-style switch row: label flush-left, switch flush-right.
    /// Expanding the label to full width forces consistent edge alignment
    /// regardless of label length.
    private func warning(_ text: Text) -> some View {
        text.font(.system(size: 10.5)).foregroundStyle(.orange)
    }

    private func switchRow(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(valueColor)
        }
    }

    private func primaryAction() {
        Task {
            if isConnected { await controller.disconnect() }
            else { await controller.connect() }
        }
    }

    private var isConnected: Bool {
        if case .connected = controller.state { return true }
        return false
    }

    private var subtitle: LocalizedStringKey {
        switch controller.state {
        case .connected: return "Tunnel + HTTP proxy active"
        case .disconnected: return "Traffic goes out directly"
        case .connecting: return "Establishing tunnel…"
        case .reconnecting: return "Watchdog reconnecting…"
        case .error: return "Something went wrong"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}
