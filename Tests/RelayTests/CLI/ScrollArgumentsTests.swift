import Foundation
@testable import Relay
import Testing

struct ScrollArgumentsTests {
  @Test func acceptsAllFourCommandsAndScenarios() throws {
    for words in [["find", "--id", "row"], ["tap", "--id", "row"], ["press", "--id", "row"],
                  ["adjust", "--id", "slider", "--position", "0.7"]] {
      let arguments = words + ["--scroll", "down", "--max-swipes", "20", "--timeout", "40", "--in", "list"]
      guard case .runner(let options) = try Arguments.parse(arguments) else { Issue.record("runner"); return }
      #expect(options.operation.scrollOptions?.timeout == 40)
      #expect(options.operation.scrollOptions?.container?.identifier == "list")
      #expect(options.operation.request.body?["scroll"] is [String: Any])
      #expect(options.operation.request.body?["timeout"] as? Double == 40)
      #expect(try Scenario.parse([(number: 1, text: arguments.joined(separator: " "))]).count == 1)
      #expect(try options.operation.resolvingHostAlias("com.test.host").scrollOptions != nil)
    }
  }

  @Test func rejectsUnsafeCombinationsAndOutOfRangeValues() {
    for tail in [["--scroll", "down", "--index", "0"], ["--scroll", "down", "--gone"],
                 ["--scroll", "sideways"], ["--scroll", "down", "--max-swipes", "31"],
                 ["--scroll", "down", "--timeout", "61"], ["--in", "list"], ["--max-swipes", "1"]] {
      #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "row"] + tail) }
    }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "10", "20", "--scroll", "down"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "--id", "row", "--scroll", "down", "--mode", "xcui"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "row", "--timeout", "11"]) }
  }

  @Test func preservesZeroAndWaitsTwentySecondsPastTheLastGestureAndAction() throws {
    guard case .runner(let zero) = try Arguments.parse(["find", "--id", "row", "--scroll", "down", "--timeout", "0"]) else {
      Issue.record("runner"); return
    }
    #expect(zero.operation.scrollOptions?.timeout == 0)
    let selector = RunnerElementSelector(identifier: "slider")
    let base = RunnerOperation.adjust(selector, .position(0.5), timeout: 4, bundleID: "host")
    let operation = RunnerOperation.scrolling(base, RunnerScrolling.Options(timeout: 60))
    #expect(operation.waitTime == RunnerAdjusting.longestAnswer + 60 + RunnerScrolling.lastGestureWait)
    #expect(RunnerControl.baseTimeout >= 20)
    #expect(try operation.resolvingHostAlias("com.test.host").request.body?["bundleId"] as? String == "com.test.host")
  }
}
