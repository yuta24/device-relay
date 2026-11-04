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
        #expect(Arguments.usage.contains("relay start --background"))
        #expect(Arguments.usage.contains("relay stop [--runner <PATH> | --session <NAME> | --all]"))
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
        #expect(progress.udid == "SIM")
        // xcodebuild output and the Ctrl-C hint stay in the log.
        #expect(BackgroundStart.handle(line: "** TEST EXECUTE FAILED **", progress: &progress) == nil)
        #expect(BackgroundStart.handle(line: "relay: press Ctrl-C to stop the runner", progress: &progress) == nil)
        #expect(progress.readyURL == nil)
        #expect(BackgroundStart.handle(line: "ready: http://127.0.0.1:8100/", progress: &progress) == nil)
        #expect(progress.readyURL == "http://127.0.0.1:8100/")
    }

    @Test func namesTheDeviceOnlyFromItsOwnRunnerInfo() {
        let mine = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM-A", name: "iPhone A", pid: 100)
        #expect(BackgroundStart.device(runnerInfo: mine, pid: 100, udid: "SIM-A") == "iPhone A (SIM-A)")
        // A start on another port in the same second wrote runner.json after this one.
        let other = RunnerInfo(url: "http://127.0.0.1:8101/", token: "u", udid: "SIM-B", name: "iPhone B", pid: 200)
        #expect(BackgroundStart.device(runnerInfo: other, pid: 100, udid: "SIM-A") == "SIM-A")
        #expect(BackgroundStart.device(runnerInfo: nil, pid: 100, udid: "SIM-A") == "SIM-A")
        #expect(BackgroundStart.device(runnerInfo: nil, pid: 100, udid: nil) == nil)
    }

    @Test func startsOnlyWhenNothingAnswersAtTheRunnerURL() throws {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro")
        #expect(BackgroundStart.conflict(with: existing, port: 8100, ping: .unreachable("refused"), owner: nil) == nil)

        let alive = try #require(BackgroundStart.conflict(with: existing, port: 8100, ping: .alive(busy: false, busyForMs: nil), owner: 1234))
        #expect(alive.contains("already running at http://127.0.0.1:8100/ (iPhone 17 Pro, relay start pid 1234)"))
        #expect(alive.contains("relay stop"))
        #expect(alive.contains("--port"))

        // Another runner with another token on the same port.
        let unauthorized = try #require(BackgroundStart.conflict(with: existing, port: 8100, ping: .status(401), owner: nil))
        #expect(unauthorized.contains("401"))
        #expect(unauthorized.contains("another runner"))
        #expect(unauthorized.contains("relay stop"))
        #expect(unauthorized.contains("--port"))

        let other = try #require(BackgroundStart.conflict(with: existing, port: 8100, ping: .status(404), owner: nil))
        #expect(other.contains("HTTP 404"))
        #expect(other.contains("--port"))
    }

    @Test func startsOnAnotherPortWhateverAnswersAtTheRunnerURL() {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        for ping: RunnerPing in [.alive(busy: true, busyForMs: 10), .status(401), .status(404), .unreachable("refused")] {
            #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: ping, owner: 1234) == nil)
        }
    }

    @Test func doesNotPingARunnerOnAnotherPort() {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        var pinged = false
        func ping() -> RunnerPing {
            pinged = true
            return .alive(busy: false, busyForMs: nil)
        }
        #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: ping(), owner: nil) == nil)
        #expect(!pinged)
        #expect(BackgroundStart.conflict(with: existing, port: 8100, ping: ping(), owner: nil) != nil)
        #expect(pinged)
    }

    @Test func refusesWhenTheRunnerURLHasNoPort() {
        for url in ["http://127.0.0.1/", "not a url"] {
            let existing = RunnerInfo(url: url, token: "t", udid: "SIM")
            #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: .status(401), owner: nil) != nil)
            #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: .unreachable("refused"), owner: nil) == nil)
        }
    }

    @Test func statusHelpListsTheExitStatuses() {
        #expect(Arguments.usage.contains("4 if it answers 401"))
        #expect(Arguments.usage(for: "status").contains("4 the token was rejected (401)"))
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
        #expect(RunnerPing.refusedByOS("Operation not permitted").exitCode == .unavailable)
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
        runner:      not reported (the runner predates build reporting)
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

    @Test func aConnectionTheOSRefusedSaysSo() throws {
        let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"),
                                         processRunning: true, ping: .refusedByOS("Operation not permitted"))
        #expect(RunnerStatus.text(report).contains(
            "ping:        no answer: the OS refused the connection (Operation not permitted); relay may be in a sandbox that blocks localhost"))
        let object = try #require(try JSONSerialization.jsonObject(with: RunnerStatus.json(report)) as? [String: Any])
        let ping = try #require(object["ping"] as? [String: Any])
        #expect(ping["refusedByOS"] as? Bool == true)
        #expect(ping["error"] as? String == "Operation not permitted")
        // Like no answer, it does not keep a new relay start from trying the port.
        #expect(BackgroundStart.conflict(with: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"), port: 8100,
                                         ping: .refusedByOS("Operation not permitted"), owner: nil) == nil)
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

