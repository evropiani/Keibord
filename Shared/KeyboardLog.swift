import Foundation
import KeibordCore

/// A short log of what the keyboard did (opening, sizes, memory, stalls) in the shared folder, shown in
/// the app (Data → Keyboard Log): a keyboard that opens blank leaves no other trace a user can send.
/// It never contains typed text, and nothing leaves the iPhone.
final class KeyboardLog {
    static let shared = KeyboardLog()

    /// The file is trimmed to its newer half beyond this size.
    private static let maxBytes: UInt64 = 64 * 1024

    private let queue = DispatchQueue(label: "com.keibord.keyboard-log", qos: .utility)
    private let url = KeibordStore.shared.url(.keyboardLog)
    private let pid = ProcessInfo.processInfo.processIdentifier
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Appends a line in the background. Several keyboard processes may write at the same time: lines
    /// are appended, never rewritten, so none of them overwrites another's.
    func add(_ message: String) {
        let date = Date()
        queue.async { [self] in
            append("\(formatter.string(from: date)) [\(pid)] \(message)\n")
        }
    }

    /// Waits for the lines added so far to be written (tests).
    func flush() { queue.sync {} }

    func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url, options: .atomic) // first line: creates the file
            return
        }
        var size: UInt64 = 0
        do {
            size = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
        try? handle.close()
        if size > Self.maxBytes { trim() }
    }

    private func trim() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
