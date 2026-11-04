import Foundation
@testable import relay
import Testing

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
            ["bogus"], ["record", "bogus"], ["skill", "bogus"], ["config", "get", "nope"], ["run"], ["bench"]
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
        // A command without help of its own points to the general one.
        #expect(CLIOutput.usageMessage("--port requires a valid TCP port", command: "start")
            == "relay: --port requires a valid TCP port\nrelay: see relay --help\n")
        for name in ["status", "stop", "record", "run", "skill"] + Arguments.runnerCommandOrder {
            #expect(Arguments.helpCommand(for: name) == "relay \(name) --help", "\(name)")
        }
        for name in ["start", "devices", "doctor", "config", "install", "bench", "bogus"] {
            #expect(Arguments.helpCommand(for: name) == "relay --help", "\(name)")
        }
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
            ["terminate", "com.example"], ["shutdown"]
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
        #expect(Arguments.usage(for: "tap").contains("--json is accepted and not needed"))
        #expect(Arguments.usage.contains("--json is accepted and not needed"))
        #expect(Arguments.usage(for: "tap").contains("Options may be written --opt value or --opt=value"))
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
            .devicesUnavailable: "devices_unavailable",
            .recordingUnavailable: "recording_unavailable",
            .failed: "failed"
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
