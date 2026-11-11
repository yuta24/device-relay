import Foundation
@testable import Relay
import Testing

struct RunnerArgumentsTests {
  private func operation(_ arguments: [String]) throws -> RunnerOperation {
    guard case .runner(let options) = try Arguments.parse(arguments) else {
      Issue.record("not a runner command: \(arguments)")
      return .ping
    }
    return options.operation
  }

  @Test func parsesCommandsWithoutArguments() throws {
    #expect(try operation(["ping"]) == .ping)
    #expect(try operation(["health"]) == .health)
    #expect(try operation(["foreground"]) == .foreground)
    #expect(try operation(["shutdown"]) == .shutdown)
    #expect(throws: ArgumentError.self) { try Arguments.parse(["health", "extra"]) }
  }

  @Test func parsesRunnerPathAnywhere() throws {
    #expect(try Arguments.parse(["health", "--runner", "a.json"])
      == .runner(RunnerControlOptions(operation: .health, runnerPath: "a.json")))
    #expect(try Arguments.parse(["launch", "--runner", "a.json", "com.example"])
      == .runner(RunnerControlOptions(operation: .launch(bundleID: "com.example"), runnerPath: "a.json")))
  }

  @Test func parsesScreenshotFormats() throws {
    #expect(try operation(["screenshot"]) == .screenshot(RunnerScreenshot()))
    #expect(try operation(["screenshot", "-o", "shot.png"]) == .screenshot(RunnerScreenshot(output: "shot.png")))
    #expect(try operation(["screenshot", "--output", "shot.JPG"]) == .screenshot(RunnerScreenshot(format: "jpeg", output: "shot.JPG")))
    #expect(try operation(["screenshot", "--quality", "0.5"]) == .screenshot(RunnerScreenshot(format: "jpeg", quality: 0.5)))
    #expect(try operation(["screenshot", "--format", "jpeg", "-o", "-"]) == .screenshot(RunnerScreenshot(format: "jpeg", output: "-")))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["screenshot", "--format", "png", "--quality", "0.5"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["screenshot", "--quality", "2"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["screenshot", "--format", "gif"]) }
  }

  @Test func parsesScreenshotSize() throws {
    #expect(try operation(["screenshot", "--max-size", "1024"]) == .screenshot(RunnerScreenshot(maxSize: 1024)))
    #expect(try operation(["screenshot", "--scale", "1"]) == .screenshot(RunnerScreenshot(scale: 1)))
    #expect(try operation(["screenshot", "--max-size", "1024", "--scale", "1", "-o", "a.jpg"])
      == .screenshot(RunnerScreenshot(format: "jpeg", maxSize: 1024, scale: 1, output: "a.jpg")))
    for invalid in [["--max-size", "15"], ["--max-size", "1.5"], ["--max-size", "abc"], ["--scale", "0"],
                    ["--scale", "0.09"], ["--scale", "11"], ["--scale", "nan"], ["--max-size", "1024", "--max-size", "512"]] {
      #expect(throws: ArgumentError.self, "\(invalid)") { try Arguments.parse(["screenshot"] + invalid) }
    }
  }

  @Test func parsesSource() throws {
    #expect(try operation(["source"]) == .source(format: nil, maxDepth: nil, filter: nil, bundleID: nil))
    #expect(try operation(["source", "--format", "text", "--max-depth", "3", "--bundle-id", "com.apple.Preferences"])
      == .source(format: "text", maxDepth: 3, filter: nil, bundleID: "com.apple.Preferences"))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--max-depth", "-1"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--bundle-id", ""]) }
  }

  @Test func parsesSourceFilterAndCompactFormat() throws {
    #expect(try operation(["source", "--filter", "interactive"])
      == .source(format: nil, maxDepth: nil, filter: "interactive", bundleID: nil))
    #expect(try operation(["source", "--format", "compact", "--filter", "interactive"])
      == .source(format: "compact", maxDepth: nil, filter: "interactive", bundleID: nil))
    #expect(try operation(["source", "--format", "compact"]) == .source(format: "compact", maxDepth: nil, filter: nil, bundleID: nil))
    // debugDescription can't be filtered.
    #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--format", "text", "--filter", "interactive"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--filter", "buttons"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--format", "xml"]) }
  }

  @Test func parsesFindSelector() throws {
    #expect(try operation(["find", "--type", "textField"])
      == .find(RunnerElementSelector(type: "textField"), limit: nil, timeout: nil, bundleID: nil))
    #expect(try operation(["find", "--label", "General", "--type", "button", "--index", "1", "--limit", "5", "--timeout", "2.5", "--bundle-id", "b"])
      == .find(RunnerElementSelector(label: "General", type: "button", index: 1), limit: 5, timeout: 2.5, bundleID: "b"))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--index", "0"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--type", "notAType"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--limit", "101"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--timeout", "11"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--id", "b"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--duration", "1"]) }
  }

  @Test func parsesTapByPointOrSelector() throws {
    #expect(try operation(["tap", "200", "120.5"]) == .tap(RunnerTouch(target: .point(RunnerPoint(x: 200, y: 120.5)))))
    #expect(try operation(["tap", "--id", "relay.input", "--mode", "xcui", "--timeout", "3"])
      == .tap(RunnerTouch(target: .element(RunnerElementSelector(identifier: "relay.input")), mode: "xcui", timeout: 3)))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "200"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "x", "y"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--id", "a"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--timeout", "1"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--mode", "fast"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--duration", "1"]) }
  }

  @Test func parsesPressDuration() throws {
    #expect(try operation(["press", "1", "2", "--duration", "1.5"])
      == .press(RunnerTouch(target: .point(RunnerPoint(x: 1, y: 2)), duration: 1.5)))
    #expect(try operation(["press", "--label", "History", "--bundle-id", "b"])
      == .press(RunnerTouch(target: .element(RunnerElementSelector(label: "History")), bundleID: "b")))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["press", "1", "2", "--duration", "0"]) }
  }

  @Test func parsesSwipe() throws {
    #expect(try operation(["swipe", "200", "700", "200", "200", "--duration", "0.5", "--hold", "0", "--mode", "private"])
      == .swipe(from: RunnerPoint(x: 200, y: 700), to: RunnerPoint(x: 200, y: 200), duration: 0.5, hold: 0, mode: "private"))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["swipe", "1", "2", "3"]) }
  }

  @Test func parsesTypeTextAndKeys() throws {
    #expect(try operation(["type", "hello world"]) == .type(text: "hello world", keys: [], bundleID: nil))
    #expect(try operation(["type", "example.com", "--key", "return", "--key", "Enter", "--bundle-id", "b"])
      == .type(text: "example.com", keys: ["return", "Enter"], bundleID: "b"))
    #expect(try operation(["type", "--key", "delete"]) == .type(text: nil, keys: ["delete"], bundleID: nil))
    // `--` lets text start with a dash; a negative number needs nothing.
    #expect(try operation(["type", "--", "--verbose"]) == .type(text: "--verbose", keys: [], bundleID: nil))
    #expect(try operation(["type", "-5"]) == .type(text: "-5", keys: [], bundleID: nil))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["type"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["type", ""]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["type", "a", "b"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["type", "a", "--key", "tab"]) }
  }

  @Test func readsTypeTextFromStandardInput() throws {
    func parse(_ arguments: [String], input: String) throws -> Command {
      try Arguments.parse(arguments, standardInput: { Data(input.utf8) })
    }
    func type(_ text: String?, keys: [String] = []) -> Command {
      .runner(RunnerControlOptions(operation: .type(text: text, keys: keys, bundleID: nil), runnerPath: nil))
    }
    #expect(try parse(["type", "--stdin"], input: "secret") == type("secret"))
    // Only one trailing line break is dropped.
    #expect(try parse(["type", "--stdin"], input: "secret\n") == type("secret"))
    #expect(try parse(["type", "--stdin"], input: "secret\r\n") == type("secret"))
    #expect(try parse(["type", "--stdin"], input: "two\nlines\n\n") == type("two\nlines\n"))
    #expect(try parse(["type", "--stdin"], input: " -x ") == type(" -x "))
    #expect(try parse(["type", "--key", "return", "--stdin"], input: "secret\n") == type("secret", keys: ["return"]))
    #expect(try parse(["type", "--stdin", "--key", "return"], input: "") == type(nil, keys: ["return"]))
    #expect(throws: ArgumentError.self) { try parse(["type", "--stdin"], input: "\n") }
    #expect(throws: ArgumentError.self) { try parse(["type", "--stdin", "text"], input: "secret") }
    #expect(throws: SetupError.self) { try Arguments.parse(["type", "--stdin"], standardInput: { Data([0xff, 0xfe]) }) }
    // Standard input is read only for --stdin, and --stdin is only a flag of type.
    #expect(try Arguments.parse(["type", "hello"], standardInput: { Issue.record("read stdin"); return Data() }) == type("hello"))
    #expect(throws: ArgumentError.self) { try parse(["key", "return", "--stdin"], input: "") }
  }

  @Test func parsesNamedArguments() throws {
    #expect(try operation(["key", "space"]) == .key("space", bundleID: nil))
    #expect(try operation(["button", "home"]) == .button("home"))
    #expect(try operation(["orientation", "landscapeLeft"]) == .orientation("landscapeLeft"))
    // The alias is resolved before sending, so the runner sees only its own four names.
    #expect(try operation(["orientation", "landscape"]) == .orientation("landscapeLeft"))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["orientation", "portraitUpsideDownish"]) }
    #expect(try operation(["launch", "com.apple.Preferences"]) == .launch(bundleID: "com.apple.Preferences"))
    #expect(try operation(["terminate", "com.apple.Preferences"]) == .terminate(bundleID: "com.apple.Preferences"))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["key", "escape"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["button", "power"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["orientation", "upsideDown"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["launch"]) }
  }

  @Test func parsesOpen() throws {
    #expect(try operation(["open", "myapp://item/42?from=relay"]) == .open(url: "myapp://item/42?from=relay", bundleID: nil))
    #expect(try operation(["open", "https://example.com/a%20b", "--bundle-id", "com.example"])
      == .open(url: "https://example.com/a%20b", bundleID: "com.example"))
    // A URL is sent as written; one the runner would reject is a usage error before anything is sent.
    for bad in [["open"], ["open", "a", "b"], ["open", "example.com"], ["open", "https://example.com/a b"], ["open", "https://例え.jp/"]] {
      #expect(throws: ArgumentError.self, "\(bad)") { try Arguments.parse(bad) }
    }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["open", "myapp://x", "--bundle-id", ""]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["open", "myapp://x", "--timeout", "1"]) }
    #expect(Arguments.usage(for: "open").contains("relay open <url> [--bundle-id <id>]"))
    #expect(try Scenario.action(["open", "myapp://item/1"]) == .runner(.open(url: "myapp://item/1", bundleID: nil)))
  }

  @Test func showsCommandHelp() throws {
    #expect(try Arguments.parse(["tap", "--help"]) == .commandHelp("tap"))
    #expect(try Arguments.parse(["screenshot", "-h"]) == .commandHelp("screenshot"))
    #expect(try Arguments.parse(["help", "find"]) == .commandHelp("find"))
    #expect(try Arguments.parse(["help", "start"]) == .commandHelp("start"))
    #expect(try Arguments.parse(["help", "bogus"]) == .help)
    #expect(Arguments.usage(for: "swipe").contains("relay swipe <x1> <y1> <x2> <y2>"))
    // Every runner command is in the overall usage, except shutdown: relay stop is what stops a runner.
    for name in Arguments.runnerUsages.keys where name != "shutdown" {
      #expect(Arguments.usage.contains("relay \(name)"))
    }
    #expect(!Arguments.usage.contains("shutdown"))
    #expect(!Arguments.listedRunnerCommands.contains("shutdown"))
    #expect(Set(Arguments.runnerCommandOrder) == Set(Arguments.runnerUsages.keys))
    // It still has its help, which says to use relay stop first.
    #expect(try Arguments.parse(["shutdown", "--help"]) == .commandHelp("shutdown"))
    #expect(Arguments.usage(for: "shutdown").contains("Normally use relay stop."))
  }
}
