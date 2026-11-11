import Darwin
import Foundation
@testable import Relay
import Testing

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

  @Test func runWritesStdoutToANewFileAndKeepsStderr() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdout = directory.appendingPathComponent("out")
    let exit = try LogProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], stdout: stdout, timeout: 30)
    #expect(exit == LogToolExit(status: 3, stderr: "err\n"))
    #expect(try String(contentsOf: stdout, encoding: .utf8) == "out\n")
    let mode = try FileManager.default.attributesOfItem(atPath: stdout.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // The file must be new.
    #expect(throws: SetupError.self) { try LogProcess.run("/bin/echo", [], stdout: stdout, timeout: 30) }
  }

  @Test func runStopsAtTheTimeLimit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let started = Date()
    let exit = try LogProcess.run("/bin/sh", ["-c", "sleep 30"], stdout: directory.appendingPathComponent("out"), timeout: 0.3)
    #expect(exit.timedOut)
    #expect(exit.stopped == nil)
    #expect(Date().timeIntervalSince(started) < 10)
  }

  @Test func runStopsWhenAsked() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stop = LogStop()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { stop.request(.signal(SIGINT)) }
    let exit = try LogProcess.run("/bin/sh", ["-c", "sleep 30"], stdout: directory.appendingPathComponent("out"), timeout: 30, stop: stop)
    #expect(exit.stopped == .signal(SIGINT))
    #expect(!exit.timedOut)
    // The first reason stays.
    stop.request(.consumer)
    #expect(stop.reason == .signal(SIGINT))
  }

  @Test func runThrowsForAToolThatCannotStart() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) {
      try LogProcess.run("/nonexistent/tool", [], stdout: directory.appendingPathComponent("out"), timeout: 1)
    }
  }

  @Test func streamHandsOverEachLineInOrder() throws {
    let lines = Lines()
    let exit = try LogProcess.stream("/bin/sh", ["-c", "printf 'a\\nb\\n'; printf 'c'; echo warn >&2"], timeout: 30,
                                     maxLineBytes: 100, stop: LogStop()) { lines.add($0); return true }
    #expect(lines.value == ["a", "b", "c"])
    #expect(exit.status == 0)
    #expect(exit.stderr == "warn\n")
    #expect(exit.stopped == nil)
  }

  @Test func streamReadsMoreThanThePipeHolds() throws {
    let lines = Lines()
    _ = try LogProcess.stream("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i; i=$((i+1)); done"], timeout: 30,
                              maxLineBytes: 100, stop: LogStop()) { lines.add($0); return true }
    #expect(lines.value.count == 20000)
    #expect(lines.value.last == "line19999")
  }

  @Test func streamStopsWhenTheReaderSaysSo() throws {
    let lines = Lines()
    let exit = try LogProcess.stream("/bin/sh", ["-c", "echo one; echo two; sleep 30"], maxLineBytes: 100, stop: LogStop()) { line in
      lines.add(line)
      return false
    }
    #expect(lines.value == ["one"])
    #expect(exit.stopped == .consumer)
  }

  @Test func streamStopsAtALongLine() throws {
    let exit = try LogProcess.stream("/bin/sh", ["-c", "head -c 5000 /dev/zero | tr '\\0' x; sleep 30"], maxLineBytes: 1000,
                                     stop: LogStop()) { _ in true }
    #expect(exit.stopped == .overlongLine)
  }

  @Test func streamStopsOnASignalOrTheTimeLimit() throws {
    let stop = LogStop()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { stop.request(.signal(SIGTERM)) }
    let stopped = try LogProcess.stream("/bin/sh", ["-c", "sleep 30"], maxLineBytes: 100, stop: stop) { _ in true }
    #expect(stopped.stopped == .signal(SIGTERM))
    let timed = try LogProcess.stream("/bin/sh", ["-c", "sleep 30"], timeout: 0.3, echoStderr: true, maxLineBytes: 100, stop: LogStop()) { _ in true }
    #expect(timed.timedOut)
    // SIGHUP is passed on as SIGTERM.
    let hangup = LogStop()
    hangup.request(.signal(SIGHUP))
    let hung = try LogProcess.stream("/bin/sh", ["-c", "sleep 30"], maxLineBytes: 100, stop: hangup) { _ in true }
    #expect(hung.stopped == .signal(SIGHUP))
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
    #expect(!LogOutput.write(Data("x".utf8), to: pipe.fileHandleForWriting.fileDescriptor))
  }

  @Test func signalsAreHandledWhileInstalled() {
    // Real signals are not raised: other tests run in this process at the same time.
    let sources = LogSignals.install(LogStop())
    #expect(sources.count == 3)
    LogSignals.uninstall(sources)
    let cancelled = sources.allSatisfy { $0.isCancelled }
    #expect(cancelled)
  }
}
