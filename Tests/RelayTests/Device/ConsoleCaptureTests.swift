import Darwin
import Foundation
@testable import Relay
import Testing

struct ConsoleCaptureTests {
  private func record(in directory: URL) -> ConsoleState {
    ConsoleState(captureID: UUID().uuidString, udid: "sim", bundleID: "com.example.host", session: "tests",
                 path: directory.appendingPathComponent("console.bin").path, runnerPID: 12, runnerStart: Date(),
                 pid: 42, startedAt: Date(), appPID: 101, state: "recording")
  }

  @Test func argumentsAndScenario() throws {
    let id = UUID().uuidString
    #expect(try Arguments.parse(["console", "status"]) == .console(.status(nil)))
    #expect(try Arguments.parse(["console", "status", id.lowercased()]) == .console(.status(id)))
    #expect(try Arguments.parse(["console", "stop", id]) == .console(.stop(id)))
    let parsed = try Arguments.parse(["launch", "host", "--console=output", "--restart", "--session=test"])
    #expect(parsed == .runner(RunnerControlOptions(operation: .launch(bundleID: "host"), session: "test", console: ConsoleLaunch(path: "output", restart: true))))
    for words in [["launch", "host", "--restart"], ["launch", "host", "--console"], ["launch", "host", "--console="],
                  ["launch", "host", "--console", "a", "--console", "b"], ["console", "stop"], ["console", "stop", "../" + id],
                  ["console", "status", id + "/"], ["console", "stop", id, id], ["console", "read", id]] {
      #expect(throws: ArgumentError.self) { try Arguments.parse(words) }
    }
    #expect(throws: ScenarioLineErrors.self) { try Scenario.parse([(1, "launch host --console output")]) }
  }

  @Test func boundedControlOutputAndExit() throws {
    let listing = try ConsoleCapture.query(["-c", "echo 'PID Status Label'; echo '23 0 UIKitApplication:app[a]'; echo diagnostic >&2"], executable: "/bin/sh")
    #expect(try ConsoleCapture.appPID(in: listing, bundleID: "app") == 23)
    #expect(!listing.contains("diagnostic"))
    for script in ["exit 7", "kill -TERM $$"] {
      let error = #expect(throws: ConsoleProblem.self) { try ConsoleCapture.query(["-c", script], executable: "/bin/sh") }
      #expect(error?.code == .consoleUnavailable)
    }
  }

