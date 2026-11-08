import Foundation

/// A value and the lock that guards it, for state several threads share (a signal handler and the waiting
/// loop, a pipe's handler and the thread that reads the result). `Value` is `Sendable`, so nothing reached
/// through the lock can be used unguarded by two threads afterwards.
///
/// Sendable by hand: every read and write of `stored` is between `lock.lock()` and `lock.unlock()`, which
/// the compiler cannot see. CLI only, so the runner target does not compile this file.
final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    withLock { $0 }
  }

  func set(_ value: Value) {
    withLock { $0 = value }
  }

  /// Don't wait for another thread inside `body`: it holds the lock until it returns.
  @discardableResult
  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&stored)
  }
}
