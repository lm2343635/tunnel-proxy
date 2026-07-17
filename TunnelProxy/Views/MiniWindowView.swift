import SwiftUI

/// A compact, always-on-top floating panel (~300×120): the hero-tile look at a
/// glance, with a power ring, status, live speed pills, and a Stop button. Opened
/// from the menu bar popover; kept above other windows via `.floating` level.
struct MiniWindowView: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        MiniWindowBody(monitor: controller.speedMonitor)
            .onAppear {
                controller.onAppear()
                // Float above other apps' windows and follow across Spaces.
                DispatchQueue.main.async { promoteToFloatingPanel() }
            }
    }

    /// Find this scene's window and make it a borderless floating panel.
    private func promoteToFloatingPanel() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "mini" })
                ?? NSApp.keyWindow else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    }
}

/// The panel's content — a single hero-style gradient tile. Observes the
/// `SpeedMonitor` so the speed pills stay live.
private struct MiniWindowBody: View {
    @EnvironmentObject var controller: TunnelController
    @ObservedObject var monitor: SpeedMonitor

    var body: some View {
        Tile(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16),
             fill: AnyShapeStyle(controller.isConnected ? DS.heroGradient : DS.heroGradientNeutral)) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    PowerRing(size: 52, ringWidth: 5.5, glow: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.state.label)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(DS.primaryText)
                        Text(controller.exitIP ?? controller.stateSubtitleText)
                            .font(.system(size: 11, design: controller.exitIP != nil ? .monospaced : .default))
                            .foregroundStyle(DS.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let ms = controller.latencyMS {
                        Text("\(ms) ms")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(controller.latencyColor)
                            .frame(alignment: .top)
                    }
                }

                HStack(spacing: 8) {
                    speedPill("↓ \(ByteRate.string(monitor.downRate))", DS.dataBlue)
                    speedPill("↑ \(ByteRate.string(monitor.upRate))", DS.dataGreen)
                    if controller.isConnected {
                        Button(action: controller.toggleConnection) {
                            Text("Stop")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(DS.dangerText)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(DS.dangerFill))
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.canToggleConnection)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .background(DS.canvas)
    }

    private func speedPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.75)))
    }
}
