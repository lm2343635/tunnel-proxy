import Foundation
import NetworkExtension
import Security

enum RoutingAttribution {
    private static let claudeCode = RoutingAppIdentity(team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code")

    static func application(for metadata: NEFlowMetaData, in apps: [RoutingApp]) -> RoutingApp? {
        let identifier = metadata.sourceAppSigningIdentifier
        let candidates = apps.filter { app in
            app.identity.identifier == identifier || app.bundledHelpers.contains { $0.identifier == identifier }
                || (app.identity.isClaudeDesktop && identifier == claudeCode.identifier)
        }
        guard !candidates.isEmpty,
              let token = metadata.sourceAppAuditToken, token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let pid = audit_token_to_pid(token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) })
        guard let process = RoutingProcess.inspect(pid)?.identity else { return nil }
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code, process.isCurrent else { return nil }

        let matches = candidates.filter { app in
            if identifier == app.identity.identifier, verifies(code, as: app.identity) { return true }
            if app.identity.isClaudeDesktop, identifier == claudeCode.identifier {
                return verifies(code, as: claudeCode) && hasVerifiedAncestor(process, matching: app.identity)
            }
            guard let url = process.executable, url.path.hasPrefix(app.directory.resolvingSymlinksInPath().path + "/")
            else { return false }
            return app.bundledHelpers.contains { $0.identifier == identifier && verifies(code, as: $0) }
        }
        return matches.count == 1 && process.isCurrent ? matches.first : nil
    }

    private static func verifies(_ code: SecCode, as identity: RoutingAppIdentity) -> Bool {
        guard let requirement = RoutingSigning.requirement(identity) else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func hasVerifiedAncestor(_ source: RoutingProcess, matching identity: RoutingAppIdentity) -> Bool {
        var child = source
        for _ in 0..<24 {
            guard let snapshot = RoutingProcess.inspect(child.pid), snapshot.identity == child,
                  let parent = RoutingProcess.inspect(snapshot.parent)?.identity else { return false }
            if let requirement = RoutingSigning.requirement(identity) {
                var code: SecCode?
                let attributes = [kSecGuestAttributePid as String: parent.pid] as CFDictionary
                if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
                   let code, SecCodeCheckValidity(code, [], requirement) == errSecSuccess {
                    return parent.isCurrent && source.isCurrent
                        && RoutingProcess.inspect(child.pid)?.parent == parent.pid
                }
            }
            child = parent
        }
        return false
    }
}
