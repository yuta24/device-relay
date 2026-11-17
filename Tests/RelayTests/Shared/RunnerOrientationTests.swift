import Foundation
@testable import Relay
import Testing

struct RunnerOrientationTests {
  @Test func xcuiAcknowledgesWithoutReadingOrWaitingForTheScreen() {
    var applied = false
    let result = RunnerOrientation.apply(
      hasHinge: false,
      setDevice: { applied = true },
      setHinge: { Issue.record("XCUI must not send hinge events"); return [:] },
      screen: { Issue.record("XCUI must not sample an unfinished rotation"); return "portrait" },
      now: { Issue.record("XCUI must not start a deadline"); return 0 },
      sleep: { _ in Issue.record("XCUI must not wait, including unchanged or unsupported orientations") }
    )
    #expect(applied)
    #expect(result["ok"] as? Bool == true)
    #expect(result.count == 1)
  }

  @Test func hingeWaitsForAChangedScreenAndReportsIt() {
    var elapsed: TimeInterval = 0
    var sent = false
    let result = RunnerOrientation.apply(
      hasHinge: true,
      setDevice: { Issue.record("hinge must not use XCUI orientation") },
      setHinge: { sent = true; return ["ok": true] },
      screen: { elapsed >= 0.2 ? "landscapeLeft" : "portrait" },
      now: { elapsed }, sleep: { elapsed += $0 }
    )
    #expect(sent)
    #expect(elapsed == 0.2)
    #expect(result["orientation"] as? String == "landscapeLeft")
    #expect(result["screenChanged"] as? Bool == true)
  }

  @Test func hingeReportsUnchangedAtTheDeadline() {
    var elapsed: TimeInterval = 0
    let result = RunnerOrientation.apply(
      hasHinge: true, setDevice: {}, setHinge: { ["ok": true] }, screen: { "portrait" },
      now: { elapsed }, sleep: { elapsed += $0 }
    )
    #expect(elapsed >= RunnerOrientation.screenWait)
    #expect(elapsed < RunnerOrientation.screenWait + 0.1)
    #expect(result["orientation"] as? String == "portrait")
    #expect(result["screenChanged"] as? Bool == false)
  }

  @Test func refusedHingeDoesNotWaitOrClaimAScreenResult() {
    let result = RunnerOrientation.apply(
      hasHinge: true, setDevice: {},
      setHinge: { RunnerErrorCode.hingeUnavailable.body("unavailable") }, screen: { "portrait" },
      now: { Issue.record("refused event must not wait"); return 0 },
      sleep: { _ in Issue.record("refused event must not wait") }
    )
    #expect(result["code"] as? String == "hinge_unavailable")
    #expect(result["orientation"] == nil)
  }
}
