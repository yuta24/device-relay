import Foundation
@testable import Relay
import Testing

struct ArgumentsTests {
  @Test func parsesStartOptions() throws {
    let command = try Arguments.parse(["start", "--udid", "ABC", "--port", "9000", "--team-id", "ABCDE12345", "--rebuild"])
    var expected = StartOptions(udid: "ABC", port: 9000, portGiven: true, teamID: "ABCDE12345")
    expected.rebuild = true
    #expect(command == .start(expected))
  }

  @Test func startPicksTheDeviceWithoutUDID() throws {
    #expect(try Arguments.parse(["start"]) == .start(StartOptions()))
    #expect(try Arguments.parse(["start", "--device", "iPhone 17", "--project", "../relay"])
      == .start(StartOptions(device: "iPhone 17", project: "../relay")))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--udid", "A", "--device", "B"]) }
  }

  @Test func startAndDoctorNarrowTheCandidates() throws {
    #expect(try Arguments.parse(["start", "--simulator", "--os", "26.5"]) == .start(StartOptions(simulator: true, os: "26.5")))
    #expect(try Arguments.parse(["start", "--device", "iPhone 17", "--os", "27"]) == .start(StartOptions(device: "iPhone 17", os: "27")))
    #expect(try Arguments.parse(["doctor", "--simulator"]) == .doctor(DoctorOptions(simulator: true)))
    #expect(try Arguments.parse(["doctor", "--os", "27.0"]) == .doctor(DoctorOptions(os: "27.0")))
    #expect(try Arguments.parse(["devices", "--os", "26"]) == .devices(json: false, os: "26"))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--os", "iOS 27"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["doctor", "--os"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["devices", "--os", "latest"]) }
  }

  @Test func rejectsMalformedTeamID() {
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--team-id", "TEAM"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--team-id", "abcde12345"]) }
  }

  @Test func parsesSetupCommands() throws {
    #expect(try Arguments.parse(["devices"]) == .devices(json: false, os: nil))
    #expect(try Arguments.parse(["devices", "--json"]) == .devices(json: true, os: nil))
    #expect(try Arguments.parse(["doctor", "--device", "iPad"]) == .doctor(DoctorOptions(device: "iPad")))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["doctor", "--udid", "A", "--device", "B"]) }
    #expect(try Arguments.parse(["config"]) == .config(ConfigOptions(action: .show)))
    #expect(try Arguments.parse(["config", "set", "teamID", "ABCDE12345"]) == .config(ConfigOptions(action: .set("teamID", "ABCDE12345"))))
    #expect(try Arguments.parse(["config", "unset", "teamID"]) == .config(ConfigOptions(action: .unset("teamID"))))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "get", "team"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "set", "teamID"]) }
  }

  @Test func rejectsInvalidPort() {
    #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--udid", "A", "--port", "70000"]) }
  }

  @Test func parsesBenchTap() throws {
    let command = try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--count", "3", "--tap", "10,20.5"])
    var expected = BenchOptions(url: "http://127.0.0.1:8100", count: 3)
    expected.tap = (10, 20.5)
    #expect(command == .bench(expected))
  }

  @Test func parsesBenchMode() throws {
    let command = try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--tap", "1,2", "--mode", "xcui"])
    var expected = BenchOptions(url: "http://127.0.0.1:8100")
    expected.tap = (1, 2)
    expected.mode = "xcui"
    #expect(command == .bench(expected))
  }

  @Test func rejectsUnknownBenchMode() {
    #expect(throws: ArgumentError.self) {
      try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--mode", "fast"])
    }
  }

  @Test func parsesBenchToken() throws {
    let command = try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--token", "abc"])
    var expected = BenchOptions(url: "http://127.0.0.1:8100")
    expected.token = "abc"
    #expect(command == .bench(expected))
  }

  @Test func parsesAllowWiFi() throws {
    #expect(try Arguments.parse(["start", "--udid", "A"]) == .start(StartOptions(udid: "A")))
    var expected = StartOptions(udid: "A")
    expected.allowWiFi = true
    #expect(try Arguments.parse(["start", "--udid", "A", "--allow-wifi"]) == .start(expected))
  }

  @Test func noArgumentsShowsHelp() throws {
    #expect(try Arguments.parse([]) == .help)
  }
}

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct BackgroundArgumentsTests {
  @Test func backgroundIsAStartOption() throws {
    guard case .start(let options) = try Arguments.parse(["start", "--background", "--device", "iPhone 17 Pro"]) else {
      Issue.record("not start")
      return
    }
    #expect(options.background)
    #expect(options.device == "iPhone 17 Pro")
  }

  @Test func foregroundArgumentsParseBackToTheSameOptions() throws {
    var options = StartOptions()
    options.udid = "SIM"
    options.simulator = true
    options.os = "27.0"
    options.project = "/tmp/device relay"
    options.port = 8123
    options.portGiven = true
    options.session = "agent-1"
    options.teamID = "TEAM000001"
    options.rebuild = true
    options.verbose = true
    options.readyTimeout = 42.5
    options.allowWiFi = true
    options.background = true

    let arguments = options.foregroundArguments
    #expect(arguments.first == "start")
    #expect(!arguments.contains("--background"))
    var expected = options
    expected.background = false
    #expect(try Arguments.parse(arguments) == .start(expected))
  }

  @Test func foregroundArgumentsOfDefaults() throws {
    #expect(try Arguments.parse(StartOptions().foregroundArguments) == .start(StartOptions()))
  }

  @Test func statusAndStop() throws {
    #expect(try Arguments.parse(["status"]) == .status(RunnerStatusOptions()))
    #expect(try Arguments.parse(["status", "--json"]) == .status(RunnerStatusOptions(json: true)))
    #expect(try Arguments.parse(["status", "--runner", "r.json"]) == .status(RunnerStatusOptions(runnerPath: "r.json")))
    #expect(try Arguments.parse(["stop"]) == .stop(RunnerStopOptions()))
    #expect(try Arguments.parse(["stop", "--runner", "r.json"]) == .stop(RunnerStopOptions(runnerPath: "r.json")))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["stop", "--json"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["status", "now"]) }
  }

  @Test func helpForStatusAndStop() throws {
    #expect(try Arguments.parse(["stop", "--help"]) == .commandHelp("stop"))
    #expect(try Arguments.parse(["help", "status"]) == .commandHelp("status"))
    #expect(Arguments.usage(for: "status").contains("relay status [--json]"))
    #expect(Arguments.usage(for: "stop").contains("not running"))
    #expect(Arguments.usage(for: "stop").contains("within \(Int(RunnerStop.exitTimeout)) seconds"))
    #expect(Arguments.usage.contains("relay start --background"))
    #expect(Arguments.usage.contains("relay stop [--runner <PATH> | --session <NAME> | --all]"))
  }
}

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

