import Foundation
@testable import Relay
import Testing

// relay record (simulators, and devices connected with USB). UDIDs, names, and paths are dummies.

struct RecordArgumentsTests {
  @Test func startDefaults() throws {
    #expect(try Arguments.parse(["record", "start"])
      == .record(RecordOptions(action: .start(output: nil, maxDuration: Recording.defaultMaxDuration))))
    #expect(Recording.defaultMaxDuration == 600)
  }

  @Test func startOptions() throws {
    #expect(try Arguments.parse(["record", "start", "-o", "demo.mp4", "--max-duration", "30", "--runner", "r.json"])
      == .record(RecordOptions(action: .start(output: "demo.mp4", maxDuration: 30), runnerPath: "r.json")))
    #expect(try Arguments.parse(["record", "start", "--output", "/tmp/a.mp4"])
      == .record(RecordOptions(action: .start(output: "/tmp/a.mp4", maxDuration: 600))))
  }

  @Test func stopAndStatus() throws {
    #expect(try Arguments.parse(["record", "stop"]) == .record(RecordOptions(action: .stop)))
    #expect(try Arguments.parse(["record", "stop", "--runner", "r.json"]) == .record(RecordOptions(action: .stop, runnerPath: "r.json")))
    #expect(try Arguments.parse(["record", "status"]) == .record(RecordOptions(action: .status(json: false))))
    #expect(try Arguments.parse(["record", "status", "--json"]) == .record(RecordOptions(action: .status(json: true))))
  }

  @Test func rejectsBadArguments() {
    for arguments in [
      ["record"], ["record", "begin"], ["record", "start", "--max-duration", "0"], ["record", "start", "--max-duration", "-5"],
      ["record", "start", "--max-duration", "soon"], ["record", "start", "--max-duration"], ["record", "start", "--output"],
      ["record", "stop", "--output", "a.mp4"], ["record", "stop", "--json"], ["record", "status", "--max-duration", "5"],
      ["record", "start", "--udid", "SIM"], ["record", "supervise", "--udid", "SIM"]
    ] {
      #expect(throws: ArgumentError.self, "\(arguments)") { try Arguments.parse(arguments) }
    }
  }

  @Test func forceOnlyForStart() throws {
    #expect(try Arguments.parse(["record", "start", "-o", "a.mp4", "--force"])
      == .record(RecordOptions(action: .start(output: "a.mp4", maxDuration: 600, force: true))))
    #expect(try Arguments.parse(["record", "start"]) == .record(RecordOptions(action: .start(output: nil, maxDuration: 600, force: false))))
    for action in ["stop", "status"] {
      #expect(throws: ArgumentError.self) { try Arguments.parse(["record", action, "--force"]) }
    }
  }

  @Test func portForStopAndStatus() throws {
    #expect(try Arguments.parse(["record", "stop", "--port", "8123"]) == .record(RecordOptions(action: .stop, port: 8123)))
    #expect(try Arguments.parse(["record", "status", "--json", "--port", "8123"])
      == .record(RecordOptions(action: .status(json: true), port: 8123)))
    for arguments in [["record", "stop", "--port", "0"], ["record", "stop", "--port", "65536"], ["record", "stop", "--port", "x"],
                      ["record", "stop", "--port"], ["record", "start", "--port", "8100"]] {
      #expect(throws: ArgumentError.self, "\(arguments)") { try Arguments.parse(arguments) }
    }
    let stopError = #expect(throws: ArgumentError.self) { try Arguments.parse(["record", "stop", "--runner", "r.json", "--port", "8100"]) }
    #expect(stopError?.description == "record stop takes one of --runner, --session, and --port")
    let error = #expect(throws: ArgumentError.self) { try Arguments.parse(["record", "status", "--port", "8100", "--runner", "r.json"]) }
    #expect(error?.description == "record status takes one of --runner, --session, and --port")
  }

  @Test func help() throws {
    #expect(try Arguments.parse(["record", "--help"]) == .commandHelp("record"))
    #expect(try Arguments.parse(["record", "start", "--help"]) == .commandHelp("record"))
    #expect(try Arguments.parse(["help", "record"]) == .commandHelp("record"))
    let usage = Arguments.usage(for: "record")
    #expect(usage.contains("simulator or device"))
    #expect(usage.contains("USB"))
    #expect(usage.contains("Privacy & Security > Camera"))
    #expect(usage.contains("relay record start"))
    #expect(Arguments.usage.contains("record   Records the screen of the runner's simulator, or of its device connected with USB"))
    #expect(Arguments.helpCommand(for: "record") == "relay record --help")
    #expect(usage.contains("--force"))
    #expect(usage.contains("relay record stop [--runner <path> | --session <name> | --port <n>]"))
  }

  @Test func superviseArgumentsParseBack() throws {
    let arguments = Recording.superviseArguments(udid: "SIM-UDID", output: "/tmp/a b.mp4", maxDuration: 42.5)
    #expect(try Arguments.parse(arguments)
      == .record(RecordOptions(action: .supervise(udid: "SIM-UDID", output: "/tmp/a b.mp4", maxDuration: 42.5))))
    // A device's name, spaces and all, which the supervisor finds its screen by.
    let device = Recording.superviseArguments(udid: "DEVICE-UDID", output: "/tmp/a.mp4", maxDuration: 600, deviceName: "Test Phone 2")
    #expect(device.suffix(2) == ["--device-name", "Test Phone 2"])
    #expect(try Arguments.parse(device) == .record(RecordOptions(
      action: .supervise(udid: "DEVICE-UDID", output: "/tmp/a.mp4", maxDuration: 600, deviceName: "Test Phone 2")
    )))
    // Only the internal supervise takes it.
    #expect(throws: ArgumentError.self) { try Arguments.parse(["record", "start", "--device-name", "Test Phone"]) }
  }

  @Test func simctlArguments() {
    #expect(Recording.simctlArguments(udid: "SIM-UDID", output: "/tmp/a.mp4")
      == ["simctl", "io", "SIM-UDID", "recordVideo", "--codec", "h264", "--force", "/tmp/a.mp4"])
  }
}

