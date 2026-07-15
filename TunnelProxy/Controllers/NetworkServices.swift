import Foundation

/// Enumerates macOS network services (as `networksetup` names them) so the UI
/// can offer a dropdown instead of a free-text field.
enum NetworkServices {

    /// All enabled network services, in priority order (highest first).
    /// Disabled services (marked with `*`) are excluded.
    static func list() -> [String] {
        let result = ProcessRunner.run(
            "/usr/sbin/networksetup", ["-listallnetworkservices"], timeout: 10)
        guard result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // First line is an explanatory header; `*` marks disabled services.
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
    }

    /// The network service carrying the default route (i.e. the interface the
    /// user's traffic actually goes out through), or the first listed service as
    /// a fallback. This is the sensible default for the system SOCKS proxy.
    static func primary() -> String? {
        let services = list()
        guard !services.isEmpty else { return nil }

        // Find the BSD device backing the default route (e.g. "en0").
        if let device = defaultRouteDevice(),
           let match = serviceForDevice(device, among: services) {
            return match
        }
        // Fallback: highest-priority enabled service.
        return services.first
    }

    // MARK: - Private

    /// Parse `route get default` for the interface device name.
    private static func defaultRouteDevice() -> String? {
        let result = ProcessRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 8)
        guard result.succeeded else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Map a BSD device (en0) back to a network service name via the service order.
    private static func serviceForDevice(_ device: String, among services: [String]) -> String? {
        let result = ProcessRunner.run(
            "/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 10)
        guard result.succeeded else { return nil }
        // Blocks look like:
        //   (4) Wi-Fi
        //   (Hardware Port: Wi-Fi, Device: en0)
        let text = result.stdout
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() where line.contains("Device: \(device)") {
            // The service name is on the preceding "(n) Name" line.
            if i > 0, let name = parseServiceName(lines[i - 1]),
               services.contains(name) {
                return name
            }
        }
        return nil
    }

    /// Extract "Wi-Fi" from "(4) Wi-Fi".
    private static func parseServiceName(_ line: String) -> String? {
        guard let close = line.firstIndex(of: ")") else { return nil }
        let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
