import SwiftUI

/// The full set of tunnel controls — status header, connection details, the
/// primary Connect/Disconnect action, preference toggles, and the window/menu
/// entry points. Shared by the menu bar popover (`MenuBarView`) and the standalone
/// main window (`MainWindowView`) so both drive the same `TunnelController`.
struct TunnelControlsView: View {
    /// When `true`, the extra "Show menu bar icon" toggle is shown. Only makes
    /// sense in the main window — hiding it from inside the popover would be
    /// confusing (you'd hide the thing you're looking at).
    var showsMenuBarToggle: Bool = false

    @EnvironmentObject var controller: TunnelController
    @Environment(\.openWindow) private var openWindow

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
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.statusColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.label)
                    .font(.system(size: 14, weight: .bold))
                Text(controller.stateSubtitle)
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
                .disabled(controller.isBusy || controller.isConnected)
            }
        }
    }

    private var primaryButton: some View {
        Button(action: controller.toggleConnection) {
            Text(controller.isConnected ? "Disconnect" : "Connect")
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.isConnected ? .red : .accentColor)
        .disabled(!controller.canToggleConnection)
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
            if showsMenuBarToggle {
                switchRow("Show menu bar icon", isOn: $controller.showMenuBarIcon)
            }
        }
        .font(.system(size: 12))
        .padding(.top, 4)
    }

    private var menuItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Logs / Statistics / Settings are now tabs of the unified window;
            // request the tab, then open/raise it.
            Button("View Logs…") {
                openMain(tab: .logs)
            }
                .buttonStyle(.plain)
            Button("Statistics…") {
                openMain(tab: .stats)
            }
                .buttonStyle(.plain)
            if AppPaths.userGuide != nil {
                Button("User Guide…") {
                    openWindow(id: "user-guide")   // dedicated in-app window
                    TunnelUI.activateApp()
                }
                    .buttonStyle(.plain)
            }
            Button("Settings…") {
                openMain(tab: .servers)
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

    /// Open the unified main window on a specific tab and bring it forward.
    private func openMain(tab: WindowTab) {
        controller.requestedTab = tab
        openWindow(id: "main")
        TunnelUI.activateApp()
    }

    private func warning(_ text: Text) -> some View {
        text.font(.system(size: 10.5)).foregroundStyle(.orange)
    }

    /// A settings-style switch row: label flush-left, switch flush-right.
    /// Expanding the label to full width forces consistent edge alignment
    /// regardless of label length.
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
}
