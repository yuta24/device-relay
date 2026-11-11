import Darwin
import Foundation

/// How a tool `LogProcess` ran ended.
struct LogToolExit: Equatable {
  /// Its exit status, or the signal that ended it.
  var status: Int32
  /// The end of what it wrote to stderr (at most `LogProcess.stderrLimit` bytes): the reason of a failure.
  var stderr = ""
  /// It ran past the time limit and was stopped.
  var timedOut = false
  /// Why relay stopped it before it ended by itself, if it did.
  var stopped: LogStop.Reason?
}

/// A request to stop a tool `LogProcess` runs, from a signal, from the code reading its output, or from the
/// reader. The first reason wins; the waiting loop of `LogProcess` wakes up at once.
final class LogStop: Sendable {
  enum Reason: Equatable, Sendable {
    /// SIGINT, SIGTERM, or SIGHUP reached relay.
    case signal(Int32)
    /// The code reading the lines asked to stop (stdout closed, a line that is not a log line).
    case consumer
    /// A line longer than the limit, which is not a log line relay can read.
    case overlongLine
  }

  private struct State {
    var reason: Reason?
    var observers: [DispatchSemaphore] = []
  }

  private let state = Locked(State())

  var reason: Reason? { state.value.reason }

  func request(_ reason: Reason) {
    let observers: [DispatchSemaphore]? = state.withLock { state in
      guard state.reason == nil else { return nil }
      state.reason = reason
      return state.observers
    }
    observers?.forEach { $0.signal() }
  }

  /// `semaphore` is signaled when a stop is requested (at once if it already was).
  fileprivate func observe(_ semaphore: DispatchSemaphore) {
    let already = state.withLock { state in
      state.observers.append(semaphore)
      return state.reason != nil
    }
    if already { semaphore.signal() }
  }

  /// The exit status of relay for a stop by `signal`: 128 + the signal (130 for SIGINT, 143 for SIGTERM).
  static func exitStatus(for signal: Int32) -> Int32 {
    128 + signal
  }
}

/// Runs `log`, `simctl spawn … log`, and `devicectl` for `relay logs` and `relay crashes`, with stdout and
/// stderr apart: `Shell` merges them and keeps everything in memory, which a log of tens of MiB or a stream
/// that never ends cannot use.
enum LogProcess {
  static let stderrLimit = 65536
  /// How long a tool gets to end after the signal relay sends it, before SIGKILL.
  static let killDelay: TimeInterval = 2
  /// How long the end of stdout is waited for once the tool ended (see `OutputReader` in Shell.swift: a
  /// process the tool started may still hold the pipe).
  static let drainDelay: TimeInterval = 1

  /// Runs `executable <args>` to completion with stdout written to `stdout`, a new file (mode 0600) that the
  /// caller removes. After `timeout` seconds, or once `stop` is requested, it gets SIGTERM (the signal, for
  /// a signal), then SIGKILL. Throws only when the tool cannot be started.
  static func run(_ executable: String, _ args: [String], stdout: URL, timeout: TimeInterval, stop: LogStop? = nil) throws -> LogToolExit {
    let outputFD = open(stdout.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard outputFD >= 0 else {
      throw SetupError(description: "cannot create \(stdout.path): \(String(cString: strerror(errno)))")
    }
    let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors

    let events = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in events.signal() }
    try process.run()
    try? output.close()
    let reader = TailReader(errors.fileHandleForReading, limit: stderrLimit, echo: false)
    stop?.observe(events)

    let deadline = DispatchTime.now() + timeout
    var timedOut = false
    while process.isRunning, stop?.reason == nil {
      if events.wait(timeout: deadline) == .timedOut {
        timedOut = process.isRunning
        break
      }
    }
    let stopped = process.isRunning ? stop?.reason : nil
    if process.isRunning {
      end(process, with: stopped.flatMap(signalNumber) ?? SIGTERM, exited: events)
    }
    return LogToolExit(status: process.isRunning ? SIGKILL : process.terminationStatus, stderr: reader.finish(),
                       timedOut: timedOut, stopped: stopped)
  }

  /// Runs `executable <args>` and calls `onLine` with each line of its stdout (without the line break), in
  /// order, on a thread of its own, until it ends or `stop` is requested; `onLine` returning false requests
  /// it. A line longer than `maxLineBytes` stops it too, and so does `timeout` (nil: none). The end of its
  /// stderr is kept for `LogToolExit.stderr`; `echoStderr` also passes it on to relay's stderr.
  static func stream(
    _ executable: String,
    _ args: [String],
    timeout: TimeInterval? = nil,
    echoStderr: Bool = false,
    maxLineBytes: Int,
    stop: LogStop,
    onLine: @escaping @Sendable (Data) -> Bool
  ) throws -> LogToolExit {
    let pipe = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = errors

    let events = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in events.signal() }
    try process.run()
    let errorReader = TailReader(errors.fileHandleForReading, limit: stderrLimit, echo: echoStderr)
    let reader = LineReader(pipe.fileHandleForReading, maxLineBytes: maxLineBytes, stop: stop, onLine: onLine, ended: events)
    stop.observe(events)

