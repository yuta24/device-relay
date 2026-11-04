import Foundation
@testable import relay
import Testing

struct ScenarioTokenizerTests {
    @Test func splitsOnSpacesAndTabs() throws {
        #expect(try ScenarioTokenizer.split("tap  --label General\t--type button") == ["tap", "--label", "General", "--type", "button"])
        #expect(try ScenarioTokenizer.split("   ") == [])
        #expect(try ScenarioTokenizer.split("") == [])
    }

    @Test func keepsQuotedTextAsOneWord() throws {
        #expect(try ScenarioTokenizer.split("type 'hello world'") == ["type", "hello world"])
        #expect(try ScenarioTokenizer.split("tap --label \"Sign In\" --type button") == ["tap", "--label", "Sign In", "--type", "button"])
        // Quotes inside a word join it, as in a shell.
        #expect(try ScenarioTokenizer.split("type a'b c'd") == ["type", "ab cd"])
        #expect(try ScenarioTokenizer.split("type ''") == ["type", ""])
        // Nothing is special inside '...'; a # is text, not a comment.
        #expect(try ScenarioTokenizer.split("type '\\n \"x\" # $HOME'") == ["type", "\\n \"x\" # $HOME"])
        #expect(try ScenarioTokenizer.split("type a#b # c") == ["type", "a#b", "#", "c"])
    }

    @Test func handlesBackslashes() throws {
        #expect(try ScenarioTokenizer.split("type hello\\ world") == ["type", "hello world"])
        #expect(try ScenarioTokenizer.split("type \\'") == ["type", "'"])
        // In "...", \ escapes only " and \.
        #expect(try ScenarioTokenizer.split("type \"say \\\"hi\\\" \\\\ \\n\"") == ["type", "say \"hi\" \\ \\n"])
    }

    @Test func rejectsUnterminatedQuotesAndTrailingBackslash() {
        for line in ["type 'abc", "type \"abc", "type \"abc\\\"", "type abc\\"] {
            #expect(throws: ArgumentError.self, "\(line)") { try ScenarioTokenizer.split(line) }
        }
    }
}

struct ScenarioParseTests {
    private func parse(_ text: String) throws -> [ScenarioStep] {
        try Scenario.parse(Scenario.lines(of: text))
    }

