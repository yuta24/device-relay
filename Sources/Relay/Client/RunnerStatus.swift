import Darwin
import Foundation

struct RunnerStatusOptions: Equatable {
  var json = false
  /// `--runner <path>`; nil uses what `RunnerLocator` describes.
  var runnerPath: String?
  /// `--session <name>` (see `RelaySession`); nil uses `$RELAY_SESSION`, else `~/.relay/runner.json`.
  var session: String?
  /// `--all`: every session and the runner of `~/.relay/runner.json` (see `RunnerSessions`).
  var all = false
}

struct RunnerStopOptions: Equatable {
  var runnerPath: String?
  var session: String?
  var all = false
}

/// The answer of `GET /ping`.
enum RunnerPing: Equatable {
  case alive(busy: Bool, busyForMs: Int?)
  /// The runner answered with something other than 200 (401 when the token is not its own).
  case status(Int)
  case unreachable(String)
  /// This Mac refused the connection (EPERM), as a sandbox that blocks localhost does; the runner may be fine.
  case refusedByOS(String)

  static func check(_ info: RunnerInfo, timeout: TimeInterval = 3) -> RunnerPing {
    checkWithBuild(info, timeout: timeout).ping
  }

  /// Also the build the runner reports in the `/ping` body (nil when it does not, or did not answer 200).
  static func checkWithBuild(_ info: RunnerInfo, timeout: TimeInterval = 3) -> (ping: RunnerPing, runner: RunnerBuildVersion?) {
    guard let url = URL(string: info.url) else { return (.unreachable("invalid url: \(info.url)"), nil) }
    var client = RunnerClient(baseURL: url, token: info.token)
    client.timeout = timeout
    do {
      let response = try client.get("/ping")
      let ping = parse(response)
      return (ping, ping.isAlive ? RunnerBuildVersion.parse(responseBody: response.body) : nil)
    } catch {
      return (RunnerConnectionError.isRefusedByOS(error) ? .refusedByOS(error.localizedDescription) : .unreachable(error.localizedDescription), nil)
    }
  }

  static func parse(_ response: RunnerResponse) -> RunnerPing {
    guard response.status == 200 else { return .status(response.status) }
    let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    return .alive(busy: object?["busy"] as? Bool ?? false, busyForMs: (object?["busyForMs"] as? NSNumber)?.intValue)
  }

  var isAlive: Bool {
    if case .alive = self { return true }
    return false
  }

  /// 0 alive, 3 no answer, else the code the runner commands use for the status (4 for 401).
  var exitCode: RunnerExitCode {
    switch self {
    case .alive: return .success
    case .status(let status): return status == 200 ? .runnerError : RunnerExitCode(status: status)
    case .unreachable, .refusedByOS: return .unavailable
    }
  }

  var summary: String {
    switch self {
    case .alive(let busy, let busyForMs):
      return busy ? "ok (busy\(busyForMs.map { " for \($0) ms" } ?? ""))" : "ok (idle)"
    case .status(let status):
      return status == 401 ? "401 (the runner rejected the token in runner.json)" : "HTTP \(status)"
    case .unreachable(let reason):
      return "no answer (\(reason))"
    case .refusedByOS:
      return "no answer: the OS refused the connection (Operation not permitted); relay may be in a sandbox that blocks localhost"
    }
  }
}

/// `relay status`: what runner.json says and whether the runner answers.
enum RunnerStatus {
  struct Report {
    var infoURL: URL
    var info: RunnerInfo
    /// Whether the `relay start` in runner.json still runs (nil when runner.json has no pid).
    var processRunning: Bool?
    var ping: RunnerPing
    /// The build the runner reports in `/ping` (nil when it does not answer, or predates reporting it).
    var runner: RunnerBuildVersion? = nil
  }

  static func run(_ options: RunnerStatusOptions) -> Int32 {
    if options.all {
      return RunnerSessions.status(json: options.json)
    }
    let infoURL: URL
    let info: RunnerInfo
    do {
      infoURL = try RunnerLocator.locate(explicitPath: options.runnerPath, session: options.session)
      info = try RunnerInfo.read(from: infoURL)
    } catch let error as RunnerUnavailableError {
      return notRunning(error.description, json: options.json)
    } catch let error as SessionSelectionError {
      return CLIOutput.usageError(error.description, command: "status")
    } catch {
      return fail("cannot read runner info: \(error)", code: .failure, json: options.json ? .runnerInfoInvalid : nil)
    }
    let check = RunnerPing.checkWithBuild(info)
    let report = Report(
      infoURL: infoURL,
      info: info,
      processRunning: info.pid.map { _ in RelayProcess.runningRelayStart(info) != nil },
      ping: check.ping,
      runner: check.runner
    )
    if options.json {
      FileHandle.standardOutput.write(json(report) + Data("\n".utf8))
    } else {
      print(text(report))
    }
    if case .refusedByOS = report.ping {
      // relay stop would remove runner.json of a runner that may be fine, and relay start can't run here either.
      FileHandle.standardError.write(Data("relay: cannot check the runner from here: \(RunnerConnectionError.refusedByOSHint)\n".utf8))
    } else if !report.ping.isAlive, report.ping.exitCode == .unavailable {
      FileHandle.standardError.write(Data("relay: the runner does not answer; relay stop cleans up, relay start --background starts a new one\n".utf8))
    }
    return report.ping.exitCode.rawValue
  }

