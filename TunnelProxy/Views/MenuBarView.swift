import SwiftUI

/// The popover shown when the menu bar icon is clicked. A thin wrapper around the
/// shared `TunnelControlsView` (also hosted by the standalone main window), sized
/// to the narrow popover width.
struct MenuBarView: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        // The redesigned controls size themselves (310 pt, own padding + canvas).
        TunnelControlsView()
            .onAppear { controller.onAppear() }
    }
}
