import Foundation

/// Visual quiet-window detection, shared with the CLI tests. Sampling does not wait for XCUI idleness.
enum RunnerStability {
  static let defaultDuration: TimeInterval = 0.5
  static let defaultTimeout: TimeInterval = 10
  static let durationRange = 0.1 ... 5.0
  static let timeoutRange = 0.0 ... 10.0
  static let pollInterval: TimeInterval = 0.1
  /// Allow for display discovery and a final XCTest capture after the polling deadline.
  static let captureAllowance: TimeInterval = 180
  static let imageEdge = 256

  struct Options: Equatable {
    var duration: TimeInterval = defaultDuration
    var timeout: TimeInterval = defaultTimeout

    init(duration: TimeInterval = defaultDuration, timeout: TimeInterval = defaultTimeout) {
      self.duration = duration
      self.timeout = timeout
    }

    init(json: [String: Any]) throws {
      guard Set(json.keys).isSubset(of: ["stable", "for", "timeout", "bundleId"]) else {
        throw RunnerError.invalidField("unknown /wait field")
      }
      guard RunnerRequestValues.bool(json["stable"] ?? NSNull()) == true else {
        throw RunnerError.invalidField("stable: expected true")
      }
      func seconds(_ key: String, fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let raw = json[key] else { return fallback }
        guard let value = RunnerRequestValues.number(raw), value.isFinite, range.contains(value) else {
          throw RunnerError.invalidField("\(key): expected seconds in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
      }
      duration = try seconds("for", fallback: RunnerStability.defaultDuration, range: RunnerStability.durationRange)
      timeout = try seconds("timeout", fallback: RunnerStability.defaultTimeout, range: RunnerStability.timeoutRange)
    }
  }

  struct Outcome: Equatable {
    var stable: Bool
    var waitedMs: Int
    var json: [String: Any] { ["ok": true, "stable": stable, "waitedMs": waitedMs] }
  }

  /// RGB(A) bytes drawn at a fixed size. Compare against the start of the quiet window so slow drift
  /// cannot disappear into the per-channel tolerance. A changed size/orientation always resets it.
  static func samePixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
  }

  /// The deadline includes acquisition. No new capture starts after it. One in flight may finish later,
  /// but cannot turn an expired wait into success. `now` is monotonic; `pause` drains the runner run loop.
  static func wait<Sample>(
    _ options: Options,
    now: () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
    pause: (TimeInterval) -> Void,
    sample: () throws -> Sample,
    equal: (Sample, Sample) -> Bool
  ) rethrows -> Outcome {
    let start = now()
    let deadline = start + options.timeout
    var baseline: Sample?
    var quietSince = start
    while true {
      let current = try sample()
      let time = now()
      if let previous = baseline, equal(previous, current) {
        if time <= deadline, time - quietSince >= options.duration {
          return Outcome(stable: true, waitedMs: Int(((time - start) * 1000).rounded()))
        }
      } else {
        baseline = current
        quietSince = time
      }
      guard time < deadline else {
        return Outcome(stable: false, waitedMs: Int(((time - start) * 1000).rounded()))
      }
      pause(min(pollInterval, deadline - time))
      if now() >= deadline {
        return Outcome(stable: false, waitedMs: Int(((now() - start) * 1000).rounded()))
      }
    }
  }
}
