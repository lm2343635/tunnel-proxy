import SwiftUI

/// The single, unified app window: a Settings-style tabbed window that merges the
/// old main window, Settings, Logs, and Statistics into one surface. The
/// **Connection** tab (an animated power toggle + status + quick options) is the
/// default; the rest are the configuration/data tabs.
///
/// The app ships as an `LSUIElement` menu bar agent (no Dock icon). While this
/// window is on screen we promote the app to `.regular` so it gets a Dock icon +
/// app menus; when it closes we drop back to `.accessory`. Closing never quits —
/// the `MenuBarExtra` scene keeps the process alive.
struct UnifiedWindowView: View {
    @EnvironmentObject var controller: TunnelController
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("mainTab") private var tab: WindowTab = .connection

    var body: some View {
        // The window uses `.hiddenTitleBar`, so content extends to the very top.
        // The tab strip is the top band: it paints the full width (including
        // behind the floating traffic-light buttons), with top padding to clear
        // them. Its own gray is the single top surface — no separate titlebar to
        // mismatch — and the content sits on white below. The vertical icon+label
        // tabs get full height here (no titlebar clipping).
        VStack(spacing: 0) {
            TabToolbar(selection: $tab)
                .padding(.top, 28)          // clear the traffic-light controls
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
                .background(WindowStyle.titlebar)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 560, idealHeight: 620)
        .ignoresSafeArea(.container, edges: .top)
        // Route "open on tab X" requests from the popover / app menus.
        .onChange(of: controller.requestedTab) { _, new in
            if let new {
                tab = new
                controller.requestedTab = nil
            }
        }
        .onAppear {
            controller.onAppear()
            // Consume any tab request that arrived before this view existed.
            if let requested = controller.requestedTab {
                tab = requested
                controller.requestedTab = nil
            }
            // Also register the reopen action here, so relaunch works even
            // when the menu bar icon is hidden (its registrar never renders).
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            AppActivation.becomeRegular()
        }
        .onDisappear {
            // Back to menu-bar-only. If the app is on its way out (⌘Q / Quit),
            // this is harmless; otherwise it removes the Dock icon.
            AppActivation.becomeAccessory()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .connection: ConnectionTab()
        case .servers:    ServersView()
        case .tunnel:     TunnelTab()
        case .logs:       LogsView()
        case .stats:      StatisticsView()
        case .advanced:   AdvancedTab()
        case .tools:      ToolsTab()
        }
    }
}

// MARK: - Tab toolbar (preference-style: icon above label)

/// A macOS-preferences-style tab strip: each item is an SF Symbol above its
/// label, with a rounded highlight behind the selected one. Reproduces the look
/// of the `Settings` scene's toolbar (which a plain window `TabView` does not).
private struct TabToolbar: View {
    @Binding var selection: WindowTab

    private struct Item: Identifiable {
        let tab: WindowTab
        let title: LocalizedStringKey
        let symbol: String
        var id: WindowTab { tab }
    }

    private let items: [Item] = [
        .init(tab: .connection, title: "Connection", symbol: "bolt.horizontal.circle"),
        .init(tab: .servers,    title: "Servers",    symbol: "server.rack"),
        .init(tab: .tunnel,     title: "Tunnel",     symbol: "network"),
        .init(tab: .logs,       title: "Logs",       symbol: "doc.plaintext"),
        .init(tab: .stats,      title: "Statistics", symbol: "chart.bar"),
        .init(tab: .advanced,   title: "Advanced",   symbol: "gearshape.2"),
        .init(tab: .tools,      title: "Tools",      symbol: "wrench.and.screwdriver"),
    ]

    var body: some View {
        // Sits inside the titlebar toolbar (Calendar-app style). No background of
        // its own — it shows the native titlebar surface, so there's no seam.
        HStack(spacing: 2) {
            ForEach(items) { item in
                TabButton(item: item, isSelected: selection == item.tab) {
                    selection = item.tab
                }
            }
        }
    }

    private struct TabButton: View {
        let item: Item
        let isSelected: Bool
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            // Vertical stack: icon above label (System-Settings style). The
            // titlebar is given extra height in WindowChrome so this doesn't clip.
            Button(action: action) {
                VStack(spacing: 2) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 16, weight: .regular))
                        .frame(height: 18)
                    Text(item.title)
                        .font(.system(size: 11))
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(minWidth: 60)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected
                              ? Color.secondary.opacity(0.20)
                              : (hovering ? Color.secondary.opacity(0.10) : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

// MARK: - Reusable style pieces (adaptive)

/// A titled group card: an uppercased caption above a rounded, separator-bordered
/// container. Filled with the window gray so it reads as a distinct card against
/// the white content surface (adapts in dark mode).
struct SectionCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Label flush-left, switch flush-right — a settings-style row.
struct SwitchRow: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ label: LocalizedStringKey, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .font(.system(size: 13))
        .padding(.vertical, 8)
    }
}

/// A small chip container. Filled with the window gray so it stands out against
/// the white content surface.
struct ChipContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// An inline warning line (amber, with a triangle glyph).
struct WarningBanner: View {
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            text
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.orange)
        .multilineTextAlignment(.leading)
    }
}

/// Shared window chrome colors.
enum WindowStyle {
    /// The tone macOS renders the titlebar (light #ECECEC / dark #2A2A2C), used
    /// for the top tab band so it reads as a native titlebar surface.
    static let titlebar = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2C/255.0, alpha: 1)
            : NSColor(red: 0xEC/255.0, green: 0xEC/255.0, blue: 0xEC/255.0, alpha: 1)
    })
}

/// Small helper for flipping the activation policy between agent (`.accessory`)
/// and normal-app (`.regular`) modes, and bringing the app forward.
enum AppActivation {
    static func becomeRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func becomeAccessory() {
        NSApp.setActivationPolicy(.accessory)
    }
}
