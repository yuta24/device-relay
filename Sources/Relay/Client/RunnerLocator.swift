import Foundation

/// Finds the `runner.json` that the runner commands (`relay tap`, `relay screenshot`, ...) read the URL
/// and token from. The token is never taken from the command line, where `ps` would show it.
///
/// Order: `--runner <path>` or `--session <name>` (one of them), then `$RELAY_RUNNER` or `$RELAY_SESSION`
/// (one of them), then `~/.relay/runner.json`, which is where `relay start` without a session writes it,
/// wherever it runs. An option wins over a variable, so `--runner` works where `RELAY_SESSION` is set.
/// A `.relay/runner.json` in the current directory or a parent is not read (older relay versions wrote
/// one there): a file that `relay start` did not just write is the likeliest cause of a 401. It is only
/// mentioned when nothing else is found (`legacyFile`); `--runner` still reads a file kept anywhere.
enum RunnerLocator {
  static let environmentKey = "RELAY_RUNNER"

  /// What selects the file. A `.file` or `.session` must exist; `.defaultRunner` is `~/.relay/runner.json`.
  enum Selection: Equatable {
    case file(source: String, path: String)
    case session(source: String, name: String)
    case defaultRunner
  }

  /// Throws `SessionSelectionError` for an invalid session name, and when the two variables are both set:
  /// nothing says which is meant, and guessing could operate the wrong device.
  static func selection(
    explicitPath: String?,
    session: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Selection {
    if explicitPath != nil, session != nil {
      throw SessionSelectionError(description: "--runner and --session select the runner in two ways; pass one")
    }
    if let explicitPath {
      return .file(source: "--runner", path: explicitPath)
    }
    if let session {
      return .session(source: "--session", name: try RelaySession.validated(session))
    }
    let path = environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
    let name = try RelaySession.resolve(flag: nil, environment: environment)
    if path != nil, name != nil {
      throw SessionSelectionError(description: "both $\(environmentKey) and $\(RelaySession.environmentKey) are set; unset one, "
        + "or pass --runner or --session")
    }
    if let path {
      return .file(source: "$\(environmentKey)", path: path)
    }
    if let name {
      return .session(source: "$\(RelaySession.environmentKey)", name: name)
    }
    return .defaultRunner
  }

  /// The file `relay start` writes.
  static func userURL(home: URL = UserHome.url) -> URL {
    RunnerInfo.defaultURL(rootURL: home)
  }

  /// The file to read. A path or session given with an option or a variable must exist: falling back to
  /// another runner would send the commands to a device the caller did not ask for. Without one, it is
  /// `~/.relay/runner.json`, which still works while sessions run, with a warning (`sessionlessWarning`):
  /// an agent whose command lost `RELAY_SESSION` may be about to operate someone else's runner.
  static func locate(
    explicitPath: String?,
    session: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: URL = WorkingDirectory.url,
    home: URL = UserHome.url,
    warn: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
  ) throws -> URL {
    switch try selection(explicitPath: explicitPath, session: session, environment: environment) {
    case .file(let source, let path):
      let url = resolve(path, in: currentDirectory)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw RunnerUnavailableError(description: "\(source) \(url.path) does not exist; is relay start running?")
      }
      return url
    case .session(let source, let name):
      let url = RelaySession.infoURL(name: name, home: home)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw RunnerUnavailableError(description: "session \(name) (\(source)) has no runner: \(url.path) does not exist; "
          + "relay start --background --session \(name) starts one, relay status --all lists what runs")
      }
      return url
    case .defaultRunner:
      break
    }

    let found = userURL(home: home)
    guard FileManager.default.fileExists(atPath: found.path) else {
      let legacy = legacyFile(currentDirectory: currentDirectory, home: home).map { "; " + legacyNote(for: $0) } ?? ""
      throw RunnerUnavailableError(description: "no runner.json at \(found.path); start the runner with relay start, "
        + "or pass --runner <path> or --session <name>, or set \(environmentKey) or \(RelaySession.environmentKey)\(legacy)")
    }
    if let warning = sessionlessWarning(using: found, sessions: RelaySession.running(home: home)) {
      warn(warning)
    }
    return found
  }

  /// The nearest `.relay/runner.json` in `currentDirectory` or a parent that older relay versions may have
  /// left there, which is no longer read. Looked for only to say so; the home copy is not one.
  static func legacyFile(currentDirectory: URL, home: URL) -> URL? {
    let user = userURL(home: home).standardizedFileURL
    var directory = currentDirectory.standardizedFileURL
    while true {
      let candidate = RunnerInfo.defaultURL(rootURL: directory).standardizedFileURL
      if candidate != user, FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      let parent = directory.deletingLastPathComponent().standardizedFileURL
      guard parent.path != directory.path else { return nil }
      directory = parent
    }
  }

  /// `.relay/runner.json in <dir> is no longer read; pass --runner <path>`.
  static func legacyNote(for file: URL) -> String {
    let directory = file.deletingLastPathComponent().deletingLastPathComponent().path
    return ".relay/runner.json in \(directory) is no longer read; pass --runner \(file.path) to use it"
  }

  /// What to say when the search found `url` while `sessions` are running; nil when none is.
  static func sessionlessWarning(using url: URL, sessions: [String]) -> String? {
    guard !sessions.isEmpty else { return nil }
    let running = sessions.count == 1 ? "session \(sessions[0]) is running" : "sessions \(sessions.joined(separator: ", ")) are running"
    return "relay: warning: no session selected; using \(url.path), while \(running); "
      + "pass --session or set \(RelaySession.environmentKey)"
  }

  /// `path` as given when absolute, else under `directory`, canonical. `URL(fileURLWithPath:relativeTo:)`
  /// would drop the last component of a directory URL without a trailing slash.
  static func resolve(_ path: String, in directory: URL) -> URL {
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    return url.canonicalFileURL
  }
}

/// No runner to talk to: no `runner.json`, or nothing answering at its URL.
struct RunnerUnavailableError: Error, CustomStringConvertible {
  let description: String
}
