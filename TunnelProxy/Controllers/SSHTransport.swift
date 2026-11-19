import Darwin
import Foundation

/// A private counter file for one SSH process, shared with its ProxyCommand.
/// Each direction has one writer and counts encrypted SSH stream bytes.
final class SSHTransportCounters: Sendable {
    let path: String
    private let descriptor: Int32

    init?() {
        var template = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelproxy-transport.XXXXXX").path.utf8CString
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { return nil }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, ftruncate(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        self.descriptor = fd
        self.path = path
    }

    deinit {
        close(descriptor)
        unlink(path)
    }

    func read() -> (down: UInt64, up: UInt64)? {
        var values = (down: UInt64(0), up: UInt64(0))
        guard pread(descriptor, &values, 16, 0) == 16 else { return nil }
        return values
    }
}

enum SSHTransport {
    static let argument = "--ssh-transport"

    static func proxyCommand(executable: URL, counters: SSHTransportCounters, command: String) -> String {
        let prefix = [executable.path, argument, counters.path].map {
            SSHRoutePlanner.shellQuote($0.replacingOccurrences(of: "%", with: "%%"))
        }
        return (prefix + [command]).joined(separator: " ")
    }

    /// Run before AppKit starts. Relay OpenSSH's stdio to the same nc command
    /// used by route discovery, and count bytes successfully forwarded.
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 3, arguments[1] == "/usr/bin/nc" else { return 1 }
        let counters = open(arguments[0], O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard counters >= 0 else { return 1 }

        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: arguments[1])
        child.arguments = Array(arguments.dropFirst(2))
        child.standardInput = input
        child.standardOutput = output

        do { try child.run() } catch {
            close(counters)
            return 1
        }

        // OpenSSH sends SIGTERM to its ProxyCommand on disconnect. Install
        // these dispositions after launching nc so it retains its defaults.
        signal(SIGTERM, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler {
            if child.isRunning { child.terminate() }
        }
        termination.activate()

        DispatchQueue.global(qos: .userInitiated).async {
            copy(from: STDIN_FILENO, to: input.fileHandleForWriting.fileDescriptor,
                 counters: counters, offset: 8)
            try? input.fileHandleForWriting.close()
        }
        copy(from: output.fileHandleForReading.fileDescriptor, to: STDOUT_FILENO,
             counters: counters, offset: 0)

        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        termination.cancel()
        // The uploader may still be waiting on SSH stdin. The helper process
        // exits immediately after this returns, closing its remaining pipes.
        return child.terminationStatus
    }

    private static func copy(from source: Int32, to destination: Int32, counters: Int32, offset: off_t) {
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        buffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while true {
                let count = Darwin.read(source, base, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                var written = 0
                while written < count {
                    let size = Darwin.write(destination, base + written, count - written)
                    if size < 0, errno == EINTR { continue }
                    guard size > 0 else { return }
                    written += size
                    total += UInt64(size)
                    while pwrite(counters, &total, MemoryLayout<UInt64>.size, offset) < 0, errno == EINTR {}
                }
            }
        }
    }
}
