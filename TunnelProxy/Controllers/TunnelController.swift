import Foundation
import Combine
import ServiceManagement
import SwiftUI

/// The tabs of the unified main window. Also used to route "open the window on
/// tab X" requests from the popover and app menus (see `requestedTab`).
enum WindowTab: String {
    case connection, appRouting, servers, logs, stats, settings, speedTest, tools
}

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
            if oldValue == .connected && state != .connected { speedTest.cancel(connectionChanged: true) }
            updateBlink()
            syncRecorderState()
            syncLatencyProbing()
            updateDockIcon()
        }
    }
    @Published private(set) var routeStatus = String(localized: "Not connected")
    @Published private(set) var routeError: String?
    @Published private(set) var routeViaProxy = false
    private var routeTimer: Timer?

    @Published private(set) var exitIP: String?
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isBusy = false

    /// Latency (ms) to the active server, averaged over recent probes, or nil when
    /// disconnected / unreachable. Probed every ~10 s while connected.
    @Published private(set) var latencyMS: Int?
    /// A rolling history of recent latency readings (ms), oldest first, for the
    /// Connection tab's latency history bars. Capped at `latencyHistoryCapacity`.
    @Published private(set) var latencyHistory: [Int] = []
    private let latencyHistoryCapacity = 50
    /// Recent raw latency samples (ms), used to average over ~60 s.
    private var latencySamples: [Int] = []
    private var latencyTimer: Timer?

    /// A request to open the unified main window on a specific tab, set by the
    /// menu-bar popover and app menus. `UnifiedWindowView` observes it, switches
    /// its `TabView` selection, and clears it back to `nil`.
    @Published var requestedTab: WindowTab?
    /// User intent to route all system traffic through the tunnel's SOCKS proxy.
    /// Persisted so it survives relaunches; the *actual* OS proxy is applied on
    /// connect and cleared on disconnect (see `applySystemProxy`).
    @Published var systemSocksOn: Bool {
        didSet { defaults.set(systemSocksOn, forKey: Keys.systemSocks) }
    }
    @Published private(set) var proxyMode: ProxyMode
    @Published private(set) var proxyModeError: String?
    let appRouting = AppRoutingController()
    private var routingTimer: Timer?
    private var routingUpdates: AnyCancellable?
    private var routingStarted = false

    /// Drives the connecting/reconnecting blink: the menu bar icon dims while
    /// this is `true`. Toggled by `blinkTimer`; only animates in those states.
    @Published private(set) var iconDimmed = false

    // Configuration (persisted as JSON in Application Support).
    @Published var config: TunnelConfig

    // Preferences.
    var automaticRouting: Bool { selectedServer?.effectiveRouting.mode == .automatic }
    var reconnectEnabled: Bool { watchdogEnabled || automaticRouting }

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
    /// Reflect the connection state on the Dock icon (tint + status badge) while
    /// the main window is open. When off, the Dock shows the plain bundle icon.
    @Published var showDockStateIcon: Bool {
        didSet {
            defaults.set(showDockStateIcon, forKey: Keys.showDockStateIcon)
            updateDockIcon()
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
    /// Whether the menu bar status item is visible. Toggled from the main
    /// window; bound to the `MenuBarExtra` scene's `isInserted:`.
    ///
    /// NOT a plain `@Published`: `MenuBarExtra(isInserted:)` installs a KVO
    /// observer on the status item that writes the *current* value back through
    /// this binding while SwiftUI is updating scenes. A `@Published` publishes on
    /// every assignment — even a same-value one — so that write-back re-triggers
    /// `objectWillChange` mid-update ("Publishing changes from within view
    /// updates"), which re-runs the update, which writes back again: a tight loop
    /// that freezes the UI. Gating the publish on an actual change breaks it.
    var showMenuBarIcon: Bool {
        get { showMenuBarIconStore }
        set {
            guard newValue != showMenuBarIconStore else { return }
            objectWillChange.send()
            showMenuBarIconStore = newValue
            defaults.set(newValue, forKey: Keys.showMenuBarIcon)
        }
    }
    private var showMenuBarIconStore: Bool

    /// Publishes live up/down rates for the menu bar label.
    let speedMonitor: SpeedMonitor
    /// Persists traffic usage over time; feeds the Statistics window.
    let recorder = TrafficRecorder()
    let speedTest = TunnelSpeedTest()

    let defaults = UserDefaults.standard
    private let engine: TunnelEngine
    private var pollTimer: Timer?
    private var blinkTimer: Timer?

    private enum Keys {
        static let watchdog = "watchdogEnabled"
        static let autoConnect = "autoConnectOnLaunch"
        static let showSpeed = "showSpeed"
        static let recordStats = "recordStats"
        static let systemSocks = "systemSocksOn"
        static let proxyMode = "proxyMode"
        static let socksOwnerService = "ownedSystemSocksService"
        static let socksOwnerPort = "ownedSystemSocksPort"
        static let socksOwnerHttpPort = "ownedSystemHttpProxyPort"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockStateIcon = "showDockStateIcon"
    }

    init() {
        let engine = TunnelEngine()
        self.engine = engine
        self.speedMonitor = SpeedMonitor(engine: engine)
        config = TunnelConfig.load()
        watchdogEnabled = defaults.object(forKey: Keys.watchdog) as? Bool ?? true
        autoConnectOnLaunch = defaults.bool(forKey: Keys.autoConnect)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        showSpeed = defaults.object(forKey: Keys.showSpeed) as? Bool ?? false
        recordStats = defaults.object(forKey: Keys.recordStats) as? Bool ?? true
        let initialProxyMode = defaults.string(forKey: Keys.proxyMode).flatMap(ProxyMode.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.systemSocks) ? .global : .local)
        proxyMode = initialProxyMode
        systemSocksOn = initialProxyMode == .global
        showMenuBarIconStore = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        showDockStateIcon = defaults.object(forKey: Keys.showDockStateIcon) as? Bool ?? true
        AppPaths.ensureSupportDirectory()
        recorder.isEnabled = recordStats
        recorder.attach(to: speedMonitor)
        syncSampling()
        // Flush recorded traffic when the app quits (⌘Q or menu Quit).
        AppDelegate.onTerminate = { [weak self] in
            MainActor.assumeIsolated {
                self?.speedTest.cancel()
                self?.recorder.shutdown()
            }
        }
        // Let the launch fallback reach us if the menu bar icon was hidden.
        AppDelegate.controller = self
        routingUpdates = appRouting.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        // Reflect the initial (disconnected) state on the Dock tile if it's shown.
        updateDockIcon()
    }

    /// Sampling must run whenever we either show the
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

    var canStartSpeedTest: Bool {
        isConnected && selectedServer != nil
    }

    func startSpeedTest() {
        guard canStartSpeedTest, let server = selectedServer else { return }
        speedTest.start(engine: engine, serverID: server.id)
    }

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
        if selectedServer?.id == serverID { speedTest.cancel(connectionChanged: true) }
        config.remove(serverID)   // also removes the Keychain secret
        saveConfig()
    }

    func selectServer(_ serverID: UUID) {
        if selectedServer?.id != serverID { speedTest.cancel(connectionChanged: true) }
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
        reconcileSystemSocksState()
        // Ensure sampling is live (for speed display and/or recording).
        syncSampling()
        if !routingStarted {
            routingStarted = true
            Task {
                await appRouting.adopt()
                if proxyMode == .appRouting {
                    _ = await appRouting.enable(using: await engine.routingPeer())
                }
            }
            routingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appRouting.maintainHistory()
                    guard self.proxyMode == .appRouting else { return }
                    await self.appRouting.heartbeat(peer: self.engine.routingPeer())
                }
            }
        }
        if autoConnectOnLaunch, config.canConnect, case .disconnected = state {
            Task { await connect() }
        }
    }

    /// On launch, clear any stale OS proxy left behind by a crash or a
    /// non-graceful quit: if SOCKS or HTTP/HTTPS is actually enabled but no
    /// tunnel is up, disabling them prevents a "no internet" state. The
    /// `systemSocksOn` intent flag is untouched — a later connect re-applies it.
    func reconcileSystemSocksState() {
        let service = config.networkService
        guard defaults.string(forKey: Keys.socksOwnerService) == service else { return }
        Task { [weak self] in
            guard let self else { return }
            let enabled = await Task.detached {
                ["-getsocksfirewallproxy", "-getwebproxy"].contains { get in
                    let r = ProcessRunner.run("/usr/sbin/networksetup", [get, service], timeout: 10)
                    return r.stdout.range(of: #"Enabled:\s*Yes"#,
                                          options: .regularExpression) != nil
                }
            }.value
            guard enabled else { return }
            // Only clear it if there is no app-owned local tunnel. Exit-IP is
            // telemetry: an ipify/DNS outage must not masquerade as tunnel death.
            let tunnelUp = await self.engine.checkHealth() != .down
            if !tunnelUp {
                await self.applySystemProxy(on: false)
            }
        }
    }

    private func startPolling() {
        routeTimer?.invalidate()
        routeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await self.engine.routingStatus()
                self.routeViaProxy = status.3
                self.routeStatus = status.0
                self.routeError = status.1
            }
        }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    // MARK: - Latency

    /// Start probing server latency every ~10 s. Fires an immediate probe so the
    /// value appears promptly on connect.
    private func startLatencyProbing() {
        latencyTimer?.invalidate()
        latencyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.probeLatency() }
        }
        Task { await probeLatency() }
    }

    private func stopLatencyProbing() {
        latencyTimer?.invalidate()
        latencyTimer = nil
        latencySamples.removeAll()
        latencyHistory.removeAll()
        latencyMS = nil
    }

    /// Match latency probing to connection state: probe while connected, idle
    /// otherwise. Called from `state`'s `didSet`.
    private func syncLatencyProbing() {
        switch state {
        case .connected:
            if latencyTimer == nil { startLatencyProbing() }
        case .reconnecting:
            break                       // keep the last average during a blip
        case .disconnected, .connecting, .error:
            stopLatencyProbing()
        }
    }

    /// Take one latency sample and fold it into the ~60 s rolling average. Only
    /// meaningful while connected; a failed probe leaves the average untouched
    /// (the tunnel may just be momentarily busy) unless we're already unknown.
    private func probeLatency() async {
        guard isConnected else { return }
        guard let ms = await engine.latencyMS() else { return }
        latencySamples.append(ms)
        if latencySamples.count > 6 { latencySamples.removeFirst(latencySamples.count - 6) }
        latencyMS = latencySamples.reduce(0, +) / latencySamples.count
        // Feed the raw reading into the history window for the latency bars.
        latencyHistory.append(ms)
        if latencyHistory.count > latencyHistoryCapacity {
            latencyHistory.removeFirst(latencyHistory.count - latencyHistoryCapacity)
        }
    }

    /// Color for a latency reading: green < 80 ms, orange < 200, red above.
    /// `DS.secondaryText`-equivalent gray when unknown.
    var latencyColor: Color {
        switch latencyMS {
        case .some(let ms) where ms < 80: return DS.textGreen
        case .some(let ms) where ms < 200: return DS.warning
        case .some: return DS.dangerText
        case .none: return DS.secondaryText
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

    /// The connecting/reconnecting state now shows a static loading glyph (see
    /// `menuBarSymbol`) instead of a blinking shield, so the icon stays fully
    /// opaque at all times. Kept as a no-op stop so any lingering timer is torn
    /// down and `iconDimmed` never sticks on.
    private func updateBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        iconDimmed = false
    }

    /// Paint the Dock tile to reflect the current connection state (tint + status
    /// badge). Only matters while the main window is open — the app is
    /// `LSUIElement` and shows a Dock icon only in `.regular` activation. Setting
    /// `applicationIconImage` while `.accessory` is harmless (no tile), so we
    /// don't gate on policy here; `AppActivation.becomeRegular()` re-invokes this
    /// so a window opened mid-connection shows the right icon immediately.
    ///
    /// When the toggle is off, restore the plain bundle icon (loaded by name so
    /// the default is always recoverable).
    func updateDockIcon() {
        if showDockStateIcon {
            NSApp.applicationIconImage = DockIconRenderer.image(for: state)
        } else {
            // nil resets `applicationIconImage` to the app bundle's own icon.
            NSApp.applicationIconImage = nil
        }
        NSApp.dockTile.display()
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

        // Reclaim only stale processes of the same kinds this app launches. A
        // foreign listener (notably launchd-managed Homebrew Privoxy) is reported
        // instead of killed: launchd would immediately restart it and race the
        // bundled child forever.
        if let conflict = await reclaimPorts() {
            state = .error(conflict)
            return
        }

        // Retrieve the secret for auth methods that need one.
        let secret: String? = (server.authMethod == .agent) ? nil : KeychainStore.secret(for: server.id)
        let health = await engine.connect(config: config, server: server,
                                          secret: secret, watchdog: watchdogEnabled)
        let routing = await engine.routingStatus()
        routeViaProxy = routing.3
        routeStatus = routing.0
        routeError = routing.1
        switch health {
        case .proxyOK:
            state = .connected
            lastConnected = Date()
            // Honor the persisted "route all traffic" intent now that we're up.
            if systemSocksOn { await applySystemProxy(on: true) }
        case .tunnelOnly:
            state = .error(String(localized: "Tunnel OK but proxy failed"))
        case .down:
            state = routing.2 ? .reconnecting : .error(routing.1 ?? String(localized: "Tunnel failed to start"))
        }
        await updateExitIP()
    }

    /// Reclaim stale app-kind listeners, or return a user-facing conflict for a
    /// foreign/root-owned process. Runs `lsof`/`kill` off the MainActor.
    private func reclaimPorts() async -> String? {
        let ports = [config.socksPort, config.httpProxyPort]
        return await Task.detached {
            for port in ports {
                guard let holder = PortInspector.holder(ofPort: port) else { continue }
                guard holder.isOurs else {
                    return String.localizedStringWithFormat(
                        String(localized: "Port %d is in use by %@"),
                        port, holder.command)
                }
                switch PortInspector.forceQuit(pid: holder.pid) {
                case .freed: continue
                case .needsAdmin:
                    return String.localizedStringWithFormat(
                        String(localized: "Port %d requires administrator access to release"), port)
                case .failed(let reason):
                    return String.localizedStringWithFormat(
                        String(localized: "Could not release port %d: %@"), port, reason)
                }
            }
            return nil
        }.value
    }

    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Always clear the *actual* OS SOCKS proxy so the machine keeps working
        // once the tunnel is gone — but leave the `systemSocksOn` intent flag on,
        // so the next connect re-applies it automatically.
        if systemSocksOn { await applySystemProxy(on: false) }
        await engine.stop()
        if proxyMode == .appRouting { await appRouting.heartbeat(peer: nil) }
        state = .disconnected
        exitIP = nil
    }

    /// Poll app-owned process/listener health + optional exit IP without blocking
    /// the UI. Public exit-IP lookup is telemetry, not the connection state.
    func refreshStatus() {
        guard !isBusy else { return }
        Task {
            let health = await engine.checkHealth()
            let routing = await engine.routingStatus()
            self.routeViaProxy = routing.3
            self.routeStatus = routing.0
            self.routeError = routing.1
            let ip: String?
            if health == .down {
                ip = nil
            } else {
                ip = await engine.exitIP()
            }
            switch health {
            case .proxyOK:
                self.exitIP = ip
                if case .connected = self.state {} else {
                    self.state = .connected
                    if self.lastConnected == nil { self.lastConnected = Date() }
                }
            case .tunnelOnly:
                self.exitIP = nil
                self.state = .error(String(localized: "Tunnel OK but proxy failed"))
            case .down:
                self.exitIP = nil
                if routing.2 { self.state = .reconnecting }
                else if let error = routing.1 { self.state = .error(error) }
                else { self.state = .disconnected }
            }
        }
    }

    private func updateExitIP() async {
        exitIP = await engine.exitIP()
    }

    // MARK: - System SOCKS proxy

    var proxyModeDetail: String? {
        if let proxyModeError { return proxyModeError }
        if proxyMode == .appRouting || appRouting.busy { return appRouting.message }
        if proxyMode == .global, !isConnected { return routingText("Waiting for the SSH tunnel") }
        return nil
    }

    func chooseProxyMode(_ mode: ProxyMode) async {
        guard !isBusy, !appRouting.busy, mode != proxyMode || (mode == .appRouting && !appRouting.confirmed) else { return }
        isBusy = true
        proxyModeError = nil
        defer { isBusy = false }
        let previous = proxyMode
        // Global and Per-App Routing are two different transports and must never
        // be live at the same time, but that only means the outgoing one has to
        // be torn down *before* the incoming one starts — not that a direct
        // switch needs a detour through Local Proxy Only. Every step is rolled
        // back on failure so a failed switch never leaves the app claiming a mode
        // whose transport is off.
        switch mode {
        case .appRouting:
            if previous == .global {
                guard await applySystemProxy(on: false) else {
                    proxyModeError = routingText("Could not change proxy mode")
                    return
                }
            }
            guard await appRouting.enable(using: await engine.routingPeer()) else {
                if previous == .global { _ = await applySystemProxy(on: true) }
                proxyModeError = appRouting.message
                return
            }
        case .global:
            if previous == .appRouting {
                guard await appRouting.disable() else {
                    proxyModeError = appRouting.message
                    return
                }
            }
            if isConnected, !(await applySystemProxy(on: true)) {
                if previous == .appRouting { _ = await appRouting.enable(using: await engine.routingPeer()) }
                proxyModeError = routingText("Could not change proxy mode")
                return
            }
        case .local:
            if previous == .appRouting, !(await appRouting.disable()) {
                proxyModeError = appRouting.message
                return
            }
            if previous == .global, !(await applySystemProxy(on: false)) {
                proxyModeError = routingText("Could not change proxy mode")
                return
            }
        }
        proxyMode = mode
        systemSocksOn = mode == .global
        defaults.set(mode.rawValue, forKey: Keys.proxyMode)
    }

    func saveRoutingApp(_ rule: RoutingApp) async {
        await appRouting.save(rule, peer: engine.routingPeer())
    }

    func setRoutingAppEnabled(_ enabled: Bool, for identity: RoutingAppIdentity) async {
        guard !isBusy else { return }
        await appRouting.setEnabled(enabled, for: identity, peer: engine.routingPeer())
    }

    func deleteRoutingApp(_ identity: RoutingAppIdentity) async {
        await appRouting.delete(identity, peer: engine.routingPeer())
    }

    func prepareToQuit() async -> Bool {
        appRouting.cancelApproval()
        for _ in 0..<60 where isBusy || appRouting.busy {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !isBusy, !appRouting.busy else { return false }
        if proxyMode == .appRouting, !(await appRouting.disable()) { return false }
        if systemSocksOn, !(await applySystemProxy(on: false)) { return false }
        await engine.stop()
        return true
    }

    /// Enable/disable the macOS system SOCKS proxy for the configured network
    /// service. `networksetup` changes the current user's own network settings,
    /// which does not require administrator rights — so no password prompt.
    ///
    /// `systemSocksOn` is the *user intent* toggle and is persisted across
    /// connect/disconnect. The actual OS proxy, however, is only meaningful while
    /// the tunnel is up: `connect()`/`disconnect()` apply and clear it to match
    /// intent, so the machine keeps working when the tunnel is down.
    func toggleSystemSocks(on: Bool) async {
        await chooseProxyMode(on ? .global : .local)
    }

    /// Push the system proxy state to `networksetup` without touching the
    /// `systemSocksOn` intent flag. Returns whether the change succeeded.
    ///
    /// Global mode sets a SOCKS proxy **and** an HTTP/HTTPS proxy:
    ///
    /// - SOCKS (`127.0.0.1:socksPort`) for apps that only speak SOCKS.
    /// - HTTP/HTTPS (`127.0.0.1:httpProxyPort`, the bundled Privoxy) because a
    ///   SOCKS client hands the proxy an *already resolved* address, so a
    ///   poisoned/hijacked local DNS answer is dialled verbatim and the tunnel
    ///   fails at the far end. An HTTP request or `CONNECT` carries the hostname,
    ///   and Privoxy passes that hostname on to `ssh -D`, which resolves it on
    ///   the server side. Chromium-based browsers (Chrome) and the ChatGPT /
    ///   Claude desktop apps only reach their backends through this path on
    ///   networks that tamper with DNS.
    ///
    /// `networksetup` needs no administrator rights here: it edits the current
    /// user's own network settings.
    @discardableResult
    private func applySystemProxy(on: Bool) async -> Bool {
        let ownedService = defaults.string(forKey: Keys.socksOwnerService)
        let ownedSocks = defaults.integer(forKey: Keys.socksOwnerPort)
        let ownedHTTP = defaults.integer(forKey: Keys.socksOwnerHttpPort)
        guard on || ownedService != nil else { return true }
        let service = on ? config.networkService : ownedService ?? config.networkService
        let socksPort = on ? config.socksPort : ownedSocks
        let httpPort = on ? config.httpProxyPort : ownedHTTP

        let result: CommandResult = await Task.detached {
            on ? Self.turnOnSystemProxy(service: service, socksPort: socksPort, httpPort: httpPort)
                : Self.turnOffSystemProxy(service: service, socksPort: socksPort, httpPort: httpPort)
        }.value

        if !result.succeeded {
            NSLog("System proxy toggle failed: \(result.output)")
        } else if on {
            defaults.set(service, forKey: Keys.socksOwnerService)
            defaults.set(socksPort, forKey: Keys.socksOwnerPort)
            defaults.set(httpPort, forKey: Keys.socksOwnerHttpPort)
        } else {
            defaults.removeObject(forKey: Keys.socksOwnerService)
            defaults.removeObject(forKey: Keys.socksOwnerPort)
            defaults.removeObject(forKey: Keys.socksOwnerHttpPort)
        }
        return result.succeeded
    }

    private nonisolated static func turnOnSystemProxy(service: String, socksPort: Int, httpPort: Int) -> CommandResult {
        let networksetup = "/usr/sbin/networksetup"
        let writes: [[String]] = [
            ["-setsocksfirewallproxy", service, "127.0.0.1", "\(socksPort)"],
            ["-setsocksfirewallproxystate", service, "on"],
            ["-setwebproxy", service, "127.0.0.1", "\(httpPort)"],
            ["-setwebproxystate", service, "on"],
            ["-setsecurewebproxy", service, "127.0.0.1", "\(httpPort)"],
            ["-setsecurewebproxystate", service, "on"],
        ]
        var failure: CommandResult?
        for args in writes {
            let result = ProcessRunner.run(networksetup, args, timeout: 20)
            if !result.succeeded, failure == nil { failure = result }
        }
        // A half-applied proxy set is worse than none: undo it before reporting.
        if let failure {
            _ = turnOffSystemProxy(service: service, socksPort: socksPort, httpPort: httpPort)
            return failure
        }
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    private nonisolated static func turnOffSystemProxy(service: String, socksPort: Int, httpPort: Int) -> CommandResult {
        let networksetup = "/usr/sbin/networksetup"
        let writes = [("-setsocksfirewallproxystate", "-getsocksfirewallproxy", socksPort),
                      ("-setwebproxystate", "-getwebproxy", httpPort),
                      ("-setsecurewebproxystate", "-getsecurewebproxy", httpPort)]
        var failure: CommandResult?
        for (set, get, port) in writes where points(atUs: get, service: service, port: port) {
            let result = ProcessRunner.run(networksetup, [set, service, "off"], timeout: 20)
            if !result.succeeded, failure == nil { failure = result }
        }
        return failure ?? CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    /// Only a proxy that still points at this app's own local listener is ours to
    /// turn off; something the user configured themselves must survive a switch.
    private nonisolated static func points(atUs get: String, service: String, port: Int) -> Bool {
        guard port > 0 else { return false }
        let saved = ProcessRunner.run("/usr/sbin/networksetup", [get, service], timeout: 10)
        guard saved.succeeded else { return false }
        return saved.stdout.contains("Server: 127.0.0.1")
            && (saved.stdout.contains("Port: \(port)\n") || saved.stdout.hasSuffix("Port: \(port)"))
    }

    /// Turn off every proxy (HTTP, HTTPS, SOCKS, and PAC) for the configured
    /// network service, clearing the interface's proxy state entirely. Also drops
    /// the `systemSocksOn` intent so the app stops re-applying SOCKS on connect.
    /// Returns whether all proxy toggles succeeded.
    @discardableResult
    func removeAllProxies() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }

        let service = config.networkService
        let ok = await Task.detached {
            NetworkServices.removeAllProxies(for: service)
        }.value

        // The system SOCKS proxy is now off; keep the UI intent flag in sync so
        // the next connect doesn't silently turn it back on.
        systemSocksOn = false
        if ok, proxyMode == .global {
            proxyMode = .local
            defaults.set(ProxyMode.local.rawValue, forKey: Keys.proxyMode)
        }
        return ok
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
