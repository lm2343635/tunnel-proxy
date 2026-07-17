import SwiftUI

// Shared UI helpers used by both the menu bar popover (`TunnelControlsView`) and
// the standalone window (`MainWindowView`) / menu commands (`TunnelCommands`), so
// status colors, labels, and the app-raise behavior live in one place.

extension TunnelController {
    /// Whether the tunnel is currently connected.
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Whether the primary Connect/Disconnect action can run right now.
    var canToggleConnection: Bool {
        !isBusy && isConfigured && privoxyAvailable
    }

    /// One-line description of the current state, shown under the status label.
    var stateSubtitle: LocalizedStringKey {
        switch state {
        case .connected: return "Tunnel + HTTP proxy active"
        case .disconnected: return "Traffic goes out directly"
        case .connecting: return "Establishing tunnel…"
        case .reconnecting: return "Watchdog reconnecting…"
        case .error: return "Something went wrong"
        }
    }

    /// Accent color for the status dot / hero, per connection state.
    var statusColor: Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    /// The primary action: connect when down, disconnect when up.
    func toggleConnection() {
        Task {
            if isConnected { await disconnect() }
            else { await connect() }
        }
    }
}

enum TunnelUI {
    /// Bring the app (and a just-opened window) to the front. As an `LSUIElement`
    /// menu bar agent the app isn't active by default, so opened windows appear
    /// behind other apps unless we explicitly activate.
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        // The window is created asynchronously by openWindow/openSettings, so
        // raise it on the next runloop tick once it exists. Pick the topmost
        // key-capable, visible window (the one just opened).
        DispatchQueue.main.async {
            let target = NSApp.windows.first { $0.canBecomeKey && $0.isVisible }
            target?.makeKeyAndOrderFront(nil)
        }
    }
}
