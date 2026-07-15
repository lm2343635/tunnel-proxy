import Foundation
import Combine

/// A single log line with a derived severity for coloring.
struct LogLine: Identifiable, Equatable {
    enum Severity {
        case info, warn, error, success
    }
    let id: Int
    let text: String
    let severity: Severity
}

/// Streams `LOG_FILE` to the Logs window. Loads the existing tail on start, then
/// follows appended lines via a `DispatchSource` watching the file descriptor.
@MainActor
final class LogTailer: ObservableObject {
    @Published private(set) var lines: [LogLine] = []

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var nextID = 0
    private let maxLines = 5000
    private var url: URL?

    /// Begin tailing the file at `path`. Safe to call again to switch files.
    func start(path: String) {
        stop()
        let fileURL = URL(fileURLWithPath: path)
        url = fileURL

        // Seed with the last chunk of the file so the view isn't empty.
        loadInitialTail(fileURL)

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        fileHandle = handle
        handle.seekToEndOfFile()
        offset = handle.offsetInFile

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.delete) || event.contains(.rename) {
                // Log rotated/recreated — restart against the new inode.
                Task { @MainActor in self.restart() }
                return
            }
            self.readAppended()
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    func clear() {
        lines.removeAll()
    }

    // MARK: - Private

    private func restart() {
        if let path = url?.path { start(path: path) }
    }

    private func loadInitialTail(_ fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let tailSize = 64 * 1024
        let slice = data.count > tailSize ? data.suffix(tailSize) : data
        guard let text = String(data: slice, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            append(String(raw))
        }
    }

    private func readAppended() {
        guard let handle = fileHandle else { return }
        let newData = handle.readDataToEndOfFile()
        offset = handle.offsetInFile
        guard !newData.isEmpty, let text = String(data: newData, encoding: .utf8) else { return }
        let chunks = text.split(separator: "\n").map(String.init)
        Task { @MainActor in
            for chunk in chunks { self.append(chunk) }
        }
    }

    private func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        lines.append(LogLine(id: nextID, text: trimmed, severity: Self.classify(trimmed)))
        nextID += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private static func classify(_ text: String) -> LogLine.Severity {
        let lower = text.lowercased()
        if lower.contains("fail") || lower.contains("error") || lower.contains("curl: (") {
            return .error
        }
        if lower.contains("down") || lower.contains("reconnect") || lower.contains("retry") || lower.contains("invalid") {
            return .warn
        }
        if lower.contains("success") || lower.contains("ok") || lower.contains("started") {
            return .success
        }
        return .info
    }
}
