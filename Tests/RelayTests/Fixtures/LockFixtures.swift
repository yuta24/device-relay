import Foundation

/// `body`'s result, trying it again every 10 ms while it throws, for up to `limit`; then its last error.
///
/// For what reads a lock this process just released, or released by closing the descriptor that checked it:
/// a process that another test starts at that moment holds every descriptor of this process while it starts
/// (close-on-exec ones too, until its exec, a few ms and longer on a loaded machine), and with it the `flock`.
/// A lock that is never released still fails here, once `limit` has passed.
func onceReleased<T>(within limit: TimeInterval = 5, _ body: () throws -> T) throws -> T {
  let deadline = Date().addingTimeInterval(limit)
  while true {
    do {
      return try body()
    } catch where Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
  }
}

/// Whether `check` comes true within `limit`, trying it again every 10 ms like `onceReleased`.
func becomesTrue(within limit: TimeInterval = 5, _ check: () -> Bool) -> Bool {
  do {
    try onceReleased(within: limit) { () throws -> Void in
      guard check() else { throw StillHeld() }
    }
    return true
  } catch {
    return false
  }
}

private struct StillHeld: Error {}