    private func lineErrors(_ text: String) -> [ScenarioLineError] {
        do {
            _ = try parse(text)
        } catch let error as ScenarioLineErrors {
            return error.errors
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        return []
    }

    @Test func skipsBlankLinesAndCommentsAndKeepsLineNumbers() throws {
        let steps = try parse("""
        # log in
        launch com.example.app

          # indented comment
        tap --label "Sign In" --type button --timeout 5\r
        sleep 0.5
        """)
        #expect(steps == [
            ScenarioStep(line: 2, text: "launch com.example.app", action: .runner(.launch(bundleID: "com.example.app"))),
            ScenarioStep(line: 5, text: "tap --label \"Sign In\" --type button --timeout 5", action: .runner(.tap(RunnerTouch(
                target: .element(try RunnerElementSelector(json: ["label": "Sign In", "type": "button"])), timeout: 5)))),
            ScenarioStep(line: 6, text: "sleep 0.5", action: .sleep(0.5))
        ])
    }

    @Test func parsesStepsAsTheRunnerCommands() throws {
        let steps = try parse("""
        find --id next --timeout 5
        type 'hello world' --key return
        type -- -dash
        swipe 200 700 200 200 --duration 0.3
        screenshot -o step.jpg --scale 1
        source --format compact --filter interactive
        """)
        #expect(steps.map(\.action) == [
            .runner(.find(try RunnerElementSelector(json: ["identifier": "next"]), limit: nil, timeout: 5, bundleID: nil)),
            .runner(.type(text: "hello world", keys: ["return"], bundleID: nil)),
            .runner(.type(text: "-dash", keys: [], bundleID: nil)),
            .runner(.swipe(from: RunnerPoint(x: 200, y: 700), to: RunnerPoint(x: 200, y: 200), duration: 0.3, hold: nil, mode: nil)),
            .runner(.screenshot(RunnerScreenshot(format: "jpeg", scale: 1, output: "step.jpg"))),
            .runner(.source(format: "compact", maxDepth: nil, filter: "interactive", bundleID: nil))
        ])
    }

    @Test func reportsEveryBadLineWithItsNumber() {
        let errors = lineErrors("""
        ping
        tap --label
        # fine
        key tab
        find --id ok
        """)
        #expect(errors.map(\.line) == [2, 4])
        #expect(errors[0].reason == "--label requires a value")
        #expect(errors[1].reason.contains("unsupported key 'tab'"))
        #expect(ScenarioLineErrors(errors: errors).description.hasPrefix("line 2: --label requires a value\nrelay: line 4: "))
    }

    @Test func rejectsCommandsThatAreNotRunnerSteps() {
        for command in ["start --background", "stop", "status", "install", "uninstall", "doctor", "devices", "skill status", "bench",
                        "run x", "config", "shutdown"] {
            let errors = lineErrors(command)
            #expect(errors.count == 1, "\(command)")
            #expect(errors.first?.reason.hasPrefix("\(command.split(separator: " ")[0]) cannot be a step") == true, "\(command)")
        }
        // Every command relay knows that is not a step, so a new subcommand is never called unknown.
        for name in Arguments.commandNames.subtracting(Scenario.stepCommands).sorted() {
            #expect(lineErrors(name).first?.reason.hasPrefix("\(name) cannot be a step") == true, "\(name)")
        }
        #expect(lineErrors("frobnicate").first?.reason.hasPrefix("unknown step: frobnicate") == true)
        #expect(lineErrors("relay tap 1 2").first?.reason.contains("without the leading relay") == true)
    }

    @Test func rejectsOptionsThatBelongToRelayRun() {
        #expect(lineErrors("health --runner a.json").first?.reason == "--runner goes to relay run, not to a step")
        #expect(lineErrors("tap --help").first?.reason == "--help cannot be a step")
        #expect(lineErrors("type --stdin").first?.reason.contains("type --stdin cannot be a step") == true)
        // After --, they are text to type.
        #expect(throws: Never.self) { try parse("type -- --runner") }
    }

    @Test func screenshotNeedsAnOutputFile() throws {
        #expect(lineErrors("screenshot").first?.reason.contains("needs --output") == true)
        #expect(lineErrors("screenshot -o -").first?.reason.contains("needs --output") == true)
        #expect(try parse("screenshot --output a.png").map(\.action) == [.runner(.screenshot(RunnerScreenshot(output: "a.png")))])
    }

    @Test func sleepTakesSecondsUpToTheLimit() throws {
        #expect(try parse("sleep 60").map(\.action) == [.sleep(60)])
        #expect(try parse("sleep 0.01").map(\.action) == [.sleep(0.01)])
        for bad in ["sleep", "sleep 0", "sleep -1", "sleep 60.5", "sleep abc", "sleep nan", "sleep inf", "sleep 1 2"] {
            #expect(lineErrors(bad).count == 1, "\(bad)")
        }
    }

    @Test func requiresAtLeastOneStep() {
        #expect(throws: ArgumentError.self) { try parse("# only a comment\n\n") }
    }

    @Test func numbersStepsByTheirPosition() throws {
        let lines = try ScenarioCommand.lines(.steps(["ping", "health"]), readFile: { _ in "" }, standardInput: { Data() })
        #expect(lines.map(\.number) == [1, 2])
        #expect(throws: ScenarioLineErrors.self) {
            try ScenarioCommand.lines(.steps(["ping", "tap 1 2\nping"]), readFile: { _ in "" }, standardInput: { Data() })
        }
        let file = try ScenarioCommand.lines(.file("a.txt"), readFile: { _ in "ping\nhealth\n" }, standardInput: { Data() })
        #expect(file.map(\.text) == ["ping", "health", ""])
        let input = try ScenarioCommand.lines(.standardInput, readFile: { _ in "" }, standardInput: { Data("ping".utf8) })
        #expect(input.map(\.text) == ["ping"])
        #expect(throws: SetupError.self) {
            try ScenarioCommand.lines(.file("missing"), readFile: { _ in throw CocoaError(.fileNoSuchFile) }, standardInput: { Data() })
        }
    }
}

