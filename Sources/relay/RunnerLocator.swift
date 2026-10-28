import Foundation

/// Finds the `runner.json` that the runner commands (`relay tap`, `relay screenshot`, ...) read the URL
/// and token from. The token is never taken from the command line, where `ps` would show it.
///
/// Order: `--runner <path>`, then `$RELAY_RUNNER`, then `.relay/runner.json` in the current directory or
/// any parent, then `~/.relay/runner.json`. `relay start` runs in the device-relay repository but the
/// runner is usually driven from the app's repository, so it also writes the copy in the home directory.
enum RunnerLocator {
    static let environmentKey = "RELAY_RUNNER"

    /// The copy `relay start` writes for commands run outside the device-relay repository.
    static func userURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        RunnerInfo.defaultURL(rootURL: home)
    }

    /// The file to read. A path given with `--runner` or `$RELAY_RUNNER` must exist: falling back to
    /// another runner would send the commands to a device the caller did not ask for.
    static func locate(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let given: (source: String, path: String)?
        if let explicitPath {
            given = ("--runner", explicitPath)
        } else if let path = environment[environmentKey], !path.isEmpty {
            given = ("$\(environmentKey)", path)
        } else {
            given = nil
        }
        if let given {
            let url = resolve(given.path, in: currentDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RunnerUnavailableError(description: "\(given.source) \(url.path) does not exist; is relay start running?")
            }
            return url
        }

        let candidates = searchPath(currentDirectory: currentDirectory, home: home)
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RunnerUnavailableError(description: "no runner.json found in .relay/ of \(currentDirectory.path) or its parents, "
                + "nor at \(userURL(home: home).path); start the runner with relay start, or pass --runner <path> or set \(environmentKey)")
        }
        return found
    }

    /// `path` as given when absolute, else under `directory`. `URL(fileURLWithPath:relativeTo:)` would
    /// drop the last component of a directory URL without a trailing slash.
    static func resolve(_ path: String, in directory: URL) -> URL {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        return url.standardizedFileURL
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
