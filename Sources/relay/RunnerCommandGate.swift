import Foundation

/// Admits one command at a time and tells how long the running one has taken.
///
/// The runner enters it on the HTTP queue, leaves it on the main queue, and reads it for `/ping` on the
/// HTTP queue. Like `RunnerAuth.swift`, this file is compiled into both the `relay` CLI and the runner
/// target so the SwiftPM unit tests cover it.
final class CommandGate: @unchecked Sendable {
    private let lock = NSLock()
    /// Monotonic nanoseconds; injectable for tests.
    private let now: @Sendable () -> UInt64
    /// When the running command was admitted, or nil while idle.
    private var enteredAt: UInt64?

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enteredAt == nil else { return false }
        enteredAt = now()
        return true
    }

    func leave() {
        lock.lock()
        enteredAt = nil
        lock.unlock()
    }

    /// Milliseconds since the running command was admitted, or nil while idle.
    func busyForMs() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let enteredAt else { return nil }
        let current = now()
        return Int((current > enteredAt ? current - enteredAt : 0) / 1_000_000)
    }

    /// The `/ping` body: `{"ok":true,"busy":<bool>,"busyForMs":<ms or null>}`.
    func pingBody() -> [String: Any] {
        let busyForMs = busyForMs()
        return ["ok": true, "busy": busyForMs != nil, "busyForMs": busyForMs.map { $0 as Any } ?? NSNull()]
    }
}
