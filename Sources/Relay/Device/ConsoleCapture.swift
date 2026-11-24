import Darwin
import Foundation

struct ConsoleRuntime: Sendable {
  var home = UserHome.url
  var relay = RelayProcess.currentExecutable
  var tool = "/usr/bin/xcrun"
  var owner: @Sendable (RunnerInfo) -> Int32? = RelayProcess.runningRelayStart
  var simulator: @Sendable (String) throws -> Void = { try ConsoleCapture.requireSimulator($0) }
  var acknowledgeTimeout: TimeInterval = 90
  var leaseTimeout: TimeInterval = 15
  var directory: URL { home.appendingPathComponent(".relay/consoles") }
  var startTimeout: TimeInterval { leaseTimeout + acknowledgeTimeout + 2 * ConsoleCapture.drainTimeout + CommandTimeout.query * 2 + 5 }
}

enum ConsoleCapture {
  static let drainTimeout: TimeInterval = 4
  static let stopTimeout: TimeInterval = 12
  static let signals = [SIGTERM, SIGINT, SIGHUP]
  static let lockKey = "RELAY_CONSOLE_LOCK_FD"
  static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// launchctl lists the exact UIKit service even when the app is in the background.
  static func appPID(in listing: String, bundleID: String) throws -> Int32? {
    let lines = listing.split(separator: "\n")
    guard lines.first?.split(whereSeparator: \.isWhitespace) == ["PID", "Status", "Label"] else {
      throw ConsoleProblem(.consoleUnavailable, "unexpected simulator process listing")
    }
    let prefix = "UIKitApplication:" + bundleID + "["
    for line in lines.dropFirst() {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.count == 3, fields[2].lowercased().hasPrefix(prefix.lowercased()), fields[0] != "-" {
        guard let pid = Int32(fields[0]), pid > 0 else { throw ConsoleProblem(.consoleUnavailable, "invalid simulator app PID") }
        return pid
      }
    }
    return nil
  }

  static func appPID(udid: String, bundleID: String, tool: String) throws -> Int32? {
    try appPID(in: query(["simctl", "spawn", udid, "launchctl", "list"], executable: tool), bundleID: bundleID)
  }

  /// Only short control responses come through here. Keep diagnostics out of the process list.
  static func query(_ arguments: [String], executable: String = "/usr/bin/xcrun") throws -> String {
    let bytes = Locked(Data())
    let stop = LogStop()
    let exit = try LogProcess.stream(executable, arguments, timeout: CommandTimeout.query, maxLineBytes: 8192, stop: stop) { line in
      bytes.withLock { data in
        guard data.count + line.count < 1024 * 1024 else { return false }
        data.append(line)
        data.append(10)
        return true
      }
    }
    guard exit.status == 0, !exit.timedOut, stop.reason == nil, !exit.deliveryAbandoned else {
      throw ConsoleProblem(.consoleUnavailable, "simctl control query failed (status \(exit.status)): \(exit.stderr)")
    }
    return String(decoding: bytes.value, as: UTF8.self)
  }

