import SwiftUI

/// Manages the list of SSH server profiles: select active, add, edit, delete.
/// Redesigned as Control-Center tiles — one card per profile over the canvas,
/// a dashed "add" tile, and a Keychain footnote. The editor is a sheet.
struct ServersView: View {
    @EnvironmentObject var controller: TunnelController

    @State private var editing: ServerProfile?
    @State private var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabHeader(title: "Servers") {
                Button(action: addServer) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("Add Server").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.accent))
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(controller.config.servers) { server in
                        serverTile(server)
                    }
                    addTile
                    footer
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(DS.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: isNew)
                .environmentObject(controller)
        }
    }

    private func serverTile(_ server: ServerProfile) -> some View {
        let isActive = server.id == (controller.config.selectedServerID
                                     ?? controller.config.servers.first?.id)
        return Tile(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            HStack(spacing: 12) {
                RadioDot(isSelected: isActive, size: 16)
                    .onTapGesture { controller.selectServer(server.id) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isActive ? DS.primaryText : DS.secondaryText)
                        .lineLimit(1)
                    Text("\(server.sshDestination):\(String(server.port)) · \(server.authMethod.label)")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    if isActive, controller.isConnected {
                        Text(latencyLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(controller.latencyColor)
                    }
                    Button { edit(server) } label: {
                        Image(systemName: "pencil").font(.system(size: 15))
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.secondaryText)
                    Button { controller.deleteServer(server.id) } label: {
                        Image(systemName: "trash").font(.system(size: 15))
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.secondaryText)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .strokeBorder(isActive ? DS.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { controller.selectServer(server.id) }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var latencyLabel: String {
        if let ms = controller.latencyMS {
            return String(localized: "● active · \(ms) ms")
        }
        return String(localized: "● active")
    }

    private var addTile: some View {
        Button(action: addServer) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Add an SSH server to connect through")
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(DS.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(DS.meterOff))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        Text("Secrets are stored in the macOS Keychain — never in config.json. Click a card to make it active; the pencil opens the editor sheet.")
            .font(.system(size: 11))
            .foregroundStyle(DS.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    private func addServer() {
        isNew = true
        editing = ServerProfile()
    }

    private func edit(_ server: ServerProfile) {
        isNew = false
        editing = server
    }
}

/// Add/edit form for one server profile, including auth + secret entry.
struct ServerEditor: View {
    @EnvironmentObject var controller: TunnelController
    @Environment(\.dismiss) private var dismiss

    @State var server: ServerProfile
    let isNew: Bool

    /// Secret entered this session. nil means "unchanged"; the placeholder shows
    /// whether a secret already exists.
    @State private var secret: String = ""
    @State private var secretTouched = false

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Server" : "Edit Server")
                .font(.headline).padding(.top, 14)
            Form {
                Section {
                    TextField("Name (optional)", text: $server.name, prompt: Text("My Server"))
                    TextField("Host", text: $server.host, prompt: Text("example.com"))
                    TextField("Username", text: $server.username, prompt: Text("root"))
                    LabeledContent("Port") {
                        TextField("", value: $server.port, format: .number.grouping(.never))
                            .frame(width: 70).multilineTextAlignment(.trailing)
                    }
                }
                Section("Authentication") {
                    Picker("Method", selection: $server.authMethod) {
                        ForEach(SSHAuthMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    if server.authMethod == .keyFile {
                        LabeledContent("Key File") {
                            HStack {
                                Text(server.keyPath.isEmpty ? "None" : server.keyPath)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Choose…", action: chooseKey)
                            }
                        }
                        secretField(label: "Passphrase", prompt: "if the key is encrypted")
                    }
                    if server.authMethod == .password {
                        secretField(label: "Password", prompt: "SSH password")
                    }
                }
                if let err = server.validationError {
                    Section { Text(err).font(.caption).foregroundStyle(.orange) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!server.isValid)
            }
            .padding(12)
        }
        .frame(width: 440, height: 460)
    }

    @ViewBuilder
    private func secretField(label: String, prompt: String) -> some View {
        SecureField(label,
                    text: $secret,
                    prompt: Text(server.hasStoredSecret && !secretTouched ? "•••••••• (stored)" : prompt))
            .onChange(of: secret) { _, _ in secretTouched = true }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true    // ~/.ssh is hidden
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            server.keyPath = url.path
        }
    }

    private func save() {
        // Only write a secret if the user typed one this session. Otherwise pass
        // nil to keep the existing Keychain entry (or none) untouched.
        let secretToSave: String? = secretTouched ? secret : nil
        controller.saveServer(server, secret: secretToSave)
        dismiss()
    }
}
