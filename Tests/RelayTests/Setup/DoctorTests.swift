import Foundation
@testable import Relay
import Testing

struct DoctorTests {
  private let project: (String?) throws -> (root: URL, source: RunnerProject.Source) = { _ in (URL(fileURLWithPath: "/relay"), .environment) }

  private func jsonObject(_ options: DoctorOptions, host: FakeHost = FakeHost(), project: (String?) throws -> (root: URL, source: RunnerProject.Source))
    throws -> (status: Int32, lines: [String], object: [String: Any]) {
    var lines: [String] = []
    let status = Doctor.run(options, commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
    // With --json the one object is the only output.
    let text = try #require(lines.first)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    return (status, lines, object)
  }

  @Test func jsonIsTheOnlyOutputAndListsEveryCheck() throws {
    let result = try jsonObject(DoctorOptions(json: true), project: project)
    #expect(result.status == RunnerExitCode.success.rawValue)
    #expect(result.lines.count == 1)
    #expect(!result.lines[0].contains("\n"))
    let object = result.object
    #expect(Set(object.keys) == ["ok", "problems", "warnings", "checks"])
    #expect(object["ok"] as? Bool == true)
    #expect(object["problems"] as? Int == 0)
    let checks = try #require(object["checks"] as? [[String: Any]])
    #expect(!checks.isEmpty)
    for check in checks {
      #expect(Set(check.keys) == ["section", "name", "status", "detail", "fix"], "\(check)")
      #expect(["ok", "warning", "problem"].contains(check["status"] as? String))
      // A fix is for a check that is not ok.
      #expect((check["status"] as? String == "ok") == (check["fix"] is NSNull), "\(check)")
    }
    #expect(object["warnings"] as? Int == checks.filter { $0["status"] as? String == "warning" }.count)
    // The same checks, and the same words, as the lines for people.
    let target = try #require(checks.first { $0["name"] as? String == "target" })
    #expect(target["status"] as? String == "warning")
    #expect((target["detail"] as? String)?.contains("the only connected device") == true)
    #expect((target["fix"] as? String)?.contains("pass --simulator") == true)
    #expect(checks.contains { $0["name"] as? String == "signing" && $0["status"] as? String == "ok" && $0["section"] as? String == "Target: Test Phone" })
  }

  @Test func jsonKeepsTheExitStatusOfAProblem() throws {
    let host = FakeHost()
    host.findIdentity = ""
    let result = try jsonObject(DoctorOptions(udid: deviceUDID, json: true), host: host,
                                project: { _ in throw SetupError(description: "not found") })
    #expect(result.status == RunnerExitCode.failure.rawValue)
    #expect(result.lines.count == 1)
    #expect(result.object["ok"] as? Bool == false)
    #expect(result.object["problems"] as? Int == 2)
    let problems = (result.object["checks"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "problem" }
    #expect(Set(problems.compactMap { $0["name"] as? String }) == ["runner project", "signing"])
    #expect(problems.allSatisfy { $0["fix"] is String })
  }

  @Test func jsonIsAnOptionOfDoctor() throws {
    #expect(try Arguments.parse(["doctor", "--json"]) == .doctor(DoctorOptions(json: true)))
    #expect(try Arguments.parse(["doctor", "--simulator", "--json"]) == .doctor(DoctorOptions(simulator: true, json: true)))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["doctor", "--json=1"]) }
  }

  @Test func passesWithWarningsOnly() {
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(), commands: FakeHost().commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
    #expect(status == RunnerExitCode.success.rawValue)
    let output = lines.joined(separator: "\n")
    // The only connected device, picked automatically: a note with how to try a simulator instead.
    #expect(output.contains("! target           Test Phone"))
    #expect(output.contains("relay start without --udid/--device would use it: the only connected device"))
    #expect(output.contains("→ to try a simulator first, pass --simulator (a booted one) or --device <simulator name>"))
    #expect(output.contains("✓ signing          team TEAM000001 (from keychain)"))
    #expect(output.contains("! UI Automation"))
  }

  @Test func failsWhenSomethingIsWrong() {
    let host = FakeHost()
    host.findIdentity = ""
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(udid: deviceUDID), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: { _ in throw SetupError(description: "not found") }, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
    #expect(status == RunnerExitCode.failure.rawValue)
    let output = lines.joined(separator: "\n")
    #expect(output.contains("✗ runner project"))
    #expect(output.contains("✗ signing"))
    #expect(output.hasSuffix("2 problem(s) found; fix the ✗ items above."))
  }

  @Test func checksTheSimulatorRelayStartWouldPickWithSimulator() {
    let host = FakeHost()
    host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Booted")])
    var lines: [String] = []
    _ = Doctor.run(DoctorOptions(simulator: true), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                   resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
    #expect(lines.contains { $0.hasPrefix("  ✓ target           iPhone 17 Pro") && $0.hasSuffix("(relay start without --udid/--device would use it: the only booted simulator (--simulator))") })
    #expect(lines.contains("Target: iPhone 17 Pro"))
    // The connected device is not a candidate, so not listed.
    #expect(!lines.contains { $0.contains("Test Phone") })

    host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Shutdown")])
    lines = []
    _ = Doctor.run(DoctorOptions(simulator: true), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                   resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
    #expect(lines.contains { $0.hasPrefix("  ! target           no booted iOS simulator (--simulator)")
        && $0.hasSuffix("→ relay devices lists the simulators; relay doctor --device <name> checks the one relay start would boot") })
  }

  @Test func aSimulatorUDIDIsCheckedWithoutDevicectl() {
    let host = FakeHost()
    var commands = host.commands
    commands.devicectlJSON = { args, _ in
      Issue.record("devicectl \(args)")
      throw ShellError(args: args, status: 1, output: "")
    }
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(udid: simulatorUDID), commands: commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), sandbox: { _ in [] }, output: { lines.append($0) })
    #expect(status == RunnerExitCode.success.rawValue)
    #expect(lines.contains("  ✓ devices          0 booted simulator(s), 1 iOS simulator(s) (devices not listed: --udid is a simulator)"))
    #expect(!lines.contains { $0.contains("devicectl") && $0.contains("cannot list") })
  }

