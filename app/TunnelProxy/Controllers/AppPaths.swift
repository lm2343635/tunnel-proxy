import Foundation

/// Central place for all on-disk locations. Everything the app writes lives under
/// `~/Library/Application Support/TunnelProxy/`, so the app is self-contained and
/// needs no external scripts directory.
enum AppPaths {

    /// `~/Library/Application Support/TunnelProxy`
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TunnelProxy", isDirectory: true)
    }

    /// Persisted configuration (JSON).
    static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    /// Tunnel log file.
    static var logURL: URL {
        supportDirectory.appendingPathComponent("tunnel.log")
    }

    /// Generated Privoxy config, written fresh on each connect.
    static var privoxyConfigURL: URL {
        supportDirectory.appendingPathComponent("privoxy.conf")
    }

    /// The bundled Privoxy executable inside the app's Resources.
    static var bundledPrivoxy: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("privoxy/privoxy")
    }

    /// The bundled SSH_ASKPASS helper (feeds ssh passwords/passphrases).
    static var askpassHelper: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helpers/askpass.sh")
    }

    /// Ensure the support directory exists. Safe to call repeatedly.
    @discardableResult
    static func ensureSupportDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("Failed to create support directory: \(error.localizedDescription)")
            return false
        }
    }
}
