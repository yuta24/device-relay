import Foundation
@testable import relay
import Testing

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
        options.project = "/tmp/device relay"
        options.port = 8123
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
        #expect(Arguments.usage.contains("relay start --background"))
        #expect(Arguments.usage.contains("relay stop [--runner <PATH>]"))
    }
}

struct RunnerInfoProcessTests {
    @Test func savesNamePidAndStartTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro",
                              pid: 1234, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url) == info)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["startedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(json?["pid"] as? Int == 1234)
    }

    @Test func readsAFileWithoutThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"url":"http://127.0.0.1:8100/","token":"t","udid":"SIM"}"#.utf8).write(to: url)
        let info = try RunnerInfo.read(from: url)
        #expect(info == RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"))
        #expect(RelayProcess.runningRelayStart(info) == nil)
    }
}

struct RelayProcessTests {
    private let started = Date(timeIntervalSince1970: 1_800_000_000.75)

    private func snapshot(executable: String = "/usr/local/bin/relay", arguments: [String] = ["relay", "start", "--udid", "SIM"],
                          startedAt: Date? = nil) -> RelayProcess.Snapshot {
        RelayProcess.Snapshot(startedAt: startedAt ?? started, executable: executable, arguments: arguments)
    }

    @Test func matchesTheRelayStartThatWroteRunnerInfo() {
        // runner.json keeps whole seconds.
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RelayProcess.isRelayStart(snapshot(), startedAt: recorded, executableName: "relay"))
    }

    @Test func rejectsAReusedPid() {
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        // Another process that started later with the same pid.
        #expect(!RelayProcess.isRelayStart(snapshot(startedAt: started.addingTimeInterval(5)), startedAt: recorded, executableName: "relay"))
        // Same start time, but not relay start.
        #expect(!RelayProcess.isRelayStart(snapshot(executable: "/bin/sleep", arguments: ["sleep", "120"]), startedAt: recorded, executableName: "relay"))
        #expect(!RelayProcess.isRelayStart(snapshot(arguments: ["relay", "screenshot"]), startedAt: recorded, executableName: "relay"))
        #expect(!RelayProcess.isRelayStart(snapshot(arguments: ["relay"]), startedAt: recorded, executableName: "relay"))
    }

    @Test func parsesProcArgs() {
        var buffer = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/usr/local/bin/relay".utf8) + [0, 0, 0, 0]
        for argument in ["relay", "start", "--device", "iPhone 17 Pro"] + ["HOME=/Users/test"] {
            buffer += Array(argument.utf8) + [0]
        }
        #expect(RelayProcess.parseProcessArguments(buffer) == ["relay", "start", "--device"])
        #expect(RelayProcess.parseProcessArguments([1, 0]) == nil)
        // argc larger than what follows.
        var short = withUnsafeBytes(of: Int32(5)) { Array($0) }
        short += Array("/bin/x".utf8) + [0] + Array("x".utf8) + [0]
        #expect(RelayProcess.parseProcessArguments(short) == nil)
    }

    @Test func readsThisProcess() throws {
        let snapshot = try #require(RelayProcess.snapshot(pid: getpid()))
        #expect(abs(snapshot.startedAt.timeIntervalSinceNow) < 24 * 3600)
        #expect(!snapshot.executable.isEmpty)
        #expect(snapshot.arguments.first != nil)
        #expect(RelayProcess.exists(getpid()))
        #expect(RelayProcess.snapshot(pid: -1) == nil)
        // This test process is not relay start, whatever its start time.
        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", pid: getpid(), startedAt: RelayProcess.currentStartTime())
        #expect(RelayProcess.runningRelayStart(info) == nil)
    }

    @Test func findsChildProcesses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(RelayProcess.descendants(of: getpid()).contains(process.processIdentifier))
        #expect(RelayProcess.descendants(of: process.processIdentifier).isEmpty)
    }
}

struct BackgroundStartTests {
    @Test func readsProgressFromTheLog() {
        var progress = BackgroundStart.Progress()
        #expect(BackgroundStart.handle(line: "relay: building runner (log: /x/build.log)", progress: &progress) == "relay: building runner (log: /x/build.log)")
        #expect(!progress.launched)
        #expect(BackgroundStart.handle(line: "relay: launching runner on SIM (log: /x/runner.log)", progress: &progress) != nil)
        #expect(progress.launched)
        // xcodebuild output and the Ctrl-C hint stay in the log.
        #expect(BackgroundStart.handle(line: "** TEST EXECUTE FAILED **", progress: &progress) == nil)
        #expect(BackgroundStart.handle(line: "relay: press Ctrl-C to stop the runner", progress: &progress) == nil)
        #expect(progress.readyURL == nil)
        #expect(BackgroundStart.handle(line: "ready: http://127.0.0.1:8100/", progress: &progress) == nil)
        #expect(progress.readyURL == "http://127.0.0.1:8100/")
    }