  private let busyUDID = "22222222-2222-2222-2222-222222222222"
  private let freeUDID = "33333333-3333-3333-3333-333333333333"
  private let heldBySession = StartLock.Holder(pid: 123, session: "a")
  private var heldText: String { heldBySession.summary }

  private func twoBootedSimulators() -> FakeHost {
    let host = FakeHost()
    host.simctl = simctlList([(busyUDID, "iPhone 17", "Booted"), (freeUDID, "iPhone 17 Pro", "Booted")])
    return host
  }

  private func run(_ options: DoctorOptions, host: FakeHost, inUse: [String: StartLock.Holder]) -> (status: Int32, lines: [String]) {
    var lines: [String] = []
    let status = Doctor.run(options, commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), sandbox: { _ in [] },
                            inUse: { _ in inUse }, output: { lines.append($0) })
    return (status, lines)
  }

  @Test func theAutomaticChoiceLeavesOutADeviceAnotherStartHolds() {
    let result = run(DoctorOptions(simulator: true), host: twoBootedSimulators(), inUse: [busyUDID: heldBySession])
    #expect(result.status == RunnerExitCode.success.rawValue)
    #expect(result.lines.contains { $0.hasPrefix("  ✓ target           iPhone 17 Pro") && $0.contains("the only booted simulator") })
    #expect(result.lines.contains { $0.hasPrefix("  ✓ in use") && $0.contains("(\(heldText))") && $0.contains("does not pick these") })
    #expect(result.lines.contains("Target: iPhone 17 Pro"))
  }

  @Test func aNamedDeviceAnotherStartHoldsIsAProblem() {
    let result = run(DoctorOptions(udid: busyUDID, simulator: true), host: twoBootedSimulators(), inUse: [busyUDID: heldBySession])
    #expect(result.status == RunnerExitCode.failure.rawValue)
    #expect(result.lines.contains { $0.hasPrefix("  ✗ target") && $0.contains("is in use by \(heldText)") })
    #expect(result.lines.contains { $0.contains("→ use another device") && $0.contains("relay stop --session a") })
    // The rest of the device's checks go on.
    #expect(result.lines.contains("Target: iPhone 17"))
  }

  @Test func aHolderWithoutASessionIsStoppedWhereItRuns() {
    let result = run(DoctorOptions(udid: busyUDID, simulator: true), host: twoBootedSimulators(), inUse: [busyUDID: StartLock.Holder(pid: 9)])
    #expect(result.status == RunnerExitCode.failure.rawValue)
    #expect(result.lines.contains { $0.contains("relay stop, or Ctrl-C where it runs") })
  }

  @Test func everyCandidateInUseIsANoteWithTheListNotAProblem() {
    let result = run(DoctorOptions(simulator: true), host: twoBootedSimulators(),
                     inUse: [busyUDID: heldBySession, freeUDID: StartLock.Holder(pid: 456, session: "b")])
    #expect(result.status == RunnerExitCode.success.rawValue)
    #expect(result.lines.contains { $0.hasPrefix("  ! target") && $0.contains("simulators are booted") == false })
    #expect(result.lines.contains { $0.hasPrefix("  ! target") && $0.contains("2 in use by another relay start (see the in use line)") })
    let inUseLine = result.lines.first { $0.hasPrefix("  ✓ in use") } ?? ""
    #expect(inUseLine.contains("(\(heldText))") && inUseLine.contains("(session b, relay start pid 456)"))
  }

  @Test func aNamedDeviceNotFoundSaysNothingAboutTheOnesInUse() {
    let result = run(DoctorOptions(udid: "44444444-4444-4444-4444-444444444444", simulator: true), host: twoBootedSimulators(),
                     inUse: [busyUDID: heldBySession])
    #expect(result.status == RunnerExitCode.failure.rawValue)
    let target = result.lines.first { $0.hasPrefix("  ✗ target") } ?? ""
    #expect(target.contains("no iOS simulator with UDID"))
    #expect(!target.contains("in use by another relay start"))
  }

  @Test func nothingInUseLeavesTheOutputAsItWas() {
    let result = run(DoctorOptions(simulator: true), host: twoBootedSimulators(), inUse: [:])
    #expect(!result.lines.contains { $0.contains("in use") })
    #expect(result.lines.contains { $0.hasPrefix("  ! target") })
  }

  @Test func jsonListsTheDevicesInUse() throws {
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(udid: busyUDID, simulator: true, json: true), commands: twoBootedSimulators().commands,
                            configURL: URL(fileURLWithPath: "/nonexistent/config.json"), resolveProject: project,
                            home: URL(fileURLWithPath: "/nonexistent"), sandbox: { _ in [] },
                            inUse: { _ in [busyUDID: heldBySession] }, output: { lines.append($0) })
    #expect(status == RunnerExitCode.failure.rawValue)
    let text = try #require(lines.first)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let checks = try #require(object["checks"] as? [[String: Any]])
    let busy = try #require(checks.first { $0["name"] as? String == "in use" })
    #expect(busy["section"] as? String == "Devices")
    #expect(busy["status"] as? String == "ok")
    let target = try #require(checks.first { $0["name"] as? String == "target" })
    #expect(target["status"] as? String == "problem")
    #expect((target["fix"] as? String)?.contains("relay stop --session a") == true)
  }

  @Test func reportsASandboxThatBlocksLocalhost() {
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(udid: simulatorUDID), commands: FakeHost().commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"),
                            sandbox: { _ in [SandboxProbe.localhostCheck(connectError: EPERM)] }, output: { lines.append($0) })
    #expect(status == RunnerExitCode.failure.rawValue)
    #expect(lines.contains { $0.hasPrefix("  ✗ localhost        the OS refused a connection to 127.0.0.1 (Operation not permitted)") })
    #expect(lines.contains { $0.contains("→ run relay outside the sandbox (in Claude Code: sandbox.excludedCommands)") })
  }

  @Test func sandboxChecksReadTheErrno() throws {
    #expect(SandboxProbe.localhostCheck(connectError: ECONNREFUSED).status == .ok)
    #expect(SandboxProbe.localhostCheck(connectError: 0).status == .ok)
    #expect(SandboxProbe.localhostCheck(connectError: EPERM).status == .problem)
    #expect(SandboxProbe.stateWriteCheck(writeError: 0, path: "/h/.relay") == .ok("~/.relay", "writable"))
    #expect(SandboxProbe.stateWriteCheck(writeError: EPERM, path: "/h/.relay").detail.contains("sandbox"))
    #expect(!SandboxProbe.stateWriteCheck(writeError: EACCES, path: "/h/.relay").detail.contains("sandbox"))
    // The live probes, outside any sandbox here: the directory is writable and leaves nothing behind.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(SandboxProbe.writeError(in: directory) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(SandboxProbe.writeError(in: directory.appendingPathComponent("missing")) == ENOENT)
  }

  @Test func aMissingTeamIsOnlyANoteForSimulators() {
    let host = FakeHost()
    host.findIdentity = ""
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(udid: simulatorUDID), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                            resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
    #expect(status == RunnerExitCode.success.rawValue)
    #expect(lines.contains { $0.hasPrefix("  ! signing") })
  }

  @Test func showsWhichRunnerProjectIsUsed() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let installed = RunnerProject.installedRoot(home: home)
    try FileManager.default.createDirectory(at: installed.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
    try RunnerInstallRecord(relayVersion: RelayVersion.current, commit: nil, source: "/src/relay", installedAt: "1970-01-01T00:00:00Z")
      .write(root: installed)
    let checkout = URL(fileURLWithPath: "/src/relay")

    // Inside a checkout: the checkout is built, and the installed copy is shown as not used.
    let inCheckout = Doctor.installCheck(project: (checkout, .currentDirectory), home: home) { _, _ in nil }
    #expect(inCheckout.status == .ok)
    #expect(inCheckout.detail.hasSuffix("(not used: current directory wins)"))
    // From an app's repository: the installed copy.
    let fromApp = Doctor.installCheck(project: (installed, .installed), home: home) { _, _ in nil }
    #expect(fromApp == .ok("runner install", "relay \(RelayVersion.current), from /src/relay, 1970-01-01T00:00:00Z"))
    // An outdated copy is a note even while a checkout wins, so it is updated before it is used again.
    let outdated = Doctor.installCheck(project: (checkout, .currentDirectory), home: home) { _, _ in "the runner was installed by relay 0.1.0" }
    #expect(outdated.status == .warning)
    // Next to the relay executable (a release, or make install) the copy is out of the picture, however old.
    let beside = Doctor.installCheck(project: (checkout, .executable), home: home) { _, _ in "the runner was installed by relay 0.1.0" }
    #expect(beside.status == .ok)
    #expect(beside.detail.hasSuffix("(not used: relay executable wins)"))
    #expect(RunnerInstaller.staleness(root: checkout, source: .executable) { Issue.record("not a copy"); return nil } == nil)
  }

  @Test func noInstalledCopyIsFineNextToTheExecutableOnly() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let root = URL(fileURLWithPath: "/opt/device-relay-v1.2.3")

    let release = Doctor.installCheck(project: (root, .executable), home: home) { _, _ in nil }
    #expect(release == .ok("runner install", "not needed; using the runner project of the relay executable"))
    #expect(Doctor.installCheck(project: (root, .currentDirectory), home: home) { _, _ in nil }.status == .warning)
    #expect(Doctor.installCheck(project: nil, home: home) { _, _ in nil }.status == .warning)
  }

  @Test func aSavedTeamIsEnoughWithoutTheKeychain() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-doctor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let configURL = RelayConfig.defaultURL(home: home)
    try RelayConfig(teamID: "ABCDE12345").write(to: configURL)
    var commands = FakeHost().commands
    commands.run = { executable, args, timeout in
      if executable == "/usr/bin/security" { throw ShellError(tool: "security", args: args, status: 1, output: "") }
      return try FakeHost().commands.run(executable, args, timeout)
    }
    var lines: [String] = []
    let status = Doctor.run(DoctorOptions(udid: deviceUDID), commands: commands, configURL: configURL,
                            resolveProject: project, home: home, output: { lines.append($0) })
    #expect(status == RunnerExitCode.success.rawValue)
    #expect(lines.contains("  ✓ signing          team ABCDE12345 (from ~/.relay/config.json)"))
  }
}