struct ScenarioArgumentsTests {
    @Test func takesExactlyOneSource() throws {
        #expect(try Arguments.parse(["run", "login.txt"]) == .run(ScenarioOptions(source: .file("login.txt"))))
        #expect(try Arguments.parse(["run", "-"]) == .run(ScenarioOptions(source: .standardInput)))
        #expect(try Arguments.parse(["run", "--step", "ping", "--step", "type -x", "--runner", "a.json", "--quiet"])
            == .run(ScenarioOptions(source: .steps(["ping", "type -x"]), runnerPath: "a.json", quiet: true)))
        for invalid in [["run"], ["run", "a.txt", "b.txt"], ["run", "a.txt", "--step", "ping"], ["run", "-", "--step", "ping"],
                        ["run", "-", "a.txt"], ["run", "--step"], ["run", "--bogus"], ["run", "a.txt", "--runner", "a", "--runner", "b"]] {
            #expect(throws: ArgumentError.self, "\(invalid)") { try Arguments.parse(invalid) }
        }
    }

    @Test func hasItsOwnHelp() throws {
        #expect(try Arguments.parse(["run", "--help"]) == .commandHelp("run"))
        #expect(try Arguments.parse(["help", "run"]) == .commandHelp("run"))
        #expect(Arguments.usage(for: "run").contains("Experimental"))
        #expect(Arguments.usage.contains("relay run (<file> | - | --step <step>...)"))
        #expect(Arguments.helpCommand(for: "run") == "relay run --help")
    }
}

struct ScenarioExecuteTests {
    private func step(_ line: Int, _ text: String) throws -> ScenarioStep {
        ScenarioStep(line: line, text: text, action: try Scenario.action(ScenarioTokenizer.split(text)))
    }

    /// A clock that moves 10 ms each time it is read.
    private func clock() -> () -> UInt64 {
        var time: UInt64 = 0
        return {
            time += 10_000_000
            return time
        }
    }

    @Test func runsEveryStepInOrder() throws {
        let steps = try [step(1, "launch com.example"), step(3, "sleep 0.5"), step(4, "tap 1 2"), step(5, "ping")]
        var performed: [RunnerOperation] = []
        var slept: [TimeInterval] = []
        var logged: [String] = []
        let status = Scenario.execute(steps, perform: { operation, _ in performed.append(operation); return 0 }, sleep: { slept.append($0) },
                                      now: clock(), log: { logged.append($0) })
        #expect(status == 0)
        #expect(performed == [.launch(bundleID: "com.example"), .tap(RunnerTouch(target: .point(RunnerPoint(x: 1, y: 2)))), .ping])
        #expect(slept == [0.5])
        #expect(logged == [
            "[1/4] launch com.example ... ok (10 ms)",
            "[2/4] sleep 0.5 ... ok (10 ms)",
            "[3/4] tap 1 2 ... ok (10 ms)",
            "[4/4] ping ... ok (10 ms)",
            "4 of 4 steps succeeded in 90 ms"
        ])
    }

    @Test func stopsAtTheFirstFailureWithItsStatus() throws {
        let steps = try [step(1, "ping"), step(2, "find --id next --timeout 5"), step(7, "sleep 1"), step(8, "ping")]
        for code in [RunnerExitCode.usage, .unavailable, .unauthorized, .busy, .actionFailed, .badRequest, .runnerError] {
            var performed = 0
            var slept = false
            var logged: [String] = []
            let status = Scenario.execute(steps, perform: { _, _ in
                performed += 1
                return performed == 2 ? code.rawValue : 0
            }, sleep: { _ in slept = true }, now: clock(), log: { logged.append($0) })
            #expect(status == code.rawValue)
            #expect(performed == 2)
            #expect(!slept)
            #expect(logged.contains("step 2/4 (line 2) failed: find --id next --timeout 5"))
            #expect(logged.last?.hasPrefix("1 of 4 steps succeeded") == true)
        }
    }

    @Test func quietLeavesOnlyTheFailure() throws {
        let steps = try [step(1, "ping"), step(2, "health")]
        var logged: [String] = []
        #expect(Scenario.execute(steps, quiet: true, perform: { _, _ in 0 }, now: clock(), log: { logged.append($0) }) == 0)
        #expect(logged.isEmpty)
        #expect(Scenario.execute(steps, quiet: true, perform: { operation, _ in operation == .health ? 6 : 0 }, now: clock(), log: { logged.append($0) }) == 6)
        #expect(logged == ["step 2/2 (line 2) failed: health"])
    }
}

