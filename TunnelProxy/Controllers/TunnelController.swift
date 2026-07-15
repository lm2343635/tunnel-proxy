import Foundation
import Combine
import ServiceManagement

/// High-level connection state used to drive the menu bar icon and popover.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected")
        case .reconnecting: return String(localized: "Reconnecting…")
        case .error(let msg): return msg
        }
    }
}

/// Owns app state and drives the native `TunnelEngine`. The single
/// `ObservableObject` the SwiftUI views observe. No shell scripts, no `.env`.
@MainActor
final class TunnelController: ObservableObject {

    // Published UI state.
    @Published private(set) var state: ConnectionState = .disconnected {
        didSet {
            updateBlink()
            syncRecorderState()
        }
    }
    @Published private(set) var exitIP: String?
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isBusy = false
    @Published var systemSocksOn = false

    /// Drives the connecting/reconnecting blink: the menu bar icon dims while
    /// this is `true`. Toggled by `blinkTimer`; only animates in those states.
    @Published private(set) var iconDimmed = false

    // Configuration (persisted as JSON in Application Support).
    @Published var config: TunnelConfig

    // Preferences.
    @Published var watchdogEnabled: Bool {
        didSet { defaults.set(watchdogEnabled, forKey: Keys.watchdog) }
    }
    @Published var autoConnectOnLaunch: Bool {
        didSet { defaults.set(autoConnectOnLaunch, forKey: Keys.autoConnect) }
    }
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }
    /// Show live network speed next to the menu bar icon.
    @Published var showSpeed: Bool {
        didSet {
            defaults.set(showSpeed, forKey: Keys.showSpeed)
            syncSampling()
        }
    }
    /// Record traffic statistics (byte volume over time) while connected.
    @Published var recordStats: Bool {
        didSet {
            defaults.set(recordStats, forKey: Keys.recordStats)
            recorder.isEnabled = recordStats
            syncSampling()
        }
    }

    /// Publishes live up/down rates for the menu bar label.
    let speedMonitor = SpeedMonitor()
    /// Persists traffic usage over time; feeds the Statistics window.
    let recorder = TrafficRecorder()

    let defaults = UserDefaults.standard
    private let engine = TunnelEngine()
    private var pollTimer: Timer?
    private var blinkTimer: Timer?

    private enum Keys {
        static let watchdog = "watchdogEnabled"
        static let autoConnect = "autoConnectOnLaunch"
        static let showSpeed = "showSpeed"
        static let recordStats = "recordStats"
    }

    init() {
        config = TunnelConfig.load()
        watchdogEnabled = defaults.object(forKey: Keys.watchdog) as? Bool ?? true
        autoConnectOnLaunch = defaults.bool(forKey: Keys.autoConnect)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        showSpeed = defaults.object(forKey: Keys.showSpeed) as? Bool ?? false
        recordStats = defaults.object(forKey: Keys.recordStats) as? Bool ?? true
        AppPaths.ensureSupportDirectory()
        recorder.isEnabled = recordStats
        recorder.attach(to: speedMonitor)
        syncSampling()
        // Flush recorded traffic when the app quits (⌘Q or menu Quit).
        AppDelegate.onTerminate = { [weak self] in
            MainActor.assumeIsolated { self?.recorder.shutdown() }
        }
    }

    /// Sampling (the 1 Hz TCP-table read) must run whenever we either show the
    /// live speed *or* record statistics — both consume `SpeedMonitor`'s deltas.
    /// The recorder additionally gates on connection state and its own toggle.
    private func syncSampling() {
        if showSpeed || recordStats {
            speedMonitor.start(socksPort: config.socksPort)
        } else {
            speedMonitor.stop()
        }
    }

    /// The log file the viewer tails.
    var logURL: URL { AppPaths.logURL }

    /// Whether the app has everything it needs to run (bundled privoxy present).
    var privoxyAvailable: Bool {
        guard let p = AppPaths.bundledPrivoxy else { return false }
        return FileManager.default.isExecutableFile(atPath: p.path)
    }

    var isConfigured: Bool { config.canConnect }

    /// The currently selected server, if any.
    var selectedServer: ServerProfile? { config.selectedServer }

    // MARK: - Server management

    /// Add or update a server profile, storing its secret in the Keychain.
    /// Passing `secret == nil` leaves any existing secret untouched; passing an
    /// empty string clears it.
    func saveServer(_ server: ServerProfile, secret: String?) {
        var updated = server
        if let secret {
            if secret.isEmpty {
                KeychainStore.deleteSecret(for: server.id)
                updated.hasStoredSecret = false
            } else {
                KeychainStore.setSecret(secret, for: server.id)
                updated.hasStoredSecret = true
            }
        } else {
            updated.hasStoredSecret = KeychainStore.hasSecret(for: server.id)
        }
        config.upsert(updated)
        saveConfig()
    }

    func deleteServer(_ serverID: UUID) {
        config.remove(serverID)   // also removes the Keychain secret
        saveConfig()
    }

    func selectServer(_ serverID: UUID) {
        config.selectedServerID = serverID
        saveConfig()
        refreshStatus()
    }

    // MARK: - Statistics

    /// Wipe all recorded traffic statistics.
    func clearStatistics() {
        recorder.clearAll()
    }

    /// Flush the recorder before the app quits (call from `applicationWillTerminate`).
    func shutdownRecorder() {
        recorder.shutdown()
    }

    // MARK: - Lifecycle

    func onAppear() {
        startPolling()
        refreshStatus()
        syncSystemSocksState()
        // Ensure sampling is live (for speed display and/or recording).
        syncSampling()
        if autoConnectOnLaunch, config.canConnect, case .disconnected = state {
            Task { await connect() }
        }
    }

    /// Read the actual system SOCKS proxy state so the UI toggle matches reality.
    func syncSystemSocksState() {
        let service = config.networkService
        Task { [weak self] in
            let result = await Task.detached {
                ProcessRunner.run("/usr/sbin/networksetup",
                                  ["-getsocksfirewallproxy", service], timeout: 10)
            }.value
            let enabled = result.stdout.range(of: #"Enabled:\s*Yes"#,
                                              options: .regularExpression) != nil
            await MainActor.run { self?.systemSocksOn = enabled }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    /// Open/close the recording session as the connection comes up or drops.
    /// Only `.connected` counts as "up" — `.reconnecting` keeps the session open
    /// (the watchdog is mid-relaunch; SpeedMonitor already contributes 0 bytes).
    private func syncRecorderState() {
        switch state {
        case .connected:
            recorder.setConnected(true,
                                  serverID: selectedServer?.id,
                                  serverName: selectedServer?.displayName ?? "")
        case .reconnecting:
            break
        case .disconnected, .connecting, .error:
            recorder.setConnected(false, serverID: nil, serverName: "")
        }
    }

    /// Start/stop the blink timer based on state. Runs only while connecting or
    /// reconnecting; otherwise the icon is fully opaque.
    private func updateBlink() {
        let shouldBlink: Bool
        switch state {
        case .connecting, .reconnecting: shouldBlink = true
        default: shouldBlink = false
        }
        if shouldBlink {
            guard blinkTimer == nil else { return }
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.iconDimmed.toggle() }
            }
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            iconDimmed = false
        }
    }

    func saveConfig() {
        do {
            try config.save()
        } catch {
            NSLog("Failed to save config: \(error.localizedDescription)")
        }
        // Keep the speed monitor pointed at the (possibly changed) SOCKS port.
        speedMonitor.updateSocksPort(config.socksPort)
    }

    // MARK: - Actions

    func connect() async {
        guard !isBusy, config.canConnect, let server = config.selectedServer else {
            if !config.canConnect { state = .error(config.connectError ?? String(localized: "Invalid configuration")) }
            return
        }
        isBusy = true
        state = .connecting
        defer { isBusy = false }

        // Preflight: silently reclaim the SOCKS / HTTP-proxy ports before spawning
        // any child. A stale ssh/privoxy (or another app) holding a port would
        // otherwise make the tunnel fail to bind and the watchdog spin. Force-quit
        // whoever is listening (SIGTERM → SIGKILL); a root-owned holder we can't
        // kill just surfaces as the usual "failed to start" error afterwards.
        await reclaimPorts()

        // Retrieve the secret for auth methods that need one.
        let secret: String? = (server.authMethod == .agent) ? nil : KeychainStore.secret(for: server.id)
        let health = await engine.connect(config: config, server: server,
                                          secret: secret, watchdog: watchdogEnabled)
        switch health {
        case .proxyOK:
            state = .connected
            lastConnected = Date()
        case .tunnelOnly:
            state = .error(String(localized: "Tunnel OK but proxy failed"))
        case .down:
            state = .error(String(localized: "Tunnel failed to start"))
        }
        await updateExitIP()
    }

    /// Force-quit any process listening on the SOCKS or HTTP-proxy port so the
    /// tunnel can bind them. Runs the `lsof`/`kill` work off the MainActor.
    private func reclaimPorts() async {
        let ports = [config.socksPort, config.httpProxyPort]
        await Task.detached {
            for port in ports {
                guard let holder = PortInspector.holder(ofPort: port) else { continue }
                _ = PortInspector.forceQuit(pid: holder.pid)
            }
        }.value
    }

    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await engine.stop()
        state = .disconnected
        exitIP = nil
    }

    /// Poll health + exit IP without blocking the UI.
    func refreshStatus() {
        guard !isBusy else { return }
        Task {
            let ip = await engine.exitIP()
            if let ip {
                self.exitIP = ip
                if case .connected = self.state {} else {
                    self.state = .connected
                    if self.lastConnected == nil { self.lastConnected = Date() }
                }
            } else {
                switch self.state {
                case .connecting, .reconnecting: break
                default:
                    self.state = .disconnected
                    self.exitIP = nil
                }
            }
        }
    }

    private func updateExitIP() async {
        exitIP = await engine.exitIP()
    }

    // MARK: - System SOCKS proxy

    /// Enable/disable the macOS system SOCKS proxy for the configured network
    /// service. `networksetup` changes the current user's own network settings,
    /// which does not require administrator rights — so no password prompt.
    func toggleSystemSocks(on: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let service = config.networkService
        let port = config.socksPort
        let networksetup = "/usr/sbin/networksetup"

        let result: CommandResult = await Task.detached {
            if on {
                let set = ProcessRunner.run(networksetup,
                    ["-setsocksfirewallproxy", service, "127.0.0.1", "\(port)"], timeout: 20)
                guard set.succeeded else { return set }
                return ProcessRunner.run(networksetup,
                    ["-setsocksfirewallproxystate", service, "on"], timeout: 20)
            } else {
                return ProcessRunner.run(networksetup,
                    ["-setsocksfirewallproxystate", service, "off"], timeout: 20)
            }
        }.value

        if !result.succeeded {
            // Revert the toggle in the UI if the change failed.
            systemSocksOn = !on
            NSLog("System SOCKS toggle failed: \(result.output)")
        }
    }

    // MARK: - Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
