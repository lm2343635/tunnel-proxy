import Foundation

/// How a server authenticates the SSH connection.
enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable {
    case agent          // default keys / ssh-agent (no -i, no secret)
    case keyFile        // private key at `keyPath` (+ optional passphrase in Keychain)
    case password       // password auth (secret in Keychain)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agent: return String(localized: "Default keys / agent")
        case .keyFile: return String(localized: "Private key file")
        case .password: return String(localized: "Password")
        }
    }
}

/// A named SSH server the tunnel can connect through. Non-secret metadata only —
/// passwords and key passphrases live in the macOS Keychain, keyed by `id`.
struct ServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: SSHAuthMethod = .agent
    /// Path to the private key, for `.keyFile` auth.
    var keyPath: String = ""
    /// True when a secret (password or passphrase) is stored in the Keychain.
    /// Persisted so the UI can show "•••• set" without touching the Keychain.
    var hasStoredSecret: Bool = false

    /// `user@host` for display / ssh destination when a username is set.
    var sshDestination: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    /// A human label falling back to the destination when unnamed.
    var displayName: String {
        !name.isEmpty ? name : (host.isEmpty ? String(localized: "New Server") : sshDestination)
    }

    /// Validation reason, or nil when usable.
    var validationError: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Host is required")
        }
        guard (1...65535).contains(port) else { return String(localized: "Port must be 1–65535") }
        if authMethod == .keyFile && keyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Key file path is required")
        }
        return nil
    }

    var isValid: Bool { validationError == nil }
}
