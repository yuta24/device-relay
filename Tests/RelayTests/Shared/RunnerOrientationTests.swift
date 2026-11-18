import Foundation
@testable import Relay
import Testing

struct RunnerOrientationTests {
  private func screen(_ name: String, width: Double = 402, height: Double = 874) -> RunnerOrientation.Screen {
    RunnerOrientation.Screen(orientation: name, width: width, height: height)
  }

  @Test(arguments: [false, true])
  func bothPathsWaitForAQuietScreen(hasHinge: Bool) {
    var elapsed: TimeInterval = 0
    var deviceSent = false
    var hingeSent = false
    let result = RunnerOrientation.apply(
      requested: "landscapeLeft", hasHinge: hasHinge,
      setDevice: { deviceSent = true }, setHinge: { hingeSent = true; return ["ok": true] },
      screen: { elapsed >= 0.2 ? screen("landscapeLeft", width: 874, height: 402) : screen("portrait") },
      now: { elapsed }, sleep: { elapsed += $0 }
    )
    #expect(deviceSent == !hasHinge)
    #expect(hingeSent == hasHinge)
    #expect(elapsed >= 0.2 + RunnerOrientation.settleTime)
    #expect(elapsed < 0.3 + RunnerOrientation.settleTime + 0.001)
    #expect(result["ok"] as? Bool == true)
    #expect(result["requested"] as? String == "landscapeLeft")
    #expect(result["orientation"] as? String == "landscapeLeft")
    #expect(result["screenChanged"] as? Bool == true)
    #expect(result.count == 4)
  }

  @Test(arguments: [false, true])
  func sameOrUnsupportedOrientationReachesDeadline(hasHinge: Bool) {
    for requested in ["portrait", "portraitUpsideDown"] {
      var elapsed: TimeInterval = 0
      let result = RunnerOrientation.apply(
        requested: requested, hasHinge: hasHinge, setDevice: {}, setHinge: { ["ok": true] },
        screen: { screen("portrait") }, now: { elapsed }, sleep: { elapsed += $0 }
      )
      #expect(elapsed == RunnerOrientation.screenWait)
      #expect(result["requested"] as? String == requested)
      #expect(result["orientation"] as? String == "portrait")
      #expect(result["screenChanged"] as? Bool == false)
      #expect(result["ok"] as? Bool == true)
    }
  }

  @Test func duoReportsTheScreenRatherThanTheRequestedPose() {
    var elapsed: TimeInterval = 0
    var sent = false
    let result = RunnerOrientation.apply(
      requested: "portrait", hasHinge: true, setDevice: {}, setHinge: { sent = true; return ["ok": true] },
      screen: { sent ? screen("landscapeRight", width: 951, height: 669) : screen("portrait") },
      now: { elapsed }, sleep: { elapsed += $0 }
    )
    #expect(result["requested"] as? String == "portrait")
    #expect(result["orientation"] as? String == "landscapeRight")
    #expect(result["screenChanged"] as? Bool == true)
  }

  @Test func sizeOrDirectionChangesRestartTheQuietWindow() {
    var elapsed: TimeInterval = 0
    let result = RunnerOrientation.apply(
      requested: "landscapeLeft", hasHinge: false, setDevice: {}, setHinge: { [:] },
      screen: {
        if elapsed < 0.2 { return screen("portrait") }
        if elapsed < 0.4 { return screen("landscapeRight", width: 874, height: 402) }
        return screen("landscapeLeft", width: elapsed < 0.6 ? 800 : 874, height: 402)
      }, now: { elapsed }, sleep: { elapsed += $0 }
    )
    #expect(elapsed >= 0.6 + RunnerOrientation.settleTime)
    #expect(result["orientation"] as? String == "landscapeLeft")
  }

  @Test func transientChangeBackToOriginalWaitsUntilDeadline() {
    var elapsed: TimeInterval = 0
    let result = RunnerOrientation.apply(
      requested: "landscapeLeft", hasHinge: false, setDevice: {}, setHinge: { [:] },
      screen: { screen(elapsed >= 0.1 && elapsed < 0.3 ? "landscapeLeft" : "portrait") },
      now: { elapsed }, sleep: { elapsed += $0 }
    )
    #expect(elapsed == RunnerOrientation.screenWait)
    #expect(result["screenChanged"] as? Bool == false)
  }

  @Test(arguments: [false, true])
  func lateChangeGetsSettlingTimeWithoutAnUnboundedWait(hasHinge: Bool) {
    for keepsChanging in [false, true] {
      var elapsed: TimeInterval = 0
      let result = RunnerOrientation.apply(
        requested: "landscapeLeft", hasHinge: hasHinge, setDevice: {}, setHinge: { ["ok": true] },
        screen: {
          guard elapsed >= 2.9 else { return screen("portrait") }
          return screen("landscapeLeft", width: keepsChanging ? elapsed : 874, height: 402)
        }, now: { elapsed }, sleep: { elapsed += $0 }
      )
      #expect(elapsed >= 2.9 + RunnerOrientation.settleTime)
      #expect(elapsed <= RunnerOrientation.screenWait + RunnerOrientation.settleTime)
      #expect(result["screenChanged"] as? Bool == true)
    }
  }

  @Test func refusedHingeDoesNotWaitOrClaimAScreenResult() {
    let result = RunnerOrientation.apply(
      requested: "portrait", hasHinge: true, setDevice: { Issue.record("must not set device") },
      setHinge: { RunnerErrorCode.hingeUnavailable.body("unavailable") }, screen: { screen("portrait") },
      now: { Issue.record("refused event must not wait"); return 0 },
      sleep: { _ in Issue.record("refused event must not wait") }
    )
    #expect(result["code"] as? String == "hinge_unavailable")
    #expect(result["orientation"] == nil)
    #expect(result["requested"] == nil)
  }
}