  static func requireSimulator(_ udid: String, commands: HostCommands = .live) throws {
    let devices = try DeviceList.load(commands, udid: udid, simulator: true).devices
    guard devices.contains(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else {
      throw ConsoleProblem(.consoleUnsupported, "console capture requires an iOS simulator")
    }
  }

  static func start(_ launch: ConsoleLaunch, bundleID: String, connection: RunnerConnection, runtime: ConsoleRuntime = ConsoleRuntime()) throws -> ConsoleState {
    let info = connection.info
    let dir = runtime.directory
    guard let runnerPID = runtime.owner(info), let runnerStart = RelayProcess.startTime(pid: runnerPID) else {
      throw ConsoleProblem(.consoleUnavailable, "cannot verify the process that owns the runner")
    }
    var state = ConsoleState(captureID: UUID().uuidString, udid: info.udid, bundleID: bundleID, session: info.session,
                             path: try ConsoleSink.outputPath(launch.path, stateDirectory: dir), runnerPID: runnerPID, runnerStart: runnerStart)
    guard let lock = try StartLock.take(state.lockURL(in: dir)) else { throw ConsoleProblem(.consoleUnavailable, "another console launch is in progress; find its captureID with relay console status") }
    defer { lock.release() }
    let running = try appPID(udid: info.udid, bundleID: bundleID, tool: runtime.tool)
    if running != nil, !launch.restart { throw ConsoleProblem(.consoleRequiresRestart, "the app is running; use --restart to capture from launch") }
    ConsoleState.prune(in: dir)
    guard let owner = try ConsoleState.ownerLock(state.captureID, in: dir, exclusive: false) else {
      throw ConsoleProblem(.consoleUnavailable, "cannot claim console capture")
    }
    var handedOff = false
    defer { if !handedOff { close(owner) } }
    let output = try ConsoleSink.create(state.path)
    defer { close(output) }
    var worker: Int32?
    do {
      try state.save(in: dir)
      let args = state.workerArguments + [String(output), String(owner), runtime.tool, String(runtime.acknowledgeTimeout),
                                          String(runtime.leaseTimeout), running != nil ? "restart" : "launch"]
      var environment = ProcessInfo.processInfo.environment
      environment["HOME"] = runtime.home.path
      let pid = try BackgroundStart.spawnDetached(arguments: args, logURL: URL(fileURLWithPath: "/dev/null"),
                                                  locks: [(lockKey, lock)], descriptors: [output, owner], blockedSignals: signals,
                                                  executable: runtime.relay, environment: environment)
      CLIOutput.note("console capture \(state.captureID); stop with relay console stop \(state.captureID)")
      worker = pid
      close(owner)
      handedOff = true
      let deadline = now + runtime.startTimeout
      repeat {
        state = try ConsoleState.read(state.captureID, in: dir)
        if state.state == "recording" { return state }
        if state.finishedAt != nil { throw startupProblem(state) }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
          worker = nil
          state = (try? checked(state.captureID, in: dir)) ?? state
          throw startupProblem(state)
        }
        usleep(20000)
      } while now < deadline
      throw ConsoleProblem(.consoleUnavailable, "timed out starting capture", capture: state)
    } catch {
      var problem = ConsoleProblem.from(error)
      if !handedOff {
        state.finish("start_failed")
        try? state.saveFinal(in: dir)
      }
      var exited = worker == nil
      if let worker {
        let until = now + drainTimeout
        var status: Int32 = 0
        repeat {
          exited = waitpid(worker, &status, WNOHANG) == worker
          if !exited { usleep(20000) }
        } while !exited && now < until
      }
      if exited { removeEmptyOutput(output, path: state.path) }
      problem.capture = (try? ConsoleState.read(state.captureID, in: dir)) ?? state
      throw problem
    }
  }

  static func removeEmptyOutput(_ fd: Int32, path: String) {
    var original = stat()
    var current = stat()
    if fstat(fd, &original) == 0, lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
       original.st_dev == current.st_dev, original.st_ino == current.st_ino, current.st_size == 0 {
      unlink(path)
    }
  }

  static func startupProblem(_ state: ConsoleState) -> ConsoleProblem {
    let code: RelayErrorCode = state.reason == "already_running" ? .consoleRequiresRestart : .consoleUnavailable
    let status = state.childExit.map { " (simctl exit \($0))" } ?? state.childSignal.map { " (simctl signal \($0))" } ?? ""
    return ConsoleProblem(code, (state.reason ?? "console worker exited during startup") + status + (state.diagnostic.map { ": " + $0 } ?? ""), capture: state)
  }