struct ScenarioFindCheckTests {
    @Test func requireIsAFlagOfFindOnly() throws {
        let selector = try RunnerElementSelector(json: ["identifier": "a"])
        #expect(try Arguments.parse(["find", "--id", "a", "--require", "--timeout", "5"])
            == .runner(RunnerControlOptions(operation: .find(selector, limit: nil, timeout: 5, bundleID: nil), runnerPath: nil, requireMatch: true)))
        // Without it, relay find keeps exiting 0 on no match.
        #expect(try Arguments.parse(["find", "--id", "a"])
            == .runner(RunnerControlOptions(operation: .find(selector, limit: nil, timeout: nil, bundleID: nil), runnerPath: nil)))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "--id", "a", "--require"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--require"]) }
    }

    @Test func aStepMeansWhatTheCommandMeansAlone() throws {
        let selector = try RunnerElementSelector(json: ["identifier": "a"])
        let steps = try Scenario.parse(Scenario.lines(of: "find --id a --timeout 5\nfind --id a --timeout 5 --require"))
        #expect(steps.map(\.action) == [
            .runner(.find(selector, limit: nil, timeout: 5, bundleID: nil), requireMatch: false),
            .runner(.find(selector, limit: nil, timeout: 5, bundleID: nil), requireMatch: true)
        ])
        var required: [Bool] = []
        #expect(Scenario.execute(steps, perform: { _, requireMatch in required.append(requireMatch); return 0 }, log: { _ in }) == 0)
        #expect(required == [false, true])
    }

    /// `relay run` sends each step with `RunnerControl.perform`, so a step gets the timeout the command gets alone.
    @Test func aStepWaitsAsLongAsTheCommandAlone() throws {
        let steps = try Scenario.parse(Scenario.lines(of: "launch com.example\ntype hello --key return\nterminate com.example"))
        let waits = steps.compactMap { step -> TimeInterval? in
            if case .runner(let operation, _) = step.action { return operation.waitTime }
            return nil
        }
        #expect(waits.count == 3)
        #expect(waits[0] == 120 && waits[2] == 120)
        #expect(abs(waits[1] - 1.5) < 1e-9)
    }

    @Test func looksAtTheElementsNotTheCount() {
        #expect(RunnerControl.hasElements(Data(#"{"ok":true,"count":1,"elements":[{"type":"button"}]}"#.utf8)))
        #expect(!RunnerControl.hasElements(Data(#"{"ok":true,"count":0,"elements":[]}"#.utf8)))
        // --index out of range: count is the number of matches, elements is empty.
        #expect(!RunnerControl.hasElements(Data(#"{"ok":true,"count":2,"elements":[]}"#.utf8)))
        #expect(!RunnerControl.hasElements(Data("not json".utf8)))
    }
}

