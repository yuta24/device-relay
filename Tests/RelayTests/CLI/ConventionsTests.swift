import Foundation
@testable import Relay
import Testing

/// `text` with every run of white space (line breaks of a wrapped help included) as one space, to look for a phrase in.
func flattened(_ text: String) -> String {
  text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The conventions of the command line: exit statuses, `--json`, `--opt=value`, the two-line usage error, and
/// where the JSON of a failure goes.
struct ExitStatusTests {
  @Test func separatesUsageFromLocalFailure() {
    #expect(RunnerExitCode.success.rawValue == 0)
    #expect(RunnerExitCode.failure.rawValue == 1)
    #expect(RunnerExitCode.usage.rawValue == 2)
    #expect(RunnerExitCode.unavailable.rawValue == 3)
    // The statuses of the runner's answers are unchanged.
    #expect([200, 401, 409, 422, 400, 404, 500].map { RunnerExitCode(status: $0).rawValue } == [0, 4, 5, 6, 7, 7, 8])
  }

  /// What `main` turns into exit 2 is thrown as `ArgumentError`; a failure that is not about how the command was written is not.
  @Test func argumentErrorIsOnlyForAWrongCommandLine() {
    let wrong: [[String]] = [
      ["start", "--bogus"], ["start", "--port", "abc"], ["start", "--port"], ["start", "--udid", "A", "--device", "B"],
      ["start", "--session", "bad/name"], ["tap", "--bogus"], ["tap", "1"], ["type", "--stdin", "text"], ["status", "--runner", "a", "--session", "b"],
      ["bogus"], ["record", "bogus"], ["skill", "bogus"], ["config", "get", "nope"], ["run"], ["bench", "--runner", "a", "--session", "b"],
      ["logs", "--since", "x"], ["logs", "--follow", "--since", "5m"], ["crashes", "--name", "../a"], ["crashes", "--udid", "A", "--session", "b"]
    ]
    for arguments in wrong {
      #expect(throws: ArgumentError.self, "\(arguments)") { try Arguments.parse(arguments) }
    }
    // Standard input that is not text is a failure to read the input, not a mistake in the command.
    #expect(throws: SetupError.self) { try Arguments.parse(["type", "--stdin"], standardInput: { Data([0xff, 0xfe]) }) }
  }

  @Test func usageErrorsPrintTwoLines() {
    #expect(CLIOutput.usageMessage("unknown option for tap: --bogus", command: "tap")
      == "relay: unknown option for tap: --bogus\nrelay: see relay tap --help\n")
    #expect(CLIOutput.usageMessage("unknown command: bogus", command: "bogus")
      == "relay: unknown command: bogus\nrelay: see relay --help\n")
    #expect(CLIOutput.usageMessage("unknown command: bogus") == "relay: unknown command: bogus\nrelay: see relay --help\n")
    #expect(CLIOutput.usageMessage("--port requires a valid TCP port", command: "start")
      == "relay: --port requires a valid TCP port\nrelay: see relay start --help\n")
    for name in ["status", "stop", "record", "run", "skill"] + Arguments.runnerCommandOrder {
      #expect(Arguments.helpCommand(for: name) == "relay \(name) --help", "\(name)")
    }
    for name in Arguments.commandNames {
      #expect(Arguments.helpCommand(for: name) == "relay \(name) --help", "\(name)")
    }
    #expect(Arguments.helpCommand(for: "bogus") == "relay --help")
    #expect(Arguments.helpCommand(for: nil) == "relay --help")
  }

  @Test func aWrongSessionSelectionIsUsageAndNothingGoesToTheFailureOutput() throws {
    let pipe = Pipe()
    let result = RunnerControl.connect(runnerPath: "/nonexistent/runner.json", session: "agent", command: "tap", failureOutput: pipe.fileHandleForWriting)
    guard case .failure(let failure) = result else { Issue.record("expected a failure"); return }
    #expect(failure.code == 2)
    try pipe.fileHandleForWriting.close()
    #expect(try pipe.fileHandleForReading.readToEnd() == nil)
  }
}

