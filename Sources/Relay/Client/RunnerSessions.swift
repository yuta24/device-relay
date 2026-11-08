import Darwin
import Foundation

/// `relay status --all` and `relay stop --all`: every session, and the runner of `~/.relay/runner.json`.
enum RunnerSessions {
  /// One line of the list.
  struct Row {
    enum State: String {
      /// `relay start` holds the session but has written no runner.json yet (booting or building).
      case starting
      case running
      /// Answers `/ping` while running a command.
      case busy
      /// runner.json is there but nothing answers: stale, `relay stop` cleans up.
      case noAnswer = "no answer"
      /// Something answers at that URL, but not to this token: not this session's runner.
      case rejected
      /// This Mac refused the connection (a sandbox), which says nothing about the runner.
      case unknown
    }

    /// nil for the runner of `~/.relay/runner.json`.
    var session: String?
    var state: State
    var info: RunnerInfo?
    var infoURL: URL
    /// The `relay start`: runner.json's while it runs, else the holder of the session's lock.
    var pid: Int32?
    var processRunning: Bool?
    var ping: RunnerPing?

    var label: String { session ?? "(default)" }

    var isAlive: Bool { ping?.isAlive ?? false }
  }

  static func state(for ping: RunnerPing) -> Row.State {
    switch ping {
    case .alive(let busy, _): return busy ? .busy : .running
    case .status: return .rejected
    case .unreachable: return .noAnswer
    case .refusedByOS: return .unknown
    }
  }

  /// A session directory with neither runner.json nor a held lock has nothing running and no row.
  static func rows(
    home: URL = UserHome.url,
    ping: (RunnerInfo) -> RunnerPing = { RunnerPing.check($0, timeout: 2) },
    processRunning: (RunnerInfo) -> Int32? = RelayProcess.runningRelayStart
  ) -> [Row] {
    func row(session: String?, infoURL: URL) -> Row? {
      guard let info = try? RunnerInfo.read(from: infoURL) else { return nil }
      let answer = ping(info)
      let running = processRunning(info)
      return Row(session: session, state: state(for: answer), info: info, infoURL: infoURL, pid: info.pid,
                 processRunning: info.pid.map { _ in running != nil }, ping: answer)
    }
    var rows: [Row] = []
    if let row = row(session: nil, infoURL: RunnerLocator.userURL(home: home)) {
      rows.append(row)
    }
    for name in RelaySession.names(home: home) {
      let infoURL = RelaySession.infoURL(name: name, home: home)
      if let row = row(session: name, infoURL: infoURL) {
        rows.append(row)
      } else if let holder = StartLock.holder(of: RelaySession.lockURL(name: name, home: home)) {
        rows.append(Row(session: name, state: .starting, infoURL: infoURL, pid: holder.pid, processRunning: holder.pid != nil))
      }
    }
    return rows
  }

  static func table(_ rows: [Row]) -> String {
    guard !rows.isEmpty else { return "no runners" }
    let header = ["SESSION", "STATE", "DEVICE", "URL", "PID"]
    let lines = rows.map { row -> [String] in
      let device = row.info.map { info in info.name.map { "\($0) (\(info.udid))" } ?? info.udid } ?? "-"
      let pid = row.pid.map { "\($0)\(row.processRunning == false ? " (exited)" : "")" } ?? "-"
      return [row.label, row.state.rawValue, device, row.info?.url ?? "-", pid]
    }
    let widths = header.indices.map { column in ([header] + lines).map { DeviceList.displayWidth($0[column]) }.max() ?? 0 }
    return ([header] + lines).map { line in
      line.enumerated().map { column, value in
        column == line.count - 1 ? value : value + String(repeating: " ", count: widths[column] - DeviceList.displayWidth(value))
      }.joined(separator: "  ")
    }.joined(separator: "\n")
  }

  /// One array; `session` is null for the runner of `~/.relay/runner.json`.
  static func json(_ rows: [Row]) -> Data {
    let objects: [[String: Any]] = rows.map { row in
      [
        "session": row.session ?? NSNull(),
        "state": row.state.rawValue,
        "alive": row.isAlive,
        "url": row.info?.url ?? NSNull(),
        "udid": row.info?.udid ?? NSNull(),
        "name": row.info?.name ?? NSNull(),
        "pid": row.pid.map { NSNumber(value: $0) } ?? NSNull(),
        "processRunning": row.processRunning.map { NSNumber(value: $0) } ?? NSNull(),
        "runnerInfo": row.infoURL.path
      ]
    }
    return CLIOutput.json(objects, fallback: Data("[]".utf8))
  }

  /// Always 0: the list is the answer, and a line that is not running is part of it.
  static func status(json asJSON: Bool) -> Int32 {
    let rows = rows()
    if asJSON {
      FileHandle.standardOutput.write(json(rows) + Data("\n".utf8))
    } else {
      print(table(rows))
    }
    return RunnerExitCode.success.rawValue
  }

  /// Stops every line, one after the other, each printing `<label>: stopped`, and returns the first failure.
  static func stopAll(home: URL = UserHome.url) -> Int32 {
    let rows = rows(home: home)
    guard !rows.isEmpty else {
      print("not running")
      return RunnerExitCode.success.rawValue
    }
    var result = RunnerExitCode.success.rawValue
    for row in rows {
      let prefix = "\(row.label): "
      let code: Int32
      if let info = row.info {
        code = RunnerStop.stop(info, infoURL: row.infoURL, prefix: prefix)
      } else if let session = row.session {
        code = RunnerStop.stopStarting(session: session, home: home, prefix: prefix)
      } else {
        continue
      }
      if result == RunnerExitCode.success.rawValue {
        result = code
      }
    }
    return result
  }
}
