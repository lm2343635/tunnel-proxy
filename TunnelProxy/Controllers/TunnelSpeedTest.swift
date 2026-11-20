import Combine
import Foundation
import Darwin
import Security

enum SpeedTestDirection: String {
    case download, upload

    var label: String {
        switch self {
        case .download: String(localized: "Download")
        case .upload: String(localized: "Upload")
        }
    }
}

struct SpeedTestSample: Identifiable {
    let id = UUID()
    let seconds: Double
    let mbps: Double
    let direction: SpeedTestDirection
}

struct SpeedTestRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let server: String
    let route: String
    let endpoint: String
    let download: Double?
    let upload: Double?
    let shortSample: Bool

    var isPartial: Bool { download == nil || upload == nil }
}

private enum SpeedTestFailure: Error {
    case connectionChanged, timeout, transfer, setup

    var message: String {
        switch self {
        case .connectionChanged: String(localized: "The SSH connection changed.")
        case .timeout: String(localized: "The speed test request timed out.")
        case .transfer: String(localized: "SSH could not complete the temporary file transfer.")
        case .setup: String(localized: "The speed test could not be started.")
        }
    }
}

private struct SpeedTestMeasurement {
    let bytes: Int
    let elapsed: Double
    var mbps: Double { Double(bytes) * 8 / elapsed / 1_000_000 }
}

private enum SpeedTestEvent {
    case progress(SpeedTestDirection, seconds: Double, rate: Double, fraction: Double)
    case uploaded(SpeedTestMeasurement, seconds: Double)
}

private enum SpeedTestTransfer {
    static let size = 8 * 1024 * 1024
    static let timeout = 30.0

    // Use one multiplexed SSH channel for the round trip. The remote shell owns
    // the temporary file for the entire operation and removes it when it exits.
    static func run(
        target: SpeedTestTarget,
        progress: (SpeedTestDirection, Double, Double) -> Void,
        uploaded: (SpeedTestMeasurement) -> Void
    ) throws -> SpeedTestMeasurement {
        var block = [UInt8](repeating: 0, count: 64 * 1024)
        let randomStatus = block.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw SpeedTestFailure.setup }

