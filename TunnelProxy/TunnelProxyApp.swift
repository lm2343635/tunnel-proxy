import SwiftUI

@main
struct TunnelProxyApp: App {
    @StateObject private var controller = TunnelController()

    var body: some Scene {
        // Menu bar status item with a popover.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller)
        } label: {
            MenuBarLabel()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)

        // Settings scene (⌘,) hosts the config form.
        Settings {
            SettingsView()
                .environmentObject(controller)
        }

        // Standalone Logs window, opened from the popover.
        Window("Logs", id: "logs") {
            LogsView()
                .environmentObject(controller)
        }
        .defaultSize(width: 680, height: 440)
    }
}

/// The status-item label. `MenuBarExtra` clips a multi-line SwiftUI label to the
/// menu bar height, so when the speed is shown we draw the whole label (icon +
/// two-line up/down text) into a single fixed-height NSImage, which the status
/// item renders at its natural size without clipping.
struct MenuBarLabel: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        if controller.showSpeed {
            // Nested view observes the SpeedMonitor so the image refreshes as
            // rates change (it's a separate ObservableObject from controller).
            SpeedLabel(monitor: controller.speedMonitor, symbol: controller.menuBarSymbol)
        } else {
            Image(nsImage: controller.menuBarImage)
                .accessibilityLabel("Tunnel Proxy")
        }
    }
}

/// Renders the icon + two-line up/down speed into one NSImage.
private struct SpeedLabel: View {
    @ObservedObject var monitor: SpeedMonitor
    let symbol: String

    var body: some View {
        Image(nsImage: MenuBarRenderer.labelImage(
            symbol: symbol, up: monitor.upText, down: monitor.downText))
            .accessibilityLabel("Tunnel Proxy")
    }
}

extension TunnelController {
    /// SF Symbol reflecting the current connection state.
    var menuBarSymbol: String {
        switch state {
        case .connected: return "shield.lefthalf.filled"
        case .connecting, .reconnecting: return "shield.lefthalf.filled.badge.plus"
        case .error: return "exclamationmark.shield"
        case .disconnected: return "shield"
        }
    }

    /// The status-item icon as a larger template image (~18pt vs the ~15pt
    /// default) so it reads more clearly in the menu bar.
    var menuBarImage: NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = NSImage(systemSymbolName: menuBarSymbol, accessibilityDescription: "Tunnel Proxy")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true   // adopt the menu bar's light/dark tint
        return image ?? NSImage()
    }
}
