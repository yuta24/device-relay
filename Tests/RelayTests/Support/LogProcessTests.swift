import Darwin
import Foundation
@testable import Relay
import Testing

/// Runs `body`, which waits for a process, on a thread of its own and awaits it. Waiting on Swift
/// Concurrency's cooperative pool would hold one of its threads, of which there are as many as cores; once
/// they are all held, GCD's global queues stop too, and with them `Process`'s termination handlers and the
/// stop requests the tests make. A Mac with 3 cores (CI) gets there with 3 such tests at once.
/// `#expect` stays outside `body`: it finds the test it belongs to from the task.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
  }
}

/// Requests `reason` of `stop` after `delay`, from a thread of its own rather than GCD's global queue.
private func request(_ reason: LogStop.Reason, of stop: LogStop, after delay: TimeInterval) {
  Thread.detachNewThread {
    Thread.sleep(forTimeInterval: delay)
    stop.request(reason)
  }
}

/// `LogProcess` with real processes (`/bin/sh`). Each test ends in a few seconds at most.
struct LogProcessTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-logprocess-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The lines `stream` hands over, in order.
  private final class Lines: Sendable {
    let lines = Locked<[String]>([])
    func add(_ data: Data) { lines.withLock { $0.append(String(decoding: data, as: UTF8.self)) } }
    var value: [String] { lines.value }
  }

  @Test func runWritesStdoutToANewFileAndKeepsStderr() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdout = directory.appendingPathComponent("out")
    let exit = try await offThePool { try LogProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], stdout: stdout, timeout: 30) }
    #expect(exit == LogToolExit(status: 3, stderr: "err\n"))
    #expect(try String(contentsOf: stdout, encoding: .utf8) == "out\n")
    let mode = try FileManager.default.attributesOfItem(atPath: stdout.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // The file must be new.
    await #expect(throws: SetupError.self) { try await offThePool { try LogProcess.run("/bin/echo", [], stdout: stdout, timeout: 30) } }
  }

  @Test func runStopsAtTheTimeLimit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Timed on the thread that runs it, from just before the call: awaiting offThePool also waits for a
    // free thread of the cooperative pool, which a loaded machine (CI) may not have for seconds.
    let (exit, elapsed) = try await offThePool {
      let started = Date()
      let exit = try LogProcess.run("/bin/sh", ["-c", "sleep 30"], stdout: directory.appendingPathComponent("out"), timeout: 0.3)
      return (exit, Date().timeIntervalSince(started))
    }
    #expect(exit.timedOut)
    #expect(exit.stopped == nil)
    #expect(elapsed < 10)
  }

  @Test func runStopsWhenAsked() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stop = LogStop()
    request(.signal(SIGINT), of: stop, after: 0.3)
    let exit = try await offThePool {
      try LogProcess.run("/bin/sh", ["-c", "sleep 30"], stdout: directory.appendingPathComponent("out"), timeout: 30, stop: stop)
    }
    #expect(exit.stopped == .signal(SIGINT))
    #expect(!exit.timedOut)
    // The first reason stays.
    stop.request(.consumer)
    #expect(stop.reason == .signal(SIGINT))
  }

  @Test func runThrowsForAToolThatCannotStart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: (any Error).self) {
      try await offThePool { try LogProcess.run("/nonexistent/tool", [], stdout: directory.appendingPathComponent("out"), timeout: 1) }
    }
  }

  @Test func streamHandsOverEachLineInOrder() async throws {
    let lines = Lines()
    let exit = try await offThePool {
      try LogProcess.stream("/bin/sh", ["-c", "printf 'a\\nb\\n'; printf 'c'; echo warn >&2"], timeout: 30,
                            maxLineBytes: 100, stop: LogStop()) { lines.add($0); return true }
    }
    #expect(lines.value == ["a", "b", "c"])
    #expect(exit.status == 0)
    #expect(exit.stderr == "warn\n")
    #expect(exit.stopped == nil)
  }

  @Test func streamReadsMoreThanThePipeHolds() async throws {
    let lines = Lines()
    _ = try await offThePool {
      try LogProcess.stream("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i; i=$((i+1)); done"], timeout: 30,
                            maxLineBytes: 100, stop: LogStop()) { lines.add($0); return true }
    }
    #expect(lines.value.count == 20000)
    #expect(lines.value.last == "line19999")
  }

  @Test func streamStopsWhenTheReaderSaysSo() async throws {
    let lines = Lines()
    let exit = try await offThePool {
      try LogProcess.stream("/bin/sh", ["-c", "echo one; echo two; sleep 30"], maxLineBytes: 100, stop: LogStop()) { line in
        lines.add(line)
        return false
      }
    }
    #expect(lines.value == ["one"])
    #expect(exit.stopped == .consumer)
  }

  @Test func streamStopsAtALongLine() async throws {
    let exit = try await offThePool {
      try LogProcess.stream("/bin/sh", ["-c", "head -c 5000 /dev/zero | tr '\\0' x; sleep 30"], maxLineBytes: 1000,
                            stop: LogStop()) { _ in true }
    }
    #expect(exit.stopped == .overlongLine)
  }

  @Test func streamStopsOnASignalOrTheTimeLimit() async throws {
    let stop = LogStop()
    request(.signal(SIGTERM), of: stop, after: 0.3)
    let stopped = try await offThePool { try LogProcess.stream("/bin/sh", ["-c", "sleep 30"], maxLineBytes: 100, stop: stop) { _ in true } }
    #expect(stopped.stopped == .signal(SIGTERM))
    let timed = try await offThePool {
      try LogProcess.stream("/bin/sh", ["-c", "sleep 30"], timeout: 0.3, echoStderr: true, maxLineBytes: 100, stop: LogStop()) { _ in true }
    }
    #expect(timed.timedOut)
    // SIGHUP is passed on as SIGTERM.
    let hangup = LogStop()
    hangup.request(.signal(SIGHUP))
    let hung = try await offThePool { try LogProcess.stream("/bin/sh", ["-c", "sleep 30"], maxLineBytes: 100, stop: hangup) { _ in true } }
    #expect(hung.stopped == .signal(SIGHUP))
  }

  @Test func streamStopsWhileALineIsStuck() async throws {
    // onLine writes to a pipe nobody reads, as `--follow` does to a stdout nobody reads.
    signal(SIGPIPE, SIG_IGN)
    let unread = Pipe()
    let unreadFD = unread.fileHandleForWriting.fileDescriptor
    let calls = Locked(0)
    let stuck = Locked<Date?>(nil)
    let stop = LogStop()
    // The stop is requested once a line is stuck, not at a fixed time from the start: a loaded machine
    // (CI) may take longer than that to start sh. Timed on the thread that ran stream: awaiting offThePool
    // also waits for a free thread of the cooperative pool, which a loaded machine may not have for seconds.
    // Should no line come, a later stop of another reason ends stream, and the test fails on it.
    request(.consumer, of: stop, after: 30)
    let (exit, elapsed) = try await offThePool {
      let exit = try LogProcess.stream("/bin/sh", ["-c", "while :; do echo x; done"], maxLineBytes: 100, stop: stop) { _ in
        if calls.withLock({ $0 += 1; return $0 == 1 }) {
          stuck.withLock { $0 = Date() }
          request(.signal(SIGTERM), of: stop, after: 0.3)
        }
        return LogOutput.write(Data(count: 1 << 20), to: unreadFD)
      }
      return (exit, stuck.value.map { Date().timeIntervalSince($0) })
    }
    #expect(exit.stopped == .signal(SIGTERM))
    // Ended by the SIGTERM sent: a tool that was never signaled is reported as SIGKILL.
    #expect(exit.status == SIGTERM)
    #expect(exit.deliveryAbandoned)
    // sh ends on SIGTERM within killDelay; LineReader then waits drainDelay for the end of stdout and
    // drainDelay for the stuck onLine (both run out here). A tool that SIGTERM does not end takes
    // killDelay more, and a wait without a limit never ends.
    #expect(try #require(elapsed) < 0.3 + LogProcess.killDelay + 2 * LogProcess.drainDelay + 1)
    // The stuck write ends once the pipe closes; no line is handed over after stream returned.
    try unread.fileHandleForReading.close()
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(calls.value == 1)
  }

  @Test func exitStatusOfASignal() {
    #expect(LogStop.exitStatus(for: SIGINT) == 130)
    #expect(LogStop.exitStatus(for: SIGTERM) == 143)
  }

  @Test func writeReturnsFalseOnAClosedPipe() throws {
    signal(SIGPIPE, SIG_IGN)
    let pipe = Pipe()
    #expect(LogOutput.write(Data("x".utf8), to: pipe.fileHandleForWriting.fileDescriptor))
    #expect(LogOutput.write(Data(), to: pipe.fileHandleForWriting.fileDescriptor))
    try pipe.fileHandleForReading.close()
    // A process another test starts at this moment holds every descriptor of this process for a few ms
    // while it starts (close-on-exec ones too, until its exec), so the pipe can still have a reader and a
    // write succeed. Retry until the write fails; a write that never reports the closed pipe still fails
    // here. Each try writes 1 byte, far below what the pipe holds, so a try never blocks.
    let deadline = Date().addingTimeInterval(5)
    var failed = false
    while !failed, Date() < deadline {
      failed = !LogOutput.write(Data("x".utf8), to: pipe.fileHandleForWriting.fileDescriptor)
      if !failed { Thread.sleep(forTimeInterval: 0.01) }
    }
    #expect(failed)
  }
}

