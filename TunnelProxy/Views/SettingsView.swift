import SwiftUI

/// Thin `Settings` scene (⌘,). The full configuration surface now lives in the
/// unified main window's tabs (`TunnelTab`, `AdvancedTab`, `ToolsTab`).
/// Rather than host a second copy of those forms, ⌘, just opens/raises the main
/// window on the Servers tab, so there's a single source of truth.
struct SettingsView: View {
    @EnvironmentObject var controller: TunnelController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A minimal placeholder; it never really shows because the onAppear
        // immediately routes to the main window. Kept non-empty so the Settings
        // scene has content if it ever renders a frame.
        VStack(spacing: 8) {
            ProgressView()
            Text("Opening Tunnel Proxy…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 260, height: 120)
        .onAppear {
            controller.requestedTab = .servers
            openWindow(id: "main")
            TunnelUI.activateApp()
        }
    }
}

// MARK: - Tunnel tab

/// Tunnel-wide settings: ports, macOS network service, watchdog. Extracted from
/// the old Settings `TabView` so both the unified window and the (thin) Settings
/// scene can host it.
struct TunnelTab: View {
    @EnvironmentObject var controller: TunnelController

    @State private var deps: [Dependency] = []
    @State private var saveMessage: String?
    @State private var networkServiceOptions: [String] = []

    var body: some View {
        Form {
            Section("Ports") {
                LabeledContent("SOCKS Port") { portField($controller.config.socksPort) }
                LabeledContent("HTTP Proxy Port") { portField($controller.config.httpProxyPort) }
            }
            Section("macOS") {
                Picker("Network Service", selection: $controller.config.networkService) {
                    ForEach(networkServiceOptions, id: \.self) { service in
                        Text(service).tag(service)
                    }
                    // Preserve a previously-saved value that's no longer listed
                    // (e.g. an unplugged adapter) so it isn't silently dropped.
                    if !controller.config.networkService.isEmpty,
                       !networkServiceOptions.contains(controller.config.networkService) {
                        Text("\(controller.config.networkService) (unavailable)")
                            .tag(controller.config.networkService)
                    }
                }
                Toggle("Auto-reconnect (watchdog)", isOn: $controller.watchdogEnabled)
                LabeledContent("Watchdog Interval (s)") {
                    intField($controller.config.watchdogInterval)
                }
            }
            Section("Runtime") {
                ForEach(deps) { dep in
                    HStack {
                        Image(systemName: dep.found ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(dep.found ? .green : .red)
                        Text(dep.name)
                        Spacer()
                        Text(dep.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    if let msg = saveMessage {
                        Text(msg).font(.caption).foregroundStyle(.green)
                    } else if let err = controller.config.connectError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Save", action: save).buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            refreshDependencies()
            loadNetworkServices()
        }
    }

    private func portField(_ binding: Binding<Int>) -> some View {
        SettingsFields.portField(binding)
    }

    private func intField(_ binding: Binding<Int>) -> some View {
        SettingsFields.intField(binding)
    }

    private func loadNetworkServices() {
        Task.detached {
            let services = NetworkServices.list()
            let primary = NetworkServices.primary()
            await MainActor.run {
                self.networkServiceOptions = services
                // Default to the primary (default-route) service when the saved
                // value is empty or no longer valid.
                let current = controller.config.networkService
                if current.isEmpty || (!services.contains(current) && current != primary) {
                    if let primary { controller.config.networkService = primary }
                }
            }
        }
    }

    private func refreshDependencies() {
        Task.detached {
            var checks: [Dependency] = []
            if let p = AppPaths.bundledPrivoxy, FileManager.default.isExecutableFile(atPath: p.path) {
                checks.append(Dependency(name: "privoxy (bundled)", found: true, detail: "included"))
            } else {
                checks.append(Dependency(name: "privoxy (bundled)", found: false, detail: "missing"))
            }
            for tool in ["ssh", "curl"] {
                let path = "/usr/bin/\(tool)"
                let found = FileManager.default.isExecutableFile(atPath: path)
                checks.append(Dependency(name: tool, found: found, detail: found ? path : "not found"))
            }
            let final = checks
            await MainActor.run { self.deps = final }
        }
    }

    private func save() {
        controller.saveConfig()
        saveMessage = "Saved."
        controller.refreshStatus()
    }
}

// MARK: - Advanced tab

/// Startup, statistics recording, files, and the menu-bar toggles the old main
/// window carried (Show menu bar icon / Show network speed).
struct AdvancedTab: View {
    @EnvironmentObject var controller: TunnelController

    @State private var confirmClearStats = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $controller.launchAtLogin)
                Toggle("Auto-connect on launch", isOn: $controller.autoConnectOnLaunch)
            }
            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { controller.showMenuBarIcon },
                    set: { controller.showMenuBarIcon = $0 }
                ))
                Toggle("Show network speed", isOn: $controller.showSpeed)
            }
            Section("Statistics") {
                Toggle("Record traffic statistics", isOn: $controller.recordStats)
                Text("Records byte volume over time — not the sites you visit. Stored locally only.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear statistics…", role: .destructive) {
                    confirmClearStats = true
                }
            }
            Section("Files") {
                LabeledContent("Config") { SettingsFields.pathText(AppPaths.configURL.path) }
                LabeledContent("Logs") { SettingsFields.pathText(AppPaths.logURL.path) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL])
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("Clear all recorded statistics?",
                            isPresented: $confirmClearStats, titleVisibility: .visible) {
            Button("Clear statistics", role: .destructive) {
                controller.clearStatistics()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all recorded traffic history.")
        }
    }
}

// MARK: - Tools tab

/// Claude Code proxy integration + "remove all proxies".
struct ToolsTab: View {
    @EnvironmentObject var controller: TunnelController

