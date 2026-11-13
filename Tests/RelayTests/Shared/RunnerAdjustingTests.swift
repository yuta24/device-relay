import Foundation
@testable import Relay
import Testing

struct RunnerAdjustingTests {
  private func node(_ type: String, value: String? = nil, frame: CGRect = CGRect(x: 16, y: 218, width: 370, height: 34)) -> RunnerElementNode {
    RunnerElementNode(type: type, identifier: "", label: "", value: value, placeholder: nil, frame: frame, enabled: true,
                      selected: false, hasFocus: false, hasKeyboardFocus: nil, children: [])
  }

  private func json(_ text: String) throws -> Any {
    let object = try JSONSerialization.jsonObject(with: Data("{\"v\":\(text)}".utf8)) as? [String: Any]
    return try #require(object?["v"])
  }

  @Test func takesOnePositionInZeroToOneOrOnePickerValue() throws {
    #expect(RunnerAdjusting.target(position: try json("0.5"), pickerValue: nil) == .success(.position(0.5)))
    #expect(RunnerAdjusting.target(position: try json("0"), pickerValue: nil) == .success(.position(0)))
    #expect(RunnerAdjusting.target(position: try json("1"), pickerValue: nil) == .success(.position(1)))
    #expect(RunnerAdjusting.target(position: nil, pickerValue: try json("\"June\"")) == .success(.pickerValue("June")))
    #expect(RunnerAdjusting.target(position: nil, pickerValue: nil) == .failure(.missing))
    #expect(RunnerAdjusting.target(position: try json("0.5"), pickerValue: try json("\"June\"")) == .failure(.both))
    for bad in ["-0.1", "1.01", "true", "\"0.5\"", "null"] {
      #expect(RunnerAdjusting.target(position: try json(bad), pickerValue: nil) == .failure(.position), "\(bad)")
    }
    for bad in ["\"\"", "2026", "true", "null"] {
      #expect(RunnerAdjusting.target(position: nil, pickerValue: try json(bad)) == .failure(.pickerValue), "\(bad)")
    }
    #expect(RunnerAdjusting.TargetError.position.description == "position: expected a number in 0...1")
  }