struct RecordOutputTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000.25)

  @Test func defaultGoesToTheTemporaryDirectory() {
    let url = Recording.outputURL(nil, now: now, currentDirectory: URL(fileURLWithPath: "/work/app"),
                                  temporaryDirectory: URL(fileURLWithPath: "/tmp/T", isDirectory: true))
    #expect(url.deletingLastPathComponent().path == "/tmp/T/relay")
    #expect(url.lastPathComponent.hasPrefix("relay-recording-"))
    #expect(url.pathExtension == "mp4")
    // yyyyMMdd-HHmmss-SSS in the local time zone.
    #expect(url.lastPathComponent.count == "relay-recording-20270115-080000-250.mp4".count)
  }

  @Test func relativeIsUnderTheCurrentDirectory() {
    let current = URL(fileURLWithPath: "/work/app", isDirectory: true)
    #expect(Recording.outputURL("videos/demo.mp4", currentDirectory: current).path == "/work/app/videos/demo.mp4")
    #expect(Recording.outputURL("../demo.mp4", currentDirectory: current).path == "/work/demo.mp4")
    #expect(Recording.outputURL("/abs/demo.mp4", currentDirectory: current).path == "/abs/demo.mp4")
  }

  @Test func parentMustExist() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-record-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(Recording.outputProblem(directory.appendingPathComponent("a.mp4")) == nil)
    let missing = Recording.outputProblem(directory.appendingPathComponent("no/a.mp4"))
    #expect(missing?.contains("does not exist") == true)
    #expect(Recording.outputProblem(directory)?.contains("is a directory") == true)
    #expect(Recording.outputProblem(directory, force: true)?.contains("is a directory") == true)
  }

  @Test func existingFileNeedsForce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-record-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let existing = directory.appendingPathComponent("demo.mp4")
    try Data("old".utf8).write(to: existing)

    let problem = try #require(Recording.outputProblem(existing))
    #expect(problem == "\(existing.path) already exists; pass --force to replace it, or give another --output")
    #expect(Recording.outputProblem(existing, force: true) == nil)
    // The default name is checked the same way.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let defaultURL = Recording.outputURL(nil, now: now, temporaryDirectory: directory)
    try FileManager.default.createDirectory(at: defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(Recording.outputProblem(defaultURL) == nil)
    try Data().write(to: defaultURL)
    #expect(Recording.outputProblem(defaultURL)?.contains("pass --force") == true)
    // simctl always gets --force; relay decides before it starts.
    #expect(Recording.simctlArguments(udid: "SIM", output: existing.path).contains("--force"))
  }
}

