import Foundation
import Security

enum RoutingSigning {
    static func identity(of url: URL) -> RoutingAppIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return identity(of: code)
    }

    static func identity(of code: SecStaticCode) -> RoutingAppIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let team = (fields[kSecCodeInfoTeamIdentifier as String] as? String) ?? "apple"
        let identity = RoutingAppIdentity(team: team, identifier: identifier)
        guard let requirement = requirement(identity),
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return identity
    }

    static func requirement(_ identity: RoutingAppIdentity) -> SecRequirement? {
        let legal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !identity.team.isEmpty, !identity.identifier.isEmpty,
              identity.team.unicodeScalars.allSatisfy(legal.contains),
              identity.identifier.unicodeScalars.allSatisfy(legal.contains) else { return nil }
        let expression: String
        if identity.team == "apple" {
            expression = "anchor apple and identifier \"\(identity.identifier)\""
        } else {
            expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(identity.team)\" and identifier \"\(identity.identifier)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
