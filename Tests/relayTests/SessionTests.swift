import Darwin
import Foundation
@testable import relay
import Testing

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func simulator(_ name: String, _ udid: String, booted: Bool = true) -> Device {
    Device(name: name, udid: udid, kind: .simulator, os: "iOS 27.0", state: booted ? "booted" : "shutdown", isAvailable: true)
}

struct SessionNameTests {
    @Test func validNames() {
        for name in ["a", "agent-1", "Agent_1", "a.b", "0", String(repeating: "x", count: RelaySession.maxNameLength)] {
            #expect(RelaySession.isValidName(name), "\(name)")
        }
    }

    @Test func invalidNames() {
        for name in ["", ".", "..", ".hidden", "-a", "_a", "a/b", "../a", "a b", "a\n", "セッション", "a:b",
                     String(repeating: "x", count: RelaySession.maxNameLength + 1)] {
            #expect(!RelaySession.isValidName(name), "\(name)")
        }
    }

    @Test func resolvePrefersTheOption() throws {
        #expect(try RelaySession.resolve(flag: "a", environment: ["RELAY_SESSION": "b"]) == "a")
        #expect(try RelaySession.resolve(flag: nil, environment: ["RELAY_SESSION": "b"]) == "b")
        #expect(try RelaySession.resolve(flag: nil, environment: ["RELAY_SESSION": ""]) == nil)
        #expect(try RelaySession.resolve(flag: nil, environment: [:]) == nil)
    }

    @Test func resolveRejectsAnInvalidVariable() {
        #expect {
            try RelaySession.resolve(flag: nil, environment: ["RELAY_SESSION": "../x"])
        } throws: { error in
            "\(error)".contains("$RELAY_SESSION") && "\(error)".contains("../x")
        }
    }
}

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

struct RunnerSelectionTests {
    @Test func order() throws {
        let both = ["RELAY_RUNNER": "env.json", "RELAY_SESSION": "env"]
        #expect(try RunnerLocator.selection(explicitPath: "x.json", session: nil, environment: both) == .file(source: "--runner", path: "x.json"))
        #expect(try RunnerLocator.selection(explicitPath: nil, session: "s", environment: both) == .session(source: "--session", name: "s"))
        #expect(try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_RUNNER": "env.json"])
            == .file(source: "$RELAY_RUNNER", path: "env.json"))
        #expect(try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_SESSION": "env"])
            == .session(source: "$RELAY_SESSION", name: "env"))
        #expect(try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_SESSION": "", "RELAY_RUNNER": ""]) == .search)
    }

    @Test func twoVariablesOrTwoOptionsAreErrors() {
        #expect(throws: SessionSelectionError.self) {
            try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_RUNNER": "r.json", "RELAY_SESSION": "s"])
        }
        #expect(throws: SessionSelectionError.self) {
            try RunnerLocator.selection(explicitPath: "r.json", session: "s", environment: [:])
        }
    }

    /// The whole point: a session never lands on the default runner.json or another session's.
    @Test func aSessionNeverFallsBack() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        // Both the search path's files exist.
        try info.write(to: RunnerLocator.userURL(home: home))
        let project = home.appendingPathComponent("project")
        try info.write(to: RunnerInfo.defaultURL(rootURL: project))
        try info.write(to: RelaySession.infoURL(name: "other", home: home))

        for environment in [[:], ["RELAY_SESSION": "mine"]] {
            #expect(throws: RunnerUnavailableError.self) {
                try RunnerLocator.locate(explicitPath: nil, session: environment.isEmpty ? "mine" : nil, environment: environment,
                                         currentDirectory: project, home: home)
            }
        }

        try info.write(to: RelaySession.infoURL(name: "mine", home: home))
        #expect(try RunnerLocator.locate(explicitPath: nil, session: "mine", environment: [:], currentDirectory: project, home: home).path
            == home.path + "/.relay/sessions/mine/runner.json")
        // Without a session, as before: the current directory's file, then the home one.
        #expect(try RunnerLocator.locate(explicitPath: nil, environment: [:], currentDirectory: project, home: home, warn: { _ in }).path
            == project.path + "/.relay/runner.json")
        #expect(try RunnerLocator.locate(explicitPath: nil, environment: [:], currentDirectory: home, home: home, warn: { _ in }).path
            == home.path + "/.relay/runner.json")
    }

    @Test func aRecordingOfAMissingSessionIsNotAnother() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{}".utf8).write(to: { () -> URL in
            let url = Recording.stateURL(port: 8100, home: home)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }())
        #expect(throws: RunnerUnavailableError.self) {
            try Recording.stateURLOfRunner(runnerPath: nil, session: "mine", home: home, environment: [:], currentDirectory: home)
        }
        #expect(throws: RunnerUnavailableError.self) {
            try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: ["RELAY_SESSION": "mine"], currentDirectory: home)
        }
        // Without a session, the only state file, as before.
        #expect(try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: [:], currentDirectory: home)?.lastPathComponent
            == "recording-8100.json")
    }

    @Test func benchUsesTheSessionsRunnerJSONOnly() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "default", udid: "SIM").write(to: RunnerLocator.userURL(home: home))
        var options = BenchOptions(url: "")
        options.session = "mine"
        #expect(throws: RunnerUnavailableError.self) { try Bench.sessionInfoURL(options, environment: [:], home: home) }

        try RunnerInfo(url: "http://127.0.0.1:8101/", token: "mine", udid: "SIM").write(to: RelaySession.infoURL(name: "mine", home: home))
        let url = try #require(try Bench.sessionInfoURL(options, environment: [:], home: home))
        #expect(try Bench.token(options, infoURL: url) == "mine")
        // Nothing to read with both given, or without a session.
        options.url = "http://127.0.0.1:8101"
        options.token = "given"
        #expect(try Bench.sessionInfoURL(options, environment: [:], home: home) == nil)
        #expect(try Bench.sessionInfoURL(BenchOptions(url: "http://x"), environment: [:], home: home) == nil)
    }
}