struct OptionEqualsTests {
  @Test func splitsAtTheFirstEquals() throws {
    #expect(try Arguments.splittingEquals(["start", "--port=8101"]) == ["start", "--port", "8101"])
    #expect(try Arguments.splittingEquals(["tap", "--label=a=b", "--type=button"]) == ["tap", "--label", "a=b", "--type", "button"])
    #expect(try Arguments.splittingEquals(["tap", "--label="]) == ["tap", "--label", ""])
  }

  @Test func leavesTheRestAsGiven() throws {
    #expect(try Arguments.splittingEquals(["type", "a=b", "-o=x", "--=y", "--", "--x=y", "--json=1"])
      == ["type", "a=b", "-o=x", "--=y", "--", "--x=y", "--json=1"])
    #expect(try Arguments.splittingEquals(["tap", "-5=x", "5"]) == ["tap", "-5=x", "5"])
  }

  @Test func aFlagWithAValueIsAnError() {
    for argument in ["--json=true", "--rebuild=1", "--verbose=", "--stdin=x", "--require=1", "--all=1", "--help=x", "--background=no"] {
      let error = #expect(throws: ArgumentError.self, "\(argument)") { try Arguments.splittingEquals(["x", argument]) }
      #expect(error?.description.contains("does not take a value") == true, "\(argument)")
    }
    // After -- it is text.
    #expect((try? Arguments.splittingEquals(["x", "--", "--json=true"])) == ["x", "--", "--json=true"])
  }

  @Test func everySubcommandTakesTheEqualsForm() throws {
    #expect(try Arguments.parse(["start", "--port=8101", "--session=a", "--ready-timeout=30", "--os=27"])
      == Arguments.parse(["start", "--port", "8101", "--session", "a", "--ready-timeout", "30", "--os", "27"]))
    #expect(try Arguments.parse(["status", "--session=a", "--json"]) == Arguments.parse(["status", "--session", "a", "--json"]))
    #expect(try Arguments.parse(["stop", "--runner=/tmp/r.json"]) == Arguments.parse(["stop", "--runner", "/tmp/r.json"]))
    #expect(try Arguments.parse(["devices", "--os=26"]) == .devices(json: false, os: "26"))
    #expect(try Arguments.parse(["doctor", "--device=iPhone 17"]) == Arguments.parse(["doctor", "--device", "iPhone 17"]))
    #expect(try Arguments.parse(["install", "--project=/p"]) == Arguments.parse(["install", "--project", "/p"]))
    #expect(try Arguments.parse(["bench", "--url=http://127.0.0.1:8100", "--count=3"])
      == Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--count", "3"]))
    #expect(try Arguments.parse(["record", "start", "--output=/tmp/a.mp4", "--max-duration=5"])
      == Arguments.parse(["record", "start", "--output", "/tmp/a.mp4", "--max-duration", "5"]))
    #expect(try Arguments.parse(["record", "status", "--port=8100", "--json"]) == Arguments.parse(["record", "status", "--port", "8100", "--json"]))
    #expect(try Arguments.parse(["skill", "install", "--dir=x"]) == Arguments.parse(["skill", "install", "--dir", "x"]))
    #expect(try Arguments.parse(["logs", "--since=5m", "--bundle-id=a", "--udid=SIM", "--output=a.json"])
      == Arguments.parse(["logs", "--since", "5m", "--bundle-id", "a", "--udid", "SIM", "-o", "a.json"]))
    #expect(try Arguments.parse(["crashes", "--name=a.ips", "--session=a"]) == Arguments.parse(["crashes", "--name", "a.ips", "--session", "a"]))
    #expect(try Arguments.parse(["run", "--step=ping", "--session=a"]) == Arguments.parse(["run", "--step", "ping", "--session", "a"]))
    #expect(try Arguments.parse(["tap", "--label=OK", "--type=button", "--timeout=3", "--session=a"])
      == Arguments.parse(["tap", "--label", "OK", "--type", "button", "--timeout", "3", "--session", "a"]))
    #expect(try Arguments.parse(["screenshot", "--output=/tmp/a.png", "--format=png"])
      == Arguments.parse(["screenshot", "--output", "/tmp/a.png", "--format", "png"]))
    #expect(try Arguments.parse(["swipe", "1", "2", "3", "4", "--duration=0.5"]) == Arguments.parse(["swipe", "1", "2", "3", "4", "--duration", "0.5"]))
  }

  @Test func aBadValueInTheEqualsFormIsStillBad() {
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--port=abc"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--port="]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "--label="]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "--bogus=1"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--rebuild=true"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--json=true"]) }
  }

  @Test func textToTypeIsNeverSplit() throws {
    func type(_ text: String?, keys: [String] = []) -> Command {
      .runner(RunnerControlOptions(operation: .type(text: text, keys: keys, bundleID: nil), runnerPath: nil))
    }
    // After -- everything is text, whatever it looks like.
    #expect(try Arguments.parse(["type", "--", "--x=y"]) == type("--x=y"))
    #expect(try Arguments.parse(["type", "--key=return", "--", "--json=1"]) == type("--json=1", keys: ["return"]))
    // A positional with = is text.
    #expect(try Arguments.parse(["type", "a=b"]) == type("a=b"))
    // Without -- an argument that looks like an option is an option, as it was without =.
    #expect(throws: ArgumentError.self) { try Arguments.parse(["type", "--x=y"]) }
    // stdin text is not split either.
    #expect(try Arguments.parse(["type", "--stdin"], standardInput: { Data("--x=y\n".utf8) }) == type("--x=y"))
  }
}

