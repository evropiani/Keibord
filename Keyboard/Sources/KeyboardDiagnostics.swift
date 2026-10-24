import Foundation

/// Notices when the keyboard's main thread stops responding (the keyboard then shows no keys) and
/// writes it to the `KeyboardLog`. Runs only while the keyboard is open: a suspended keyboard's
/// silence is not a stall. One per process.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    /// Silence after which the main thread counts as stalled.
    private static let stallAfter: TimeInterval = 1.5
    private static let interval: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.keibord.keyboard.watchdog", qos: .utility)
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var lastAnswer = Date()
    private var stalledSince: Date?
    private var owners: Set<ObjectIdentifier> = []
    private var lastTick: Date?

    /// Watches while at least one keyboard controller is on screen (an old controller can go away
    /// after the next one appeared).
    func start(for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        queue.async { [self] in
            owners.insert(id)
            guard timer == nil else { return }
            lastAnswer = Date()
            lastTick = nil
            stalledSince = nil
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop(for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        queue.async { [self] in
            owners.remove(id)
            guard owners.isEmpty, let t = timer else { return }
            t.cancel()
            timer = nil
            if let since = stalledSince {
                KeyboardLog.shared.add(String(format: "main thread was still stalled when the keyboard closed (%.1f s)", Date().timeIntervalSince(since)))
                stalledSince = nil
            }
        }
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        if let previous = lastTick, now.timeIntervalSince(previous) > Self.interval * 6 {
            // The timer itself did not run: iOS had suspended the whole keyboard, which is no stall.
            lastAnswer = now
            stalledSince = nil
        }
        let silence = now.timeIntervalSince(lastAnswer)
        if stalledSince == nil, silence > Self.stallAfter {
            stalledSince = lastAnswer
            KeyboardLog.shared.add(String(format: "main thread not responding for %.1f s", silence) + " (memory \(KeyboardDiagnostics.memoryDescription))")
        } else if let since = stalledSince, silence < Self.interval * 1.5 {
            KeyboardLog.shared.add(String(format: "main thread responding again after %.1f s", lastAnswer.timeIntervalSince(since)))
            stalledSince = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            self.queue.async { self.lastAnswer = now }
        }
    }
}

enum KeyboardDiagnostics {
    /// The keyboard's memory footprint (what iOS compares with the extension's limit), or nil.
    static var memoryFootprintMB: Double? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
        #else
        return nil
        #endif
    }

    static var memoryDescription: String {
        memoryFootprintMB.map { String(format: "%.0f MB", $0) } ?? "unknown"
    }
}