struct SessionFilesTests {
    @Test func paths() throws {
        let home = URL(fileURLWithPath: "/h", isDirectory: true)
        #expect(RelaySession.infoURL(name: "a", home: home).path == "/h/.relay/sessions/a/runner.json")
        #expect(RelaySession.lockURL(name: "a", home: home).path == "/h/.relay/sessions/a/session.lock")
        #expect(StartLock.deviceURL(udid: "abc-1", home: home).path == "/h/.relay/locks/device-ABC-1.lock")
    }

    @Test func namesAreTheValidDirectories() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RelaySession.names(home: home).isEmpty)
        for name in ["b", "a", ".DS_Store"] {
            try FileManager.default.createDirectory(at: RelaySession.directory(name: name, home: home), withIntermediateDirectories: true)
        }
        #expect(RelaySession.names(home: home) == ["a", "b"])
    }

    @Test func runnerInfoKeepsTheSessionAndOldFilesStillRead() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("runner.json")
        try RunnerInfo(url: "u", token: "t", udid: "SIM", session: "a").write(to: url)
        #expect(try RunnerInfo.read(from: url).session == "a")
        try Data(#"{"url":"u","token":"t","udid":"SIM"}"#.utf8).write(to: url)
        #expect(try RunnerInfo.read(from: url).session == nil)
    }

    @Test func logsNameTheSession() throws {
        let directory = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stamp = "20261104-120000"
        #expect(try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8101, session: "a").lastPathComponent
            == "start-20261104-120000-a-8101.log")
        #expect(try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8101).lastPathComponent == "start-20261104-120000-8101.log")
    }

    @Test func defaultOutputsNameTheSession() {
        let now = Date(timeIntervalSince1970: 0)
        let temporary = URL(fileURLWithPath: "/t", isDirectory: true)
        let shot = RunnerControl.screenshotURL(RunnerScreenshot(output: nil), now: now, session: "a", temporaryDirectory: temporary)
        #expect(shot.lastPathComponent.hasPrefix("screenshot-a-"))
        #expect(!RunnerControl.screenshotURL(RunnerScreenshot(output: nil), now: now, temporaryDirectory: temporary).lastPathComponent.hasPrefix("screenshot-a-"))
        #expect(Recording.outputURL(nil, now: now, session: "a", temporaryDirectory: temporary).lastPathComponent.hasPrefix("relay-recording-a-"))
    }

    @Test func testDataIsPerPortAndOutsideTheBuild() {
        let build = URL(fileURLWithPath: "/h/.relay/build/installed", isDirectory: true)
        #expect(RunnerLauncher.testDataURL(buildURL: build, port: 8101).path == "/h/.relay/build/installed/TestData/port-8101")
        #expect(RunnerLauncher.testDataURL(buildURL: build, port: 8101) != RunnerLauncher.testDataURL(buildURL: build, port: 8102))
    }
}