    let deadline = timeout.map { DispatchTime.now() + $0 } ?? .distantFuture
    var timedOut = false
    while process.isRunning, stop.reason == nil {
      if events.wait(timeout: deadline) == .timedOut {
        timedOut = process.isRunning
        break
      }
    }
    let stopped = stop.reason
    if process.isRunning {
      end(process, with: stopped.flatMap(signalNumber) ?? (timedOut ? SIGTERM : SIGINT), exited: events)
    }
    reader.finish(wait: drainDelay)
    return LogToolExit(status: process.isRunning ? SIGKILL : process.terminationStatus, stderr: errorReader.finish(),
                       timedOut: timedOut, stopped: stopped)
  }

  private static func signalNumber(_ reason: LogStop.Reason) -> Int32? {
    if case .signal(let number) = reason {
      // SIGHUP is passed on as SIGTERM: simctl and log end on it the same way.
      return number == SIGHUP ? SIGTERM : number
    }
    return nil
  }

  /// Sends `signal`, then SIGKILL after `killDelay`, and waits a moment more for the exit.
  private static func end(_ process: Process, with signal: Int32, exited: DispatchSemaphore) {
    kill(process.processIdentifier, signal)
    let deadline = DispatchTime.now() + killDelay
    while process.isRunning, exited.wait(timeout: deadline) == .success {}
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      let abandon = DispatchTime.now() + killDelay
      while process.isRunning, exited.wait(timeout: abandon) == .success {}
    }
  }
}

/// Keeps the last `limit` bytes a pipe gets, on a thread of its own; `echo` also writes them to stderr.
private final class TailReader: Sendable {
  private struct State {
    var data = Data()
    var isFinished = false
  }

  private let state = Locked(State())
  private let reachedEnd = DispatchSemaphore(value: 0)

  init(_ handle: FileHandle, limit: Int, echo: Bool) {
    Thread.detachNewThread { [state, reachedEnd] in
      var buffer = [UInt8](repeating: 0, count: 16384)
      while true {
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        state.withLock { state in
          guard !state.isFinished else { return }
          if echo {
            _ = LogOutput.write(Data(buffer[..<count]), to: STDERR_FILENO)
          }
          state.data.append(contentsOf: buffer[..<count])
          if state.data.count > limit {
            state.data.removeFirst(state.data.count - limit)
          }
        }
      }
      reachedEnd.signal()
    }
  }

  func finish() -> String {
    _ = reachedEnd.wait(timeout: .now() + LogProcess.drainDelay)
    return state.withLock { state in
      state.isFinished = true
      return String(decoding: state.data, as: UTF8.self)
    }
  }
}

/// Splits what a pipe gets into lines and hands each to `onLine`, on a thread of its own. A last line
/// without a line break is handed over at the end of the pipe.
private final class LineReader: Sendable {
  private let isFinished = Locked(false)
  private let reachedEnd = DispatchSemaphore(value: 0)

  init(_ handle: FileHandle, maxLineBytes: Int, stop: LogStop, onLine: @escaping @Sendable (Data) -> Bool, ended: DispatchSemaphore) {
    Thread.detachNewThread { [isFinished, reachedEnd] in
      var buffer = [UInt8](repeating: 0, count: 65536)
      var pending = Data()
      var reading = true
      func deliver(_ line: Data) {
        guard reading else { return }
        // Under the lock, so nothing is handed over after `finish()`.
        let keep = isFinished.withLock { finished in finished ? false : onLine(line) }
        if !keep {
          reading = false
          stop.request(.consumer)
        }
      }
      while true {
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        guard reading else { continue }
        pending.append(contentsOf: buffer[..<count])
        while reading, let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
          let line = pending[pending.startIndex ..< newline]
          deliver(Data(line))
          pending.removeSubrange(pending.startIndex ... newline)
        }
        if reading, pending.count > maxLineBytes {
          reading = false
          stop.request(.overlongLine)
        }
      }
      if reading, !pending.isEmpty {
        deliver(pending)
      }
      reachedEnd.signal()
      ended.signal()
    }
  }

  func finish(wait: TimeInterval) {
    _ = reachedEnd.wait(timeout: .now() + wait)
    isFinished.set(true)
  }
}

/// SIGINT, SIGTERM, and SIGHUP request `stop` instead of ending relay at once, so the tool it runs is
/// stopped and its files removed first. SIGPIPE is ignored: a closed stdout is an error of `write`.
enum LogSignals {
  static let handled = [SIGINT, SIGTERM, SIGHUP]

  static func install(_ stop: LogStop) -> [DispatchSourceSignal] {
    signal(SIGPIPE, SIG_IGN)
    return handled.map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { stop.request(.signal(number)) }
      source.resume()
      return source
    }
  }

  static func uninstall(_ sources: [DispatchSourceSignal]) {
    sources.forEach { $0.cancel() }
    handled.forEach { signal($0, SIG_DFL) }
  }
}

/// Writes to a file descriptor with write(2): `FileHandle.write` raises an Objective-C exception on a
/// closed pipe, which ends relay, while this returns false.
enum LogOutput {
  static func write(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { raw in
      guard var pointer = raw.baseAddress else { return true }
      var left = raw.count
      while left > 0 {
        let written = Darwin.write(fd, pointer, left)
        if written < 0 {
          if errno == EINTR { continue }
          return false
        }
        left -= written
        pointer += written
      }
      return true
    }
  }
}
