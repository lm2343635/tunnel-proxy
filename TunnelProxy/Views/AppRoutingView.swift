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
    @FocusState private var focusedMode: ProxyMode?
    @State private var selectedEvents: [RoutingAppIdentity: UUID] = [:]
    @State private var timelineStacked = false

    private var historyApp: RoutingApp? {
        routing.rules.apps.first { $0.id == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gridGap) {
            Text(routingText("App Routing")).font(.system(size: 24, weight: .bold))
            modeHeader
            HStack(alignment: .top, spacing: DS.gridGap) {
                applicationList.frame(width: 180)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(DS.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { restoreSelection() }
        .task(id: historyApp?.id) {
            guard let app = historyApp?.id else { return }
            while !Task.isCancelled {
                await routing.loadHistory(for: app)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        .onChange(of: routing.rules.version) { _, _ in
            if let selected, !routing.rules.apps.contains(where: { $0.id == selected }) { restoreSelection() }
        }
        .alert(routingText("Remove App?"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button(routingText("Remove"), role: .destructive) {
                guard let identity = pendingRemoval else { return }
                pendingRemoval = nil
                Task {
                    await controller.deleteRoutingApp(identity)
                    selectedEvents.removeValue(forKey: identity)
                    restoreSelection()
                }
            }
            Button(routingText("Cancel"), role: .cancel) {}
        } message: {
            Text(routingText("New connections from this app will use the system network."))
        }
    }

    private var modeHeader: some View {
        let busy = controller.isBusy || routing.busy
        let canRetry = controller.proxyMode == .appRouting && !routing.confirmed && !busy
        let status = controller.proxyModeDetail ?? (canRetry ? routingText("Routing state unknown") : nil)
        return VStack(alignment: .leading, spacing: 8) {
            Text(routingText("Proxy Mode")).font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: DS.gridGap) {
                modeCard(.local, icon: "terminal", description: routingText(
                    "Connect through the local proxy by setting it in each app."))
                modeCard(.appRouting, icon: "point.3.connected.trianglepath.dotted", description: routingText(
                    "Apply your routing rules to apps you’ve enabled below."))
                modeCard(.global, icon: "globe", description: routingText(
                    "Use the macOS SOCKS proxy for apps that follow system settings."))
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(busy)
            if let status {
                HStack(alignment: .firstTextBaseline) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if routing.canCancelApproval {
                        Button(routingText("Cancel")) { routing.cancelApproval() }
                    }
                    if canRetry {
                        Button(routingText("Retry")) { Task { await controller.chooseProxyMode(.appRouting) } }
                    }
                }
            }
        }
    }

    private func modeCard(_ mode: ProxyMode, icon: String, description: String) -> some View {
        let selected = controller.proxyMode == mode
        let focused = focusedMode == mode
        let shape = RoundedRectangle(cornerRadius: 10)
        return Button {
            Task { await controller.chooseProxyMode(mode) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selected ? DS.dataBlue : .secondary)
                    Spacer()
                    RadioDot(isSelected: selected, size: 12)
                }
                .padding(.bottom, 3)
                Text(mode.label).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                shape.fill(DS.tile)
                    .overlay { shape.fill(selected ? DS.accent.opacity(0.13) : .clear) }
            }
            .overlay { shape.strokeBorder(selected || focused ? DS.accent : DS.tileBorder,
                                          lineWidth: focused ? 2 : 1).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focused($focusedMode, equals: mode)
        .accessibilityLabel(Text(mode.label))
        .accessibilityValue(Text(description))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                            applicationRow(app)
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

    private func applicationRow(_ app: RoutingApp) -> some View {
        HStack(spacing: 6) {
            Button { edit(app) } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.directory.path))
                        .resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(app.isEnabled ? app.policy.label : routingText("Paused"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected == app.id ? .isSelected : [])

            Toggle(String.localizedStringWithFormat(routingText("Enable routing for %@"), app.name), isOn: Binding(
                get: { app.isEnabled },
                set: { enabled in
                    Task { await controller.setRoutingAppEnabled(enabled, for: app.id) }
                }))
                .toggleStyle(.switch)
                .tint(DS.accent)
                .controlSize(.small)
                .labelsHidden()
                .disabled(controller.isBusy || routing.busy)
                .padding(.trailing, 6)
        }
        .background(selected == app.id ? DS.accent.opacity(0.13) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var editor: some View {
        ScrollViewReader { proxy in
            editorScrollView(proxy)
        }
    }

    private func editorScrollView(_ proxy: ScrollViewProxy) -> some View {
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
                if let app = historyApp { recent(app, scrollProxy: proxy) }
            }
        }
    }

    private func recent(_ app: RoutingApp, scrollProxy: ScrollViewProxy) -> some View {
        let history = routing.histories[app.id] ?? AppRoutingController.History()
        let events = history.page.events.filter { $0.time >= RoutingHistoryStore.cutoff() }
        let selection = selectedEvents[app.id]
        return Tile {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        historyTitle(app)
                        Spacer(minLength: 10)
                        historyRetention
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        historyTitle(app)
                        historyRetention
                    }
                }
                Divider()
                let syncFailed = controller.proxyMode == .appRouting && routing.confirmed && routing.historySyncFailed
                if history.failed || syncFailed {
                    Label(routingText("Could not refresh connections"), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !events.isEmpty {
                    let selectedEvent = events.first { $0.id == selection }
                    // Use one timeline in either layout to keep its scroll anchor.
                    TimelineLayout {
                        VStack(alignment: .leading, spacing: 6) {
                            RoutingTimeline(events: events, selection: selection,
                                            hasEarlier: history.page.hasEarlier, isLoading: history.isLoading,
                                            select: { selectedEvents[app.id] = $0 },
                                            loadEarlier: { Task { await routing.loadHistory(for: app.id, earlier: true) } })
                                .id(app.id)
                            if timelineStacked && selectedEvent != nil {
                                Button(routingText("Show connection details")) {
                                    withAnimation { scrollProxy.scrollTo("routing-history-details", anchor: .top) }
                                }
                            }
                        }
                        connectionDetails(selectedEvent).id("routing-history-details")
                    }
                    .onGeometryChange(for: Bool.self) { $0.size.width < TimelineLayout.splitWidth } action: {
                        timelineStacked = $0
                    }
                    tlsSummary(events)
                } else if !history.hasLoaded && !history.failed && !syncFailed {
                    ProgressView(routingText("Loading connections…")).controlSize(.small)
                } else if history.hasLoaded && !history.failed && !syncFailed {
                    Text(routingText("No recent connections")).foregroundStyle(.secondary).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyTitle(_ app: RoutingApp) -> some View {
        Text(String.localizedStringWithFormat(routingText("Recent Connections · %@"), app.name))
            .font(.headline).accessibilityAddTraits(.isHeader)
    }

    private var historyRetention: some View {
        Text(String.localizedStringWithFormat(routingText("Last %lld days · Up to %@ per app"),
            Int64(RoutingHistoryStore.retention / 86_400), RoutingHistoryStore.perAppLimit.formatted()))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func tlsSummary(_ events: [RoutingEvent]) -> some View {
        let samples = Dictionary(grouping: events.compactMap(\.tcp), by: \.flowID)
            .compactMap { $0.value.first?.nameSource }
        let sni = samples.filter { $0 == "TLS SNI" }.count
        let ech = samples.filter { $0 == "ECH or GREASE" }.count
        let misses = samples.filter { $0 == "SNI timeout" || $0 == "No usable SNI" }.count
        if sni + ech + misses > 0 {
            Text(String(format: routingText("TLS names %d · ECH/GREASE %d · Other misses %d"),
                        sni, ech, misses)).font(.caption).foregroundStyle(DS.secondaryText)
        }
    }

    private func connectionDetails(_ event: RoutingEvent?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(routingText("Connection Details")).font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let event {
                Text(event.decision.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(timelineColor(event.decision))
                Divider()
                detailField("Destination", value: event.displayDestination)
                detailField("Local time", value: event.time.formatted(
                    .dateTime.year().month(.abbreviated).day().hour().minute().second()))
                if let reason = event.reason { detailField("Reason", value: routingText(reason)) }
                if let tcp = event.tcp {
                    let fields = [tcp.originalEndpoint, tcp.process, routingText(tcp.nameSource),
                                  tcp.addressType.map { "ATYP \($0)" }, routingText(tcp.stage),
                                  tcp.replyCode.map { "REP \($0)" }]
                    detailField("TCP details", value: fields.compactMap { $0 }.joined(separator: " · "))
                }
            } else {
                Text(routingText("Select a connection to see its details."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.tileBorder).allowsHitTesting(false) }
    }

    private func detailField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(routingText(label)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func restoreSelection() {
        if let first = routing.rules.apps.first { edit(first) }
        else { selected = nil; draft = nil; domains = "" }
    }

    private func edit(_ app: RoutingApp) {
        selected = app.id
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
        let chosen: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            adopt(url)
        }
        // Attach the panel to the window as a sheet. A modeless `begin` panel in
        // a menu-bar app can end up behind the main window — or never become the
        // key window at all — where clicks and scrolling do nothing, which looks
        // exactly like "Add App is broken".
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, !window.isSheet {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    /// Inspect the picked bundle and save it right away: "Add App" should add the
    /// app to the list, not leave a draft that only Apply Rules commits.
    private func adopt(_ url: URL) {
        picking = true
        Task {
            let inspected = await Task.detached { AppRoutingController.inspectApp(url) }.value
            picking = false
            guard let inspected else {
                notice = routingText("The app’s signing identity could not be verified.")
                return
            }
            var app = inspected
            if let old = routing.rules.apps.first(where: { $0.id == inspected.id }) {
                app.policy = old.policy
                app.domains = old.domains
                app.isEnabled = old.isEnabled
            }
            edit(app)
            await controller.saveRoutingApp(app)
            edit(app)
            notice = routing.message
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

private struct RoutingTimeline: View {
    let events: [RoutingEvent]
    let selection: UUID?
    let hasEarlier: Bool
    let isLoading: Bool
    let select: (UUID) -> Void
    let loadEarlier: () -> Void
    @State private var anchor: UUID?
    @FocusState private var focusedEvent: UUID?
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let rows = timelineRows()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        if row.startsDay { dayHeading(row.day) }
                        timelineRow(row)
                    }
                }
                if hasEarlier {
                    Button(routingText("Show earlier connections"), action: loadEarlier)
                        .disabled(isLoading)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $anchor, anchor: .top)
        .frame(height: 244)
    }

    private struct Row: Identifiable {
        let event: RoutingEvent
        let day: Date
        let startsDay: Bool
        let endsDay: Bool
        var id: UUID { event.id }
    }

    private func timelineRows() -> [Row] {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let days = events.map { localCalendar.startOfDay(for: $0.time) }
        return events.indices.map { index in
            Row(event: events[index], day: days[index],
                startsDay: index == 0 || days[index] != days[index - 1],
                endsDay: index == events.count - 1 || days[index] != days[index + 1])
        }
    }

    private func dayHeading(_ day: Date) -> some View {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let date = day.formatted(.dateTime.year().month(.abbreviated).day())
        let label: String
        if localCalendar.isDateInToday(day) {
            label = String.localizedStringWithFormat(routingText("Today · %@"), date)
        } else if localCalendar.isDateInYesterday(day) {
            label = String.localizedStringWithFormat(routingText("Yesterday · %@"), date)
        } else {
            label = date
        }
        return Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 8).padding(.bottom, 4)
    }

    private func timelineRow(_ row: Row) -> some View {
        let event = row.event
        let color = timelineColor(event.decision)
        return Button { select(event.id) } label: {
            HStack(spacing: 6) {
                Text(event.time.formatted(.dateTime.hour().minute().second()))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
                VStack(spacing: 0) {
                    Rectangle().fill(row.startsDay ? Color.clear : DS.tileBorder)
                    Circle().fill(color).frame(width: 7, height: 7)
                    Rectangle().fill(row.endsDay ? Color.clear : DS.tileBorder)
                }
                .frame(width: 8, height: 29)
                .accessibilityHidden(true)
                Text(event.displayDestination)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(event.decision.label)
                    .font(.caption.weight(.medium)).foregroundStyle(color).fixedSize()
            }
            .font(.callout)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .background(selection == event.id ? DS.accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if focusedEvent == event.id {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(DS.accent).allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($focusedEvent, equals: event.id)
        .accessibilityAddTraits(selection == event.id ? .isSelected : [])
    }
}

private struct TimelineLayout: Layout {
    private let spacing: CGFloat = 14
    static let splitWidth: CGFloat = 390

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.splitWidth
        let sizes = sizes(for: width, subviews: subviews)
        let height = width >= Self.splitWidth ? max(sizes.timeline.height, sizes.details.height)
            : sizes.timeline.height + spacing + sizes.details.height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(for: bounds.width, subviews: subviews)
        let split = bounds.width >= Self.splitWidth
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(sizes.timeline))
        let details = CGPoint(x: bounds.minX + (split ? sizes.timeline.width + spacing : 0),
                              y: bounds.minY + (split ? 0 : sizes.timeline.height + spacing))
        subviews[1].place(at: details, anchor: .topLeading, proposal: ProposedViewSize(sizes.details))
    }

    private func sizes(for width: CGFloat, subviews: Subviews) -> (timeline: CGSize, details: CGSize) {
        let split = width >= Self.splitWidth
        let detailsWidth = min(214, max(150, width * 0.36))
        let timelineWidth = split ? width - detailsWidth - spacing : width
        return (subviews[0].sizeThatFits(ProposedViewSize(width: timelineWidth, height: nil)),
                subviews[1].sizeThatFits(ProposedViewSize(width: split ? detailsWidth : width, height: nil)))
    }
}

private func timelineColor(_ decision: RoutingDecision) -> Color {
    switch decision {
    case .proxy: return .green
    case .blocked: return .red
    case .direct: return DS.secondaryText
    }
}

private extension RoutingEvent {
    var displayDestination: String {
        destination.isEmpty ? routingText("Destination unavailable") : destination
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