struct PortPickerTests {
    private func lockInHome(_ home: URL) -> (Int) throws -> StartLock? {
        { try StartLock.tryAcquire(port: $0, home: home) }
    }

    @Test func theDefaultPortIsLeftToStartsWithoutASession() {
        #expect(!PortPicker.sessionRange.contains(8100))
    }

    @Test func picksTheFirstPortThatIsBothUnlockedAndFree() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let held = try StartLock.acquire(port: 9001, home: home)
        defer { held.release() }

        let picked = try PortPicker.pick(range: 9001...9004, isFree: { $0 != 9002 }, lock: lockInHome(home))
        defer { picked.lock.release() }
        #expect(picked.port == 9003)

        // The lock is held, so the next start moves on, and the one given up for a taken port is free again.
        let next = try PortPicker.pick(range: 9001...9004, isFree: { _ in true }, lock: lockInHome(home))
        defer { next.lock.release() }
        #expect(next.port == 9002)
    }

    @Test func noPortLeftIsAnError() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect {
            try PortPicker.pick(range: 9001...9002, isFree: { _ in false }, lock: lockInHome(home))
        } throws: { "\($0)".contains("--port") && "\($0)".contains("9001") }
    }

    @Test func isFreeSeesAListeningPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        #expect(!PortPicker.isFree(Int(in_port_t(bigEndian: address.sin_port))))
    }
}

struct DeviceLockTests {
    @Test func oneStartPerDevice() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let phone = simulator("iPhone 17", "sim-a")
        let lock = try StartLock.acquire(device: phone, session: "a", home: home)

        #expect {
            try StartLock.acquire(device: phone, session: "b", home: home)
        } throws: { error in
            let message = "\(error)"
            return error is SetupError && message.contains("sim-a") && message.contains("session a") && message.contains("relay stop --session a")
        }
        // The other device is free, and so is this one after the holder exits.
        let other = try StartLock.acquire(device: simulator("iPhone 17 Pro", "sim-b"), session: "b", home: home)
        other.release()
        lock.release()
        try StartLock.acquire(device: phone, session: "b", home: home).release()
    }

    @Test func holderReadsPidAndSession() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let phone = simulator("iPhone 17", "SIM-A")
        let url = StartLock.deviceURL(udid: phone.udid, home: home)
        #expect(StartLock.holder(of: url) == nil)

        let lock = try StartLock.acquire(device: phone, session: "a", home: home)
        #expect(StartLock.holder(of: url) == StartLock.Holder(pid: getpid(), session: "a"))
        #expect(StartLock.devicesInUse([phone, simulator("iPhone 17 Pro", "SIM-B")], home: home) == ["SIM-A": "session a, relay start pid \(getpid())"])

        lock.release()
        #expect(StartLock.holder(of: url) == nil)
        #expect(StartLock.devicesInUse([phone], home: home).isEmpty)
    }

    @Test func aHolderWithoutASessionStopsWithPlainRelayStop() {
        let message = StartLock.deviceHeldMessage(simulator("iPhone 17", "SIM-A"), holder: StartLock.Holder(pid: 12))
        #expect(message.contains("relay start pid 12"))
        #expect(!message.contains("--session"))
    }

    @Test func oneStartPerSession() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lock = try StartLock.acquire(session: "a", home: home)
        #expect {
            try StartLock.acquire(session: "a", home: home)
        } throws: { "\($0)".contains("relay stop --session a") }
        try StartLock.acquire(session: "b", home: home).release()
        lock.release()
    }
}

struct AutomaticDeviceTests {
    private let devices = [simulator("iPhone 17", "SIM-A"), simulator("iPhone 17 Pro", "SIM-B"), simulator("iPhone Air", "SIM-C", booted: false)]

    @Test func leavesOutDevicesInUse() throws {
        let selection = try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-A": "session a"])
        #expect(selection.device.udid == "SIM-B")
        #expect(selection.isAutomatic)
    }

