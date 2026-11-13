import Foundation

/// A value protected by an `NSLock` (macOS 13 has no `Synchronization.Mutex`).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// Monotonic-ish wall clock in milliseconds (`Date.now()`).
@inline(__always) func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/// `setTimeout`-style sleep that ignores cancellation errors.
@inline(__always) func sleepMs(_ ms: Double) async {
    if ms <= 0 {
        await Task.yield()
        return
    }
    try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
}
