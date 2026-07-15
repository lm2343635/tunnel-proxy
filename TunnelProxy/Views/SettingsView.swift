import SwiftUI

/// Settings window. Servers are managed in the Servers tab; tunnel-wide settings
/// (ports, watchdog, network service) in the Tunnel tab. The app owns all SSH
/// data — nothing is shared with the CLI.
struct SettingsView: View {
    @EnvironmentObject var controller: TunnelController

    @State private var deps: [Dependency] = []
    @State private var saveMessage: String?
    @State private var networkServiceOptions: [String] = []
    @State private var confirmClearStats = false

    var body: some View {
        TabView {
            ServersView()
                .environmentObject(controller)
                .tabItem { Label("Servers", systemImage: "server.rack") }
            tunnelTab
                .tabItem { Label("Tunnel", systemImage: "network") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
        .onAppear {
            refreshDependencies()
            loadNetworkServices()
        }
    }

    // MARK: - Tunnel

    private var tunnelTab: some View {
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
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $controller.launchAtLogin)
                Toggle("Auto-connect on launch", isOn: $controller.autoConnectOnLaunch)
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
                LabeledContent("Config") { pathText(AppPaths.configURL.path) }
                LabeledContent("Logs") { pathText(AppPaths.logURL.path) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL])
                }
            }
            Section {
                Button("Save", action: save).buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
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

    private var aboutTab: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            }
            Text("Tunnel Proxy").font(.title2).bold()
            Text("A self-contained menu bar SSH SOCKS5 → HTTP proxy.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Privoxy is bundled; ssh and curl ship with macOS. All SSH data is managed here.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fields

    private func portField(_ binding: Binding<Int>) -> some View {
        // Empty title + labelsHidden so only LabeledContent's label shows
        // (a non-empty title would render a second value next to the field).
        TextField("", value: binding, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 80).multilineTextAlignment(.trailing)
    }

    private func intField(_ binding: Binding<Int>) -> some View {
        TextField("", value: binding, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 80).multilineTextAlignment(.trailing)
    }

    private func pathText(_ path: String) -> some View {
        Text(path).font(.caption).foregroundStyle(.secondary)
            .truncationMode(.middle).lineLimit(1)
    }

    // MARK: - Logic

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

struct Dependency: Identifiable {
    let id = UUID()
    let name: String
    let found: Bool
    let detail: String
}