struct RecordStateTests {
  func state(pid: Int32 = 4242, port: Int = 8100) -> RecordingState {
    RecordingState(pid: pid, processStartedAt: Date(timeIntervalSince1970: 1_800_000_000), supervisorPid: 4241,
                   output: "/tmp/T/relay/relay-recording.mp4", udid: "SIM-UDID", port: port,
                   startedAt: Date(timeIntervalSince1970: 1_800_000_001), maxDuration: 600, log: "/home/.relay/logs/record.log")
  }

  @Test func writesOwnerOnlyAndReadsBack() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-record-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let url = Recording.stateURL(port: 8123, home: home)
    #expect(url.path.hasSuffix("/.relay/recording-8123.json"))

    try state(port: 8123).write(to: url)
    #expect(try RecordingState.read(from: url) == state(port: 8123))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    // Rewriting replaces it.
    try state(pid: 1, port: 8123).write(to: url)
    #expect(try RecordingState.read(from: url).pid == 1)
    #expect(Recording.stateURLs(home: home) == [url])
  }

  @Test func portOfAStateFile() {
    #expect(Recording.port(ofStateURL: Recording.stateURL(port: 8123, home: URL(fileURLWithPath: "/home"))) == 8123)
    #expect(Recording.port(ofStateURL: URL(fileURLWithPath: "/home/.relay/recording-x.json")) == nil)
    #expect(Recording.port(ofStateURL: URL(fileURLWithPath: "/home/.relay/runner.json")) == nil)
  }

  @Test func severalRecordingsAreListedByPort() {
    let message = Recording.severalRecordingsMessage([
      Recording.Candidate(port: 8200, output: "/tmp/b.mp4", recording: false),
      Recording.Candidate(port: 8100, output: "/tmp/a.mp4", recording: true),
      Recording.Candidate(port: 8300, output: nil, recording: false)
    ])
    #expect(message == """
    no runner.json, and recordings of several runner ports:
      --port 8100: /tmp/a.mp4 (recording)
      --port 8200: /tmp/b.mp4 (ended)
      --port 8300: (cannot read the state file)
    choose one with --port <n>
    """)
  }

  @Test func portOfTheRunner() {
    #expect(Recording.port(of: RunnerInfo(url: "http://127.0.0.1:8123/", token: "t", udid: "SIM")) == 8123)
    #expect(Recording.port(of: RunnerInfo(url: "http://127.0.0.1/", token: "t", udid: "SIM")) == Recording.defaultPort)
  }

  @Test func recordingOnlyWhileTheSameSimctlRuns() {
    let recording = state()
    let simctl = RelayProcess.Snapshot(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000.6),
      executable: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl",
      arguments: ["simctl", "io", "SIM-UDID", "recordVideo", "--codec", "h264", "--force", recording.output]
    )
    #expect(Recording.isRecording(recording) { $0 == 4242 ? simctl : nil })
    // Gone: a stale state, which does not block the next start.
    #expect(!Recording.isRecording(recording) { _ in nil })
    // The pid reused by another process, or by a later simctl.
    var other = simctl
    other.executable = "/usr/bin/yes"
    #expect(!Recording.isRecording(recording) { _ in other })
    var later = simctl
    later.startedAt = Date(timeIntervalSince1970: 1_800_000_100)
    #expect(!Recording.isRecording(recording) { _ in later })
    var screenshot = simctl
    screenshot.arguments = ["simctl", "io", "SIM-UDID", "screenshot", "a.png"]
    #expect(!Recording.isRecording(recording) { _ in screenshot })
  }

  @Test func recordingOnlyWhileTheSameDeviceSupervisorRuns() {
    var recording = state()
    recording.kind = .device
    let supervisor = RelayProcess.Snapshot(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000.2), executable: "/Users/me/.local/bin/relay",
      arguments: ["/Users/me/.local/bin/relay", "record", "supervise", "--udid", "DEVICE-UDID", "--output", recording.output,
                  "--max-duration", "600.0", "--device-name", "Test Phone"]
    )
    let check = { (snapshot: RelayProcess.Snapshot) in
      Recording.isRecordingProcess(snapshot, startedAt: recording.processStartedAt, device: true, relayName: "relay")
    }
    #expect(check(supervisor))
    // Another relay command, another executable, or a later process with the pid.
    var start = supervisor
    start.arguments = ["relay", "record", "start"]
    #expect(!check(start))
    var other = supervisor
    other.executable = "/usr/bin/yes"
    #expect(!check(other))
    var later = supervisor
    later.startedAt = Date(timeIntervalSince1970: 1_800_000_100)
    #expect(!check(later))
    // A simulator's state does not take the supervisor for simctl, nor a device's simctl for its recorder.
    #expect(!Recording.isRecordingProcess(supervisor, startedAt: recording.processStartedAt, device: false, relayName: "relay"))
    #expect(!Recording.isRecording(recording) { _ in nil })
  }

  @Test func stateOfAnEarlierVersionIsASimulator() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-record-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let url = Recording.stateURL(port: 8100, home: home)
    try state().write(to: url)
    // Written without "kind", as before devices were recorded.
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("kind"))
    let read = try RecordingState.read(from: url)
    #expect(read.kind == nil && !read.isDevice && read.recorder == "simctl")

    var device = state()
    device.kind = .device
    try device.write(to: url)
    #expect(try RecordingState.read(from: url) == device)
    #expect(device.recorder == "relay record supervise")
    #expect(Recording.alreadyRecordingMessage(device, url: "http://127.0.0.1:8100/").contains("relay record supervise pid 4242"))
    let status = Recording.statusText(device, recording: true, stateURL: url, now: device.startedAt)
    #expect(status.contains("pid:       4242 (relay record supervise)"))
    let json = try #require(try JSONSerialization.jsonObject(with: Recording.statusJSON(device, recording: true, stateURL: url)) as? [String: Any])
    #expect(json["kind"] as? String == "device")
  }

  @Test func alreadyRecordingNamesTheRecordingAndTheWayOut() {
    let message = Recording.alreadyRecordingMessage(state(), url: "http://127.0.0.1:8100/")
    #expect(message.hasPrefix("a recording is already running for the runner at http://127.0.0.1:8100/"))
    #expect(message.contains("simctl pid 4242"))
    #expect(message.contains("relay record stop"))
  }

  @Test func statusTextAndJSON() throws {
    let recording = state()
    let now = recording.startedAt.addingTimeInterval(12.7)
    let text = Recording.statusText(recording, recording: true, stateURL: URL(fileURLWithPath: "/home/.relay/recording-8100.json"),
                                    now: now, timeZone: TimeZone(identifier: "UTC")!)
    #expect(text.contains("recording: yes (12s; stops by itself after 600s)"))
    #expect(text.contains("output:    /tmp/T/relay/relay-recording.mp4"))
    #expect(text.contains("started:   2027-01-15 08:00:01 +0000"))
    let ended = Recording.statusText(recording, recording: false, stateURL: URL(fileURLWithPath: "/s.json"), now: now)
    #expect(ended.contains("recording: ended"))

    let data = Recording.statusJSON(recording, recording: true, stateURL: URL(fileURLWithPath: "/s.json"), now: now)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["recording"] as? Bool == true)
    #expect(object["elapsedSeconds"] as? Int == 12)
    #expect(object["output"] as? String == recording.output)
    #expect(object["pid"] as? Int == 4242)
    #expect(object["port"] as? Int == 8100)
    #expect(object["kind"] as? String == "simulator")
  }
}

struct RecordProgressTests {
  @Test func startedAfterPidAndMarker() {
    var progress = Recording.Progress()
    // What simctl and the supervisor write to the log.
    for line in ["relay: recording with simctl pid 5150",
                 "Note: No display specified. Defaulting to display: DISPLAY-ID (screenID: 1, name: LCD)"] {
      Recording.handle(line: line, progress: &progress)
    }
    #expect(progress == Recording.Progress(recorderPid: 5150, started: false))
    Recording.handle(line: "Recording started", progress: &progress)
    #expect(progress == Recording.Progress(recorderPid: 5150, started: true))
  }

  @Test func aDeviceSupervisorReportsItsOwnPid() {
    var progress = Recording.Progress()
    Recording.handle(line: "relay: recording the device in pid 6160", progress: &progress)
    #expect(progress == Recording.Progress(recorderPid: 6160, started: false))
    // Written at the first frame.
    Recording.handle(line: "Recording started", progress: &progress)
    #expect(progress.started)
    let log = """
    relay: recording the device in pid 6160
    Recording started
    relay: the device was disconnected; stopped the recording
    relay: wrote 120 frames (1000x2000) to /tmp/a.mp4
    """
    #expect(Recording.endReason(inLog: log) == "the device was disconnected; stopped the recording; wrote 120 frames (1000x2000) to /tmp/a.mp4")
  }

  @Test func statusTellsWhileNoFrameComes() throws {
    let stalled = """
    relay: recording the device in pid 6160
    Recording started
    relay: no frame for 5s (the device may be locked, or the capture stalled); still recording, and the video holds the last frame until frames come again
    """
    let note = try #require(Recording.stall(inLog: stalled))
    #expect(note.hasPrefix("no frame for 5s"))
    let resumed = stalled + "\nrelay: frames came again after 12s without one\n"
    #expect(Recording.stall(inLog: resumed) == nil)
    #expect(Recording.stall(inLog: resumed + "relay: no frame for 5s (again)\n") == "no frame for 5s (again)")
    #expect(Recording.stall(inLog: "relay: recording the device in pid 6160\nRecording started\n") == nil)
    // Not why it ended.
    #expect(Recording.endReason(inLog: resumed + "relay: stopping the recording\n") == "stopping the recording")

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let state = RecordingState(pid: 6160, processStartedAt: start, supervisorPid: 6160, output: "/tmp/a.mp4",
                               udid: "00000000-0000000000000001", port: 8100, startedAt: start, maxDuration: 600,
                               log: "/tmp/record.log", kind: .device)
    let text = Recording.statusText(state, recording: true, stall: note, stateURL: URL(fileURLWithPath: "/s.json"), now: state.startedAt)
    #expect(text.contains("frames:    no frame for 5s"))
    #expect(!Recording.statusText(state, recording: true, stateURL: URL(fileURLWithPath: "/s.json")).contains("frames:"))
    let json = try #require(try JSONSerialization.jsonObject(with: Recording.statusJSON(state, recording: true, stall: note,
                                                                                        stateURL: URL(fileURLWithPath: "/s.json"))) as? [String: Any])
    #expect(json["stall"] as? String == note)
    let fine = try #require(try JSONSerialization.jsonObject(with: Recording.statusJSON(state, recording: true,
                                                                                        stateURL: URL(fileURLWithPath: "/s.json"))) as? [String: Any])
    #expect(fine["stall"] == nil)
  }

  @Test func errorsAreNotAStart() {
    var progress = Recording.Progress()
    for line in ["An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):",
                 "Unable to lookup in current state: Shutdown", "relay: simctl exited (status 1)", "Recording started later"] {
      Recording.handle(line: line, progress: &progress)
    }
    #expect(!progress.started)
    #expect(progress.recorderPid == nil)
  }

  @Test func endReasonIsWhatTheSupervisorSaid() {
    let log = """
    relay: recording with simctl pid 5150
    Recording started
    relay: reached --max-duration of 5s; stopped the recording
    Recording completed. Writing to disk.
    Wrote video to: /tmp/a.mp4
    relay: simctl exited (status 0)
    """
    #expect(Recording.endReason(inLog: log) == "reached --max-duration of 5s; stopped the recording; simctl exited (status 0)")
    #expect(Recording.endReason(inLog: "relay: recording with simctl pid 1\nRecording started\n") == nil)
  }

  @Test func targetIsASimulatorOrADevice() {
    let simulator = Device(name: "iPhone", udid: "SIM-UDID", kind: .simulator, os: "iOS 27.0", state: "booted", isAvailable: true)
    let device = Device(name: "Test Phone", udid: "00000000-0000000000000001", kind: .device, os: "iOS 26.0", state: "connected",
                        isAvailable: true, transport: "wired")
    #expect(Recording.target(udid: "SIM-UDID", devices: [simulator, device]) == .simulator(simulator))
    #expect(Recording.target(udid: "00000000-0000000000000001", devices: [simulator, device]) == .device(device))
    // runner.json may spell the UDID in another case.
    #expect(Recording.target(udid: "00000000-0000000000000001".lowercased(), devices: [device]) == .device(device))
    #expect(Recording.target(udid: "DEVICE-UDID", devices: [simulator]) == .notFound)
    #expect(Recording.target(udid: "DEVICE-UDID", devices: []) == .notFound)
  }
}

struct RecordStateLookupTests {
  /// A scratch home and an empty current directory, so no real runner.json is found.
  func scratch() throws -> (home: URL, current: URL, cleanUp: () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-record-lookup-\(UUID().uuidString)").canonicalFileURL
    let home = root.appendingPathComponent("home", isDirectory: true)
    let current = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".relay"), withIntermediateDirectories: true)
    return (home, current, { try? FileManager.default.removeItem(at: root) })
  }

  func writeState(port: Int, home: URL) throws -> URL {
    let url = Recording.stateURL(port: port, home: home)
    try RecordingState(pid: 1, processStartedAt: Date(timeIntervalSince1970: 0), supervisorPid: 1, output: "/tmp/\(port).mp4",
                       udid: "SIM", port: port, startedAt: Date(timeIntervalSince1970: 0), maxDuration: 600, log: "/tmp/r.log")
      .write(to: url)
    return url
  }

  @Test func missingRunnerGivenWithTheOptionIsUnavailable() throws {
    let (home, current, cleanUp) = try scratch()
    defer { cleanUp() }
    // A state file must not be picked instead.
    _ = try writeState(port: 8100, home: home)
    let error = #expect(throws: RunnerUnavailableError.self) {
      try Recording.stateURLOfRunner(runnerPath: "missing.json", home: home, environment: [:], currentDirectory: current)
    }
    #expect(error?.description == "--runner \(current.path)/missing.json does not exist; is relay start running?")
  }

  @Test func missingRunnerGivenWithTheEnvironmentIsUnavailable() throws {
    let (home, current, cleanUp) = try scratch()
    defer { cleanUp() }
    _ = try writeState(port: 8100, home: home)
    let error = #expect(throws: RunnerUnavailableError.self) {
      try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: ["RELAY_RUNNER": "/nowhere/runner.json"],
                                     currentDirectory: current)
    }
    #expect(error?.description == "$RELAY_RUNNER /nowhere/runner.json does not exist; is relay start running?")
  }

  @Test func givenRunnerNamesItsPort() throws {
    let (home, current, cleanUp) = try scratch()
    defer { cleanUp() }
    let runner = current.appendingPathComponent("r.json")
    try RunnerInfo(url: "http://127.0.0.1:8123/", token: "t", udid: "SIM").write(to: runner)
    #expect(try Recording.stateURLOfRunner(runnerPath: "r.json", home: home, environment: [:], currentDirectory: current)
      == Recording.stateURL(port: 8123, home: home))
  }

  @Test func searchedRunnerFallsBackToTheStateFiles() throws {
    let (home, current, cleanUp) = try scratch()
    defer { cleanUp() }
    // None: not recording.
    #expect(try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: [:], currentDirectory: current) == nil)
    // One: that one. An empty $RELAY_RUNNER is not given.
    let first = try writeState(port: 8100, home: home)
    #expect(try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: ["RELAY_RUNNER": ""], currentDirectory: current)
      == first)
    // Several: listed by port.
    _ = try writeState(port: 8101, home: home)
    let error = #expect(throws: SetupError.self) {
      try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: [:], currentDirectory: current)
    }
    #expect(error?.description.contains("--port 8101: /tmp/8101.mp4 (ended)") == true)
    #expect(error?.description.hasSuffix("choose one with --port <n>") == true)
  }
}
