import Foundation
import Security

enum ClaudeFlowSource: String {
    case main = "com.anthropic.claudefordesktop"
    case helper = "com.anthropic.claudefordesktop.helper"

    private static let team = "Q6L2SF6YDW"
    private static let mainRequirement = requirement(for: .main)
    private static let helperRequirement = requirement(for: .helper)

    func verify(auditToken: Data?) -> Bool {
        guard let auditToken else { return false }
        let requirement = self == .main ? Self.mainRequirement : Self.helperRequirement
        guard let requirement else { return false }

        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func requirement(for source: Self) -> SecRequirement? {
        let expression = """
        anchor apple generic and certificate leaf[subject.OU] = "\(team)" and identifier "\(source.rawValue)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }
}