    @Test func caseOfTheUDIDDoesNotMatter() throws {
        let lower = [simulator("iPhone 17", "sim-a"), simulator("iPhone 17 Pro", "sim-b")]
        #expect(try DeviceSelector.select(from: lower, udid: nil, name: nil, inUse: ["SIM-A": "session a"]).device.udid == "sim-b")
    }

    @Test func nothingFreeSaysWhoHoldsIt() {
        #expect {
            try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-A": "session a", "SIM-B": "session b"])
        } throws: { error in
            let message = "\(error)"
            return message.contains("in use by another relay start") && message.contains("session a") && message.contains("session b")
                && message.contains("SIM-C")
        }
    }

    @Test func severalFreeStillNeedAName() {
        #expect(throws: SetupError.self) {
            try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-X": "session x"])
        }
    }

    /// A named device is not replaced by another one: the device lock then says it is in use.
    @Test func aNamedDeviceIsStillPicked() throws {
        #expect(try DeviceSelector.select(from: devices, udid: "SIM-A", name: nil, inUse: ["SIM-A": "session a"]).device.udid == "SIM-A")
        #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17", inUse: ["SIM-A": "session a"]).device.udid == "SIM-A")
    }

    @Test func withoutAnyInUseItIsAsBefore() throws {
        #expect(try DeviceSelector.select(from: [simulator("iPhone 17", "SIM-A")], udid: nil, name: nil).device.udid == "SIM-A")
    }

    @Test func prepareClaimsTheDeviceBeforeBooting() throws {
        let commands = HostCommands(
            xcrun: { arguments in
                if arguments.prefix(3) == ["simctl", "list", "devices"] {
                    return #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"SIM-C","name":"iPhone Air","state":"Shutdown","isAvailable":true}]}}"#
                }
                Issue.record("should not run: \(arguments)")
                return ""
            },
            devicectlJSON: { _ in Data() },
            run: { _, _ in "" }
        )
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect {
            _ = try StartSetup.prepare(
                StartOptions(udid: "SIM-C"), commands: commands, configURL: home.appendingPathComponent("config.json"),
                resolveProject: { _ in (home, .option) }, staleness: { _, _ in nil }, info: { _ in },
                claimDevice: { throw SetupError(description: "in use: \($0.udid)") }
            )
        } throws: { "\($0)".contains("in use: SIM-C") }
    }
}

struct BuildLockTests {
    private func makeLock(_ home: URL) throws -> BuildLock {
        try BuildLock(derivedData: home.appendingPathComponent("DerivedData-sim"), relayDirectory: home.appendingPathComponent(".relay"))
    }

    @Test func aDerivedDataHasOneLockFile() {
        let relay = URL(fileURLWithPath: "/h/.relay", isDirectory: true)
        let sim = BuildLock.url(derivedData: URL(fileURLWithPath: "/h/.relay/build/a/DerivedData-sim"), relayDirectory: relay)
        #expect(sim.deletingLastPathComponent().path == "/h/.relay/locks")
        #expect(sim.lastPathComponent.hasPrefix("build-"))
        #expect(sim != BuildLock.url(derivedData: URL(fileURLWithPath: "/h/.relay/build/a/DerivedData-device"), relayDirectory: relay))
    }