        let command = """
        umask 077
        file=$(mktemp /tmp/tunnelproxy-speed.XXXXXXXX) || exit 1
        trap 'rm -f "$file"' 0
        trap 'exit 1' HUP INT TERM
        cat > "$file" || exit 1
        test "$(wc -c < "$file")" -eq \(size) || exit 1
        printf 'OK\\n'
        cat "$file"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // If the saved socket has disappeared, the fallback transport always
        // fails. This command never opens another network connection.
        process.arguments = ["-F", "/dev/null", "-T", "-o", "BatchMode=yes",
                             "-o", "ControlMaster=no", "-o", "ControlPath=\(target.controlSocket)",
                             "-o", "ProxyCommand=/usr/bin/false", "--", "tunnelproxy-speed", command]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        let inputFD = writer.fileDescriptor
        let outputFD = reader.fileDescriptor
        guard fcntl(inputFD, F_SETFL, O_NONBLOCK) == 0,
              fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(outputFD, F_SETFL, O_NONBLOCK) == 0 else { throw SpeedTestFailure.setup }
        var writerClosed = false
        defer {
            if !writerClosed { try? writer.close() }
            try? reader.close()
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        try process.run()
        let uploadStart = now
        try transfer(.upload, fd: inputFD, since: uploadStart, target: target, progress: progress) { offset in
            block.withUnsafeBytes { bytes in
                let index = offset % bytes.count
                return Darwin.write(inputFD, bytes.baseAddress!.advanced(by: index),
                                    min(bytes.count - index, size - offset))
            }
        }
        try writer.close()
        writerClosed = true

        // The server acknowledges the size before returning any payload.
        let ack: [UInt8] = [79, 75, 10]
        for expected in ack {
            var byte: UInt8 = 0
            try wait(fd: outputFD, event: Int16(POLLIN), since: uploadStart, target: target) {
                Darwin.read(outputFD, &byte, 1)
            }
            guard byte == expected else { throw SpeedTestFailure.transfer }
        }
        let downloadStart = now
        uploaded(SpeedTestMeasurement(bytes: size, elapsed: downloadStart - uploadStart))
        try transfer(.download, fd: outputFD, since: downloadStart, target: target, progress: progress) { offset in
            block.withUnsafeMutableBytes { bytes in
                Darwin.read(outputFD, bytes.baseAddress!, min(bytes.count, size - offset))
            }
        }
        let downloadElapsed = now - downloadStart
        while process.isRunning {
            try check(since: downloadStart, target: target)
            usleep(20_000)
        }
        guard process.terminationStatus == 0 else { throw SpeedTestFailure.transfer }
        return SpeedTestMeasurement(bytes: size, elapsed: downloadElapsed)
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private static func check(since start: Double, target: SpeedTestTarget) throws {
        try Task.checkCancellation()
        guard target.peer.ssh.isCurrent else { throw SpeedTestFailure.connectionChanged }
        guard now - start < timeout else { throw SpeedTestFailure.timeout }
    }

    @discardableResult
    private static func wait(fd: Int32, event: Int16, since start: Double, target: SpeedTestTarget,
                             operation: () -> Int) throws -> Int {
        var descriptor = pollfd(fd: fd, events: event, revents: 0)
        while true {
            try check(since: start, target: target)
            let count = operation()
            if count > 0 { return count }
            guard count < 0, [EAGAIN, EINTR].contains(errno) else { throw SpeedTestFailure.transfer }
            if errno == EAGAIN, poll(&descriptor, 1, 100) < 0, errno != EINTR {
                throw SpeedTestFailure.transfer
            }
        }
    }

    private static func transfer(
        _ direction: SpeedTestDirection,
        fd: Int32,
        since start: Double,
        target: SpeedTestTarget,
        progress: (SpeedTestDirection, Double, Double) -> Void,
        operation: (Int) -> Int
    ) throws {
        let event = Int16(direction == .upload ? POLLOUT : POLLIN)
        var bytes = 0
        var lastBytes = 0
        var lastTime = start
        while bytes < size {
            let offset = bytes
            bytes += try wait(fd: fd, event: event, since: start, target: target) { operation(offset) }
            let time = now
            if time - lastTime >= 1 {
                let rate = Double(bytes - lastBytes) * 8 / (time - lastTime) / 1_000_000
                progress(direction, rate, Double(bytes) / Double(size))
                lastTime = time
                lastBytes = bytes
            }
        }
    }
}

@MainActor
final class TunnelSpeedTest: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var direction: SpeedTestDirection = .upload
    @Published private(set) var samples: [SpeedTestSample] = []
    @Published private(set) var phaseProgress = 0.0
    @Published private(set) var currentRate: Double?
    @Published private(set) var download: Double?
    @Published private(set) var upload: Double?
    @Published private(set) var target: SpeedTestTarget?
    @Published private(set) var status: String?
    @Published private(set) var history: [SpeedTestRecord] = []

    private let historyURL = AppPaths.supportDirectory.appendingPathComponent("speed-test-history.json")
    private var task: Task<Void, Never>?
    private var runID = UUID()

    init() {
        if let data = try? Data(contentsOf: historyURL) {
            history = (try? JSONDecoder().decode([SpeedTestRecord].self, from: data)) ?? []
        }
    }

    func start(engine: TunnelEngine, serverID: UUID) {
        guard task == nil else { return }
        runID = UUID()
        let id = runID
        target = nil
        status = nil
        samples = []
        download = nil
        upload = nil
        direction = .upload
        phaseProgress = 0
        currentRate = nil
        isRunning = true
        task = Task { [self] in
            defer { task = nil; isRunning = false }
            guard let target = await engine.speedTestTarget(serverID: serverID) else {
                if !Task.isCancelled { status = SpeedTestFailure.connectionChanged.message }
                return
            }
            guard !Task.isCancelled else { return }
            self.target = target
            let start = ProcessInfo.processInfo.systemUptime
            var shortSample = false
            let (events, continuation) = AsyncStream<SpeedTestEvent>.makeStream()
            let transfer = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                return try SpeedTestTransfer.run(target: target) { phase, rate, progress in
                    let seconds = ProcessInfo.processInfo.systemUptime - start
                    continuation.yield(.progress(phase, seconds: seconds, rate: rate, fraction: progress))
                } uploaded: { measurement in
                    let seconds = ProcessInfo.processInfo.systemUptime - start
                    continuation.yield(.uploaded(measurement, seconds: seconds))
                }
            }
            do {
                let measurement = try await withTaskCancellationHandler {
                    for await event in events {
                        guard runID == id else { break }
                        switch event {
                        case let .progress(phase, seconds, rate, fraction):
                            samples.append(SpeedTestSample(seconds: seconds, mbps: rate, direction: phase))
                            currentRate = rate
                            phaseProgress = fraction
                        case let .uploaded(result, seconds):
                            upload = result.mbps
                            shortSample = result.elapsed < 1
                            if !samples.contains(where: { $0.direction == .upload }) {
                                samples.append(SpeedTestSample(seconds: seconds, mbps: result.mbps, direction: .upload))
                            }
                            direction = .download
                            phaseProgress = 0
                            currentRate = nil
                        }
                    }
                    return try await transfer.value
                } onCancel: {
                    transfer.cancel()
                }
                try Task.checkCancellation()
                guard await engine.isCurrentSpeedTestTarget(target) else {
                    status = SpeedTestFailure.connectionChanged.message
                    return
                }
                guard !Task.isCancelled else { return }
                download = measurement.mbps
                if !samples.contains(where: { $0.direction == .download }) {
                    samples.append(SpeedTestSample(seconds: ProcessInfo.processInfo.systemUptime - start,
                                                   mbps: measurement.mbps, direction: .download))
                }
                shortSample = shortSample || measurement.elapsed < 1
                status = shortSample ? String(localized: "Complete · Short sample") : String(localized: "Complete")
            } catch is CancellationError {
                return
            } catch SpeedTestFailure.connectionChanged {
                status = SpeedTestFailure.connectionChanged.message
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = (error as? SpeedTestFailure)?.message ?? SpeedTestFailure.setup.message
            }
            if download != nil || upload != nil {
                let record = SpeedTestRecord(server: target.server, route: target.route, endpoint: target.endpoint,
                                             download: download, upload: upload, shortSample: shortSample)
                history.insert(record, at: 0)
                history = Array(history.prefix(200))
                do {
                    AppPaths.ensureSupportDirectory()
                    try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
                } catch {
                    status = [status, String(localized: "Speed test history could not be saved.")]
                        .compactMap { $0 }.joined(separator: "\n")
                }
            }
        }
    }

    func cancel(connectionChanged: Bool = false) {
        guard isRunning else { return }
        runID = UUID()
        status = connectionChanged ? SpeedTestFailure.connectionChanged.message : String(localized: "Speed test canceled.")
        task?.cancel()
    }
}
