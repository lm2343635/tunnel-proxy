import SwiftUI

/// The menu bar popover content, redesigned as Control-Center tiles on a gray
/// canvas: a hero mini-tile (power ring + status), a SPEED / SERVER pair, an
/// options tile, a full-width primary action, and a footer link row. Drives the
/// same `TunnelController` as the main window.
struct TunnelControlsView: View {
    /// Unused in the redesign (the menu-bar-icon toggle lives in Settings now);
    /// kept for source compatibility with existing call sites.
    var showsMenuBarToggle: Bool = false

    @EnvironmentObject var controller: TunnelController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            heroTile
            HStack(spacing: 8) {
                speedTile
                serverTile
            }
            optionsTile
            primaryAction
            warning
            footer
        }
        .padding(12)
        .frame(width: 310)
        .background(DS.canvas)
    }

    // MARK: - Hero

    private var heroTile: some View {
        Tile(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
             fill: AnyShapeStyle(controller.isConnected ? DS.heroGradient : DS.heroGradientNeutral)) {
            HStack(spacing: 12) {
                PowerRing(size: 46, ringWidth: 5, glow: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.label)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(DS.primaryText)
                    Text(controller.exitIP ?? controller.stateSubtitleText)
                        .font(.system(size: 11, design: controller.exitIP != nil ? .monospaced : .default))
                        .foregroundStyle(DS.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    if let ms = controller.latencyMS {
                        Text("● \(ms) ms")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(controller.latencyColor)
                    }
                    Button {
                        openWindow(id: "mini")
                        TunnelUI.activateApp()
                    } label: {
                        Image(systemName: "pip")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Open the always-on-top mini window")
                }
            }
        }
    }

    // MARK: - Speed / Server

    private var speedTile: some View {
        SpeedMiniTile(monitor: controller.speedMonitor)
    }

    private var serverTile: some View {
        Tile(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
            VStack(alignment: .leading, spacing: 2) {
                TileCaption("Server")
                Text(controller.selectedServer?.displayName ?? String(localized: "None"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.primaryText).lineLimit(1)
                if controller.config.servers.count > 1 {
                    Menu {
                        ForEach(controller.config.servers) { server in
                            Button {
                                controller.selectServer(server.id)
                            } label: {
                                Label(server.displayName,
                                      systemImage: server.id == controller.config.selectedServerID
                                      ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Text("Switch ▾").font(.system(size: 10.5)).foregroundStyle(DS.accent)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(controller.isBusy || controller.isConnected)
                }
            }
        }
    }

    // MARK: - Options (two half-width button-cards)

    private var optionsTile: some View {
        HStack(spacing: 8) {
            OptionCard(title: "Route Mac traffic",
                       isOn: .constant(controller.systemSocksOn),
                       onTap: { newValue in
                           guard newValue != controller.systemSocksOn else { return }
                           controller.systemSocksOn = newValue
                           Task { await controller.toggleSystemSocks(on: newValue) }
                       },
                       titleSize: 11.5, captionSize: 10)
            OptionCard(title: "Auto-reconnect",
                       caption: controller.watchdogEnabled
                           ? String(localized: "Watchdog · On")
                           : String(localized: "Watchdog · Off"),
                       isOn: $controller.watchdogEnabled,
                       titleSize: 11.5, captionSize: 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Primary action + footer

    private var primaryAction: some View {
        Button(action: controller.toggleConnection) {
            Text(controller.isConnected ? "Disconnect" : "Connect")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(controller.isConnected ? DS.dangerText : DS.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(controller.isConnected ? DS.dangerFill : DS.accentFill))
        }
        .buttonStyle(.plain)
        .disabled(!controller.canToggleConnection)
        .opacity(controller.canToggleConnection ? 1 : 0.5)
    }

    @ViewBuilder
    private var warning: some View {
        if controller.config.servers.isEmpty {
            WarningBanner(text: Text("Add an SSH server in Settings to connect."))
                .padding(.horizontal, 4)
        } else if !controller.isConfigured {
            WarningBanner(text: Text(controller.config.connectError
                                     ?? String(localized: "Check server settings")))
                .padding(.horizontal, 4)
        } else if !controller.privoxyAvailable {
            WarningBanner(text: Text("Bundled proxy missing — reinstall the app."))
                .padding(.horizontal, 4)
        }
    }

    /// Two equal-width card buttons: Open App (accent) and Quit (secondary).
    private var footer: some View {
        HStack(spacing: 8) {
            footerButton("Open App", color: DS.accent) { openMain(tab: .connection) }
            footerButton("Quit", color: DS.secondaryText) {
                Task { await controller.disconnect(); NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func footerButton(_ title: LocalizedStringKey, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.tile))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DS.tileBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func openMain(tab: WindowTab) {
        controller.requestedTab = tab
        openWindow(id: "main")
        TunnelUI.activateApp()
    }
}

/// The popover's SPEED tile — observes the `SpeedMonitor` so the values refresh.
private struct SpeedMiniTile: View {
    @ObservedObject var monitor: SpeedMonitor

    var body: some View {
        Tile(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
            VStack(alignment: .leading, spacing: 1) {
                TileCaption("Speed")
                Text("↓ \(monitor.downText.spaced)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dataBlue)
                    .padding(.top, 3)
                Text("↑ \(monitor.upText.spaced)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dataGreen)
            }
        }
    }
}

private extension String {
    /// Insert a space before the unit in a compact rate string ("82KB/s" →
    /// "82 KB/s") for the roomier popover typography.
    var spaced: String {
        replacingOccurrences(of: "KB/s", with: " KB/s")
            .replacingOccurrences(of: "MB/s", with: " MB/s")
    }
}
