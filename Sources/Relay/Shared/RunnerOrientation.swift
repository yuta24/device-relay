import Foundation

/// Only hinge events need a screen-change wait. XCUI keeps its immediate acknowledgement: a screen
/// read directly after assigning the device orientation cannot describe the completed rotation.
enum RunnerOrientation {
  static let screenWait: TimeInterval = 3

  static func apply(
    hasHinge: Bool,
    setDevice: () -> Void,
    setHinge: () -> [String: Any],
    screen: () -> String,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> [String: Any] {
    guard hasHinge else {
      setDevice()
      return ["ok": true]
    }
    let before = screen()
    let result = setHinge()
    guard result["ok"] as? Bool == true else { return result }
    let deadline = now() + screenWait
    repeat {
      sleep(0.1)
      if screen() != before { break }
    } while now() < deadline
    let after = screen()
    return ["ok": true, "orientation": after, "screenChanged": after != before]
  }
}