struct SessionArgumentTests {
  @Test func startTakesASessionAndRemembersAGivenPort() throws {
    guard case .start(let options) = try Arguments.parse(["start", "--session", "agent-1"]) else {
      Issue.record("not start")
      return
    }
    #expect(options.session == "agent-1")
    #expect(!options.portGiven)
    guard case .start(let given) = try Arguments.parse(["start", "--session", "a", "--port", "8100"]) else {
      Issue.record("not start")
      return
    }
    #expect(given.portGiven)
    #expect(given.port == 8100)
  }

  @Test func aPickedPortGoesToTheDetachedStart() throws {
    var options = StartOptions(session: "a")
    #expect(!options.foregroundArguments.contains("--port"))
    options.port = 8123
    options.portGiven = true
    #expect(try Arguments.parse(options.foregroundArguments) == .start(options))
  }

  @Test func everyCommandThatUsesARunnerTakesASession() throws {
    #expect(try Arguments.parse(["status", "--session", "a"]) == .status(RunnerStatusOptions(session: "a")))
    #expect(try Arguments.parse(["stop", "--session", "a"]) == .stop(RunnerStopOptions(session: "a")))
    #expect(try Arguments.parse(["ping", "--session", "a"]) == .runner(RunnerControlOptions(operation: .ping, session: "a")))
    #expect(try Arguments.parse(["run", "--step", "ping", "--session", "a"])
      == .run(ScenarioOptions(source: .steps(["ping"]), session: "a")))
    #expect(try Arguments.parse(["record", "stop", "--session", "a"]) == .record(RecordOptions(action: .stop, session: "a")))
    #expect(try Arguments.parse(["record", "status", "--session", "a"]) == .record(RecordOptions(action: .status(json: false), session: "a")))
    var bench = BenchOptions(url: "")
    bench.session = "a"
    #expect(try Arguments.parse(["bench", "--session", "a"]) == .bench(bench))
  }

  @Test func invalidNamesAndTwoSelectorsAreErrors() {
    for arguments in [
      ["start", "--session", "../x"], ["status", "--session", "a/b"], ["ping", "--session", ".."], ["run", "--step", "ping", "--session", ".."],
      ["status", "--session", "a", "--runner", "r.json"], ["ping", "--session", "a", "--runner", "r.json"],
      ["run", "--step", "ping", "--session", "a", "--runner", "r.json"],
      ["record", "stop", "--session", "a", "--port", "8101"], ["record", "stop", "--session", "a", "--runner", "r.json"],
      ["status", "--all", "--session", "a"], ["stop", "--all", "--runner", "r.json"]
    ] {
      #expect(throws: ArgumentError.self, "\(arguments)") { try Arguments.parse(arguments) }
    }
  }

  @Test func allIsAnOptionOfStatusAndStop() throws {
    #expect(try Arguments.parse(["status", "--all", "--json"]) == .status(RunnerStatusOptions(json: true, all: true)))
    #expect(try Arguments.parse(["stop", "--all"]) == .stop(RunnerStopOptions(all: true)))
  }

  @Test func aStepCannotNameASession() {
    #expect {
      _ = try Scenario.parse([(1, "tap 1 2 --session a")])
    } throws: { "\($0)".contains("--session goes to relay run") }
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
