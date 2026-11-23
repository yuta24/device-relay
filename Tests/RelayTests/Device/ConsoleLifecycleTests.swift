import Darwin
import Foundation
@testable import Relay
import Testing

private final class BundleMarker: NSObject {}

/// The injected absolute tool is the only executable used for list, terminate and launch.
private struct ConsoleFixture: Sendable {
  let home: URL
  var runtime: ConsoleRuntime
  let output: URL
  let connection: RunnerConnection

  init(_ mode: String) throws {
    home = try temporaryHome()
    output = home.appendingPathComponent("capture")
    var dir = Bundle(for: BundleMarker.self).bundleURL
    while !FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("relay").path), dir.path != "/" {
      dir.deleteLastPathComponent()
    }
    let relay = dir.appendingPathComponent("relay")
    guard FileManager.default.isExecutableFile(atPath: relay.path) else { throw SetupError(description: "missing built relay in test products") }
    let tool = home.appendingPathComponent("fake-simctl")
    try Self.script.write(to: tool, atomically: true, encoding: .utf8)
    chmod(tool.path, 0o700)
    try mode.write(to: home.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    runtime = ConsoleRuntime(home: home, relay: relay.path, tool: tool.path, owner: { _ in getpid() }, simulator: { _ in })
    let url = URL(string: "http://localhost")!
    connection = RunnerConnection(infoURL: home, info: RunnerInfo(url: url.absoluteString, token: "fixture", udid: "FAKE", hostBundleID: "host.id"), baseURL: url)
  }

