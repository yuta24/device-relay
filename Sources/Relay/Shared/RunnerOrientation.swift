import Foundation

/// Both event paths observe the same screen state used by /health and touches. A changed direction
/// alone can precede the end of the rotation animation, so require a short quiet window as well.
enum RunnerOrientation {
  static let screenWait: TimeInterval = 3
  static let settleTime: TimeInterval = 1
  static let pollInterval: TimeInterval = 0.1

  struct Screen: Equatable {
    var orientation: String
    var width: Double
    var height: Double
  }

  static func apply(
    requested: String,
    hasHinge: Bool,
    setDevice: () -> Void,
    setHinge: () -> [String: Any],
    screen: () -> Screen,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> [String: Any] {
    let before = screen()
    if hasHinge {
      let result = setHinge()
      guard result["ok"] as? Bool == true else { return result }
    } else {
      setDevice()
    }
    let deadline = now() + screenWait
    var after = before
    var quietSince = now()
    repeat {
      let current = screen()
      let time = now()
      if current != after {
        after = current
        quietSince = time
      }
      if after.orientation != before.orientation, time - quietSince >= settleTime { break }
      // A change first observed at the deadline still gets a full settling window.
      let stop = after.orientation == before.orientation ? deadline : deadline + settleTime
      guard time < stop else { break }
      sleep(min(pollInterval, stop - time))
    } while true
    return ["ok": true, "requested": requested, "orientation": after.orientation,
            "screenChanged": after.orientation != before.orientation]
  }
}