    @Test func sharedHoldersRunSideBySide() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try makeLock(home)
        let second = try makeLock(home)
        defer {
            first.release()
            second.release()
        }
        #expect(try first.wait(for: .shared, info: { _ in }) == false)
        #expect(try second.wait(for: .shared, info: { _ in }) == false)
    }

    @Test func anExclusiveHolderMakesOthersWaitAndSaysSo() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let builder = try makeLock(home)
        try builder.wait(for: .exclusive, info: { _ in })
        let waiter = try makeLock(home)
        defer { waiter.release() }

        // Released from another thread once the waiter has said that it waits.
        var lines: [String] = []
        let waited = try waiter.wait(for: .shared, isCancelled: { false }, info: { line in
            lines.append(line)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { builder.release() }
        })
        #expect(waited)
        #expect(lines.count == 1)
        #expect(lines[0].contains("waiting for another relay start's build"))
    }

    @Test func aBuildWaitsForAStartLaunchingFromTheProducts() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let launching = try makeLock(home)
        try launching.wait(for: .shared, info: { _ in })
        let builder = try makeLock(home)
        defer { builder.release() }
        let waited = try builder.wait(for: .exclusive, isCancelled: { false }, info: { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { launching.release() }
        })
        #expect(waited)
    }

    /// `body` on a thread of its own, since waiting for the lock polls. `join` returns what it returned.
    private final class Waiter: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<Bool, Error>?
        private var waiting = false
        private let waitingSignal = DispatchSemaphore(value: 0)

        init(_ buildLock: BuildLock, deadline: Date) {
            let thread = Thread { [self] in
                let result = Result {
                    try buildLock.wait(for: .exclusive, isCancelled: { Date() > deadline }, info: { [self] _ in waitingSignal.signal() })
                }
                lock.withLock { self.result = result }
                done.signal()
            }
            thread.start()
        }

        /// Returns once the thread has said that it waits, or by the time limit.
        func waitUntilPolling(timeout: TimeInterval) -> Bool {
            waitingSignal.wait(timeout: .now() + timeout) == .success
        }

        var hasFinished: Bool { lock.withLock { result != nil } }

        func join() throws -> Bool {
            done.wait()
            return try lock.withLock { result! }.get()
        }
    }

    // On Darwin a failed LOCK_EX | LOCK_NB keeps the shared lock: two starts that both held it shared and
    // both decided to build would each block the other for ever. The limit turns that into a failure here.
    @Test func twoStartsHoldingItSharedCanBothGoOnToBuild() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try makeLock(home)
        let second = try makeLock(home)
        defer {
            first.release()
            second.release()
        }
        try first.wait(for: .shared, info: { _ in })
        try second.wait(for: .shared, info: { _ in })

        let deadline = Date().addingTimeInterval(3)
        let waiter = Waiter(second, deadline: deadline)
        #expect(waiter.waitUntilPolling(timeout: 3))

        // The other one gets it, and the waiter does not get it at the same time.
        try first.wait(for: .exclusive, isCancelled: { Date() > deadline }, info: { _ in })
        Thread.sleep(forTimeInterval: BuildLock.pollInterval * 2)
        #expect(!waiter.hasFinished)

        first.release()
        #expect(try waiter.join())
    }

    @Test func aBuilderGoesBackToSharedWithoutLettingABuildIn() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let builder = try makeLock(home)
        let reader = try makeLock(home)
        let nextBuilder = try makeLock(home)
        defer {
            builder.release()
            reader.release()
            nextBuilder.release()
        }
        try builder.wait(for: .exclusive, info: { _ in })

        let waiter = Waiter(nextBuilder, deadline: Date().addingTimeInterval(5))
        #expect(waiter.waitUntilPolling(timeout: 3))

        // Nothing holds it against the builder, so this does not wait; a reader then joins it.
        #expect(try builder.wait(for: .shared, isCancelled: { true }, info: { _ in }) == false)
        #expect(try reader.wait(for: .shared, isCancelled: { true }, info: { _ in }) == false)
        Thread.sleep(forTimeInterval: BuildLock.pollInterval * 2)
        #expect(!waiter.hasFinished)

        // A build gets in only once nobody reads the products any more.
        builder.release()
        reader.release()
        #expect(try waiter.join())
    }

    @Test func waitingCanBeCancelled() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let builder = try makeLock(home)
        defer { builder.release() }
        try builder.wait(for: .exclusive, info: { _ in })
        let waiter = try makeLock(home)
        defer { waiter.release() }
        #expect(throws: SetupError.self) {
            try waiter.wait(for: .shared, isCancelled: { true }, info: { _ in })
        }
    }
}

struct SessionConflictTests {
    private let existing = RunnerInfo(url: "http://127.0.0.1:8101/", token: "t", udid: "SIM", name: "iPhone 17")

    @Test func aRunnerThatStillAnswersIsAConflict() throws {
        let message = try #require(BackgroundStart.conflict(session: "a", with: existing, ping: .alive(busy: false, busyForMs: nil)))
        #expect(message.contains("relay stop --session a"))
        #expect(message.contains("iPhone 17"))
    }

    /// A port another session took since answers 401 to this token: that is not this session's runner.
    @Test func anythingElseIsNot() {
        for ping in [RunnerPing.status(401), .status(404), .unreachable("refused"), .refusedByOS("EPERM")] {
            #expect(BackgroundStart.conflict(session: "a", with: existing, ping: ping) == nil)
        }
    }
}

