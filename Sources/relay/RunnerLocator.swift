import Foundation

/// Finds the `runner.json` that the runner commands (`relay tap`, `relay screenshot`, ...) read the URL
/// and token from. The token is never taken from the command line, where `ps` would show it.
///
/// Order: `--runner <path>` or `--session <name>` (one of them), then `$RELAY_RUNNER` or `$RELAY_SESSION`
/// (one of them), then `.relay/runner.json` in the current directory or any parent, then
/// `~/.relay/runner.json`, which is where `relay start` without a session writes it, wherever it runs.
/// An option wins over a variable, so `--runner` works where `RELAY_SESSION` is set.
enum RunnerLocator {
    static let environmentKey = "RELAY_RUNNER"

    /// What selects the file. A `.file` or `.session` must exist; only `.search` looks further.
    enum Selection: Equatable {
        case file(source: String, path: String)
        case session(source: String, name: String)
        case search
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
        return .search
    }

    /// The file `relay start` writes.
    static func userURL(home: URL = UserHome.url) -> URL {
        RunnerInfo.defaultURL(rootURL: home)
    }

    /// The file to read. A path or session given with an option or a variable must exist: falling back to
    /// another runner would send the commands to a device the caller did not ask for. A file found by the
    /// search still works while sessions run, with a warning (`sessionlessWarning`): an agent whose command
    /// lost `RELAY_SESSION` may be about to operate someone else's runner.
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
        case .search:
            break
        }

        let candidates = searchPath(currentDirectory: currentDirectory, home: home)
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RunnerUnavailableError(description: "no runner.json found in .relay/ of \(currentDirectory.path) or its parents, "
                + "nor at \(userURL(home: home).path); start the runner with relay start, or pass --runner <path> or --session <name>, or set \(environmentKey) or \(RelaySession.environmentKey)")
        }
        if let warning = sessionlessWarning(using: found, sessions: RelaySession.running(home: home)) {
            warn(warning)
        }
        return found
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

    /// `.relay/runner.json` in `currentDirectory` and each parent up to the root, then the home copy.
    static func searchPath(currentDirectory: URL, home: URL) -> [URL] {
        var candidates: [URL] = []
        var directory = currentDirectory.standardizedFileURL
        while true {
            candidates.append(RunnerInfo.defaultURL(rootURL: directory))
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { break }
            directory = parent
        }
        let user = userURL(home: home).standardizedFileURL
        if !candidates.contains(user) {
            candidates.append(user)
        }
        return candidates
    }
}

/// No runner to talk to: no `runner.json`, or nothing answering at its URL.
struct RunnerUnavailableError: Error, CustomStringConvertible {
    let description: String
}