  static func worker(_ args: [String]) -> Int32 {
    guard args.count == 10, let id = ConsoleState.validID(args[0]), var state = try? ConsoleState.read(id), state.pid == nil,
          state.state == "starting", Array(state.workerArguments.dropFirst()) == Array(args.prefix(4)),
          let output = Int32(args[4]), output > 2, fcntl(output, F_SETFD, FD_CLOEXEC) == 0,
          let owner = Int32(args[5]), owner > 2, fcntl(owner, F_SETFD, FD_CLOEXEC) == 0,
          let ackTimeout = Double(args[7]), let leaseTimeout = Double(args[8]),
          let lock = StartLock.inherited(url: state.lockURL(), key: lockKey, environment: ProcessInfo.processInfo.environment) else { return 1 }
    defer { close(owner) }
    var locked = true
    defer { if locked { lock.release() } }
    signal(SIGXFSZ, SIG_IGN)
    state.pid = getpid()
    state.startedAt = RelayProcess.startTime(pid: getpid())
    var sink = ConsoleSink(fd: output)
    var reason = "child_exited"
    var childStatus: Int32?
    do {
      try state.save()
      if args[9] == "restart" {
        do { _ = try query(["simctl", "terminate", state.udid, state.bundleID], executable: args[6]) }
        catch {
          if try appPID(udid: state.udid, bundleID: state.bundleID, tool: args[6]) != nil { throw error }
        }
      }
      let transport = try ConsoleTransport(state: state, tool: args[6], leaseTimeout: leaseTimeout)
      let start = now
      var header = ConsoleHeader(bundleID: state.bundleID)
      var buffer = [UInt8](repeating: 0, count: 32768)
      var stoppingAt: TimeInterval?
      var pendingSave = false
      var retrySaveAt = start
      func stop(_ why: String) {
        if stoppingAt == nil {
          reason = why
          stoppingAt = now
          transport.stop()
        }
      }
      func checkStop() {
        var pending = sigset_t()
        sigpending(&pending)
        if signals.contains(where: { sigismember(&pending, $0) == 1 }) { stop("signal") }
        else if requestedStop(state) { stop("stopped") }
        else if RelayProcess.startTime(pid: state.runnerPID) != state.runnerStart { stop("runner_exited") }
        else if state.appPID == nil {
          if let launched = transport.launchedAt {
            if now - launched >= ackTimeout { stop("launch_timeout") }
          } else if now - start >= leaseTimeout + drainTimeout { stop("lease_timeout") }
        }
      }
      do {
        var nextCheck = start
        while true {
          transport.update()
          if now >= nextCheck {
            checkStop()
            nextCheck = now + 0.05
          }
          if let end = stoppingAt ?? transport.guardEndedAt, now - end >= drainTimeout {
            transport.killTool()
            break
          }
          if pendingSave, now >= retrySaveAt {
            do { try state.save(); pendingSave = false }
            catch { retrySaveAt = now + 2 }
          }
          var pfd = pollfd(fd: transport.master, events: Int16(POLLIN), revents: 0)
          if poll(&pfd, 1, 50) <= 0 { continue }
          let n = read(transport.master, &buffer, buffer.count)
          if n < 0, [EINTR, EAGAIN].contains(errno) { continue }
          guard n > 0 else { break }
          if state.appPID == nil {
            if let pid = try header.consume(Data(buffer.prefix(n)), sink: &sink) {
              // Stop can arrive while poll waits or while the acknowledgement is split across reads.
              checkStop()
              state.appPID = pid
              state.appStart = RelayProcess.startTime(pid: pid)
              // The guard publishes the spawn time before the tool can write to the PTY.
              transport.update()
              guard let app = state.appStart, let tool = transport.toolStart else {
                stop("app_identity_unavailable")
                continue
              }
              if app < tool {
                transport.killTool() // Do not forward a catchable signal to an already-running app.
                stop("already_running")
              }
              if stoppingAt == nil { state.state = "recording" }
              try state.save()
              lock.release()
              locked = false
              transport.closeSlave()
            }
          } else {
            buffer.withUnsafeBytes { sink.append(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
          }
          if sink.count == sink.capacity && !state.limitReached || sink.error != state.saveError {
            state.limitReached = sink.count == sink.capacity
            state.saveError = sink.error
            pendingSave = true
          }
        }
      } catch {
        stop(ConsoleProblem.from(error).message)
      }
      header.flush(to: &sink)
      transport.finish(into: &sink, buffer: &buffer)
      childStatus = transport.childStatus
      if transport.leaseTimedOut { reason = "lease_timeout" }
      else if childStatus == nil, reason == "child_exited" { reason = "guard_exited" }
      state.diagnostic = [state.appPID == nil ? header.preview : "", transport.diagnostic].filter { !$0.isEmpty }.joined(separator: "\n")
      if state.diagnostic == "" { state.diagnostic = nil }
    } catch {
      reason = ConsoleProblem.from(error).message
    }
    if close(output) != 0, sink.error == nil { sink.error = String(cString: strerror(errno)) }
    state.saveError = sink.error
    state.limitReached = sink.count == sink.capacity
    state.bytesWritten = sink.count
    state.finish(reason, status: childStatus)
    do { try state.saveFinal() } catch { return 1 }
    unlink(state.stopURL.path)
    return 0
  }

  // No signal by PID crosses the journal boundary. The worker accepts only its own request.
  static func requestedStop(_ state: ConsoleState) -> Bool {
    guard access(state.stopURL.path, F_OK) == 0, let request = try? ConsoleState.read(state.captureID, from: state.stopURL) else { return false }
    return request.workerArguments == state.workerArguments && request.pid == state.pid && request.startedAt == state.startedAt
  }

  /// A worker can die after spawning the guard but before the guard takes its owner lock.
  /// Check same-user process arguments before marking that capture lost.
  private static func hasCaptureProcess(_ id: String) -> Bool {
    let type = UInt32(PROC_UID_ONLY)
    let bytes = proc_listpids(type, getuid(), nil, 0)
    guard bytes > 0 else { return true }
    var pids = [Int32](repeating: 0, count: Int(bytes) / 4 + 64)
    let used = proc_listpids(type, getuid(), &pids, Int32(pids.count * 4))
    guard used > 0, used < pids.count * 4 else { return true }
    return pids.prefix(Int(used) / 4).contains { pid in
      guard let args = RelayProcess.arguments(pid: pid), args.count >= 3 else { return false }
      return ["__console-worker", "__console-child"].contains(args[1]) && args[2] == id
    }
  }

  static func checked(_ id: String, in directory: URL = ConsoleState.directory, now: Date = Date(),
                      executableName: String = RelayProcess.currentExecutableName, snapshot: (Int32) -> RelayProcess.Snapshot? = RelayProcess.snapshot(pid:)) throws -> ConsoleState {
    let url = ConsoleState.file(id, in: directory)
    let unavailable = ConsoleProblem(.consoleOwnershipUnverified, "cannot verify ownership of capture \(id)")
    let modified = ConsoleState.modified(url)
    let original: ConsoleState
    do { original = try ConsoleState.read(id, in: directory) }
    catch {
      guard let modified, now.timeIntervalSince(modified) >= 7 * 86400 else { throw error }
      let fields = ConsoleState.partial(id, in: directory)
      original = ConsoleState(captureID: id, udid: fields["udid"] ?? "", bundleID: fields["bundleID"] ?? "",
                              session: fields["session"], path: fields["path"] ?? "", runnerPID: 0, runnerStart: .distantPast)
    }
    func rereadBeforeFailure() throws -> ConsoleState {
      if let latest = try? ConsoleState.read(id, in: directory), latest.finishedAt != nil { return latest }
      throw unavailable
    }
    if original.finishedAt != nil { return original }
    if let pid = original.pid {
      if let observed = snapshot(pid) {
        if original.owns(observed, executableName: executableName) { return original }
        if !observed.arguments.isEmpty, original.startedAt == nil || original.startedAt == observed.startedAt {
          return try rereadBeforeFailure()
        }
      } else if kill(pid, 0) == 0 || errno != ESRCH { return try rereadBeforeFailure() }
    }
    guard let lock = try ConsoleState.ownerLock(id, in: directory, exclusive: true) else {
      if let last = try? ConsoleState.read(id, in: directory), last.finishedAt != nil || last.state == "starting" && last.pid == nil { return last }
      throw unavailable
    }
    defer { close(lock) }
    var last = (try? ConsoleState.read(id, in: directory)) ?? original
    if last.finishedAt != nil { return last }
    if hasCaptureProcess(id) { return try rereadBeforeFailure() }
    guard ConsoleState.modified(url) != nil else { throw ConsoleProblem(.consoleNotFound, "unknown console capture \(id)") }
    last.finish("lost")
    last.finishedAt = modified ?? now
    try last.saveFinal(in: directory)
    return last
  }

  static func appOutcome(_ state: ConsoleState) -> String {
    guard let pid = state.appPID, let start = state.appStart else { return "unknown" }
    if let current = RelayProcess.startTime(pid: pid) { return current == start ? "running" : "ended" }
    return kill(pid, 0) < 0 && errno == ESRCH ? "ended" : "unknown"
  }

  static func run(_ command: ConsoleCommand) -> Int32 {
    do {
      switch command {
      case .status(nil):
        let rows = try ConsoleState.ids().map { id -> [String: Any] in
          do { return try checked(id).json }
          catch {
            var row = ConsoleState.partial(id, in: ConsoleState.directory)
            row["captureID"] = id
            row["state"] = "ownership_unverified"
            row["code"] = ConsoleProblem.from(error).code.rawValue
            return row
          }
        }
        CLIOutput.writeLine(CLIOutput.json(rows))
      case .status(let id?):
        let state = try checked(id)
        if let message = state.saveError {
          CLIOutput.writeLine(CLIOutput.failureBody(.consoleSaveFailed, message, extra: ["console": state.json]))
          return 1
        }
        CLIOutput.writeLine(CLIOutput.json(state.json))
      case .stop(let id):
        var state = try checked(id)
        if state.finishedAt == nil {
          guard state.pid != nil else { throw ConsoleProblem(.consoleOwnershipUnverified, "worker has not registered its identity yet") }
          try state.write(to: state.stopURL)
          let deadline = now + stopTimeout
          repeat {
            usleep(25000)
            state = try checked(id)
          } while state.finishedAt == nil && now < deadline
          guard state.finishedAt != nil else { throw ConsoleProblem(.consoleUnavailable, "timed out stopping \(id); the stop request remains pending; check relay console status \(id)") }
          unlink(state.stopURL.path)
        }
        var result = state.json
        result["appState"] = appOutcome(state)
        CLIOutput.writeLine(CLIOutput.json(result))
      }
      return 0
    } catch {
      let problem = ConsoleProblem.from(error)
      CLIOutput.writeLine(CLIOutput.failureBody(problem.code, problem.message))
      return 1
    }
  }
}