struct StartLockTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func oneStartPerPort() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lock = try StartLock.acquire(port: 8100, home: home)
        #expect(StartLock.url(port: 8100, home: home).path == home.path + "/.relay/locks/start-8100.lock")

        // flock is per open file, so a second acquire in this process is refused like one in another process.
        #expect {
            try StartLock.acquire(port: 8100, home: home)
        } throws: { error in
            let message = String(describing: error)
            return error is SetupError && message.contains("(pid \(getpid())) is starting or running a runner on port 8100")
                && message.contains("--port")
        }
        // Another port is another lock.
        let other = try StartLock.acquire(port: 8101, home: home)
        other.release()

        lock.release()
        try StartLock.acquire(port: 8100, home: home).release()
    }

    @Test func aLeftoverLockFileDoesNotBlock() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = StartLock.url(port: 8100, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Left by a relay start that was killed; the kernel released its lock.
        try "99999999\n".write(to: url, atomically: true, encoding: .utf8)

        let lock = try StartLock.acquire(port: 8100, home: home)
        defer { lock.release() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "\(getpid())\n")
    }

    @Test func theDetachedStartKeepsTheLockItInherits() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lock = try StartLock.acquire(port: 8100, home: home)
        defer { lock.release() }
        let environment = [StartLock.inheritedEnvironmentKey: "\(lock.fileDescriptor)"]

        #expect(StartLock.inherited(port: 8100, home: home, environment: environment)?.fileDescriptor == lock.fileDescriptor)
        #expect(fcntl(lock.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        // Not the lock for another port, and not a descriptor of the file that does not hold the lock.
        try StartLock.acquire(port: 8101, home: home).release()
        #expect(StartLock.inherited(port: 8101, home: home, environment: environment) == nil)
        let unlocked = open(StartLock.url(port: 8100, home: home).path, O_RDONLY)
        defer { close(unlocked) }
        #expect(StartLock.inherited(port: 8100, home: home, environment: [StartLock.inheritedEnvironmentKey: "\(unlocked)"]) == nil)
        #expect(StartLock.inherited(port: 8100, home: home, environment: [:]) == nil)
    }

    @Test func theMessageLeavesOutAnUnknownOwner() {
        #expect(StartLock.heldMessage(port: 8100, owner: nil).hasPrefix("another relay start is starting or running a runner on port 8100, "))
    }
}

struct StartLogTests {
    @Test func logsAreNamedByPortAndNeverShared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stamp = "20261029-120000"

        // Two starts in the same second, on different ports.
        let a = try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8100)
        let b = try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8101)
        #expect(a.lastPathComponent == "start-20261029-120000-8100.log")
        #expect(b.lastPathComponent == "start-20261029-120000-8101.log")
        #expect(try Data(contentsOf: a).isEmpty)

        // A restart on the same port in the same second does not read or truncate the previous log.
        try Data("ready: http://127.0.0.1:8100/\n".utf8).write(to: a)
        let again = try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8100)
        #expect(again.lastPathComponent == "start-20261029-120000-8100-2.log")
        #expect(try Data(contentsOf: again).isEmpty)
        #expect(try String(contentsOf: a, encoding: .utf8) == "ready: http://127.0.0.1:8100/\n")
        #expect(try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8100).lastPathComponent == "start-20261029-120000-8100-3.log")

        // relay install --build has no port.
        #expect(try RunnerLauncher.createLog("build", in: directory, stamp: stamp, port: nil).lastPathComponent == "build-20261029-120000.log")
        #expect(throws: ArgumentError.self) {
            try RunnerLauncher.createLog("start", in: directory.appendingPathComponent("missing"), stamp: stamp, port: 8100)
        }
    }
}
