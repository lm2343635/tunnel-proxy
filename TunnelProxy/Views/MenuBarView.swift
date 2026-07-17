import SwiftUI

/// The popover shown when the menu bar icon is clicked. A thin wrapper around the
/// shared `TunnelControlsView` (also hosted by the standalone main window), sized
/// to the narrow popover width.
struct MenuBarView: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        TunnelControlsView()
            .padding(14)
            .frame(width: 280)
            .onAppear { controller.onAppear() }
    }
}