    @State private var claudeProxyOn = false
    @State private var claudeProxyMessage: String?
    @State private var claudeProxyIsError = false
    @State private var removeProxiesAlert: RemoveProxiesResult?

    var body: some View {
        Form {
            Section("Claude Code") {
                Toggle("Route Claude Code through this proxy", isOn: Binding(
                    get: { claudeProxyOn },
                    set: { setClaudeProxy($0) }
                ))
                Text("Adds the HTTP proxy env keys to ~/.claude/settings.json, pointing Claude Code at \(ClaudeCodeConfig.proxyURL(port: controller.config.httpProxyPort)). Other settings are left untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                if let msg = claudeProxyMessage {
                    Text(msg).font(.caption)
                        .foregroundStyle(claudeProxyIsError ? .orange : .green)
                }
            }
            Section("File") {
                LabeledContent("Settings") { SettingsFields.pathText(ClaudeCodeConfig.settingsURL.path) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ClaudeCodeConfig.settingsURL])
                }
            }
            Section("System Proxies") {
                Button("Remove All Proxies", role: .destructive) {
                    Task {
                        let service = controller.config.networkService
                        let ok = await controller.removeAllProxies()
                        removeProxiesAlert = RemoveProxiesResult(service: service, succeeded: ok)
                    }
                }
                .disabled(controller.config.networkService.isEmpty || controller.isBusy)
                Text("Turns off HTTP, HTTPS, SOCKS, and auto (PAC) proxies for the \(controller.config.networkService.isEmpty ? "selected network service" : controller.config.networkService) network service.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: refreshClaudeProxyState)
        .alert("Remove All Proxies",
               isPresented: Binding(
                get: { removeProxiesAlert != nil },
                set: { if !$0 { removeProxiesAlert = nil } }
               ),
               presenting: removeProxiesAlert) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            if result.succeeded {
                Text("All proxies were removed for “\(result.service)”.")
            } else {
                Text("Some proxies could not be removed for “\(result.service)”. Check the logs for details.")
            }
        }
    }

    private func refreshClaudeProxyState() {
        let port = controller.config.httpProxyPort
        Task.detached {
            let enabled = ClaudeCodeConfig.isProxyEnabled(port: port)
            await MainActor.run { self.claudeProxyOn = enabled }
        }
    }

    /// Write (or clear) the proxy keys, reverting the toggle and surfacing the
    /// message on failure so a malformed settings.json never overwrites silently.
    private func setClaudeProxy(_ enabled: Bool) {
        let port = controller.config.httpProxyPort
        Task.detached {
            do {
                try ClaudeCodeConfig.setProxyEnabled(enabled, port: port)
                await MainActor.run {
                    self.claudeProxyOn = enabled
                    self.claudeProxyIsError = false
                    self.claudeProxyMessage = enabled ? "Claude Code will use this proxy." : "Proxy removed from Claude Code."
                }
            } catch {
                await MainActor.run {
                    self.claudeProxyOn = ClaudeCodeConfig.isProxyEnabled(port: port)
                    self.claudeProxyIsError = true
                    self.claudeProxyMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Shared field helpers

/// Small field builders shared across the config tabs.
enum SettingsFields {
    static func portField(_ binding: Binding<Int>) -> some View {
        // Empty title + labelsHidden so only LabeledContent's label shows
        // (a non-empty title would render a second value next to the field).
        TextField("", value: binding, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 80).multilineTextAlignment(.trailing)
    }

    static func intField(_ binding: Binding<Int>) -> some View {
        TextField("", value: binding, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 80).multilineTextAlignment(.trailing)
    }

    static func pathText(_ path: String) -> some View {
        Text(path).font(.caption).foregroundStyle(.secondary)
            .truncationMode(.middle).lineLimit(1)
    }
}

struct Dependency: Identifiable {
    let id = UUID()
    let name: String
    let found: Bool
    let detail: String
}

/// Outcome of "Remove All Proxies", used to drive the result alert.
struct RemoveProxiesResult: Identifiable {
    let id = UUID()
    let service: String
    let succeeded: Bool
}