  @Test func listingRequiresExactAppAndActivePID() throws {
    let rows = "PID\tStatus\tLabel\n99 0 UIKitApplication:com.example.host.other[a]\n- 0 UIKitApplication:com.example.host[b]"
    #expect(try ConsoleCapture.appPID(in: rows, bundleID: "com.example.host") == nil)
    #expect(try ConsoleCapture.appPID(in: rows + "\n123 0 UIKitApplication:com.example.Host[a][b]", bundleID: "com.example.host") == 123)
    #expect(throws: ConsoleProblem.self) { try ConsoleCapture.appPID(in: "?", bundleID: "b") }
    #expect(throws: ConsoleProblem.self) { try ConsoleCapture.appPID(in: rows + "\n? 0 UIKitApplication:b[a]", bundleID: "b") }
    var tools = HostCommands.live
    tools.xcrun = { _, _ in #"{"devices":{}}"# }
    tools.devicectlJSON = { _, _ in Issue.record("consulted a physical device"); return Data() }
    let error = #expect(throws: ConsoleProblem.self) { try ConsoleCapture.requireSimulator("physical", commands: tools) }
    #expect(error?.code == .consoleUnsupported)
  }

  @Test func ownershipAndCorruption() throws {
    let directory = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = record(in: directory)
    let id = record.captureID
    let file = ConsoleState.file(id, in: directory)
    try record.save(in: directory)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    let owner = RelayProcess.Snapshot(startedAt: try #require(record.startedAt), executable: RelayProcess.currentExecutable,
                                      arguments: ["relay"] + record.workerArguments + ["8"])
    #expect(try ConsoleCapture.checked(id, in: directory, snapshot: { $0 == record.pid ? owner : nil }).captureID == id)
    var impostors = [RelayProcess.Snapshot]()
    for index in 1 ... 5 {
      var fake = owner
      fake.arguments[index] += "x"
      impostors.append(fake)
    }
    var reused = owner
    reused.startedAt.addTimeInterval(0.0001)
    #expect(try ConsoleCapture.checked(id, in: directory, snapshot: { _ in reused }).reason == "lost")
    try record.save(in: directory)
    reused = owner
    reused.executable = "/bin/cat"
    impostors.append(reused)
    for fake in impostors {
      let failure = #expect(throws: ConsoleProblem.self) { try ConsoleCapture.checked(id, in: directory, snapshot: { _ in fake }) }
      #expect(failure?.code == .consoleOwnershipUnverified)
    }
    var zombie = owner
    zombie.arguments = []
    #expect(try ConsoleCapture.checked(id, in: directory, snapshot: { _ in zombie }).reason == "lost")
    try record.save(in: directory)
    var finished = record
    finished.finish("stopped")
    let latest = try ConsoleCapture.checked(id, in: directory, snapshot: { _ in
      try? finished.save(in: directory)
      return impostors[0]
    })
    #expect(latest.reason == "stopped")
    try Data("broken".utf8).write(to: file)
    let broken = #expect(throws: ConsoleProblem.self) { try ConsoleState.read(id, in: directory) }
    #expect(broken?.code == .consoleOwnershipUnverified)
    let missing = #expect(throws: ConsoleProblem.self) { try ConsoleState.read(UUID().uuidString, in: directory) }
    #expect(missing?.code == .consoleNotFound)
  }

  @Test func binaryLimitExclusiveCreationAndWriteFailure() throws {
    let dir = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: dir) }
    let output = dir.appendingPathComponent("raw")
    let reserved = dir.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: false)
    let alias = dir.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: reserved)
    #expect(throws: ConsoleProblem.self) { try ConsoleSink.outputPath(alias.appendingPathComponent("journal").path, stateDirectory: reserved) }
    #expect(try ConsoleSink.outputPath(output.path, stateDirectory: reserved) == output.path)
    let fd = try ConsoleSink.create(output.path)
    defer { close(fd) }
    #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    #expect(throws: ConsoleProblem.self) { try ConsoleSink.create(output.path) }
    let link = dir.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("absent"))
    #expect(throws: ConsoleProblem.self) { try ConsoleSink.create(link.path) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("absent").path))
    var sink = ConsoleSink(fd: fd, capacity: 3)
    let bytes = Data([0xff, 0, 1, 2, 3])
    var calls = 0
    bytes.withUnsafeBytes {
      sink.append($0) { fd, pointer, _ in
        calls += 1
        if calls == 1 { errno = EINTR; return -1 }
        return write(fd, pointer, 1)
      }
    }
    bytes.withUnsafeBytes { sink.append($0) }
    #expect(calls == 4 && sink.count == 3 && sink.error == nil)
    #expect(try Data(contentsOf: output) == bytes.prefix(3))
    var failed = ConsoleSink(fd: -1)
    bytes.withUnsafeBytes { failed.append($0) }
    #expect(failed.error != nil && failed.count == 0)
    bytes.withUnsafeBytes { failed.append($0) { _, _, _ in Issue.record("retried failed writer"); return 0 } }
  }

  @Test func concurrentLeaseHasOneOwner() throws {
    let directory = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("capture.lock")
    let locks = Locked<[StartLock]>([])
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
      if let lock = try? StartLock.take(url) { locks.withLock { $0.append(lock) } }
    }
    #expect(locks.value.count == 1)
    locks.value.forEach { $0.release() }
    let reacquired = try StartLock.take(url)
    try #require(reacquired).release()
  }

  @Test func terminationAndPruneOnlyExpiredState() throws {
    let dir = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: dir) }
    var ended = record(in: dir)
    let live = record(in: dir)
    let owner = try #require(try ConsoleState.ownerLock(live.captureID, in: dir, exclusive: false))
    defer { close(owner) }
    try live.save(in: dir)
    try Data([255]).write(to: URL(fileURLWithPath: ended.path))
    ended.finish("child_exited", status: 7 << 8)
    #expect(ended.childExit == 7 && ended.childSignal == nil)
    try ended.save(in: dir)
    let status = try ConsoleCapture.checked(ended.captureID, in: dir, snapshot: { _ in Issue.record("signalled an ended capture"); return nil })
    #expect(status.reason == "child_exited")
    var signalled = record(in: dir)
    signalled.finish("stopped", status: SIGTERM)
    #expect(signalled.childSignal == 15 && signalled.childExit == nil)
    try signalled.save(in: dir)
    let endTime = try #require(ended.finishedAt)
    ConsoleState.prune(in: dir, now: endTime.addingTimeInterval(7 * 86400 - 1))
    #expect(try ConsoleState.ids(in: dir).count == 3)
    ConsoleState.prune(in: dir, now: endTime.addingTimeInterval(7 * 86400 + 2))
    #expect(try ConsoleState.ids(in: dir) == [live.captureID])
    #expect(try Data(contentsOf: URL(fileURLWithPath: ended.path)) == Data([255]))
    #expect(try ConsoleState.ids(in: dir.appendingPathComponent("missing")).isEmpty)
  }

  @Test func appOutcomeAndLaunchJSON() throws {
    let dir = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: dir) }
    var capture = record(in: dir)
    #expect(ConsoleCapture.appOutcome(capture) == "unknown")
    capture.appPID = getpid()
    capture.appStart = RelayProcess.startTime(pid: getpid())
    #expect(ConsoleCapture.appOutcome(capture) == "running")
    capture.appStart = .distantPast
    #expect(ConsoleCapture.appOutcome(capture) == "ended")
    let body = Data(#"{ "ok": false, "code": "busy", "extra": 42 }"#.utf8)
    let result = try #require(JSONSerialization.jsonObject(with: capture.attaching(to: body, in: dir)) as? [String: Any])
    #expect(result["code"] as? String == "busy" && result["extra"] as? Int == 42)
    let console = try #require(result["console"] as? [String: Any])
    #expect(console["captureID"] as? String == capture.captureID && console["stream"] as? String == "combined")
    // A launch without --console still returns the exact runner response, including its spacing.
    let info = RunnerInfo(url: "http://localhost", token: "fixture", udid: "sim", hostBundleID: "example")
    let c = RunnerConnection(infoURL: dir, info: info, baseURL: URL(fileURLWithPath: "/"))
    let pipe = Pipe()
    let success = Data(#"{ "ok" : true }"#.utf8)
    let exit = RunnerControl.perform(.launch(bundleID: "host"), on: c, successOutput: pipe.fileHandleForWriting) { _ in
      RunnerResponse(status: 200, body: success)
    }
    try pipe.fileHandleForWriting.close()
    #expect(exit == 0 && pipe.fileHandleForReading.readDataToEndOfFile() == success + Data([10]))
  }
}

extension ConsoleCaptureTests {
  @Test func guardRetriesContendedOwnerLockUntilReleasedOrCancelled() throws {
    let dir = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString
    let reader = try #require(try ConsoleState.ownerLock(id, in: dir, exclusive: true))
    defer { close(reader) }
    var attempts = 0
    let cancelled = try ConsoleTransport.acquireOwner(id, in: dir) {
      attempts += 1
      return attempts == 2
    }
    #expect(cancelled == nil && attempts == 2)
    let expired = try ConsoleTransport.acquireOwner(id, in: dir, timeout: 0.05) { false }
    #expect(expired == nil)
    attempts = 0
    let guardFD = try #require(try ConsoleTransport.acquireOwner(id, in: dir) {
      attempts += 1
      if attempts == 2 { flock(reader, LOCK_UN) }
      return false
    })
    defer { close(guardFD) }
    #expect(attempts == 2)
    #expect(try ConsoleState.ownerLock(id, in: dir, exclusive: true) == nil)
  }
}
