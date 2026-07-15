import Foundation

/// Result of running a shell command.
struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
    /// Combined output, trimmed — handy for parsing script messages.
    var output: String {
        (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thin wrapper around `Process` for invoking the existing `proxy` script and
/// other CLI tools. All calls are synchronous and meant to be run off the main
/// thread (callers use `Task.detached`).
enum ProcessRunner {

    /// Run an executable with arguments and capture its output.
    /// - Parameter env: extra environment variables merged onto the current env.
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval = 60
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd = currentDirectory {
            process.currentDirectoryURL = cwd
        }
        if !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read pipes on background queues to avoid deadlock on large output.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "ProcessRunner.io", attributes: .concurrent)

        group.enter()
        ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "",
                                 stderr: "Failed to launch \(launchPath): \(error.localizedDescription)")
        }

        // Enforce a timeout so a hung ssh/curl never blocks the UI forever.
        let deadline = DispatchTime.now() + timeout
        let waiter = DispatchQueue(label: "ProcessRunner.wait")
        var timedOut = false
        waiter.async {
            if group.wait(timeout: deadline) == .timedOut {
                timedOut = true
                process.terminate()
            }
        }

        process.waitUntilExit()
        group.wait()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if timedOut {
            return CommandResult(exitCode: -2, stdout: stdout,
                                 stderr: stderr + "\n(timed out after \(Int(timeout))s)")
        }
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Locate an executable on PATH (plus common Homebrew locations), returning
    /// its absolute path if found. Used for the dependency check.
    static func which(_ tool: String) -> String? {
        let result = run("/usr/bin/env", ["which", tool], timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded, !path.isEmpty { return path }
        // Fallback: probe common Homebrew paths (GUI apps get a minimal PATH).
        for candidate in ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "/usr/bin/\(tool)"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