struct JSONFlagTests {
  @Test func everyRunnerCommandAcceptsJSONAndItChangesNothing() throws {
    let lines: [[String]] = [
      ["ping"], ["health"], ["foreground"], ["screenshot", "-o", "/tmp/a.png"], ["source", "--format", "compact"],
      ["find", "--label", "OK"], ["tap", "1", "2"], ["tap", "--label", "OK"], ["press", "1", "2"], ["swipe", "1", "2", "3", "4"],
      ["type", "hello"], ["key", "return"], ["button", "home"], ["orientation", "portrait"], ["launch", "com.example"],
      ["open", "myapp://item/1"], ["open", "https://example.com", "--bundle-id", "com.example"], ["terminate", "com.example"],
      ["shutdown"]
    ]
    for line in lines {
      let plain = try Arguments.parse(line)
      #expect(try Arguments.parse(line + ["--json"]) == plain, "\(line)")
      #expect(try Arguments.parse([line[0], "--json"] + line.dropFirst()) == plain, "\(line)")
    }
    #expect(Set(lines.map { $0[0] }) == Set(Arguments.runnerCommandOrder))
  }

  @Test func aStepTakesJSONAndEqualsToo() throws {
    #expect(try Scenario.action(["tap", "--json", "1", "2"]) == Scenario.action(["tap", "1", "2"]))
    #expect(try Scenario.action(["tap", "--label=OK", "--type=button"]) == Scenario.action(["tap", "--label", "OK", "--type", "button"]))
    #expect(try Scenario.action(["type", "--", "--x=y"]) == Scenario.action(["type", "--", "--x=y"]))
    #expect(throws: ArgumentError.self) { try Scenario.action(["tap", "--runner=a.json", "1", "2"]) }
    #expect(throws: ArgumentError.self) { try Scenario.action(["tap", "--session=a", "1", "2"]) }
    #expect(throws: ArgumentError.self) { try Scenario.action(["ping", "--help=1"]) }
    #expect(throws: ArgumentError.self) { try Scenario.action(["ping", "--json=1"]) }
  }

  @Test func theHelpSaysSo() {
    #expect(flattened(Arguments.usage(for: "tap")).contains("--json is accepted, not needed"))
    #expect(flattened(Arguments.usage).contains("--json is accepted, not needed"))
    #expect(flattened(Arguments.usage(for: "tap")).contains("Options may be written --opt value or --opt=value"))
  }
}

