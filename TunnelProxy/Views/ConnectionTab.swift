import SwiftUI

/// The unified window's first tab: a centered, animated connection surface built
/// around a large circular power toggle. Replaces the old main window's hero +
/// CTA. Everything binds to existing `TunnelController` state/actions — the only
/// new logic here is the view-layer animation.
struct ConnectionTab: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 8)

                PowerToggle()

                // Status label + subtitle, cross-fading on state change.
                VStack(spacing: 4) {
                    Text(controller.state.label)
                        .font(.system(size: 24, weight: .heavy))
                        .multilineTextAlignment(.center)
                    Text(controller.stateSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .animation(.easeInOut(duration: 0.35), value: controller.state)

                warningBanner

                // Exit-IP chip, only while connected.
                if let ip = controller.exitIP {
                    exitChip(ip)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if let last = controller.lastConnected {
                    lastConnectedChip(last)
                        .transition(.opacity)
                }

                serverPicker

                QuickOptionsCard()

                Spacer(minLength: 12)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.35), value: controller.exitIP)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background comes from the unified window's white content surface.
        .scrollContentBackground(.hidden)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var warningBanner: some View {
        if controller.config.servers.isEmpty {
            WarningBanner(text: Text("Add an SSH server in the Servers tab to connect."))
        } else if !controller.isConfigured {
            WarningBanner(text: Text(controller.config.connectError
                                     ?? String(localized: "Check server settings.")))
        } else if !controller.privoxyAvailable {
            WarningBanner(text: Text("Bundled proxy missing — reinstall the app."))
        }
    }

    private func exitChip(_ ip: String) -> some View {
        ChipContainer {
            HStack(spacing: 8) {
                Circle().fill(controller.statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EXIT IP").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(ip).font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
            }
        }
        .fixedSize()
    }

    private func lastConnectedChip(_ date: Date) -> some View {
        ChipContainer {
            VStack(alignment: .leading, spacing: 2) {
                Text("LAST CONNECTED").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .fixedSize()
    }

    private var serverPicker: some View {
        HStack(spacing: 8) {
            Text("Server").font(.system(size: 12)).foregroundStyle(.secondary)
            if controller.config.servers.isEmpty {
                Text("None — add one in Servers")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
}

// MARK: - Power toggle

/// The large circular connect/disconnect control. Reads connection state through
/// color, a state-driven ring, and motion:
/// - disconnected → thin grey ring, muted glyph
/// - connecting/reconnecting → an accent arc sweeps around the ring (+ breathing)
/// - connected → full ring, glow, gentle breathing
/// - error → red ring; tapping retries
private struct PowerToggle: View {
    @EnvironmentObject var controller: TunnelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the indeterminate sweep + breathing. Toggled on appear / state
    /// change; ignored when Reduce Motion is on.
    @State private var animating = false

    private let size: CGFloat = 132
    private let lineWidth: CGFloat = 12

    private var accent: Color { controller.statusColor }
    private var connecting: Bool {
        switch controller.state {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    var body: some View {
        Button(action: controller.toggleConnection) {
            ZStack {
                // Glow behind the button while connected.
                if controller.isConnected {
                    Circle()
                        .fill(accent)
                        .frame(width: size * 1.5, height: size * 1.5)
                        .blur(radius: 34)
                        .opacity(0.28)
                }

                // Base track ring.
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: lineWidth)
                    .frame(width: size, height: size)

                // Progress / state ring.
                ring
                    .frame(width: size, height: size)

                // Knob face.
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: size - lineWidth * 2 - 8, height: size - lineWidth * 2 - 8)
                    .overlay(
                        Image(systemName: "power")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(glyphColor)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
            .frame(width: size * 1.5, height: size * 1.5)
            .scaleEffect(breathingScale)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.canToggleConnection)
        .opacity(controller.canToggleConnection ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.35), value: controller.state)
        .onAppear { syncAnimation() }
        .onChange(of: controller.state) { _, _ in syncAnimation() }
    }

    /// The colored ring: a sweeping arc while connecting, a full circle when
    /// connected/error, and nothing extra when disconnected (track shows through).
    @ViewBuilder
    private var ring: some View {
        if connecting && !reduceMotion {
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(animating ? 360 : 0))
                .animation(animating
                           ? .linear(duration: 1).repeatForever(autoreverses: false)
                           : .default,
                           value: animating)
        } else if connecting {
            // Reduce Motion: show a determinate-looking partial ring, no spin.
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        } else if controller.isConnected {
            Circle()
                .stroke(accent, lineWidth: lineWidth)
        } else if case .error = controller.state {
            Circle()
                .stroke(accent, lineWidth: lineWidth)
        }
    }

    private var glyphColor: Color {
        switch controller.state {
        case .connected: return accent
        case .connecting, .reconnecting: return .secondary
        case .error: return accent
        case .disconnected: return .secondary
        }
    }

    /// Gentle breathing while connected (or connecting), unless Reduce Motion.
    private var breathingScale: CGFloat {
        guard animating, !reduceMotion else { return 1 }
        return (controller.isConnected || connecting) ? 1.03 : 1
    }

    private func syncAnimation() {
        guard !reduceMotion else { animating = false; return }
        let shouldAnimate = connecting || controller.isConnected
        withAnimation(shouldAnimate
                      ? .easeInOut(duration: 2).repeatForever(autoreverses: true)
                      : .default) {
            animating = shouldAnimate
        }
    }
}

// MARK: - Quick options

/// Connection-relevant toggles surfaced on the Connection tab for convenience:
/// route-all-traffic (macOS SOCKS proxy) and the watchdog. Both remain editable
/// in their settings tabs; these bind to the same controller state.
private struct QuickOptionsCard: View {
    @EnvironmentObject var controller: TunnelController

    var body: some View {
        SectionCard(title: "Quick Options") {
            // Intent binding: run the toggle action only on a real change so a
            // programmatic state sync never re-issues networksetup.
            SwitchRow("Route Mac traffic through proxy", isOn: Binding(
                get: { controller.systemSocksOn },
                set: { newValue in
                    guard newValue != controller.systemSocksOn else { return }
                    controller.systemSocksOn = newValue
                    Task { await controller.toggleSystemSocks(on: newValue) }
                }
            ))
            Divider()
            SwitchRow("Auto-reconnect (watchdog)", isOn: $controller.watchdogEnabled)
        }
        .frame(maxWidth: 360)
    }
}