  static func text(_ report: Report, timeZone: TimeZone = .current) -> String {
    let info = report.info
    var rows: [(String, String)] = info.session.map { [("session", $0)] } ?? []
    rows.append(("url", info.url))
    rows.append(("device", info.name.map { "\($0) (\(info.udid))" } ?? info.udid))
    if let pid = info.pid {
      let state = report.processRunning == true ? "relay start running" : "relay start not running"
      rows.append(("pid", "\(pid) (\(state))"))
    }
    if let startedAt = info.startedAt {
      rows.append(("started", formatted(startedAt, timeZone: timeZone)))
    }
    if let host = info.hostBundleID {
      rows.append(("host app", host))
    }
    rows.append(("ping", report.ping.summary))
    if let runner = runnerSummary(report) {
      rows.append(("runner", runner))
    }
    rows.append(("runner.json", report.infoURL.path))
    let width = rows.map(\.0.count).max() ?? 0
    return rows.map { "\($0.0):\(String(repeating: " ", count: width - $0.0.count + 1))\($0.1)" }.joined(separator: "\n")
  }

  /// The `runner:` row: what the runner reports, and whether it is what `relay start` built or reused
  /// (runner.json's `runner`), or what runner.json expects while the runner does not answer.
  static func runnerSummary(_ report: Report) -> String? {
    let expected = report.info.runner
    guard report.ping.isAlive else {
      return expected.map { "\($0.summary), from runner.json" }
    }
    guard let reported = report.runner else {
      return "not reported (the runner predates build reporting)"
    }
    if let expectedHash = expected?.sourceHash,
       let mismatch = RunnerBuildVersion.mismatch(reported: reported, expectedSourceHash: expectedHash) {
      return "\(reported.summary); \(mismatch)"
    }
    return reported.summary
  }

  static func json(_ report: Report) -> Data {
    let info = report.info
    var object: [String: Any] = [
      "alive": report.ping.isAlive,
      "url": info.url,
      "udid": info.udid,
      "runnerInfo": report.infoURL.path,
      "name": info.name ?? NSNull(),
      "pid": info.pid.map { NSNumber(value: $0) } ?? NSNull(),
      "processRunning": report.processRunning.map { NSNumber(value: $0) } ?? NSNull(),
      "startedAt": info.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
      "hostBundleID": info.hostBundleID ?? NSNull(),
      "session": info.session ?? NSNull()
    ]
    func build(_ version: RunnerBuildVersion?) -> Any {
      guard let version else { return NSNull() }
      return ["version": version.version ?? NSNull(), "sourceHash": version.sourceHash ?? NSNull()] as [String: Any]
    }
    // What the runner reports, and what relay start expects it to (runner.json).
    object["runner"] = build(report.runner)
    object["expectedRunner"] = build(report.info.runner)
    switch report.ping {
    case .alive(let busy, let busyForMs):
      object["ping"] = ["status": 200, "busy": busy, "busyForMs": busyForMs.map { NSNumber(value: $0) } ?? NSNull()] as [String: Any]
    case .status(let status):
      object["ping"] = ["status": status]
    case .unreachable(let reason):
      object["ping"] = ["error": reason]
    case .refusedByOS(let reason):
      object["ping"] = ["error": reason, "refusedByOS": true] as [String: Any]
    }
    return CLIOutput.json(object)
  }

  static func formatted(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter.string(from: date)
  }

  /// No runner.json: `not running` and the reason on stderr, or, with `--json`, one object on stdout
  /// (`alive: false` and the failure's `code` and `error`; the reason is not repeated on stderr).
  private static func notRunning(_ reason: String, json: Bool) -> Int32 {
    if json {
      return fail(reason, code: .unavailable, json: .runnerUnavailable)
    }
    print("not running")
    return fail(reason, code: .unavailable)
  }

  /// A failure: `relay: <message>` on stderr, or, with `--json` (`json` names the failure's code), the failure
  /// as one object on stdout.
  static func fail(_ message: String, code: RunnerExitCode, json errorCode: RelayErrorCode? = nil) -> Int32 {
    if let errorCode {
      CLIOutput.writeLine(CLIOutput.failureBody(errorCode, message, extra: ["alive": false]))
    } else {
      CLIOutput.note(message)
    }
    return code.rawValue
  }
}

/// `relay stop`: stops the `relay start` in runner.json the way Ctrl-C does, or, when that process is
/// gone, the runner itself, and removes the stale runner.json.
enum RunnerStop {
  /// `relay start` needs up to 10 seconds to stop the runner, then shuts down a simulator it booted.
  static let exitTimeout: TimeInterval = 60