struct ScenarioDisplayTests {
    private func shown(_ line: String) throws -> String {
        try #require(Scenario.parse(Scenario.lines(of: line)).first).text
    }

    @Test func masksTheTextOfTypeSteps() throws {
        #expect(try shown("type 'hunter 2' --key return") == "type *** --key return")
        #expect(try shown("type --bundle-id com.example \"p@ss\"") == "type --bundle-id com.example ***")
        #expect(try shown("type -- --secret") == "type -- ***")
        #expect(try shown("type --key delete") == "type --key delete")
        // Negative numbers are text, as relay type reads them.
        #expect(try shown("type -42") == "type ***")
    }

    @Test func showsOtherStepsAsWritten() throws {
        #expect(try shown("  tap --label \"Sign In\" --type button  ") == "tap --label \"Sign In\" --type button")
    }

    @Test func masksTheTextInTheFailureLineToo() throws {
        let steps = try Scenario.parse(Scenario.lines(of: "type secret"))
        var logged: [String] = []
        #expect(Scenario.execute(steps, perform: { _, _ in 6 }, log: { logged.append($0) }) == 6)
        #expect(logged.allSatisfy { !$0.contains("secret") })
        #expect(logged.first == "step 1/1 (line 1) failed: type ***")
    }

    @Test func takesOptionValuesThatLookLikeHelpAsValues() throws {
        #expect(Scenario.optionWords("tap", ["--label", "-h", "--type", "button"]) == ["--label", "--type"])
        #expect(Scenario.optionWords("type", ["-h"]) == ["-h"])
        #expect(Scenario.optionWords("type", ["--", "--runner", "-h"]) == [])
        #expect(try Scenario.parse(Scenario.lines(of: "tap --label -h --type button")).count == 1)
        #expect(throws: ScenarioLineErrors.self) { try Scenario.parse(Scenario.lines(of: "tap -h")) }
        #expect(throws: ScenarioLineErrors.self) { try Scenario.parse(Scenario.lines(of: "screenshot -o a.png --help")) }
    }
}

struct ScenarioFormatTests {
    private func lineErrors(_ text: String) -> [ScenarioLineError] {
        do {
            _ = try Scenario.parse(Scenario.lines(of: text))
        } catch let error as ScenarioLineErrors {
            return error.errors
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        return []
    }

    @Test func readsTheFormatLineBeforeTheFirstStep() throws {
        #expect(try Scenario.parse(Scenario.lines(of: "# relay-run: 1\nping")).map(\.line) == [2])
        #expect(try Scenario.parse(Scenario.lines(of: "# login\n\n  #relay-run:1  \nping")).map(\.line) == [4])
        // Without it, the scenario is read as the current format.
        #expect(try Scenario.parse(Scenario.lines(of: "ping")).count == 1)
        // Other comments that only look alike stay comments.
        #expect(try Scenario.parse(Scenario.lines(of: "# relay-run notes\n# relay-runner: 2\nping")).count == 1)
    }

    @Test func refusesAnotherFormatOrAMisplacedLine() {
        #expect(lineErrors("# relay-run: 2\nping") == [ScenarioLineError(line: 1, reason: "unsupported scenario format 2 (this relay reads 1)")])
        #expect(lineErrors("# relay-run:\nping").first?.reason.contains("requires a format version") == true)
        #expect(lineErrors("# relay-run: 1.0\nping").map(\.line) == [1])
        #expect(lineErrors("ping\n# relay-run: 1") == [ScenarioLineError(line: 2, reason: "# relay-run: goes before the first step")])
        // A bad step before it still counts as a step.
        #expect(lineErrors("pong\n# relay-run: 1").map(\.line) == [1, 2])
    }

    @Test func parsesCheck() throws {
        #expect(try Arguments.parse(["run", "a.relay", "--check"]) == .run(ScenarioOptions(source: .file("a.relay"), check: true)))
        #expect(try Arguments.parse(["run", "--check", "--step", "ping", "-q"])
            == .run(ScenarioOptions(source: .steps(["ping"]), quiet: true, check: true)))
    }