struct RunnerSessionsListTests {
    private func info(_ url: String, name: String? = "iPhone 17", session: String? = nil) -> RunnerInfo {
        RunnerInfo(url: url, token: "t", udid: "SIM", name: name, pid: 42, session: session)
    }

    @Test func rowsListTheDefaultRunnerAndEverySessionThatHasOne() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RunnerSessions.rows(home: home, ping: { _ in .unreachable("") }, processRunning: { _ in nil }).isEmpty)

        try info("http://127.0.0.1:8100/").write(to: RunnerLocator.userURL(home: home))
        try info("http://127.0.0.1:8101/", session: "a").write(to: RelaySession.infoURL(name: "a", home: home))
        try info("http://127.0.0.1:8102/", session: "b").write(to: RelaySession.infoURL(name: "b", home: home))
        // Ended: only its directory and its free lock are left.
        try StartLock.acquire(session: "ended", home: home).release()
        // Still booting or building: its lock is held and there is no runner.json yet.
        let starting = try StartLock.acquire(session: "starting", home: home)
        defer { starting.release() }

        let rows = RunnerSessions.rows(home: home, ping: { $0.url.contains("8102") ? .unreachable("refused") : .alive(busy: $0.url.contains("8101"), busyForMs: nil) },
                                       processRunning: { $0.url.contains("8102") ? nil : 42 })
        #expect(rows.map(\.label) == ["(default)", "a", "b", "starting"])
        #expect(rows.map(\.state) == [.running, .busy, .noAnswer, .starting])
        #expect(rows.map(\.processRunning) == [true, true, false, true])
        #expect(rows[3].pid == getpid())
        #expect(rows[3].info == nil)
    }

    @Test func stateOfEachAnswer() {
        #expect(RunnerSessions.state(for: .alive(busy: false, busyForMs: nil)) == .running)
        #expect(RunnerSessions.state(for: .alive(busy: true, busyForMs: 3)) == .busy)
        #expect(RunnerSessions.state(for: .status(401)) == .rejected)
        #expect(RunnerSessions.state(for: .unreachable("")) == .noAnswer)
        #expect(RunnerSessions.state(for: .refusedByOS("")) == .unknown)
    }

    @Test func table() {
        let url = URL(fileURLWithPath: "/r.json")
        let table = RunnerSessions.table([
            .init(session: nil, state: .running, info: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM-1"), infoURL: url, pid: 7, processRunning: true),
            .init(session: "agent-1", state: .noAnswer, info: info("http://127.0.0.1:8101/"), infoURL: url, pid: 42, processRunning: false),
            .init(session: "s", state: .starting, infoURL: url, pid: 9, processRunning: true)
        ])
        #expect(table == """
        SESSION    STATE      DEVICE           URL                     PID
        (default)  running    SIM-1            http://127.0.0.1:8100/  7
        agent-1    no answer  iPhone 17 (SIM)  http://127.0.0.1:8101/  42 (exited)
        s          starting   -                -                       9
        """)
        #expect(RunnerSessions.table([]) == "no runners")
    }

    @Test func json() throws {
        let url = URL(fileURLWithPath: "/r.json")
        let data = RunnerSessions.json([
            .init(session: nil, state: .running, info: info("http://127.0.0.1:8100/"), infoURL: url, pid: 42, processRunning: true,
                  ping: .alive(busy: false, busyForMs: nil)),
            .init(session: "s", state: .starting, infoURL: url, pid: nil, processRunning: false)
        ])
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.count == 2)
        #expect(objects[0]["session"] is NSNull)
        #expect(objects[0]["alive"] as? Bool == true)
        #expect(objects[0]["url"] as? String == "http://127.0.0.1:8100/")
        #expect(objects[0]["pid"] as? Int == 42)
        #expect(objects[1]["session"] as? String == "s")
        #expect(objects[1]["state"] as? String == "starting")
        #expect(objects[1]["url"] is NSNull)
        // The token stays in the 0600 file.
        #expect(!String(decoding: data, as: UTF8.self).contains("\"token\""))
    }

    @Test func statusShowsTheSession() {
        let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info("http://127.0.0.1:8101/", session: "a"),
                                         processRunning: true, ping: .alive(busy: false, busyForMs: nil))
        #expect(RunnerStatus.text(report).hasPrefix("session:"))
        let object = (try? JSONSerialization.jsonObject(with: RunnerStatus.json(report))) as? [String: Any]
        #expect(object?["session"] as? String == "a")
    }
}

struct SessionlessWarningTests {
    private let info = RunnerInfo(url: "http://127.0.0.1:8101", token: "token", udid: "UDID")

    /// `locate`, and what it warned about.
    private func locate(session: String? = nil, explicitPath: String? = nil, environment: [String: String] = [:], in home: URL) throws -> (url: URL, warnings: [String]) {
        var warnings: [String] = []
        let url = try RunnerLocator.locate(explicitPath: explicitPath, session: session, environment: environment,
                                           currentDirectory: home, home: home, warn: { warnings.append($0) })
        return (url, warnings)
    }

    @Test func runningMeansARunnerInfoOrAHeldLock() {
        let running = RelaySession.running(
            names: ["building", "ended", "up"],
            hasRunnerInfo: { $0 == "up" },
            isLocked: { $0 == "building" }
        )
        #expect(running == ["building", "up"])
    }

    @Test func aLockIsNotOpenedWhenRunnerInfoAlreadySaysSo() {
        var opened: [String] = []
        _ = RelaySession.running(names: ["up"], hasRunnerInfo: { _ in true }, isLocked: { opened.append($0); return false })
        #expect(opened.isEmpty)
    }

    @Test func messageNamesTheFileAndTheSessions() {
        let url = URL(fileURLWithPath: "/home/.relay/runner.json")
        #expect(RunnerLocator.sessionlessWarning(using: url, sessions: []) == nil)
        #expect(RunnerLocator.sessionlessWarning(using: url, sessions: ["a"])
            == "relay: warning: no session selected; using /home/.relay/runner.json, while session a is running; pass --session or set RELAY_SESSION")
        #expect(RunnerLocator.sessionlessWarning(using: url, sessions: ["a", "b"])
            == "relay: warning: no session selected; using /home/.relay/runner.json, while sessions a, b are running; pass --session or set RELAY_SESSION")
    }

    @Test func aSearchWarnsWhileASessionHasARunnerInfo() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try info.write(to: RunnerLocator.userURL(home: home))
        #expect(try locate(in: home).warnings.isEmpty)

        try info.write(to: RelaySession.infoURL(name: "a", home: home))
        let found = try locate(in: home)
        // It still works: the file is the one the search finds, as without sessions.
        #expect(found.url.path == home.path + "/.relay/runner.json")
        #expect(found.warnings == [RunnerLocator.sessionlessWarning(using: found.url, sessions: ["a"])])
    }

    @Test func aSearchWarnsWhileASessionIsStarting() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try info.write(to: RunnerLocator.userURL(home: home))
        let lock = try StartLock.acquire(session: "a", home: home)
        #expect(try locate(in: home).warnings.count == 1)

        // What an ended session leaves: its directory, and a lock nobody holds.
        lock.release()
        #expect(RelaySession.names(home: home) == ["a"])
        #expect(try locate(in: home).warnings.isEmpty)
    }

    @Test func aSelectedRunnerDoesNotWarn() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try info.write(to: RelaySession.infoURL(name: "a", home: home))
        try info.write(to: RelaySession.infoURL(name: "b", home: home))
        let path = RelaySession.infoURL(name: "b", home: home).path

        #expect(try locate(session: "a", in: home).warnings.isEmpty)
        #expect(try locate(environment: ["RELAY_SESSION": "a"], in: home).warnings.isEmpty)
        #expect(try locate(explicitPath: path, in: home).warnings.isEmpty)
        #expect(try locate(environment: ["RELAY_RUNNER": path], in: home).warnings.isEmpty)
    }

    @Test func nothingFoundThrowsWithoutAWarning() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try info.write(to: RelaySession.infoURL(name: "a", home: home))
        var warnings: [String] = []
        #expect(throws: RunnerUnavailableError.self) {
            try RunnerLocator.locate(explicitPath: nil, environment: [:], currentDirectory: home, home: home, warn: { warnings.append($0) })
        }
        #expect(warnings.isEmpty)
    }
}