    @Test func startsOnlyWhenNothingAnswersAtTheRunnerURL() throws {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro")
        #expect(BackgroundStart.conflict(with: existing, ping: .unreachable("refused"), owner: nil) == nil)

        let alive = try #require(BackgroundStart.conflict(with: existing, ping: .alive(busy: false, busyForMs: nil), owner: 1234))
        #expect(alive.contains("already running at http://127.0.0.1:8100/ (iPhone 17 Pro, relay start pid 1234)"))
        #expect(alive.contains("relay stop"))

        // Another runner with another token on the same port.
        let unauthorized = try #require(BackgroundStart.conflict(with: existing, ping: .status(401), owner: nil))
        #expect(unauthorized.contains("401"))
        #expect(unauthorized.contains("another runner"))
        #expect(unauthorized.contains("relay stop"))
        #expect(unauthorized.contains("--port"))

        let other = try #require(BackgroundStart.conflict(with: existing, ping: .status(404), owner: nil))
        #expect(other.contains("HTTP 404"))
        #expect(other.contains("--port"))
    }

    @Test func describesWaitStatus() {
        #expect(BackgroundStart.describe(0) == "status 0")
        #expect(BackgroundStart.describe(1 << 8) == "status 1")
        #expect(BackgroundStart.describe(65 << 8) == "status 65")
        #expect(BackgroundStart.describe(9) == "signal 9")
    }
}

struct RunnerStatusTests {
    private let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro",
                                  pid: 1234, startedAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func parsesPing() {
        #expect(RunnerPing.parse(RunnerResponse(status: 200, body: Data(#"{"ok":true,"busy":false,"busyForMs":null}"#.utf8)))
            == .alive(busy: false, busyForMs: nil))
        #expect(RunnerPing.parse(RunnerResponse(status: 200, body: Data(#"{"ok":true,"busy":true,"busyForMs":1200}"#.utf8)))
            == .alive(busy: true, busyForMs: 1200))
        #expect(RunnerPing.parse(RunnerResponse(status: 401, body: Data())) == .status(401))
    }

    @Test func exitCodes() {
        #expect(RunnerPing.alive(busy: true, busyForMs: 5).exitCode == .success)
        #expect(RunnerPing.unreachable("refused").exitCode == .unavailable)
        #expect(RunnerPing.status(401).exitCode == .unauthorized)
        #expect(RunnerPing.status(404).exitCode == .badRequest)
        #expect(RunnerPing.check(RunnerInfo(url: "not a url", token: "t", udid: "SIM")).exitCode == .unavailable)
    }

    @Test func text() throws {
        let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/home/.relay/runner.json"), info: info,
                                         processRunning: true, ping: .alive(busy: true, busyForMs: 1200))
        let text = RunnerStatus.text(report, timeZone: try #require(TimeZone(identifier: "UTC")))
        #expect(text == """
        url:         http://127.0.0.1:8100/
        device:      iPhone 17 Pro (SIM)
        pid:         1234 (relay start running)
        started:     2027-01-15 08:00:00 +0000
        ping:        ok (busy for 1200 ms)
        runner.json: /home/.relay/runner.json
        """)
    }

    @Test func textWithoutProcessInfo() {
        let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"),
                                         processRunning: nil, ping: .unreachable("refused"))
        #expect(RunnerStatus.text(report) == """
        url:         http://127.0.0.1:8100/
        device:      SIM
        ping:        no answer (refused)
        runner.json: /r.json
        """)
    }

    @Test func json() throws {
        let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info, processRunning: false, ping: .status(401))
        let object = try #require(try JSONSerialization.jsonObject(with: RunnerStatus.json(report)) as? [String: Any])
        #expect(object["alive"] as? Bool == false)
        #expect(object["pid"] as? Int == 1234)
        #expect(object["processRunning"] as? Bool == false)
        #expect(object["name"] as? String == "iPhone 17 Pro")
        #expect(object["startedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect((object["ping"] as? [String: Any])?["status"] as? Int == 401)
        #expect(object["token"] == nil)

        let alive = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info, processRunning: true, ping: .alive(busy: false, busyForMs: nil))
        let aliveObject = try #require(try JSONSerialization.jsonObject(with: RunnerStatus.json(alive)) as? [String: Any])
        #expect(aliveObject["alive"] as? Bool == true)
        let ping = try #require(aliveObject["ping"] as? [String: Any])
        #expect(ping["busy"] as? Bool == false)
        #expect(ping["busyForMs"] is NSNull)
    }
}