/// `LogSignals` changes how this process handles signals, so these run one at a time. Real signals are
/// never sent to this process: other tests run in it at the same time.
@Suite(.serialized) struct LogSignalsTests {
  @Test func signalsAreHandledWhileInstalled() {
    let sources = LogSignals.install(LogStop())
    #expect(sources.count == 3)
    LogSignals.uninstall(sources)
    let cancelled = sources.allSatisfy { $0.isCancelled }
    #expect(cancelled)
  }

  @Test func aToolStartedWhileSignalsAreIgnoredEndsOnTheSignalSent() async throws {
    // relay ignores SIGINT and SIGTERM while they are installed; the tool it starts must not inherit that,
    // or the signal it gets would do nothing and only SIGKILL (after killDelay) would end it.
    let sources = LogSignals.install(LogStop())
    defer { LogSignals.uninstall(sources) }
    for number in [SIGTERM, SIGINT] {
      let stop = LogStop()
      let ready = Locked<Date?>(nil)
      // The signal is requested once the tool runs (its first line), and timed from there on the thread
      // that ran stream: a loaded machine (CI) may start it, or give offThePool a thread, seconds later.
      // sh execs sleep, which keeps what sh inherited. Should no line come, a later stop of another reason
      // ends stream, and the test fails on it.
      request(.consumer, of: stop, after: 30)
      let (exit, elapsed) = try await offThePool {
        let exit = try LogProcess.stream("/bin/sh", ["-c", "echo ready; exec /bin/sleep 30"], maxLineBytes: 100, stop: stop) { _ in
          ready.withLock { $0 = Date() }
          request(.signal(number), of: stop, after: 0.3)
          return true
        }
        return (exit, ready.value.map { Date().timeIntervalSince($0) })
      }
      #expect(exit.stopped == .signal(number))
      #expect(exit.status == number, "ended by \(exit.status), not by the signal sent")
      #expect(try #require(elapsed) < 0.3 + LogProcess.killDelay)
    }
  }
}
