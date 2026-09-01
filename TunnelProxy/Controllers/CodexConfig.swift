import Foundation

/// Points the Codex CLI at this app's HTTP proxy.
///
/// Unlike Claude Code (see `ClaudeCodeConfig`), Codex has **no** config key for its
/// own outbound proxy — its HTTP client only reads the standard proxy *environment
/// variables*. So routing Codex takes two edits:
///
/// 1. `~/.codex/config.toml` → `[shell_environment_policy.set]`, the environment
///    Codex hands to the shell commands it runs (`curl`, `git`, `npm`, …).
/// 2. A marker-delimited `export` block in the user's shell startup file, which is
///    what Codex itself inherits when launched from a terminal.
///
/// Both edits are surgical: every other table, key, and comment in the TOML round-trips
/// untouched, and the profile block is found and removed by its markers. Files we can't
/// parse confidently are reported as errors rather than rewritten, so user config is
/// never silently destroyed.
enum CodexConfig {

    /// `~/.codex/config.toml`. The app is not sandboxed, so the real home directory
    /// is reachable.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    /// The startup file an interactive shell reads. zsh is the macOS default; bash
    /// users get `~/.bash_profile`.
    static var shellProfileURL: URL {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let file = (shell as NSString).lastPathComponent == "bash" ? ".bash_profile" : ".zshrc"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(file)
    }

    /// The same standard proxy variables `ClaudeCodeConfig` writes: four proxy-URL
    /// keys followed by the two no-proxy keys.
    static let urlProxyKeys = ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"]
    static let noProxyKeys = ["no_proxy", "NO_PROXY"]
    static var proxyKeys: [String] { urlProxyKeys + noProxyKeys }

    static let noProxyValue = "localhost,127.0.0.1"

    static func proxyURL(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// The TOML table holding the env Codex passes to the commands it runs.
    private static let envTable = "shell_environment_policy.set"

    static let beginMarker = "# >>> TunnelProxy proxy >>>"
    static let endMarker = "# <<< TunnelProxy proxy <<<"

    enum ConfigError: LocalizedError {
        case malformedTOML
        case malformedProfile(String)

        var errorDescription: String? {
            switch self {
            case .malformedTOML:
                return String(localized: "~/.codex/config.toml has an unterminated multi-line string. Fix it, then try again.")
            case .malformedProfile(let name):
                return String(localized: "The TunnelProxy block in \(name) is damaged — its start and end markers don't match. Fix or remove it, then try again.")
            }
        }
    }

    // MARK: - Public API

    /// True when both halves are in place and point at *this* app's proxy on `port`.
    /// A stale port, a half-applied state, or an unreadable file all read as disabled.
    static func isProxyEnabled(port: Int) -> Bool {
        ((try? isTOMLProxyEnabled(port: port)) ?? false)
            && ((try? isProfileProxyEnabled(port: port)) ?? false)
    }

    /// Add (or remove) the proxy keys in both files. Both are parsed up front so that a
    /// file we can't edit safely fails the whole toggle instead of leaving the other one
    /// half-applied.
    static func setProxyEnabled(_ enabled: Bool, port: Int) throws {
        _ = try envTableSpan(loadLines(configURL))
        _ = try profileBlockRange(loadLines(shellProfileURL))

        try setTOMLProxy(enabled, port: port)
        try setProfileProxy(enabled, port: port)
    }

    // MARK: - config.toml

    private static func isTOMLProxyEnabled(port: Int) throws -> Bool {
        let lines = loadLines(configURL)
        guard let span = try envTableSpan(lines) else { return false }
        var present: [String: String] = [:]
        for line in lines[span.body] {
            if let pair = keyValue(line) { present[pair.key] = pair.value }
        }
        return expectedValues(port: port).allSatisfy { present[$0.key] == $0.value }
    }

    private static func setTOMLProxy(_ enabled: Bool, port: Int) throws {
        var lines = loadLines(configURL)
        let span = try envTableSpan(lines)

        if let span {
            // Drop our keys wherever they sit in the table, then re-add them at its end.
            var body = Array(lines[span.body])
            body.removeAll { keyValue($0).map { proxyKeys.contains($0.key) } ?? false }

            if enabled {
                let insertAt = body.lastIndex { !isBlank($0) }.map { $0 + 1 } ?? 0
                body.insert(contentsOf: tomlLines(port: port), at: insertAt)
                lines.replaceSubrange(span.body, with: body)
            } else if body.contains(where: { !isBlank($0) }) {
                lines.replaceSubrange(span.body, with: body)
            } else {
                // Nothing is left under the header — drop the empty table too. When it
                // ends the file, take the blank line above it as well; otherwise that
                // blank line stays on as the separator for whatever follows.
                let endsFile = span.body.upperBound == lines.count
                var start = span.header
                if endsFile, start > 0, isBlank(lines[start - 1]) { start -= 1 }
                lines.replaceSubrange(start..<span.body.upperBound,
                                      with: body.isEmpty || endsFile ? [] : [""])
            }
        } else if enabled {
            if let last = lines.last, !isBlank(last) { lines.append("") }
            lines.append("[\(envTable)]")
            lines.append(contentsOf: tomlLines(port: port))
        } else {
            return  // Table absent and we're disabling — nothing to do.
        }

        try write(lines, to: configURL, newFileMode: 0o600)
    }

    private static func tomlLines(port: Int) -> [String] {
        expectedKeyOrder(port: port).map { "\($0.key) = \"\($0.value)\"" }
    }

    /// Index of the `[shell_environment_policy.set]` header and the range of body lines
    /// after it, up to the next table header or EOF. `nil` when the table is absent.
    private static func envTableSpan(_ lines: [String]) throws -> (header: Int, body: Range<Int>)? {
        var header: Int?
        var openDelimiter: String?  // Set while inside a `"""` / `'''` string.

        for (index, line) in lines.enumerated() {
            if let delimiter = openDelimiter {
                if line.contains(delimiter) { openDelimiter = nil }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = tableName(trimmed) {
                if name == envTable {
                    header = index
                } else if let start = header {
                    return (start, (start + 1)..<index)
                }
            } else {
                openDelimiter = openedMultilineString(trimmed)
            }
        }
        if openDelimiter != nil { throw ConfigError.malformedTOML }
        return header.map { ($0, ($0 + 1)..<lines.count) }
    }

    /// The dotted name of a `[table]` / `[[array]]` header line, quotes stripped.
    /// `nil` for anything that isn't a header line on its own.
    private static func tableName(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("[") else { return nil }
        var body = trimmed
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]) }
        body = body.trimmingCharacters(in: .whitespaces)
        guard body.hasSuffix("]") else { return nil }

