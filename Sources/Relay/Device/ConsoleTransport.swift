import Darwin
import Foundation

/// simctl creates the app PTY. Its own private controlling terminal lets the worker kill
/// the correct foreground group even after the guard (the direct parent of simctl) dies.
final class ConsoleTransport {
  let master: Int32
  private var slave: Int32
  private let control = Pipe()
  private let result = Pipe()
  private let errors = Pipe()
  private let guardProcess = Process()
  private var messages = Data()
  private var errorTail = Data()
  private(set) var toolStart: Date?
  private(set) var launchedAt: TimeInterval?
  private(set) var guardEndedAt: TimeInterval?
  private(set) var childStatus: Int32?
  var diagnostic: String { String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
  var guardFailed: Bool { !guardProcess.isRunning && guardProcess.terminationStatus != 0 }
  var leaseTimedOut: Bool { !guardProcess.isRunning && guardProcess.terminationReason == .exit && guardProcess.terminationStatus == 75 }

  init(state: ConsoleState, tool: String, leaseTimeout: TimeInterval) throws {
    var m: Int32 = -1
    var s: Int32 = -1
    var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard openpty(&m, &s, &name, nil, nil) == 0 else { throw ConsoleProblem(.consoleUnavailable, "cannot open console PTY") }
    master = m
    slave = s
    var settings = termios()
    guard fcntl(m, F_SETFD, FD_CLOEXEC) == 0, fcntl(s, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(m, F_SETFL, O_NONBLOCK) == 0, tcgetattr(s, &settings) == 0,
          fcntl(result.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
          fcntl(errors.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
      throw ConsoleProblem(.consoleUnavailable, "cannot configure console PTY")
    }
    cfmakeraw(&settings)
    guard tcsetattr(s, TCSANOW, &settings) == 0 else { throw ConsoleProblem(.consoleUnavailable, "cannot set raw console PTY") }
    guardProcess.executableURL = URL(fileURLWithPath: RelayProcess.currentExecutable)
    guardProcess.arguments = ["__console-child", state.captureID, "\(getpid())", state.udid, state.bundleID, String(nullTerminated: name), tool, String(leaseTimeout)]
    guardProcess.standardInput = control
    guardProcess.standardOutput = result
    guardProcess.standardError = errors
    try guardProcess.run()
  }

  deinit {
    close(master)
    closeSlave()
  }

  func closeSlave() {
    if slave >= 0 { close(slave); slave = -1 }
  }

  func stop() { try? control.fileHandleForWriting.close() }
  func killTool() { _ = ioctl(master, TIOCSIG, SIGKILL) }

  func update() {
    if !guardProcess.isRunning, guardEndedAt == nil {
      guardEndedAt = ConsoleCapture.now
      if guardFailed { killTool() }
      closeSlave()
    }
    var bytes = [UInt8](repeating: 0, count: 8192)
    // Bound work per iteration even if the tool floods its diagnostic stream.
    for _ in 0 ..< 8 {
      let n = read(errors.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
      if n <= 0 { break }
      errorTail.append(contentsOf: bytes.prefix(n))
      errorTail = errorTail.suffix(4096)
    }
    let n = read(result.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
    if n > 0 { messages.append(contentsOf: bytes.prefix(n)) }
    while let end = messages.firstIndex(of: 10) {
      let line = String(decoding: messages[..<end], as: UTF8.self)
      if line.hasPrefix("launch "), let timestamp = Double(line.dropFirst(7)) {
        toolStart = Date(timeIntervalSince1970: timestamp)
        launchedAt = ConsoleCapture.now
      }
      else { childStatus = Int32(line) }
      messages.removeSubrange(...end)
    }
  }

  /// Never block on waitUntilExit or a descendant holding a pipe open.
  func finish() {
    stop()
    let until = ConsoleCapture.now + ConsoleCapture.drainTimeout
    repeat {
      update()
      if guardEndedAt != nil { return }
      usleep(20000)
    } while ConsoleCapture.now < until
    killTool()
    update()
  }

  /// The spawned session leader must explicitly acquire its slave on Darwin. Do it after
  /// setsid, before exec, and verify the foreground group on that terminal.
  static func execTool(_ args: [String]) -> Int32 {
    guard args.count == 4, ioctl(0, TIOCSCTTY, 0) == 0, tcsetpgrp(0, getpgrp()) == 0,
          tcgetpgrp(0) == getpid(), getppid() == Int32(args[3]) else { return 126 }
    let words = [args[0], "simctl", "launch", "--console-pty", args[1], args[2]]
    let argv = words.map { strdup($0) } + [nil]
    execv(args[0], argv)
    perror("exec console tool")
    return 127
  }

  static func guardChild(_ args: [String]) -> Int32 {
    guard args.count == 7, ConsoleState.validID(args[0]) == args[0], let parent = Int32(args[1]), let timeout = Double(args[6]),
          let owner = try? ConsoleState.ownerLock(args[0], in: ConsoleState.directory, exclusive: false) else { return 1 }
    defer { close(owner) }
    guard getppid() == parent, let state = try? ConsoleState.read(args[0]), state.pid == parent,
          state.owns(RelayProcess.snapshot(pid: parent)), state.udid == args[2], state.bundleID == args[3] else { return 1 }

    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    func cancelled() -> Bool { getppid() != parent || poll(&input, 1, 0) > 0 || ConsoleCapture.requestedStop(state) }
    let until = ConsoleCapture.now + timeout
    var lease: StartLock?
    repeat {
      if cancelled() { return 0 }
      lease = try? StartLock.take(state.lockURL().appendingPathExtension("capture"))
      if lease == nil { usleep(30000) }
    } while lease == nil && ConsoleCapture.now < until
    guard let lease else { return 75 }
    defer { lease.release() }
    guard !cancelled() else { return 0 }

    // Losing the result pipe must not interrupt supervision before waitpid.
    signal(SIGPIPE, SIG_IGN)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var mask = sigset_t()
    sigemptyset(&mask)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGPIPE)
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
          posix_spawnattr_setsigmask(&attributes, &mask) == 0,
          posix_spawn_file_actions_addopen(&actions, 0, args[4], O_RDWR, 0) == 0,
          posix_spawn_file_actions_adddup2(&actions, 0, 1) == 0,
          posix_spawn_file_actions_addinherit_np(&actions, 2) == 0 else { return 1 }
    let executable = RelayProcess.currentExecutable
    let words = [executable, "__console-exec", args[5], state.udid, state.bundleID, String(getpid())]
    let argv = words.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var child: Int32 = 0
    print("launch \(Date().timeIntervalSince1970)")
    let rc = posix_spawn(&child, executable, &actions, &attributes, argv, environ)
    guard rc == 0 else { CLIOutput.note("cannot spawn console tool: \(String(cString: strerror(rc)))"); return 1 }
    var status: Int32 = 0
    var deadline: TimeInterval?
    while true {
      let reaped = waitpid(child, &status, WNOHANG)
      if reaped == child { break }
      if reaped < 0 {
        if errno == EINTR { continue }
        return 1
      }
      if let deadline {
        if ConsoleCapture.now >= deadline { kill(child, SIGKILL) }
        usleep(20000)
      } else if poll(&input, 1, 50) > 0 || getppid() != parent {
        kill(child, SIGTERM)
        deadline = ConsoleCapture.now + 2
      }
    }
    if getppid() != parent, var last = try? ConsoleState.read(state.captureID), last.finishedAt == nil {
      last.finish("worker_exited", status: status)
      try? last.saveFinal()
      unlink(last.stopURL.path)
    }
    print(status)
    return 0
  }
}

/// Keep every byte except the acknowledgement, including an unterminated prefix on its line.
struct ConsoleHeader {
  let bundleID: String
  private var pending = Data()
  private var prefix = Data()
  private var scanned = 0
  private var lines = 0
  var preview: String { String(decoding: prefix, as: UTF8.self) }

  init(bundleID: String) { self.bundleID = bundleID }

  private static let bundleCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_".utf8)

  mutating func consume(_ bytes: Data, sink: inout ConsoleSink) throws -> Int32? {
    prefix.append(bytes.prefix(256 - prefix.count))
    pending.append(bytes)
    let marker = Data((bundleID + ": ").utf8)
    while let end = pending.firstIndex(of: 10) {
      let line = pending[..<end]
      if scanned + line.count <= 8192, let match = line.range(of: marker, options: .backwards),
         (match.lowerBound == line.startIndex || !Self.bundleCharacters.contains(line[match.lowerBound - 1])),
         let pid = Int32(String(decoding: line[match.upperBound...], as: UTF8.self)), pid > 0 {
        pending[..<match.lowerBound].withUnsafeBytes { sink.append($0) }
        pending.removeSubrange(...end)
        flush(to: &sink)
        return pid
      }
      scanned += line.count + 1
      lines += 1
      pending[...end].withUnsafeBytes { sink.append($0) }
      pending.removeSubrange(...end)
      if lines >= 16 || scanned >= 8192 { break }
    }
    if lines >= 16 || scanned + pending.count > 8192 {
      throw ConsoleProblem(.consoleUnavailable, "missing simctl acknowledgement")
    }
    return nil
  }

  mutating func flush(to sink: inout ConsoleSink) {
    pending.withUnsafeBytes { sink.append($0) }
    pending.removeAll()
  }
}
