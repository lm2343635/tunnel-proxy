import Foundation

/// Reads and writes the HTTP-proxy env keys in Claude Code's settings file
/// (`~/.claude/settings.json`). This is a *separate* file from the app's own
/// config — the Tools tab uses it to point Claude Code at this app's HTTP proxy.
///
/// The file is parsed with `JSONSerialization` (not `Codable`) so any unknown
/// top-level keys and other `env` entries round-trip untouched: we only ever add
/// or remove our own six proxy keys. A malformed existing file is reported as an
/// error rather than overwritten, so user settings are never silently destroyed.
enum ClaudeCodeConfig {

    /// `~/.claude/settings.json`. The app is not sandboxed, so the real home
    /// directory is reachable.
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// The four proxy-URL keys, followed by the two no-proxy keys.
    static let urlProxyKeys = ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"]
    static let noProxyKeys = ["no_proxy", "NO_PROXY"]
    static var proxyKeys: [String] { urlProxyKeys + noProxyKeys }

    static let noProxyValue = "localhost,127.0.0.1"

    static func proxyURL(port: Int) -> String { "http://127.0.0.1:\(port)" }

    enum ConfigError: LocalizedError {
        case malformed

        var errorDescription: String? {
            switch self {
            case .malformed:
                return String(localized: "~/.claude/settings.json is not valid JSON. Fix or remove it, then try again.")
            }
        }
    }

    /// Load `settings.json` as a mutable dictionary. Returns an empty dictionary
    /// when the file is missing or empty; throws `ConfigError.malformed` when the
    /// file exists but isn't a JSON object.
    private static func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else {
            return [:]
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw ConfigError.malformed
        }
        return dict
    }

    /// True when all six proxy keys are present in `env` and the four URL keys
    /// point at *this* app's proxy on `port`. A stale port reads as disabled.
    static func isProxyEnabled(port: Int) -> Bool {
        guard let settings = try? loadSettings(),
              let env = settings["env"] as? [String: Any] else {
            return false
        }
        let expected = proxyURL(port: port)
        for key in urlProxyKeys where (env[key] as? String) != expected { return false }
        for key in noProxyKeys where (env[key] as? String) != noProxyValue { return false }
        return true
    }

    /// Merge the six proxy keys into `env` (when `enabled`), or remove only those
    /// six keys (when disabled). All other settings and env entries are preserved.
    static func setProxyEnabled(_ enabled: Bool, port: Int) throws {
        var settings = try loadSettings()
        var env = settings["env"] as? [String: Any] ?? [:]

        if enabled {
            let url = proxyURL(port: port)
            for key in urlProxyKeys { env[key] = url }
            for key in noProxyKeys { env[key] = noProxyValue }
        } else {
            for key in proxyKeys { env.removeValue(forKey: key) }
        }
        settings["env"] = env

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
