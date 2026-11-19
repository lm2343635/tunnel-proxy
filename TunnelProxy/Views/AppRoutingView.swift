import SwiftUI
import UniformTypeIdentifiers

struct AppRoutingView: View {
    @EnvironmentObject private var controller: TunnelController
    @ObservedObject var routing: AppRoutingController
    @State private var selected: RoutingAppIdentity?
    @State private var draft: RoutingApp?
    @State private var domains = ""
    @State private var notice: String?
    @State private var picking = false
    @State private var pendingRemoval: RoutingAppIdentity?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gridGap) {
            heading
            modeHeader
            HStack(alignment: .top, spacing: DS.gridGap) {
                applicationList.frame(minWidth: 180, idealWidth: 200, maxWidth: 224)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(DS.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { restoreSelection() }
        .onDisappear { routing.observeEvents(for: nil) }
        .onChange(of: routing.rules.version) { _, _ in
            if let selected, !routing.rules.apps.contains(where: { $0.id == selected }) { restoreSelection() }
        }
        .alert(routingText("Remove App?"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button(routingText("Remove"), role: .destructive) {
                guard let identity = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await controller.deleteRoutingApp(identity); restoreSelection() }
            }
            Button(routingText("Cancel"), role: .cancel) {}
        } message: {
            Text(routingText("New connections from this app will use the system network."))
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(routingText("App Routing")).font(.system(size: 24, weight: .bold))
            Text(routingText(controller.proxyMode == .appRouting
                             ? "Unlisted apps use the system network."
                             : "Rules take effect in Per-App Routing mode."))
                .font(.callout).foregroundStyle(DS.secondaryText)
        }
    }

    private var modeHeader: some View {
        Tile {
            VStack(alignment: .leading, spacing: 8) {
                Text(routingText("Proxy Mode")).font(.headline)
                Picker(routingText("Proxy Mode"), selection: Binding(
                    get: { controller.proxyMode },
                    set: { mode in Task { await controller.chooseProxyMode(mode) } })) {
                    ForEach(ProxyMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .labelsHidden().pickerStyle(.segmented)
                .disabled(controller.isBusy || routing.busy)
                if let status = controller.proxyModeDetail {
                    HStack {
                        Text(status).font(.caption).foregroundStyle(DS.secondaryText)
                        Spacer()
                        if routing.busy {
                            Button(routingText("Cancel")) { routing.cancelApproval() }
                        }
                        if controller.proxyMode == .appRouting && !routing.confirmed && !routing.busy {
                            Button(routingText("Retry")) { Task { await controller.chooseProxyMode(.appRouting) } }
                        }
                    }
                }
            }
        }
    }

    private var applicationList: some View {
        Tile {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(routingText("Applications")).font(.headline)
                    Spacer()
                    Button(action: pick) { Label(routingText("Add App"), systemImage: "plus").labelStyle(.iconOnly) }
                        .disabled(picking || routing.busy)
                        .help(routingText("Add App"))
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(routing.rules.apps) { app in
                            Button { edit(app) } label: {
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.directory.path))
                                        .resizable().frame(width: 26, height: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(app.isEnabled ? app.policy.label : routingText("Paused"))
                                            .font(.caption).foregroundStyle(DS.secondaryText).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(6)
                                .background(selected == app.id ? DS.accent.opacity(0.13) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected == app.id ? .isSelected : [])
                        }
                    }
                }
                Spacer(minLength: 2)
                Text(routingAppCount(routing.rules.apps.count, key: "routing.appCount"))
                    .foregroundStyle(DS.secondaryText).font(.caption)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gridGap) {
                Tile {
                    if let draft {
                        let app = routing.rules.apps.first { $0.id == draft.id }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(draft.name).font(.headline)
                                Spacer()
                                if app != nil {
                                    Button(routingText("Remove")) { pendingRemoval = draft.id }
                                        .disabled(routing.busy)
                                }
                            }
                            if let app {
                                Toggle(routingText("Enable routing for this app"), isOn: Binding(
                                    get: { app.isEnabled },
                                    set: { enabled in
                                        notice = nil
                                        Task { await controller.setRoutingAppEnabled(enabled, for: app.id) }
                                    }))
                                    .toggleStyle(.switch)
                                    .disabled(controller.isBusy || routing.busy)
                            }
                            Text(routingText(app?.isEnabled == false
                                             ? "In Per-App Routing mode, new connections from this app use the system network."
                                             : "Local and LAN destinations use the system network."))
                                .foregroundStyle(DS.secondaryText).font(.caption)
                            Picker(routingText("Connection Policy"), selection: Binding(
                                get: { self.draft?.policy ?? .proxyAll },
                                set: { self.draft?.policy = $0 })) {
                                ForEach(AppRoutePolicy.allCases) { value in Text(value.label).tag(value) }
                            }
                            if draft.policy.usesDomains {
                                Text(routingText("One domain per line. Subdomains are included.")).font(.caption)
                                TextEditor(text: $domains)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 76, maxHeight: 124)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.secondaryText.opacity(0.25)))
                                    .accessibilityLabel(routingText("Domains"))
                            }
                            HStack {
                                if let notice { Text(notice).font(.caption).foregroundStyle(DS.secondaryText) }
                                Spacer()
                                Button(routingText("Apply Rules")) { save(draft) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(routing.busy)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(routingText("Choose an app to edit its rules.")).font(.headline)
                            Button(routingText("Add App"), action: pick).disabled(picking || routing.busy)
                            if let notice { Text(notice).foregroundStyle(DS.secondaryText).font(.caption) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let selected { recent(selected) }
            }
        }
    }

    private func recent(_ identity: RoutingAppIdentity) -> some View {
        let recent = routing.status?.events.filter { $0.application == identity }.reversed().prefix(50)
        return Tile {
            VStack(alignment: .leading, spacing: 7) {
                Text(routingText("Recent Connections")).font(.headline)
                if let recent, !recent.isEmpty {
                    ForEach(Array(recent)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.destination.isEmpty ? routingText("Destination unavailable") : event.destination)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(event.decision.label)
                                    .foregroundStyle(event.decision == .proxy ? DS.accent
                                                     : event.decision == .blocked ? Color.red : DS.secondaryText)
                            }
                            if let reason = event.reason { Text(routingText(reason)).font(.caption).foregroundStyle(DS.secondaryText) }
                        }
                    }
                } else {
                    Text(routingText("No recent connections")).foregroundStyle(DS.secondaryText).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func restoreSelection() {
        if let first = routing.rules.apps.first { edit(first) }
        else { selected = nil; draft = nil; domains = ""; routing.observeEvents(for: nil) }
    }

    private func edit(_ app: RoutingApp) {
        selected = app.id
        routing.observeEvents(for: app.id)
        draft = app
        domains = app.domains.joined(separator: "\n")
        notice = nil
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = routingText("Add App")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            picking = true
            Task {
                let app = await Task.detached { AppRoutingController.inspectApp(url) }.value
                picking = false
                guard let app else { notice = routingText("The app’s signing identity could not be verified."); return }
                if let old = routing.rules.apps.first(where: { $0.id == app.id }) {
                    var renewed = app
                    renewed.policy = old.policy
                    renewed.domains = old.domains
                    edit(renewed)
                } else {
                    edit(app)
                }
            }
        }
    }

    private func save(_ rule: RoutingApp) {
        var basedOn = rule
        var seen = Set<String>()
        let lines = domains.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var normalized: [String] = []
        for line in lines {
            guard let name = RoutingDomain.normalize(line) else {
                notice = routingText("Enter valid domain names without URLs or wildcards.")
                return
            }
            if seen.insert(name).inserted { normalized.append(name) }
        }
        basedOn.domains = normalized
        Task { await controller.saveRoutingApp(basedOn); edit(basedOn); notice = routing.message }
    }
}

func routingAppCount(_ count: Int, key: String = "routing.configuredAppCount") -> String {
    String.localizedStringWithFormat(routingText(key), Int64(count))
}

struct ProxyModeSummary: View {
    @EnvironmentObject private var controller: TunnelController
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routingText("Proxy Mode")).font(.system(size: 11.5, weight: .semibold))
                    Text(controller.proxyMode.label).font(.caption).lineLimit(1)
                    if controller.proxyMode == .appRouting {
                        Text(routingAppCount(controller.appRouting.rules.apps.count))
                            .font(.caption2).lineLimit(1)
                    }
                    if let status = controller.proxyModeDetail {
                        Text(status).font(.caption2).lineLimit(1)
                    }
                }
                .foregroundStyle(DS.secondaryText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DS.secondaryText)
            }
            .padding(7)
            .background(DS.canvas, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(routingText("Proxy Mode"))
        .accessibilityValue(controller.proxyMode.label)
        .help(controller.proxyModeDetail ?? routingText("Manage App Routing"))
    }
}