struct FailureJSONTests {
  private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func codesAreStableSnakeCase() {
    let expected: [RelayErrorCode: String] = [
      .runnerUnavailable: "runner_unavailable",
      .runnerTimeout: "runner_timeout",
      .runnerInfoInvalid: "runner_info_invalid",
      .runnerBadResponse: "runner_bad_response",
      .screenshotSaveFailed: "screenshot_save_failed",
      .appNotInstalled: "app_not_installed",
      .appBundleInvalid: "app_bundle_invalid",
      .appPlatformMismatch: "app_platform_mismatch",
      .appInstallFailed: "app_install_failed",
      .appUninstallFailed: "app_uninstall_failed",
      .appUninstallRefused: "app_uninstall_refused",
      .devicesUnavailable: "devices_unavailable",
      .recordingUnavailable: "recording_unavailable",
      .deviceUnavailable: "device_unavailable",
      .logsUnavailable: "logs_unavailable",
      .logsPermissionDenied: "logs_permission_denied",
      .logsFollowUnsupported: "logs_follow_unsupported",
      .logsFilterUnsupported: "logs_filter_unsupported",
      .logAppUnavailable: "log_app_unavailable",
      .logsSaveFailed: "logs_save_failed",
      .crashesUnavailable: "crashes_unavailable",
      .crashFilterUnsupported: "crash_filter_unsupported",
      .crashesSaveFailed: "crashes_save_failed"
    ]
    #expect(RelayErrorCode.allCases.count == expected.count)
    for code in RelayErrorCode.allCases {
      #expect(code.rawValue == expected[code], "\(code)")
      #expect(code.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
      // The runner's codes are the runner's.
      #expect(RunnerErrorCode(rawValue: code.rawValue) == nil, "\(code)")
    }
    #expect(AppInstallCheck.notInstalledCode == "app_not_installed")
  }

  @Test func hasTheShapeOfARunnerError() throws {
    let body = try object(CLIOutput.failureBody(.runnerUnavailable, "no runner.json found"))
    #expect(body as NSDictionary == ["ok": false, "code": "runner_unavailable", "error": "no runner.json found"] as NSDictionary)
    let data = CLIOutput.failureBody(.runnerUnavailable, "x")
    #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
  }

