import SwiftUI

/// Manages the list of SSH server profiles: select active, add, edit, delete.
/// The editor is presented as a sheet.
struct ServersView: View {
    @EnvironmentObject var controller: TunnelController

    @State private var editing: ServerProfile?
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            if controller.config.servers.isEmpty {
                emptyState
            } else {
                serverList
            }
            Divider()
            toolbar
        }
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: isNew)
                .environmentObject(controller)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No servers yet").font(.headline)
            Text("Add an SSH server to connect through.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverList: some View {
        List {
            ForEach(controller.config.servers) { server in
                row(for: server)
            }
        }
        .listStyle(.inset)
    }

    private func row(for server: ServerProfile) -> some View {
        let isSelected = server.id == controller.config.selectedServerID
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .onTapGesture { controller.selectServer(server.id) }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).fontWeight(.medium)
                Text("\(server.sshDestination):\(server.port) · \(server.authMethod.label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isNew = false
                editing = server
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button(role: .destructive) {
                controller.deleteServer(server.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { controller.selectServer(server.id) }
    }

    private var toolbar: some View {
        HStack {
            Button {
                isNew = true
                editing = ServerProfile()
            } label: { Label("Add Server", systemImage: "plus") }
            Spacer()
        }
        .padding(8)
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
                        TextField("22", value: $server.port, format: .number.grouping(.never))
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