  static func run(_ options: RunnerStopOptions) -> Int32 {
    if options.all {
      return RunnerSessions.stopAll()
    }
    let infoURL: URL
    let info: RunnerInfo
    do {
      infoURL = try RunnerLocator.locate(explicitPath: options.runnerPath, session: options.session)
      info = try RunnerInfo.read(from: infoURL)
    } catch is RunnerUnavailableError {
      // A session that is still booting or building has no runner.json yet, but it can be stopped.
      if case .session(_, let name)? = try? RunnerLocator.selection(explicitPath: options.runnerPath, session: options.session) {
        return stopStarting(session: name)
      }
      print("not running")
      return RunnerExitCode.success.rawValue
    } catch let error as SessionSelectionError {
      return CLIOutput.usageError(error.description, command: "stop")
    } catch {
      return RunnerStatus.fail("cannot read runner info: \(error)", code: .failure)
    }
    return stop(info, infoURL: infoURL)
  }

  /// Stops the `relay start` holding `session`'s lock (booting or building: it has written no runner.json), or
  /// prints `not running` when nothing holds it. The pid must be a relay start, as for runner.json.
  static func stopStarting(session: String, home: URL = UserHome.url, prefix: String = "") -> Int32 {
    let lockURL = RelaySession.lockURL(name: session, home: home)
    guard let holder = StartLock.holder(of: lockURL), let pid = holder.pid, let snapshot = RelayProcess.snapshot(pid: pid),
          URL(fileURLWithPath: snapshot.executable).lastPathComponent == RelayProcess.currentExecutableName,
          snapshot.arguments.dropFirst().first == "start" else {
      print("\(prefix)not running")
      return RunnerExitCode.success.rawValue
    }
    note("stopping relay start (pid \(pid)) of session \(session), which is still booting or building")
    guard kill(pid, SIGTERM) == 0 else {
      return RunnerStatus.fail("cannot signal relay start (pid \(pid)): \(String(cString: strerror(errno)))", code: .failure)
    }
    let deadline = Date().addingTimeInterval(exitTimeout)
    while StartLock.holder(of: lockURL) != nil {
      guard Date() < deadline else {
        return RunnerStatus.fail("relay start (pid \(pid)) did not exit within \(Int(exitTimeout))s; see its log in ~/.relay/logs", code: .failure)
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    print("\(prefix)stopped")
    return RunnerExitCode.success.rawValue
  }

  /// Stops the runner `info` names. `prefix` goes before the `stopped` / `not running` line (`relay stop --all`).
  static func stop(_ info: RunnerInfo, infoURL: URL, prefix: String = "") -> Int32 {
    // While the simulator still runs, so the video is complete; its path goes to stderr.
    Recording.cleanUp(port: Recording.port(of: info))

    if let pid = RelayProcess.runningRelayStart(info) {
      note("stopping relay start (pid \(pid)); it shuts the runner down")
      if kill(pid, SIGTERM) != 0 {
        let error = errno
        let reason = error == EPERM ? "; relay may be running inside a sandbox (an AI agent's, for example); run relay stop outside it" : ""
        return RunnerStatus.fail("cannot signal relay start (pid \(pid)): \(String(cString: strerror(error)))\(reason)", code: .failure)
      }
      let deadline = Date().addingTimeInterval(exitTimeout)
      while RelayProcess.runningRelayStart(info) != nil {
        guard Date() < deadline else {
          return RunnerStatus.fail("relay start (pid \(pid)) did not exit within \(Int(exitTimeout))s; see its log in ~/.relay/logs",
                                   code: .failure)
        }
        Thread.sleep(forTimeInterval: 0.2)
      }
      // relay start removes it itself unless it was killed.
      RunnerInfo.remove(at: infoURL, ifTokenIs: info.token)
      print("\(prefix)stopped")
      return RunnerExitCode.success.rawValue
    }

    // No relay start (killed, or runner.json from an old version): stop the runner directly.
    guard let url = URL(string: info.url) else {
      RunnerInfo.remove(at: infoURL, ifTokenIs: info.token)
      note("removed \(infoURL.path), which had an invalid url")
      print("\(prefix)not running")
      return RunnerExitCode.success.rawValue
    }
    var client = RunnerClient(baseURL: url, token: info.token)
    client.timeout = 5
    let status: Int?
    do {
      status = try client.post("/shutdown").status
    } catch {
      if RunnerConnectionError.isRefusedByOS(error) {
        // Nothing is known about the runner, so its runner.json stays.
        return RunnerStatus.fail("cannot reach the runner at \(info.url) to stop it: \(RunnerConnectionError.refusedByOSHint); "
          + "\(infoURL.path) is left as it is", code: .unavailable)
      }
      status = nil
    }
    RunnerInfo.remove(at: infoURL, ifTokenIs: info.token)
    if status == 200 {
      note("relay start is not running; sent /shutdown to the runner at \(info.url) and removed \(infoURL.path)")
      print("\(prefix)stopped")
    } else {
      let reason = status.map { "it answered \($0)" } ?? "nothing answered at \(info.url)"
      note("removed the stale \(infoURL.path) (\(reason))")
      print("\(prefix)not running")
    }
    return RunnerExitCode.success.rawValue
  }

  private static func note(_ message: String) {
    FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
  }
}