  @Test func noRunnerIsAJSONFailureOnTheOutputGivenWithExit3() throws {
    let pipe = Pipe()
    let result = RunnerControl.connect(runnerPath: "/nonexistent/dir/runner.json", failureOutput: pipe.fileHandleForWriting)
    guard case .failure(let failure) = result else { Issue.record("expected a failure"); return }
    #expect(failure.code == 3)
    try pipe.fileHandleForWriting.close()
    let body = try object(try #require(try pipe.fileHandleForReading.readToEnd()))
    #expect(body["ok"] as? Bool == false)
    #expect(body["code"] as? String == "runner_unavailable")
    #expect((body["error"] as? String)?.contains("/nonexistent/dir/runner.json") == true)
  }

  @Test func noConnectionIsAJSONFailureWithExit3() throws {
    // Port 1 on localhost: nothing listens.
    let connection = RunnerConnection(
      infoURL: URL(fileURLWithPath: "/tmp/runner.json"),
      info: RunnerInfo(url: "http://127.0.0.1:1/", token: "t", udid: "SIM"),
      baseURL: URL(string: "http://127.0.0.1:1/")!
    )
    let pipe = Pipe()
    let status = RunnerControl.perform(.ping, on: connection, failureOutput: pipe.fileHandleForWriting)
    #expect(status == 3)
    try pipe.fileHandleForWriting.close()
    let body = try object(try #require(try pipe.fileHandleForReading.readToEnd()))
    #expect(body["code"] as? String == "runner_unavailable")
    #expect(body["ok"] as? Bool == false)
  }

  @Test func aScreenshotToStdoutKeepsStdoutForTheImage() {
    func handle(_ operation: RunnerOperation) -> FileHandle { RunnerControl.failureHandle(for: operation) }
    #expect(handle(.screenshot(RunnerScreenshot(output: "-"))) === FileHandle.standardError)
    #expect(handle(.screenshot(RunnerScreenshot(output: "/tmp/a.png"))) === FileHandle.standardOutput)
    #expect(handle(.screenshot(RunnerScreenshot())) === FileHandle.standardOutput)
    #expect(handle(.tap(RunnerTouch(target: .point(RunnerPoint(x: 1, y: 2))))) === FileHandle.standardOutput)
  }

  @Test func aRunnerErrorIsPassedOnAsItCame() throws {
    let body = Data(#"{"ok":false,"code":"point_offscreen","error":"invalid field: x, y"}"#.utf8)
    #expect(RunnerControl.failureBody(of: RunnerResponse(status: 400, body: body, headers: [:])) == body)
  }

  @Test func aRunnerErrorThatIsNotJSONBecomesOne() throws {
    let response = RunnerResponse(status: 502, body: Data("Bad Gateway\n".utf8), headers: [:])
    let body = try object(RunnerControl.failureBody(of: response))
    #expect(body["ok"] as? Bool == false)
    #expect(body["code"] as? String == "runner_bad_response")
    #expect(body["error"] as? String == "the runner answered HTTP 502: Bad Gateway")
    #expect(body["status"] as? Int == 502)
    let empty = try object(RunnerControl.failureBody(of: RunnerResponse(status: 500, body: Data(), headers: [:])))
    #expect(empty["error"] as? String == "the runner answered HTTP 500")
  }

  @Test func requireMatchKeepsTheAnswerAndSaysElementNotFound() throws {
    let body = try object(RunnerControl.noMatchBody(Data(#"{"count":3,"elements":[]}"#.utf8)))
    #expect(body["ok"] as? Bool == false)
    #expect(body["code"] as? String == "element_not_found")
    #expect(body["error"] as? String == "no element matched")
    #expect(body["count"] as? Int == 3)
    #expect((body["elements"] as? [Any])?.isEmpty == true)
  }

  @Test func anUnreadableScenarioIsALocalFailureAndABadStepIsUsage() {
    let options = ScenarioOptions(source: .file("a.relay"), quiet: true, check: true)
    #expect(ScenarioCommand.run(options, readFile: { _ in throw CocoaError(.fileNoSuchFile) }) == 1)
    #expect(ScenarioCommand.run(options, readFile: { _ in "" }) == 2)
    #expect(ScenarioCommand.run(options, readFile: { _ in "bogus\n" }) == 2)
    #expect(ScenarioCommand.run(ScenarioOptions(source: .standardInput, quiet: true, check: true), standardInput: { Data([0xff]) }) == 1)
  }
}

/// Every line of every help text fits in `HelpText.width` characters, so a terminal of that width never wraps one.
struct HelpWidthTests {
  private var texts: [(name: String, text: String)] {
    var texts: [(String, String)] = [("relay --help", Arguments.usage), ("relay skill --help", SkillCommand.usage),
                                     ("relay runner --help", Arguments.usage(for: "runner"))]
    for name in ["start", "install", "uninstall", "devices", "doctor", "config", "bench"] {
      texts.append(("relay \(name) --help", Arguments.usage(for: name)))
    }
    for name in (Array(Arguments.runnerUsages.keys) + Array(Arguments.lifecycleUsages.keys)).sorted() {
      texts.append(("relay \(name) --help", Arguments.usage(for: name)))
    }
    return texts
  }

  @Test func noLineIsLongerThanTheWidth() {
    #expect(HelpText.width == 100)
    // The overall usage, every runner command (16), status, stop, record, run, skill, and runner.
    #expect(texts.count == 10 + Arguments.runnerUsages.count + Arguments.lifecycleUsages.count)
    for (name, text) in texts {
      for line in text.components(separatedBy: "\n") {
        #expect(line.count <= HelpText.width, "\(name): \(line.count) characters: \(line)")
      }
    }
  }

  @Test func theHelpPrintedForACommandIsThatText() throws {
    #expect(try Arguments.parse(["skill", "--help"]) == .skill(SkillOptions(action: .help)))
    for name in Arguments.lifecycleUsages.keys {
      #expect(Arguments.usage(for: name).hasPrefix("Usage:\n  relay \(name)"), "\(name)")
    }
  }

  @Test func wrappedBreaksAtSpacesAndHangs() {
    let words = (1 ... 30).map { "word\($0)" }.joined(separator: " ")
    let lines = HelpText.wrapped(words, hanging: 2, width: 40).components(separatedBy: "\n")
    #expect(lines.count > 1)
    #expect(lines.allSatisfy { $0.count <= 40 })
    #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("  w") })
    // Split up: Swift 6.3 (Xcode 26) cannot type-check it as one #expect in reasonable time.
    let rejoined: [String] = lines.joined(separator: " ").split(separator: " ").map(String.init)
    let original: [String] = words.split(separator: " ").map(String.init)
    #expect(rejoined == original)
  }
}

/// What the help says about which command to use when.
struct HelpGuidanceTests {
  @Test func shutdownIsListedAndPointsToStop() {
    #expect(Arguments.usage.contains("\n  relay shutdown\n"))
    #expect(flattened(Arguments.usage).contains("normally use relay stop"))
    #expect(Arguments.usage(for: "shutdown").hasPrefix("Usage:\n  relay shutdown\n\nNormally use relay stop."))
  }

  @Test func uninstallHasItsOwnHelp() {
    let install = flattened(Arguments.usage(for: "install"))
    let uninstall = flattened(Arguments.usage(for: "uninstall"))
    #expect(install != uninstall)
    #expect(Arguments.usage(for: "uninstall").hasPrefix("Usage:\n  relay uninstall <BUNDLE_ID>"))
    #expect(uninstall.contains("app_not_installed (exit 6)"))
    #expect(uninstall.contains("app_uninstall_refused"))
    #expect(uninstall.contains("up to \(Int(AppInstall.uninstallTimeout)) seconds"))
    for code in ["app_bundle_invalid", "app_platform_mismatch", "app_install_failed", "device_unavailable", "Exit status:"] {
      #expect(install.contains(code), "\(code)")
    }
    #expect(install.contains("up to \(Int(AppInstall.installTimeout)) seconds"))
  }

  @Test func startSaysWhatItPrintsAndHowItExits() {
    let start = flattened(Arguments.usage(for: "start"))
    for text in ["device: <name> (<udid>)", "pid: <relay start's pid>", "log: <its log>", "token: <runner.json path>",
                 "Exit status:", "--rebuild builds", "--verbose shows", "--ready-timeout is", "--port is"] {
      #expect(start.contains(text), "\(text)")
    }
    // The overall usage stays as it was.
    #expect(!flattened(Arguments.usage).contains("--rebuild builds"))
  }

  @Test func runnerCommandsSayHowLongRelayWaits() {
    let common = flattened(Arguments.runnerCommonUsage)
    #expect(common.contains("relay waits \(Int(RunnerControl.baseTimeout)) seconds"))
    #expect(common.contains("150 s in all"))
    #expect(common.contains("stays busy"))
    #expect(Int(RunnerControl.baseTimeout + RunnerOperation.applicationStateWait) == 150)
    #expect(common.contains("up to \(RelaySession.maxNameLength) letters"))
    #expect(common.contains("from 0"))
    #expect(common.contains("app_not_installed from launch, open --bundle-id, and uninstall"))
  }

  @Test func launchAndOpenPointToRelayInstall() {
    for name in ["launch", "open"] {
      let help = flattened(Arguments.usage(for: name))
      #expect(help.contains("app_not_installed (exit 6)"), "\(name)")
      #expect(help.contains("relay install <app>"), "\(name)")
      #expect(help.contains("cannot tell whether"), "\(name)")
    }
  }

  @Test func findSourceAndHealthDescribeTheirOutput() {
    let find = flattened(Arguments.usage(for: "find"))
    #expect(find.contains("\"identifier\",\"label\"") && find.contains("counts from 0"))
    let source = flattened(Arguments.usage(for: "source"))
    for flag in ["selected", "focused", "disabled", "truncated"] {
      #expect(source.contains(flag), "\(flag)")
    }
    for type in RunnerElementTree.typeNames {
      #expect(source.contains(" \(type) ") || source.hasSuffix(" \(type)") || source.contains(" \(type)\n"), "\(type)")
    }
    let health = flattened(Arguments.usage(for: "health"))
    #expect(health.contains("displays") && health.contains("display is the id"))
    let status = flattened(Arguments.usage(for: "status"))
    #expect(status.contains("--json keys:") && status.contains("processRunning"))
    #expect(flattened(Arguments.usage(for: "tap")).contains("--mode xcui"))
  }

  @Test func doctorAndRecordSayWhatFailsAndWhatDoesNot() {
    #expect(flattened(Arguments.usage(for: "doctor")).contains("does not stop relay start"))
    #expect(flattened(Arguments.usage(for: "record")).contains("two connected devices with the same name"))
  }

  @Test func pingHealthAndStatusSayHowTheyDiffer() {
    #expect(flattened(Arguments.usage(for: "ping")).contains("even while a command runs"))
    #expect(flattened(Arguments.usage(for: "ping")).contains("relay health"))
    #expect(flattened(Arguments.usage(for: "health")).contains("exit 5 (busy)"))
    #expect(flattened(Arguments.usage(for: "health")).contains("relay ping answers even then"))
    #expect(flattened(Arguments.usage(for: "status")).contains("Unlike relay ping"))
    #expect(flattened(Arguments.usage).contains("ping, health, and status:"))
  }

  @Test func theOrderOfTheSearchHasNoCurrentDirectory() {
    for text in [Arguments.usage, Arguments.usage(for: "tap")] {
      #expect(flattened(text).contains("else ~/.relay/runner.json"))
      #expect(flattened(text).contains("A .relay/runner.json in the current directory is not read"))
      #expect(!flattened(text).contains("or a parent"))
    }
  }
}

/// One format for every `--json` output: one line, sorted keys, slashes as they are.
struct JSONFormatTests {
  @Test func oneLineSortedWithoutEscapedSlashes() throws {
    let data = CLIOutput.json(["b": "a/b", "a": 1, "list": [["z": 1, "y": 2]]])
    #expect(String(decoding: data, as: UTF8.self) == #"{"a":1,"b":"a/b","list":[{"y":2,"z":1}]}"#)
    #expect(String(decoding: CLIOutput.failureBody(.devicesUnavailable, "x/y"), as: UTF8.self)
      == #"{"code":"devices_unavailable","error":"x/y","ok":false}"#)
    let noMatch = RunnerControl.noMatchBody(Data(#"{"count":0,"elements":[],"note":"a/b"}"#.utf8))
    #expect(String(decoding: noMatch, as: UTF8.self).contains(#""note":"a/b""#))
    #expect(!String(decoding: noMatch, as: UTF8.self).contains("\n"))
  }
}

/// `relay <cmd> --help`, `-h`, and `relay help <cmd>` work for every subcommand.
struct EveryCommandHasHelpTests {
  @Test func helpIsAnswerWithExitZeroOnStdout() throws {
    for name in Arguments.commandNames.sorted() {
      for form in [[name, "--help"], [name, "-h"], ["help", name]] {
        let command = try Arguments.parse(form)
        switch command {
        case .commandHelp(let shown): #expect(shown == name, "\(form)")
        case .skill(let options): #expect(name == "skill" && options.action == .help, "\(form)")
        default: Issue.record("\(form) parsed as \(command)")
        }
      }
    }
    // An option before it, or after other arguments, still asks for help.
    #expect(try Arguments.parse(["start", "--simulator", "--help"]) == .commandHelp("start"))
    #expect(try Arguments.parse(["bench", "--count", "3", "-h"]) == .commandHelp("bench"))
  }

  @Test func theTextHasTheSynopsisAndTheDescription() throws {
    let start = Arguments.usage(for: "start")
    #expect(start.hasPrefix("Usage:\n  relay start [--udid"))
    #expect(start.contains("Builds the RelayRunner XCTest runner"))
    // Only its own entry and its details: not the next entry (status).
    #expect(!start.contains("The check after relay start"))
    for name in ["install", "uninstall", "devices", "doctor", "config", "bench"] {
      let text = Arguments.usage(for: name)
      #expect(text.hasPrefix("Usage:\n  relay \(name)"), "\(name)")
      #expect(text.components(separatedBy: "\n\n").count == 2, "\(name)")
    }
    // Only its own entry: the next one (run) does not follow bench.
    #expect(!Arguments.usage(for: "bench").contains("one process"))
    #expect(!Arguments.usage(for: "start").contains("Records the screen"))
    #expect(Arguments.usage(for: "uninstall").contains("relay uninstall"))
    #expect(Arguments.usage(for: "uninstall").contains("<BUNDLE_ID>"))
    // relay runner has its own text, like relay skill.
    #expect(Arguments.usage(for: "runner") == InstallCommand.usage)
    #expect(InstallCommand.usage.hasPrefix("Usage:\n  relay runner install"))
  }
}
