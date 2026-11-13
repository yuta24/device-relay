import Foundation
@testable import Relay
import Testing

struct RunnerOperationTests {
  private func body(_ request: RunnerHTTPRequest) throws -> String? {
    try request.body.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
  }

  @Test func buildsGetQueries() {
    #expect(RunnerOperation.health.request.path == "/health")
    #expect(RunnerOperation.screenshot(RunnerScreenshot()).request.path == "/screenshot")
    #expect(RunnerOperation.screenshot(RunnerScreenshot(format: "jpeg", quality: 0.5)).request.path == "/screenshot?format=jpeg&quality=0.5")
    let source = RunnerOperation.source(format: "text", maxDepth: 3, filter: nil, bundleID: "com.apple.Preferences").request
    #expect(source.method == "GET")
    #expect(source.path == "/source?format=text&maxDepth=3&bundleId=com.apple.Preferences")
    #expect(source.body == nil)
    #expect(RunnerOperation.source(format: "compact", maxDepth: nil, filter: "interactive", bundleID: nil).request.path
      == "/source?format=compact&filter=interactive")
    #expect(RunnerOperation.screenshot(RunnerScreenshot(format: "jpeg", maxSize: 1024, scale: 1)).request.path
      == "/screenshot?format=jpeg&maxSize=1024&scale=1.0")
  }

  @Test func buildsTouchBodies() throws {
    let point = RunnerOperation.tap(RunnerTouch(target: .point(RunnerPoint(x: 200, y: 120.5)), mode: "xcui")).request
    #expect(point.method == "POST")
    #expect(point.path == "/tap")
    #expect(try body(point) == #"{"mode":"xcui","x":200,"y":120.5}"#)

    let double = RunnerOperation.tap(RunnerTouch(target: .element(RunnerElementSelector(identifier: "map")), taps: 2)).request
    #expect(try body(double) == #"{"element":{"identifier":"map"},"taps":2}"#)

    let element = RunnerOperation.press(RunnerTouch(
      target: .element(RunnerElementSelector(label: "General", type: "button", index: 0)),
      duration: 1, timeout: 3, bundleID: "com.apple.Preferences"
    )).request
    #expect(element.path == "/press")
    #expect(try body(element)
      == #"{"bundleId":"com.apple.Preferences","duration":1,"element":{"index":0,"label":"General","type":"button"},"timeout":3}"#)
  }

  @Test func buildsAdjustBodies() throws {
    let slider = RunnerOperation.adjust(RunnerElementSelector(identifier: "volume"), .position(0.5), timeout: 2, bundleID: nil).request
    #expect(slider.method == "POST")
    #expect(slider.path == "/adjust")
    #expect(try body(slider) == #"{"element":{"identifier":"volume"},"position":0.5,"timeout":2}"#)
    let wheel = RunnerOperation.adjust(RunnerElementSelector(type: "pickerWheel", index: 0), .pickerValue("June"), timeout: nil,
                                       bundleID: "com.example").request
    #expect(try body(wheel) == #"{"bundleId":"com.example","element":{"index":0,"type":"pickerWheel"},"pickerValue":"June"}"#)
    #expect(RunnerOperation.adjust(RunnerElementSelector(identifier: "a"), .position(0), timeout: nil, bundleID: nil).commandName == "adjust")
  }

  /// The runner answers an adjust within `--timeout`, XCUI's idle waits (120 s), and `RunnerAdjusting.giveUp`; relay
  /// waits at least 20 s more. On a screen that never idles the runner answered after 120.2-121.0 s.
  @Test func adjustWaitsTwentySecondsPastTheRunner() {
    for timeout in [nil, 0, 4, 10] as [TimeInterval?] {
      let adjust = RunnerOperation.adjust(RunnerElementSelector(identifier: "a"), .position(0.5), timeout: timeout, bundleID: nil)
      let relayWaits = RunnerControl.baseTimeout + adjust.waitTime
      let runnerAnswersBy = (timeout ?? 0) + RunnerAdjusting.idleWait + RunnerAdjusting.giveUp
      #expect(relayWaits - runnerAnswersBy >= 20, "\(String(describing: timeout))")
      #expect(relayWaits - (timeout ?? 0) - 121.0 >= 20, "the longest answer measured")
    }
  }

  @Test func buildsOtherBodies() throws {
    #expect(try body(RunnerOperation.find(RunnerElementSelector(type: "cell"), limit: 5, timeout: nil, bundleID: nil).request)
      == #"{"element":{"type":"cell"},"limit":5}"#)
    #expect(try body(RunnerOperation.find(RunnerElementSelector(type: "cell"), limit: nil, timeout: 5, bundleID: nil, gone: true).request)
      == #"{"element":{"type":"cell"},"gone":true,"timeout":5}"#)
    #expect(try body(RunnerOperation.swipe(from: RunnerPoint(x: 1, y: 2), to: RunnerPoint(x: 3, y: 4), duration: nil, hold: nil, mode: nil).request)
      == #"{"from":{"x":1,"y":2},"to":{"x":3,"y":4}}"#)
    #expect(try body(RunnerOperation.type(text: "hi", keys: ["return"], bundleID: nil).request) == #"{"keys":["return"],"text":"hi"}"#)
    #expect(try body(RunnerOperation.type(text: nil, keys: ["delete"], bundleID: "b").request) == #"{"bundleId":"b","keys":["delete"]}"#)
    #expect(try body(RunnerOperation.type(text: nil, keys: [], bundleID: nil, clear: true).request) == #"{"clear":true}"#)
    #expect(try body(RunnerOperation.type(text: "new", keys: [], bundleID: nil, clear: true).request) == #"{"clear":true,"text":"new"}"#)
    #expect(try body(RunnerOperation.key("space", bundleID: nil).request) == #"{"key":"space"}"#)
    #expect(try body(RunnerOperation.button("home").request) == #"{"name":"home"}"#)
    #expect(try body(RunnerOperation.orientation("portrait").request) == #"{"orientation":"portrait"}"#)
    #expect(try body(RunnerOperation.launch(bundleID: "b").request) == #"{"bundleId":"b"}"#)
    #expect(RunnerOperation.terminate(bundleID: "b").request.path == "/terminate")
    #expect(try body(RunnerOperation.open(url: "myapp://x", bundleID: nil).request) == #"{"url":"myapp:\/\/x"}"#)
    #expect(try body(RunnerOperation.open(url: "myapp://x", bundleID: "b").request) == #"{"bundleId":"b","url":"myapp:\/\/x"}"#)
    #expect(RunnerOperation.open(url: "myapp://x", bundleID: nil).request.path == "/open")
    #expect(RunnerOperation.shutdown.request.method == "POST")
  }

  /// relay must wait past the runner's give-up, or it reports runner_timeout while the runner is about to answer.
  /// The margin with --clear is the same 20 s as for text alone.
  @Test func typeWaitsTwentySecondsPastTheRunner() {
    for (text, keys) in [("", ["return"]), ("hello", []), (String(repeating: "x", count: 300), ["delete", "return"])] {
      for clear in [false, true] {
        let operation = RunnerOperation.type(text: text, keys: keys, bundleID: nil, clear: clear)
        let runner = RunnerTyping.runnerGiveUp(text: text, keyCount: keys.count, clear: clear)
        let margin = RunnerControl.baseTimeout + operation.waitTime - runner
        #expect(abs(margin - 20) < 1e-9, "\(text.count) characters, clear: \(clear)")
      }
    }
  }

  @Test func allowsForWaitsInTheTimeout() {
    #expect(RunnerOperation.health.waitTime == 0)
    #expect(RunnerOperation.find(RunnerElementSelector(type: "cell"), limit: nil, timeout: 5, bundleID: nil).waitTime == 5)
    #expect(RunnerOperation.find(RunnerElementSelector(type: "cell"), limit: nil, timeout: 7, bundleID: nil, gone: true).waitTime == 7)
    let typed = RunnerOperation.type(text: "ab", keys: [], bundleID: nil).waitTime
    #expect(RunnerOperation.type(text: "ab", keys: [], bundleID: nil, clear: true).waitTime == typed + RunnerTyping.clearGiveUp)
    #expect(RunnerOperation.press(RunnerTouch(target: .point(RunnerPoint(x: 0, y: 0)), duration: 4, timeout: 2)).waitTime == 6)
    #expect(RunnerOperation.tap(RunnerTouch(target: .point(RunnerPoint(x: 0, y: 0)), timeout: 2)).waitTime == 2)
    #expect(RunnerOperation.tap(RunnerTouch(target: .point(RunnerPoint(x: 0, y: 0)), taps: 2, timeout: 2)).waitTime
      == 2 + RunnerRequestValues.tapPeriod)
  }

  /// The runner waits up to XCTest's application state timeout, 120 s when it cannot set it back to 60 s.
  @Test func allowsForTheApplicationStateTimeout() {
    #expect(RunnerOperation.launch(bundleID: "b").waitTime == 120)
    #expect(RunnerOperation.terminate(bundleID: "b").waitTime == 120)
    // Without the private path the runner opens the URL with XCTest's public calls, which wait for the app as /launch does.
    #expect(RunnerOperation.open(url: "myapp://x", bundleID: nil).waitTime == 120)
    #expect(RunnerOperation.open(url: "myapp://x", bundleID: nil).waitTime > RunnerOpen.acceptWait + RunnerOpen.foregroundWait)
    #expect(RunnerControl.baseTimeout + RunnerOperation.launch(bundleID: "b").waitTime > 120)
  }

  /// 0.1 s per Unicode scalar of text and 1 s per key, several times what was measured.
  @Test func allowsForTypingByLength() {
    #expect(RunnerOperation.type(text: "", keys: [], bundleID: nil).waitTime == 0)
    #expect(RunnerOperation.type(text: nil, keys: ["return"], bundleID: nil).waitTime == 1)
    #expect(abs(RunnerOperation.type(text: "hello", keys: ["delete", "return"], bundleID: nil).waitTime - 2.5) < 1e-9)
    #expect(abs(RunnerOperation.type(text: String(repeating: "a", count: 2500), keys: [], bundleID: nil).waitTime - 250) < 1e-9)
    // Counted in scalars: "é" as e + U+0301 is one character but two scalars.
    #expect(abs(RunnerOperation.type(text: "e\u{301}日本", keys: [], bundleID: nil).waitTime - 0.4) < 1e-9)
    #expect(RunnerOperation.key("return", bundleID: nil).waitTime == 1)
  }

  /// The runner stops waiting for synthesized text before relay stops waiting for the answer, so a slow
  /// `type` ends in `typing_failed` instead of a timeout that leaves the runner busy.
  @Test func runnerGivesUpOnTypingFirst() {
    for operation in [RunnerOperation.type(text: "abcdefghij", keys: ["return"], bundleID: nil), .key("delete", bundleID: nil),
                      .type(text: String(repeating: "a", count: 2500), keys: [], bundleID: nil)] {
      #expect(operation.waitTime + RunnerTyping.synthesisGrace + 10 <= RunnerControl.baseTimeout + operation.waitTime)
    }
    #expect(RunnerTyping.synthesisTimeoutMessage(seconds: 11.05) == "typing did not complete within 12s; some of the text may have been typed")
  }
}
