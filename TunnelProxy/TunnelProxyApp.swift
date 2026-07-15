import SwiftUI

@main
struct TunnelProxyApp: App {
    @StateObject private var controller = TunnelController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

        // Standalone Statistics window, opened from the popover.
        Window("Statistics", id: "statistics") {
            StatisticsView()
                .environmentObject(controller)
        }
        .defaultSize(width: 720, height: 560)

        // Standalone User Guide window, opened from the popover. Shows the
        // bundled HTML manual in-app instead of the default browser.
        Window("User Guide", id: "user-guide") {
            ManualView()
        }
        .defaultSize(width: 860, height: 640)
    }
}

/// App delegate used only to flush the traffic recorder on quit. SwiftUI tears
/// the scene down before `deinit` runs reliably, so we hook
/// `applicationWillTerminate`. The controller registers its flush closure here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `TunnelController` on init; invoked synchronously on quit.
    static var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.onTerminate?()
    }
}

/// The status-item label. `MenuBarExtra` clips a multi-line SwiftUI label to the
/// menu bar height, so when the speed is shown we draw the whole label (icon +
/// two-line up/down text) into a single fixed-height NSImage, which the status
/// item renders at its natural size without clipping.
struct MenuBarLabel: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        // Reading `iconDimmed` here re-renders the label each blink tick. The
        // dim is baked into the NSImage (a template image ignores SwiftUI
        // `.opacity`, so fading has to happen at the pixel level).
        let dimmed = controller.iconDimmed
        if controller.showSpeed {
            // Nested view observes the SpeedMonitor so the image refreshes as
            // rates change (it's a separate ObservableObject from controller).
            SpeedLabel(monitor: controller.speedMonitor,
                       symbol: controller.menuBarSymbol,
                       dimmed: dimmed)
        } else {
            Image(nsImage: MenuBarRenderer.iconImage(
                symbol: controller.menuBarSymbol, dimmed: dimmed))
                .accessibilityLabel("Tunnel Proxy")
        }
    }
}

/// Renders the icon + two-line up/down speed into one NSImage.
private struct SpeedLabel: View {
    @ObservedObject var monitor: SpeedMonitor
    let symbol: String
    let dimmed: Bool

    var body: some View {
        Image(nsImage: MenuBarRenderer.labelImage(
            symbol: symbol, up: monitor.upText, down: monitor.downText, dimmed: dimmed))
            .accessibilityLabel("Tunnel Proxy")
    }
}

extension TunnelController {
    /// SF Symbol reflecting the current connection state.
    var menuBarSymbol: String {
        switch state {
        case .connected: return "shield.lefthalf.filled"
        // Hollow shield that blinks (via `iconDimmed`); the previous
        // `.badge.plus` variant doesn't exist on all macOS versions and left the
        // status item blank while connecting.
        case .connecting, .reconnecting: return "shield"
        case .error: return "exclamationmark.shield"
        case .disconnected: return "shield"
        }
    }
}
