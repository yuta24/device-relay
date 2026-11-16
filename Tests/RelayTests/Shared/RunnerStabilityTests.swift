import Foundation
@testable import Relay
import Testing

struct RunnerStabilityTests {
  @Test func validatesWireOptions() throws {
    let json = RunnerStability.Outcome(stable: false, waitedMs: 500).json
    #expect(json["ok"] as? Bool == true)
    #expect(json["stable"] as? Bool == false)
    #expect(json["waitedMs"] as? Int == 500)
    #expect(try RunnerStability.Options(json: ["stable": true]) == RunnerStability.Options())
    #expect(try RunnerStability.Options(json: ["stable": true, "for": 0.1, "timeout": 0])
      == RunnerStability.Options(duration: 0.1, timeout: 0))
    #expect(try RunnerStability.Options(json: ["stable": true, "for": 5, "timeout": 10, "bundleId": "host"])
      == RunnerStability.Options(duration: 5, timeout: 10))
    for json: [String: Any] in [[:], ["stable": false], ["stable": 1], ["stable": true, "for": true],
                                ["stable": true, "for": 0], ["stable": true, "for": 5.1], ["stable": true, "for": "1"],
                                ["stable": true, "timeout": -1], ["stable": true, "timeout": 11],
                                ["stable": true, "timeout": Double.infinity], ["stable": true, "extra": 0]] {
      #expect(throws: RunnerError.self) { try RunnerStability.Options(json: json) }
    }
  }

  @Test func detectsSmallLocalDrawingChanges() {
    #expect(RunnerStability.samePixels([0, 10, 255], [8, 2, 247]))
    #expect(!RunnerStability.samePixels([0, 10, 255], [9, 10, 255]))
    #expect(!RunnerStability.samePixels([], []))
    #expect(!RunnerStability.samePixels([1], [1, 1]))
  }

  private func sequence(_ values: [[UInt8]], duration: Double = 0.5, timeout: Double = 3,
                        cost: Double = 0) -> (RunnerStability.Outcome, Int) {
    var time = 0.0
    var index = 0
    let outcome = RunnerStability.wait(.init(duration: duration, timeout: timeout), now: { time }, pause: { time += $0 }, sample: {
      time += cost
      defer { index += 1 }
      return values[min(index, values.count - 1)]
    }, equal: RunnerStability.samePixels)
    return (outcome, index)
  }

  @Test func stableScreenWaitsForTheWholeQuietInterval() {
    let (outcome, _) = sequence([[20]])
    #expect(outcome.stable)
    #expect(outcome.waitedMs == 500)
    let (slow, _) = sequence([[20]], cost: 0.09)
    #expect(slow.stable)
    #expect(slow.waitedMs >= 590)
    #expect(slow.waitedMs < 800)
  }

  @Test func animationResetsQuietWindowAndDriftUsesTheWindowStart() {
    let (outcome, _) = sequence([[0], [6], [12], [18], [24], [30]])
    #expect(outcome.stable)
    #expect(outcome.waitedMs >= 900)
    let (repeating, _) = sequence((0 ..< 50).map { [$0 % 2 == 0 ? 0 : 255] }, timeout: 1)
    #expect(!repeating.stable)
    #expect(repeating.waitedMs == 1000)
  }

  @Test func timeoutIncludesCaptureAndNeverStartsAnotherAfterDeadline() {
    let (zero, captures) = sequence([[20]], timeout: 0)
    #expect(!zero.stable)
    #expect(zero.waitedMs == 0)
    #expect(captures == 1)
    let (late, count) = sequence([[20]], timeout: 0.3, cost: 0.4)
    #expect(!late.stable)
    #expect(late.waitedMs == 400)
    #expect(count == 1)
    #expect(!sequence([[20]], duration: 2, timeout: 0.5).0.stable)
  }

  @Test func failedCaptureDoesNotBecomeAQuietScreen() {
    #expect(throws: RunnerError.self) {
      try RunnerStability.wait(.init(), pause: { _ in }, sample: { () throws -> [UInt8] in
        throw RunnerError.actionFailed("capture failed")
      }, equal: RunnerStability.samePixels)
    }
  }
}
