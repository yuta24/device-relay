import Darwin
import Foundation

/// `--session` and `$RELAY_SESSION` could not be used: an invalid name, or two sources that disagree.
struct SessionSelectionError: Error, CustomStringConvertible {
  let description: String
}

/// A named `relay start`, so several agents can each drive their own device: start each agent with
/// `RELAY_SESSION=agent-1` in its environment, or pass `--session agent-1` to every command. An `export` in
/// one command's shell does not reach the next command where each gets a new shell (agents' shell tools).
///
/// A session's files are under `~/.relay/sessions/<name>/`: `runner.json` (what `~/.relay/runner.json` is
/// without a session) and `session.lock`, which `relay start` holds from before it picks a device until it
/// exits (see `StartLock`). A session never reads or writes `~/.relay/runner.json` or another session's
/// file: falling back to one would send the commands to a device the caller did not ask for.
enum RelaySession {
  static let environmentKey = "RELAY_SESSION"
  static let maxNameLength = 64

  /// Letters, digits, `.`, `_`, and `-`, starting with a letter or digit: one path component, never `..`.
  /// The default APFS volume ignores case, so `A` and `a` are the same session there.
  static func isValidName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= maxNameLength else { return false }
    func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
      ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || ("0" ... "9").contains(scalar)
    }
    return isASCIIAlphanumeric(first)
      && name.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
  }

  static func validated(_ name: String, source: String = "--session") throws -> String {
    guard isValidName(name) else {
      throw SessionSelectionError(description: "invalid session name in \(source): \(name) "
        + "(up to \(maxNameLength) letters, digits, '.', '_', and '-', starting with a letter or digit)")
    }
    return name
  }

  /// `--session`, else `$RELAY_SESSION`; nil when neither is given. An empty variable counts as unset.
  static func resolve(flag: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
    if let flag {
      return try validated(flag)
    }
    guard let value = environment[environmentKey], !value.isEmpty else { return nil }
    return try validated(value, source: "$\(environmentKey)")
  }

  static func directory(name: String, home: URL = UserHome.url) -> URL {
    sessionsDirectory(home: home).appendingPathComponent(name, isDirectory: true)
  }

  static func infoURL(name: String, home: URL = UserHome.url) -> URL {
    directory(name: name, home: home).appendingPathComponent(RunnerInfo.fileName)
  }

  static func lockURL(name: String, home: URL = UserHome.url) -> URL {
    directory(name: name, home: home).appendingPathComponent("session.lock")
  }

  /// The session directories that exist, sorted. The directories of sessions that ended stay; only the
  /// files in them tell whether anything runs (see `RunnerSessions`).
  static func names(home: URL = UserHome.url) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory(home: home).path)) ?? []
    return names.filter(isValidName).sorted()
  }

  /// The sessions among `names` with something running: a runner.json, or a held lock (still booting or
  /// building). A runner.json left by a `kill -9` counts too: telling it apart takes a `/ping`.
  static func running(names: [String], hasRunnerInfo: (String) -> Bool, isLocked: (String) -> Bool) -> [String] {
    names.filter { hasRunnerInfo($0) || isLocked($0) }
  }

  /// Lists a directory and checks a file or two per session, without asking any runner: every runner
  /// command without a session goes through this.
  static func running(home: URL = UserHome.url) -> [String] {
    running(
      names: names(home: home),
      hasRunnerInfo: { FileManager.default.fileExists(atPath: infoURL(name: $0, home: home).path) },
      isLocked: { StartLock.holder(of: lockURL(name: $0, home: home)) != nil }
    )
  }

  private static func sessionsDirectory(home: URL) -> URL {
    home.appendingPathComponent(".relay/sessions", isDirectory: true)
  }
}

/// What `relay start --session` picks when `--port` is not given.
enum PortPicker {
  /// The default port stays out of it, so a `relay start` without a session keeps working next to sessions.
  static let sessionRange = 8101 ... 8199

  /// Whether this Mac can listen on `port` now (a simulator's runner shares the Mac's loopback). Without
  /// `SO_REUSEADDR`, a port something listened on a moment ago counts as taken too.
  static func isFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  /// The first port in `range` whose lock this process gets and that is free, with that lock held. The
  /// lock comes first: another `relay start` looking at the same moment skips the port, even though
  /// nothing listens there until the runner is built and launched.
  static func pick(
    range: ClosedRange<Int> = sessionRange,
    isFree: (Int) -> Bool = PortPicker.isFree,
    lock: (Int) throws -> StartLock?
  ) throws -> (port: Int, lock: StartLock) {
    for port in range {
      guard let held = try lock(port) else { continue }
      if isFree(port) {
        return (port, held)
      }
      held.release()
    }
    throw SetupError(description: "no free port in \(range.lowerBound)...\(range.upperBound) for the session; pass --port <n>")
  }
}