    @Test func checkRunsNothingAndNeedsNoRunner() {
        // A runner.json that does not exist would be exit 3 if relay run tried to connect.
        let options = ScenarioOptions(source: .file("a.relay"), runnerPath: "/nonexistent/runner.json", quiet: true, check: true)
        #expect(ScenarioCommand.run(options, readFile: { _ in "# relay-run: 1\ntap 1 2\nsleep 1\n" }) == 0)
        #expect(ScenarioCommand.run(options, readFile: { _ in "tap 1\n" }) == 2)
        #expect(ScenarioCommand.run(options, readFile: { _ in "# relay-run: 9\nping\n" }) == 2)
        #expect(ScenarioCommand.checkedSummary(1) == "1 step checked; nothing was run")
        #expect(ScenarioCommand.checkedSummary(3) == "3 steps checked; nothing was run")
    }
}

struct ScenarioByteOrderMarkTests {
    @Test func dropsALeadingByteOrderMark() throws {
        #expect(Scenario.lines(of: "\u{FEFF}ping\nhealth").map(\.text) == ["ping", "health"])
        #expect(Scenario.lines(of: "\u{FEFF}# relay-run: 1\r\nping\r\n").map(\.text) == ["# relay-run: 1", "ping", ""])
        // Only at the very start; elsewhere it stays text.
        #expect(Scenario.lines(of: "ping\n\u{FEFF}health").map(\.text) == ["ping", "\u{FEFF}health"])
        #expect(Scenario.lines(of: "\u{FEFF}").map(\.text) == [""])
    }

    @Test func readsFilesAndStandardInputWithAByteOrderMark() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let input = try ScenarioCommand.lines(.standardInput, readFile: { _ in "" }, standardInput: { bom + Data("# relay-run: 1\nping\n".utf8) })
        #expect(try Scenario.parse(input).map(\.line) == [2])
        let file = try ScenarioCommand.lines(.file("a.relay"), readFile: { _ in "\u{FEFF}launch com.example\n" }, standardInput: { Data() })
        #expect(try Scenario.parse(file).map(\.action) == [.runner(.launch(bundleID: "com.example"))])
        // The format line is still found when the file starts with a mark.
        let versioned = try ScenarioCommand.lines(.file("a.relay"), readFile: { _ in "\u{FEFF}# relay-run: 2\nping\n" }, standardInput: { Data() })
        #expect(throws: ScenarioLineErrors.self) { try Scenario.parse(versioned) }
    }
}

struct CommandNamesTests {
    @Test func theUsageListsEveryCommandOfTheTable() {
        for entry in Arguments.commandSynopses {
            for name in entry.names {
                #expect(entry.synopsis.contains("relay \(name)"), "\(name)")
                #expect(Arguments.usage.contains(entry.synopsis.components(separatedBy: "\n")[0]), "\(name)")
            }
            // A command shown in a synopsis has its name in the table.
            let shown = entry.synopsis.components(separatedBy: "relay ").dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) }
            #expect(Set(shown).isSubset(of: entry.names), "\(shown)")
        }
    }

    @Test func everyNameIsACommandArgumentsParses() {
        for name in Arguments.commandNames.sorted() {
            do {
                _ = try Arguments.parse([name], standardInput: { Data() })
            } catch {
                // Missing arguments are fine; an unknown command is not.
                #expect("\(error)" != "unknown command: \(name)", "\(name)")
            }
        }
        #expect(Arguments.commandNames.isSuperset(of: ["start", "install", "uninstall", "skill", "devices", "doctor", "config", "bench",
                                                       "status", "stop", "run", "tap", "shutdown"]))
    }
}
