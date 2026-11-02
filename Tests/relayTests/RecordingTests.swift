import Foundation
@testable import relay
import Testing

// relay record (simulators only). UDIDs, names, and paths are dummies.

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
        #expect(stopError?.description == "record stop takes either --runner or --port, not both")
        let error = #expect(throws: ArgumentError.self) { try Arguments.parse(["record", "status", "--port", "8100", "--runner", "r.json"]) }
        #expect(error?.description == "record status takes either --runner or --port, not both")
    }

    @Test func help() throws {
        #expect(try Arguments.parse(["record", "--help"]) == .commandHelp("record"))
        #expect(try Arguments.parse(["record", "start", "--help"]) == .commandHelp("record"))
        #expect(try Arguments.parse(["help", "record"]) == .commandHelp("record"))
        let usage = Arguments.usage(for: "record")
        #expect(usage.contains("Simulators only"))
        #expect(usage.contains("relay record start"))
        #expect(Arguments.usage.contains("record   Simulators only"))
        #expect(Arguments.errorUsage(for: "record").contains("Run relay record --help"))
        #expect(usage.contains("--force"))
        #expect(usage.contains("relay record stop [--runner <path> | --port <n>]"))
    }

    @Test func superviseArgumentsParseBack() throws {
        let arguments = Recording.superviseArguments(udid: "SIM-UDID", output: "/tmp/a b.mp4", maxDuration: 42.5)
        #expect(try Arguments.parse(arguments)
            == .record(RecordOptions(action: .supervise(udid: "SIM-UDID", output: "/tmp/a b.mp4", maxDuration: 42.5))))
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
        #expect(progress == Recording.Progress(simctlPid: 5150, started: false))
        Recording.handle(line: "Recording started", progress: &progress)
        #expect(progress == Recording.Progress(simctlPid: 5150, started: true))
    }

    @Test func errorsAreNotAStart() {
        var progress = Recording.Progress()
        for line in ["An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):",
                     "Unable to lookup in current state: Shutdown", "relay: simctl exited (status 1)", "Recording started later"] {
            Recording.handle(line: line, progress: &progress)
        }
        #expect(!progress.started)
        #expect(progress.simctlPid == nil)
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

    @Test func onlySimulatorsAreRecorded() {
        let simulator = Device(name: "iPhone", udid: "SIM-UDID", kind: .simulator, os: "iOS 27.0", state: "booted", isAvailable: true)
        #expect(Recording.target(udid: "SIM-UDID", simulators: [simulator]) == .simulator(simulator))
        #expect(Recording.target(udid: "DEVICE-UDID", simulators: [simulator]) == .notSimulator)
        #expect(Recording.target(udid: "DEVICE-UDID", simulators: []) == .notSimulator)
    }
}