        var inner = body.dropFirst().dropLast()
        if inner.hasPrefix("["), inner.hasSuffix("]") { inner = inner.dropFirst().dropLast() }
        let name = inner
            .split(separator: ".")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: ".")
        return name.isEmpty ? nil : name
    }

    /// The multi-line-string delimiter a line leaves open, if any — an odd number of
    /// `"""` or `'''` on the line means the string continues onto the next one.
    private static func openedMultilineString(_ line: String) -> String? {
        ["\"\"\"", "'''"].first { line.components(separatedBy: $0).count % 2 == 0 }
    }

    /// `key = "value"` split into its bare key and unquoted value.
    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["),
              let equals = trimmed.firstIndex(of: "=") else { return nil }

        let key = unquote(trimmed[..<equals].trimmingCharacters(in: .whitespaces))
        guard !key.isEmpty else { return nil }

        // A quoted value ends at its closing quote; a bare one at a trailing comment.
        let rest = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if let quote = rest.first, quote == "\"" || quote == "'" {
            let afterQuote = rest.dropFirst()
            guard let close = afterQuote.firstIndex(of: quote) else { return (key, "") }
            return (key, String(afterQuote[..<close]))
        }
        return (key, rest.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ text: String) -> String {
        guard let quote = text.first, quote == "\"" || quote == "'",
              text.count >= 2, text.last == quote else { return text }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Shell profile

    private static func isProfileProxyEnabled(port: Int) throws -> Bool {
        let lines = loadLines(shellProfileURL)
        guard let range = try profileBlockRange(lines) else { return false }
        let present = Set(lines[range].map { $0.trimmingCharacters(in: .whitespaces) })
        return Set(exportLines(port: port)).isSubset(of: present)
    }

    private static func setProfileProxy(_ enabled: Bool, port: Int) throws {
        var lines = loadLines(shellProfileURL)
        let range = try profileBlockRange(lines)

        if enabled {
            let block = [beginMarker] + exportLines(port: port) + [endMarker]
            if let range {
                lines.replaceSubrange(range, with: block)
            } else {
                if let last = lines.last, !isBlank(last) { lines.append("") }
                lines.append(contentsOf: block)
            }
        } else {
            guard let range else { return }
            lines.removeSubrange(range)
            // Drop the blank line we added above the block when it sat at the end.
            if range.lowerBound == lines.count, let last = lines.last, isBlank(last) {
                lines.removeLast()
            }
        }

        try write(lines, to: shellProfileURL, newFileMode: 0o644)
    }

    /// The line range of our marked block, end marker included. Throws when the markers
    /// are unbalanced — better to ask the user to look than to guess where the block ends.
    private static func profileBlockRange(_ lines: [String]) throws -> Range<Int>? {
        let begins = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == beginMarker }
        let ends = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == endMarker }
        if begins.isEmpty, ends.isEmpty { return nil }
        guard begins.count == 1, ends.count == 1, let begin = begins.first, let end = ends.first,
              begin < end else {
            throw ConfigError.malformedProfile(shellProfileURL.lastPathComponent)
        }
        return begin..<(end + 1)
    }

    private static func exportLines(port: Int) -> [String] {
        expectedKeyOrder(port: port).map { "export \($0.key)=\"\($0.value)\"" }
    }

    // MARK: - Shared helpers

    private static func expectedKeyOrder(port: Int) -> [(key: String, value: String)] {
        urlProxyKeys.map { ($0, proxyURL(port: port)) } + noProxyKeys.map { ($0, noProxyValue) }
    }

    private static func expectedValues(port: Int) -> [String: String] {
        Dictionary(uniqueKeysWithValues: expectedKeyOrder(port: port).map { ($0.key, $0.value) })
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Split a file into lines, dropping the trailing newline's empty component — `write`
    /// puts it back. A missing or empty file reads as no lines.
    private static func loadLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Write atomically, keeping an existing file's permissions (`config.toml` is 0600)
    /// and creating new ones with `newFileMode`.
    private static func write(_ lines: [String], to url: URL, newFileMode: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: existing ?? NSNumber(value: newFileMode)],
                              ofItemAtPath: url.path)
    }
}