  static let script = #"""
  #!/usr/bin/python3
  import os, pathlib, signal, sys, time
  base = pathlib.Path(__file__).parent
  args = sys.argv[1:]
  mode = (base / 'mode').read_text()
  current = base / 'current'
  if args == ['simctl', 'spawn', 'FAKE', 'launchctl', 'list']:
      print('PID Status Label')
      if current.exists():
          print(current.read_text() + ' 0 UIKitApplication:host.id[fixture]')
      sys.exit(0)
  if args == ['simctl', 'terminate', 'FAKE', 'host.id']:
      pid = int(current.read_text())
      (base / 'terminated').write_text(str(pid))
      os.kill(pid, signal.SIGTERM)
      current.unlink()
      sys.exit(0)
  assert args == ['simctl', 'launch', '--console-pty', 'FAKE', 'host.id'], args
  assert os.tcgetpgrp(0) == os.getpid()
  os.close(os.open('/dev/tty', os.O_RDWR))
  (base / 'pids').write_text(f'{os.getpid()} {os.getppid()}')
  def ack(*_):
      print(f'host.id: {os.getpid()}', flush=True)
  if mode == 'restart':
      current.write_text(str(os.getpid()))
  if mode in ('resist', 'background', 'marker', 'early', 'die-before-ack'):
      signal.signal(signal.SIGHUP, signal.SIG_IGN)
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
  if mode == 'background':
      # Leave an empty foreground group after its leader exits. The tool still holds the slave.
      leader = os.fork()
      if leader == 0:
          os.setpgid(0, 0)
          time.sleep(0.1)
          os._exit(0)
      os.setpgid(leader, leader)
      os.tcsetpgrp(0, leader)
      os.waitpid(leader, 0)
      ack()
  elif mode == 'marker':
      record = next((base / '.relay/consoles').glob('*.json'))
      # Wake the worker, then publish stop and ack in the same poll interval.
      os.write(1, b'waiting\n')
      time.sleep(0.012)
      tmp = record.with_suffix('.pending')
      tmp.write_bytes(record.read_bytes())
      tmp.replace(record.with_suffix('.stop'))
      ack()
  elif mode == 'missing':
      print('host.id: 2147483647', flush=True)
  elif mode == 'die-before-ack':
      import json
      worker = json.loads(next((base / '.relay/consoles').glob('*.json')).read_text())['pid']
      os.kill(worker, signal.SIGKILL)
  elif mode == 'late':
      signal.signal(signal.SIGTERM, ack)
  elif mode == 'slow':
      time.sleep(13)
      ack()
  elif mode == 'bad':
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      print('fixture diagnostic', file=sys.stderr, flush=True)
      print('warning\n' * 18, flush=True)
      sys.exit(7)
  elif mode == 'early':
      ack()
      while not (base / 'exit').exists():
          time.sleep(0.01)
      sys.exit(0)
  elif mode == 'old':
      print('host.id: ' + (base / 'oldpid').read_text(), flush=True)
  else:
      os.write(1, b'warning\nunterminated:')
      ack()
  while True:
      signal.pause()
  """#

  func start(restart: Bool = false, output target: URL? = nil) throws -> ConsoleState {
    try ConsoleCapture.start(ConsoleLaunch(path: (target ?? output).path, restart: restart), bundleID: "host.id", connection: connection, runtime: runtime)
  }

  func records() throws -> [ConsoleState] {
    try ConsoleState.ids(in: runtime.directory).map { try ConsoleState.read($0, in: runtime.directory) }
  }

  func wait(_ condition: () throws -> Bool, seconds: Double = 8) throws {
    let until = ConsoleCapture.now + seconds
    repeat {
      if try condition() { return }
      usleep(20000)
    } while ConsoleCapture.now < until
    throw SetupError(description: "fixture timed out")
  }

  func stop(_ state: ConsoleState) throws {
    try state.write(to: runtime.directory.appendingPathComponent(state.captureID + ".stop"))
    try wait { try ConsoleState.read(state.captureID, in: runtime.directory).finishedAt != nil }
  }
}

struct ConsoleLifecycleTests {
  @Test func controllingTerminalAndLostCapture() throws {
    for killBoth in [false, true] {
      let f = try ConsoleFixture("quiet")
      defer { try? FileManager.default.removeItem(at: f.home) }
      let recording = try f.start()
      let worker = try #require(recording.pid)
      let pids = try String(contentsOf: f.home.appendingPathComponent("pids"), encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
      try #require(pids.count == 2)
      // Verify pgrp and /dev/tty inside the fake as well as termination of a silent child here.
      if killBoth { kill(worker, SIGSTOP) }
      kill(pids[1], SIGKILL)
      if killBoth { kill(worker, SIGKILL) }
      var status: Int32 = 0
      try f.wait { waitpid(worker, &status, WNOHANG) == worker }
      try f.wait { kill(pids[0], 0) < 0 && errno == ESRCH }
      let last = try ConsoleCapture.checked(recording.captureID, in: f.runtime.directory)
      #expect(last.reason == (killBoth ? "lost" : "guard_exited"))
      #expect(try Data(contentsOf: f.output) == Data("warning\nunterminated:".utf8))
    }
  }

  @Test func stoppedOrTimedOutBeforeAcknowledgement() throws {
    for explicitStop in [false, true] {
      var fixture = try ConsoleFixture("late")
      fixture.runtime.acknowledgeTimeout = explicitStop ? 10 : 0.5
      let f = fixture
      defer { try? FileManager.default.removeItem(at: f.home) }
      let result = Locked<ConsoleProblem?>(nil)
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        defer { done.signal() }
        do { _ = try f.start(); Issue.record("late acknowledgement reported as recording") }
        catch { result.set(ConsoleProblem.from(error)) }
      }
      try f.wait { FileManager.default.fileExists(atPath: f.home.appendingPathComponent("pids").path) }
      if explicitStop {
        let record = try #require(try f.records().first)
        try record.write(to: f.runtime.directory.appendingPathComponent(record.captureID + ".stop"))
      }
      #expect(done.wait(timeout: .now() + 8) == .success)
      let capture = try #require(result.value?.capture)
      #expect(capture.reason == (explicitStop ? "stopped" : "launch_timeout"))
      #expect(capture.state == "ended" && capture.appPID != nil && capture.childSignal == SIGKILL)
      #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }
  }

  @Test func slowAcknowledgementGetsItsOwnBudget() throws {
    let f = try ConsoleFixture("slow")
    defer { try? FileManager.default.removeItem(at: f.home) }
    #expect(f.runtime.acknowledgeTimeout >= 60)
    let recording = try f.start() // Longer than the former 12-second timeout.
    try f.stop(recording)
  }

  @Test func leaseTimeoutAndDiagnostics() throws {
    var f = try ConsoleFixture("bad")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let state = ConsoleState(captureID: UUID().uuidString, udid: "FAKE", bundleID: "host.id", path: f.output.path, runnerPID: 1, runnerStart: Date())
    let lease = try #require(try StartLock.take(state.lockURL(in: f.runtime.directory).appendingPathExtension("capture")))
    f.runtime.leaseTimeout = 0.3
    let error = #expect(throws: ConsoleProblem.self) { try f.start() }
    lease.release()
    #expect(error?.capture?.reason == "lease_timeout")
    #expect(!FileManager.default.fileExists(atPath: f.output.path))
    let bad = #expect(throws: ConsoleProblem.self) { try f.start() }
    #expect(bad?.capture?.childExit == 7)
    #expect(bad?.message.contains("fixture diagnostic") == true)
    #expect(try Data(contentsOf: f.output).starts(with: Data("warning\n".utf8)))
  }

  @Test func foregroundFailuresIncludeCapture() throws {
    for (status, expectedExit, expectedCode) in [(409, 5, "runner_busy"), (0, 3, "runner_unavailable"), (200, 8, "runner_bad_response")] {
      let f = try ConsoleFixture("quiet")
      defer { try? FileManager.default.removeItem(at: f.home) }
      let pipe = Pipe()
      let result = RunnerControl.perform(.launch(bundleID: "host"), on: f.connection, console: ConsoleLaunch(path: f.output.path, restart: false),
                                         consoleRuntime: f.runtime, failureOutput: pipe.fileHandleForWriting, successOutput: pipe.fileHandleForWriting) { _ in
        if status == 0 { throw URLError(.cannotConnectToHost) }
        return RunnerResponse(status: status, body: Data((status == 200 ? "[]" : #"{"code":"runner_busy","detail":42}"#).utf8))
      }
      try pipe.fileHandleForWriting.close()
      let object = try #require(JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
      #expect(result == Int32(expectedExit) && object["code"] as? String == expectedCode)
      let state = try #require(try f.records().first)
      #expect((object["console"] as? [String: Any])?["captureID"] as? String == state.captureID)
      if status == 409 { #expect(object["detail"] as? Int == 42) }
      try f.stop(state)
    }
  }
}

extension ConsoleLifecycleTests {
  @Test func lossRequiresBothOwnersToBeGone() throws {
    let f = try ConsoleFixture("quiet")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let capture = try f.start()
    let worker = try #require(capture.pid)
    let guardLock = try #require(try ConsoleState.ownerLock(capture.captureID, in: f.runtime.directory, exclusive: false))
    // The final save fails while the journal is temporarily read-only.
    chmod(f.runtime.directory.path, 0o500)
    defer { chmod(f.runtime.directory.path, 0o700) }
    kill(worker, SIGTERM)
    var status: Int32 = 0
    try f.wait { waitpid(worker, &status, WNOHANG) == worker }
    #expect(status >> 8 == 1)
    chmod(f.runtime.directory.path, 0o700)
    #expect(try f.records().first?.state == "recording")
    #expect(throws: ConsoleProblem.self) { try ConsoleCapture.checked(capture.captureID, in: f.runtime.directory) }
    close(guardLock)
    #expect(try ConsoleCapture.checked(capture.captureID, in: f.runtime.directory).reason == "lost")

    let broken = UUID().uuidString
    let file = ConsoleState.file(broken, in: f.runtime.directory)
    try Data(#"{"path":"/old","udid":"SIM","bundleID":"app"}"#.utf8).write(to: file)
    #expect(ConsoleState.partial(broken, in: f.runtime.directory)["path"] == "/old")
    #expect(throws: ConsoleProblem.self) { try ConsoleCapture.checked(broken, in: f.runtime.directory) }
    let future = Date().addingTimeInterval(8 * 86400)
    #expect(try ConsoleCapture.checked(broken, in: f.runtime.directory, now: future).reason == "lost")
    ConsoleState.prune(in: f.runtime.directory, now: future)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: f.output.path))
  }

  @Test func stopDuringLeaseDoesNotSpawnTool() throws {
    let f = try ConsoleFixture("quiet")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let seed = ConsoleState(captureID: "", udid: "FAKE", bundleID: "host.id", path: "", runnerPID: 1, runnerStart: Date())
    let lock = try #require(try StartLock.take(seed.lockURL(in: f.runtime.directory).appendingPathExtension("capture")))
    defer { lock.release() }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { done.signal() }
      let problem = #expect(throws: ConsoleProblem.self) { try f.start() }
      #expect(problem?.capture?.reason == "stopped")
    }
    try f.wait { try f.records().first?.pid != nil }
    let state = try #require(try f.records().first)
    let second = #expect(throws: ConsoleProblem.self) { try f.start() }
    #expect(second?.code == .consoleUnavailable)
    var wrong = state
    wrong.pid = 1
    let request = f.runtime.directory.appendingPathComponent(state.captureID + ".stop")
    try Data("corrupt".utf8).write(to: request)
    usleep(100000)
    #expect(try f.records().first?.finishedAt == nil)
    try wrong.write(to: request)
    usleep(150000)
    #expect(try f.records().first?.finishedAt == nil)
    try state.write(to: request)
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent("pids").path))
  }

  @Test func refusesPreexistingPIDAndPreservesReplacedOutput() throws {
    let f = try ConsoleFixture("old")
    defer { try? FileManager.default.removeItem(at: f.home) }
    try String(getpid()).write(to: f.home.appendingPathComponent("oldpid"), atomically: true, encoding: .utf8)
    let error = #expect(throws: ConsoleProblem.self) { try f.start() }
    #expect(error?.code == .consoleRequiresRestart && error?.capture?.reason == "already_running")
    let fd = try ConsoleSink.create(f.output.path)
    defer { close(fd) }
    try FileManager.default.moveItem(at: f.output, to: f.home.appendingPathComponent("original"))
    try Data().write(to: f.output)
    ConsoleCapture.removeEmptyOutput(fd, path: f.output.path)
    #expect(FileManager.default.fileExists(atPath: f.output.path))
  }
}

extension ConsoleLifecycleTests {
  @Test func leaseWaitDoesNotSpendAcknowledgementTime() throws {
    var fixture = try ConsoleFixture("quiet")
    fixture.runtime.leaseTimeout = 6
    fixture.runtime.acknowledgeTimeout = 1
    let f = fixture
    defer { try? FileManager.default.removeItem(at: f.home) }
    let seed = ConsoleState(captureID: "", udid: "FAKE", bundleID: "host.id", path: "", runnerPID: 1, runnerStart: Date())
    let lock = try #require(try StartLock.take(seed.lockURL(in: f.runtime.directory).appendingPathExtension("capture")))
    let done = DispatchSemaphore(value: 0)
    let result = Locked<ConsoleState?>(nil)
    DispatchQueue.global().async {
      defer { done.signal() }
      do { result.set(try f.start()) } catch { Issue.record("startup failed after lease release: \(error)") }
    }
    try f.wait { try f.records().first?.pid != nil }
    Thread.sleep(forTimeInterval: 1.5)
    lock.release()
    #expect(done.wait(timeout: .now() + 5) == .success)
    try f.stop(try #require(result.value))
  }
}

extension ConsoleLifecycleTests {
  @Test func runnerExitEndsCaptureAndMissingFakeCannotLaunch() throws {
    var f = try ConsoleFixture("quiet")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let runner = Process()
    runner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    runner.arguments = ["30"]
    try runner.run()
    defer { if runner.isRunning { runner.terminate(); runner.waitUntilExit() } }
    let pid = runner.processIdentifier
    f.runtime.owner = { _ in pid }
    _ = try f.start()
    runner.terminate()
    runner.waitUntilExit()
    try f.wait { try f.records().first?.reason == "runner_exited" }
    // The same injected absolute file handles the preflight query. Removing it must fail
    // before a worker is created, even on a machine with an installed Xcode.
    try FileManager.default.removeItem(atPath: f.runtime.tool)
    f.runtime.owner = { _ in getpid() }
    #expect(throws: (any Error).self) { try f.start() }
    #expect(try f.records().count == 1)
  }
}

extension ConsoleLifecycleTests {
  @Test func launchJSONAndEarlyExit() throws {
    for mode in ["quiet", "early", "lease"] {
      var f = try ConsoleFixture(mode)
      defer { try? FileManager.default.removeItem(at: f.home) }
      f.runtime.leaseTimeout = 0.4
      let seed = ConsoleState(captureID: "", udid: "FAKE", bundleID: "host.id", path: "", runnerPID: 1, runnerStart: Date())
      let lease = mode == "lease" ? try StartLock.take(seed.lockURL(in: f.runtime.directory).appendingPathExtension("capture")) : nil
      defer { lease?.release() }
      let calls = Locked(0)
      let pipe = Pipe()
      let result = RunnerControl.perform(.launch(bundleID: "host"), on: f.connection, console: ConsoleLaunch(path: f.output.path, restart: false),
                                         consoleRuntime: f.runtime, startConsole: { launch, bundle, connection, runtime in
                                           let capture = try ConsoleCapture.start(launch, bundleID: bundle, connection: connection, runtime: runtime)
                                           if mode == "early" {
                                             try Data().write(to: f.home.appendingPathComponent("exit"))
                                             try f.wait { try f.records().first?.finishedAt != nil }
                                           }
                                           return capture
                                         }, failureOutput: pipe.fileHandleForWriting, successOutput: pipe.fileHandleForWriting) { _ in
        calls.withLock { $0 += 1 }
        return RunnerResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
      }
      let record = try #require(try f.records().first)
      if mode == "quiet" { try f.stop(record) }
      try pipe.fileHandleForWriting.close()
      let body = try #require(JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
      let console = try #require(body["console"] as? [String: Any])
      #expect(console["captureID"] as? String == record.captureID)
      #expect(result == (mode == "quiet" ? 0 : 1))
      #expect(calls.value == (mode == "quiet" ? 1 : 0))
      if mode != "quiet" {
        #expect(body["code"] as? String == "console_unavailable")
        #expect(console["state"] as? String == "ended")
      }
      if mode == "lease" { #expect(console["reason"] as? String == "lease_timeout") }
    }
  }

  @Test func restartTerminatesBeforeNextLaunch() throws {
    let f = try ConsoleFixture("restart")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let first = try f.start()
    defer { try? f.stop(first) }
    let terminated = f.home.appendingPathComponent("terminated")
    let next = f.home.appendingPathComponent("next")
    let second = try f.start(restart: true, output: next)
    defer { try? f.stop(second) }
    #expect(try String(contentsOf: terminated, encoding: .utf8) == String(try #require(first.appPID)))
    #expect(try ConsoleState.read(first.captureID, in: f.runtime.directory).finishedAt != nil)
    #expect(second.appPID != first.appPID)
    try "bad".write(to: f.home.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    let failure = #expect(throws: ConsoleProblem.self) { try f.start(restart: true, output: f.home.appendingPathComponent("third")) }
    #expect(try String(contentsOf: terminated, encoding: .utf8) == String(try #require(second.appPID)))
    #expect(failure?.capture?.childExit == 7 && failure?.code == .consoleUnavailable)
  }

  @Test func stopPublishedWithAcknowledgement() throws {
    let f = try ConsoleFixture("marker")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let failure = #expect(throws: ConsoleProblem.self) { try f.start() }
    #expect(failure?.capture?.reason == "stopped" && failure?.capture?.appPID != nil)
    try f.wait { try f.records().first?.finishedAt != nil }
  }

  @Test func boundsDrainAfterGuardLossAndStop() throws {
    for frozen in [false, true] {
      let f = try ConsoleFixture(frozen ? "resist" : "background")
      defer { try? FileManager.default.removeItem(at: f.home) }
      let record = try f.start()
      let (tool, supervisor) = try f.toolAndGuard()
      let toolStart = try #require(record.appStart)
      let guardStart = try #require(RelayProcess.startTime(pid: supervisor))
      defer {
        if frozen, RelayProcess.startTime(pid: supervisor) == guardStart { kill(supervisor, SIGCONT) }
        if RelayProcess.startTime(pid: tool) == toolStart { kill(tool, SIGKILL) }
        try? f.wait { RelayProcess.startTime(pid: tool) != toolStart }
      }
      kill(supervisor, frozen ? SIGSTOP : SIGKILL)
      if frozen {
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: f.runtime.relay)
        stop.arguments = ["console", "stop", record.captureID]
        stop.environment = ProcessInfo.processInfo.environment.merging(["HOME": f.home.path]) { _, new in new }
        let result = Pipe()
        stop.standardOutput = result
        try stop.run()
        try f.wait({ !stop.isRunning }, seconds: 13)
        #expect(stop.terminationStatus == 0)
      }
      try f.wait({ try f.records().first?.finishedAt != nil }, seconds: frozen ? 0.5 : 6)
      #expect(try f.records().first?.reason == (frozen ? "stopped" : "guard_exited"))
    }
  }

  @Test func guardProtectsCaptureAfterWorkerDeath() throws {
    let f = try ConsoleFixture("resist")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let capture = try f.start()
    let worker = try #require(capture.pid)
    let (_, supervisor) = try f.toolAndGuard()
    kill(worker, SIGKILL)
    var status: Int32 = 0
    try f.wait { waitpid(worker, &status, WNOHANG) == worker }
    let id = capture.captureID
    let directory = f.runtime.directory
    let probe = try ConsoleState.ownerLock(id, in: directory, exclusive: true)
    if let probe { close(probe); Issue.record("guard did not hold its owner lock") }
    #expect(throws: ConsoleProblem.self) { try ConsoleCapture.checked(id, in: directory) }
    // Model the interval before the guard takes the shared lock, keeping its real argv visible.
    let ownerURL = directory.appendingPathComponent(id + ".owner")
    try FileManager.default.moveItem(at: ownerURL, to: ownerURL.appendingPathExtension("held"))
    #expect(throws: ConsoleProblem.self) { try ConsoleCapture.checked(id, in: directory) }
    try f.wait { kill(supervisor, 0) < 0 && errno == ESRCH || (try? f.records().first?.finishedAt) != nil }
    #expect(try ConsoleCapture.checked(id, in: directory).reason == "worker_exited")
  }

  @Test func fourConcurrentStartsHaveOneWinner() throws {
    let f = try ConsoleFixture("quiet")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let winners = Locked<[ConsoleState]>([])
    let errors = Locked<[ConsoleProblem]>([])
    let seed = ConsoleState(captureID: "", udid: "FAKE", bundleID: "host.id", path: "", runnerPID: 1, runnerStart: Date())
    let lease = try #require(try StartLock.take(seed.lockURL(in: f.runtime.directory).appendingPathExtension("capture")))
    let group = DispatchGroup()
    let completed = DispatchSemaphore(value: 0)
    for number in 0 ..< 4 {
      group.enter()
      Thread.detachNewThread {
        defer { group.leave(); completed.signal() }
        do {
          let record = try f.start(output: f.home.appendingPathComponent("output-\(number)"))
          winners.withLock { $0.append(record) }
        } catch { errors.withLock { $0.append(ConsoleProblem.from(error)) } }
      }
    }
    // Keep the winning startup inside the lock until each competing caller has tried it.
    let deadline = DispatchTime.now() + 3
    for _ in 0 ..< 3 { _ = completed.wait(timeout: deadline) }
    lease.release()
    group.wait()
    defer {
      for winner in winners.value { try? f.stop(winner) }
    }
    #expect(winners.value.count == 1)
    #expect(errors.value.count == 3 && errors.value.allSatisfy { $0.message.contains("relay console status") })
    #expect(try f.records().count == 1)
  }
}

private extension ConsoleFixture {
  func toolAndGuard() throws -> (Int32, Int32) {
    let pids = try String(contentsOf: home.appendingPathComponent("pids"), encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
    try #require(pids.count == 2)
    return (pids[0], pids[1])
  }
}

extension ConsoleLifecycleTests {
  @Test func appStartedDuringLeaseIsAlreadyRunning() throws {
    let f = try ConsoleFixture("old")
    defer { try? FileManager.default.removeItem(at: f.home) }
    let seed = ConsoleState(captureID: "", udid: "FAKE", bundleID: "host.id", path: "", runnerPID: 1, runnerStart: Date())
    let lease = try #require(try StartLock.take(seed.lockURL(in: f.runtime.directory).appendingPathExtension("capture")))
    let failure = Locked<ConsoleProblem?>(nil)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { done.signal() }
      do { try f.stop(f.start()) } catch { failure.set(ConsoleProblem.from(error)) }
    }
    try f.wait { try f.records().first?.pid != nil }
    let app = Process()
    app.executableURL = URL(fileURLWithPath: "/bin/sleep")
    app.arguments = ["15"]
    try app.run()
    defer { if app.isRunning { app.terminate(); app.waitUntilExit() } }
    try String(app.processIdentifier).write(to: f.home.appendingPathComponent("oldpid"), atomically: true, encoding: .utf8)
    lease.release()
    #expect(done.wait(timeout: .now() + 8) == .success)
    #expect(failure.value?.code == .consoleRequiresRestart && app.isRunning)
  }

  @Test func missingAppIdentityAndWorkerDeathFailStartup() throws {
    for mode in ["missing", "die-before-ack"] {
      let f = try ConsoleFixture(mode)
      defer { try? FileManager.default.removeItem(at: f.home) }
      let failure = Locked<ConsoleProblem?>(nil)
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        defer { done.signal() }
        do { _ = try f.start() } catch { failure.set(ConsoleProblem.from(error)) }
      }
      if done.wait(timeout: .now() + 6) == .timedOut {
        Issue.record("startup did not fail promptly")
        if let record = try f.records().first { try f.stop(record) }
        _ = done.wait(timeout: .now() + 4)
      }
      #expect(failure.value?.code == .consoleUnavailable)
      if mode == "missing" { #expect(failure.value?.capture?.reason == "app_identity_unavailable") }
      try f.wait { try f.records().first?.finishedAt != nil }
    }
  }

  @Test func acknowledgementRejectsBundleSuffix() throws {
    let dir = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("bytes")
    let fd = try ConsoleSink.create(path.path)
    defer { close(fd) }
    var sink = ConsoleSink(fd: fd)
    var header = ConsoleHeader(bundleID: "host.id")
    let others = ["com.", "X", "9", "-", "_"].map { $0 + "host.id: 123\n" }.joined()
    #expect(try header.consume(Data(others.utf8), sink: &sink) == nil)
    #expect(try header.consume(Data(":host.id: 456\n".utf8), sink: &sink) == 456)
    #expect(try Data(contentsOf: path) == Data((others + ":").utf8))
  }
}