  /// XCUI's adjust on an element of another type fails, so the runner refuses it first.
  @Test func takesOnlySlidersForPositionsAndWheelsForValues() {
    #expect(RunnerAdjusting.typeMismatch(.position(0.5), element: node("slider")) == nil)
    #expect(RunnerAdjusting.typeMismatch(.pickerValue("June"), element: node("pickerWheel")) == nil)
    #expect(RunnerAdjusting.typeMismatch(.position(0.5), element: node("button"))
      == "the element is a button, not a slider (position applies to a slider); nothing was adjusted")
    // A picker holds the wheels; the wheel is what takes a value.
    #expect(RunnerAdjusting.typeMismatch(.pickerValue("June"), element: node("picker"))
      == "the element is a picker, not a pickerWheel (pickerValue applies to a picker wheel); nothing was adjusted")
    #expect(RunnerAdjusting.typeMismatch(.pickerValue("50%"), element: node("slider")) != nil)
  }

  @Test func aSliderWithinTheToleranceIsSet() {
    #expect(RunnerAdjusting.failure(.position(0.5), value: "51%", position: 0.508, issues: []) == nil)
    #expect(RunnerAdjusting.failure(.position(0.5), value: "52%", position: 0.52, issues: []) == nil)
    #expect(RunnerAdjusting.failure(.position(0.6), value: "75%", position: 0.75, issues: [])
      == "the slider ended at 0.75, not 0.6 (within 0.02)")
    #expect(RunnerAdjusting.failure(.position(0.5), value: nil, position: nil, issues: [])
      == "cannot read the slider's position after adjusting it")
  }

  @Test func aWheelMustShowTheValueExactly() {
    #expect(RunnerAdjusting.failure(.pickerValue("June"), value: "June", position: nil, issues: []) == nil)
    #expect(RunnerAdjusting.failure(.pickerValue("31"), value: "30", position: nil, issues: [])
      == #"the picker wheel shows "30", not "31""#)
    #expect(RunnerAdjusting.failure(.pickerValue("June"), value: nil, position: nil, issues: []) != nil)
    // XCUI's own failure comes first, whatever the value.
    let issue = "Requested adjust to value 'Mango' which is not one of the possible values Apple, Banana"
    #expect(RunnerAdjusting.failure(.pickerValue("Mango"), value: "Banana", position: nil, issues: [issue])
      == "XCUI could not adjust the element: " + issue)
  }

  @Test func theOutcomeHasThePositionOfASliderOnly() {
    let match = RunnerElementMatch(index: 0, node: node("slider", value: "30%"))
    let slider = RunnerAdjusting.Outcome(bundleID: "com.example", element: match, value: "50%", position: 0.5, target: .position(0.5))
    #expect(slider.json["value"] as? String == "50%")
    #expect(slider.json["position"] as? Double == 0.5)
    #expect((slider.json["element"] as? [String: Any])?["value"] as? String == "30%")
    let unread = RunnerAdjusting.Outcome(bundleID: "com.example", element: match, value: nil, position: nil, target: .position(0.5))
    #expect(unread.json["value"] is NSNull)
    #expect(unread.json["position"] is NSNull)
    let wheel = RunnerAdjusting.Outcome(bundleID: "com.example", element: match, value: "June", position: nil, target: .pickerValue("June"))
    #expect(wheel.json["position"] == nil)
    #expect(wheel.json["bundleId"] as? String == "com.example")
  }

  /// The failure carries what the element shows now.
  @Test func anAdjustThatMissedAnswersWithTheValue() {
    let match = RunnerElementMatch(index: 0, node: node("pickerWheel", value: "June"))
    let outcome = RunnerAdjusting.Outcome(bundleID: "com.example", element: match, value: "30", position: nil, target: .pickerValue("31"))
    let error = RunnerError.adjustFailed(#"the picker wheel shows "30", not "31""#, outcome)
    #expect(error.json["code"] as? String == "adjust_failed")
    #expect(error.json["ok"] as? Bool == false)
    #expect(error.json["value"] as? String == "30")
    #expect(error.json["error"] as? String == #"the picker wheel shows "30", not "31""#)
    let refused = RunnerError.notAdjustable("the element is a button, not a slider", element: match)
    #expect((refused.json["element"] as? [String: Any])?["type"] as? String == "pickerWheel")
  }

  @Test func correctsAlongTheTrackFromTheThumb() throws {
    // 370 wide, 34 high: the track runs from 33 to 369 (336 points).
    let frame = CGRect(x: 16, y: 218, width: 370, height: 34)
    let track = try #require(RunnerAdjusting.track(of: frame))
    #expect(track.minX == 33 && track.width == 336)
    let drag = try #require(RunnerAdjusting.correction(from: 0.25, to: 0.5, frame: frame, slack: 0))
    #expect(drag.from == CGPoint(x: 117, y: 235))
    #expect(drag.to == CGPoint(x: 201, y: 235))
    // Slack goes on in the direction of the move.
    #expect(try #require(RunnerAdjusting.correction(from: 0.25, to: 0.5, frame: frame, slack: 10)).to.x == 211)
    #expect(try #require(RunnerAdjusting.correction(from: 0.5, to: 0.25, frame: frame, slack: 10)).to.x == 107)
    #expect(RunnerAdjusting.correction(from: 0.5, to: 0.5, frame: frame, slack: 0) == nil)
    // A vertical slider: no direction to drag in.
    #expect(RunnerAdjusting.correction(from: 0.2, to: 0.5, frame: CGRect(x: 0, y: 0, width: 34, height: 300), slack: 0) == nil)
  }

  /// On iOS 27 the thumb stayed some 10 points behind the finger.
  @Test func learnsHowFarTheFingerMovedWithoutTheThumb() {
    let frame = CGRect(x: 16, y: 218, width: 370, height: 34)
    // The finger moved 33.6 points (0.1 of the track) and the thumb 23.6.
    #expect(abs(RunnerAdjusting.slack(fingerMoved: 33.6, before: 0.4, after: 0.4 + 23.6 / 336, frame: frame) - 10) < 0.001)
    #expect(abs(RunnerAdjusting.slack(fingerMoved: -33.6, before: 0.4, after: 0.4 - 23.6 / 336, frame: frame) - 10) < 0.001)
    // A thumb that did not move at all: the whole move was slack.
    #expect(RunnerAdjusting.slack(fingerMoved: 8, before: 0.4, after: 0.4, frame: frame) == 8)
    // Further than the finger, or the other way: nothing to learn.
    #expect(RunnerAdjusting.slack(fingerMoved: 10, before: 0.4, after: 0.5, frame: frame) == 0)
    #expect(RunnerAdjusting.slack(fingerMoved: 10, before: 0.4, after: 0.3, frame: frame) == 0)
  }

  /// The runner answers within `giveUp` of finding the element: no correction starts after `correctionStop`, and one
  /// lasts at most `correctionLength`.
  @Test func theRunnerGivesUpAfterItsLastCorrection() {
    #expect(RunnerAdjusting.giveUp == RunnerAdjusting.correctionStop + RunnerAdjusting.correctionLength)
    // XCUI's idle waits before and after, about 60 s each, as for /launch.
    #expect(RunnerAdjusting.idleWait == 120)
    #expect(RunnerAdjusting.longestAnswer == RunnerAdjusting.idleWait + RunnerAdjusting.giveUp)
    #expect(RunnerAdjusting.correctionLength
      == RunnerAdjusting.correctionHold + RunnerAdjusting.correctionDuration + 10)
  }
}
