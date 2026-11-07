import Foundation

/// Finds the runner root (a directory holding `Runner/RelayRunner.xcodeproj`) that `relay start` builds,
/// so relay runs from any directory (usually the app's repository).
///
/// Order: `--project <path>`, then `$RELAY_HOME`, then a device-relay checkout in the current directory
/// or its parents, then the directory holding the relay executable (symlinks resolved, so `make install`'s
/// link finds its checkout, and `bin/relay` of an extracted release or a link to it finds `../Runner`), then
/// the copy `relay install` made in `~/.relay/runner`. A "checkout" is anything with the repository's layout,
/// an extracted release included. The executable's own directory wins over the installed copy, so upgrading
/// relay never keeps building the runner of an older `relay install`; the copy is for a relay binary copied
/// away from its directory. Build products, logs, and `runner.json` go under `~/.relay`, never to the current directory (see
/// `buildDirectory`).
enum RunnerProject {
    static let environmentKey = "RELAY_HOME"
    static let projectPath = "Runner/RelayRunner.xcodeproj"

    enum Source: Equatable {
        case option
        case environment
        case installed
        case currentDirectory
        case executable

        var label: String {
            switch self {
            case .option: return "--project"
            case .environment: return "$\(RunnerProject.environmentKey)"
            case .installed: return "relay install"
            case .currentDirectory: return "current directory"
            case .executable: return "relay executable"
            }
        }
    }

    /// The copy `relay install` makes: `Runner/` and the shared sources it compiles, as in the checkout.
    static func installedRoot(home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay", isDirectory: true).appendingPathComponent("runner", isDirectory: true)
    }

    /// Whether `root` is the copy `relay install` made, however it was found (`--project` can name it too).
    static func isInstalledRoot(_ root: URL, home: URL = UserHome.url) -> Bool {
        root.canonicalFileURL.path == installedRoot(home: home).canonicalFileURL.path
    }

    /// Where the runner at `root` is built: `~/.relay/build/installed` for the installed copy, else a
    /// directory per checkout path, so builds of different sources never reuse each other's `.xctestrun`.
    static func buildDirectory(root: URL, home: URL = UserHome.url) -> URL {
        let builds = home.appendingPathComponent(".relay/build", isDirectory: true)
        if isInstalledRoot(root, home: home) {
            return builds.appendingPathComponent("installed", isDirectory: true)
        }
        let root = root.canonicalFileURL
        let key = RunnerAuth.tokenHash(root.path).prefix(12)
        return builds.appendingPathComponent("\(root.lastPathComponent)-\(key)", isDirectory: true)
    }

    /// The runner root. A path given with `--project` or `$RELAY_HOME` must hold the project: falling
    /// back to another one would build something the caller did not ask for. `includeInstalled: false`
    /// finds a checkout or extracted release only, which is what `relay install` copies from.
    static func resolve(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = WorkingDirectory.url,
        executableURL: URL? = Bundle.main.executableURL,
        home: URL = UserHome.url,
        includeInstalled: Bool = true
    ) throws -> (root: URL, source: Source) {
        let given: (source: Source, path: String)?
        if let explicitPath {
            given = (.option, explicitPath)
        } else if let path = environment[environmentKey], !path.isEmpty {
            given = (.environment, path)
        } else {
            given = nil
        }
        if let given {
            var root = RunnerLocator.resolve(given.path, in: currentDirectory)
            // Also accept the Runner directory or the .xcodeproj itself.
            if root.pathExtension == "xcodeproj" {
                root = root.deletingLastPathComponent()
            }
            if !contains(root), contains(root.deletingLastPathComponent()) {
                root = root.deletingLastPathComponent()
            }
            guard contains(root) else {
                throw SetupError(description: "\(given.source.label) \(given.path): \(projectPath) not found under \(root.path)")
            }
            return (root, given.source)
        }

        let installed = installedRoot(home: home)
        // Skip the installed copy when looking for a checkout from inside it.
        let isCheckout = { (root: URL) in contains(root) && root.canonicalFileURL.path != installed.canonicalFileURL.path }
        if let root = ancestors(of: currentDirectory).first(where: isCheckout) {
            return (root, .currentDirectory)
        }
        if let executableURL, let root = ancestors(of: executableURL.resolvingSymlinksInPath().deletingLastPathComponent()).first(where: isCheckout) {
            return (root, .executable)
        }
        if includeInstalled, contains(installed) {
            return (installed, .installed)
        }
        throw SetupError(description: includeInstalled
            ? "cannot find the runner project (\(projectPath)) around the relay executable or in \(installed.path); "
                + "a relay binary copied away from its directory needs relay install run once from the extracted release "
                + "directory (or the checkout). Otherwise pass --project <path to device-relay>, or set \(environmentKey)=<path to device-relay>"
            : "cannot find a device-relay checkout or extracted release to install the runner from; run relay install from inside "
                + "one, pass --project <path to device-relay>, or set \(environmentKey)=<path to device-relay>")
    }

    static func contains(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(projectPath).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// `directory` and each parent up to the root.
    static func ancestors(of directory: URL) -> [URL] {
        var directories: [URL] = []
        var directory = directory.standardizedFileURL
        while true {
            directories.append(directory)
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return directories
    }
}

/// `~/.relay/build/<dir>/relay-build-dir.json`: which runner project a build directory belongs to and when
/// relay last used it, for `RelayPrune`. It sits next to `DerivedData-*`, so neither Xcode nor the runner
/// source hash (files under the root) ever reads it.
///
/// A runner that stays up for longer than `RelayPrune.buildUnusedMaxAge` is not refreshed while it runs: being
/// in use protects its directory until it stops, and at worst the next start after that rebuilds.
struct BuildDirectoryRecord: Codable, Equatable {
    static let fileName = "relay-build-dir.json"

    /// The canonical path of the runner root.
    var root: String
    var lastUsed: Date

    static func url(buildDirectory: URL) -> URL {
        buildDirectory.appendingPathComponent(fileName)
    }

    static func read(buildDirectory: URL) -> BuildDirectoryRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(buildDirectory: buildDirectory))).flatMap { try? decoder.decode(BuildDirectoryRecord.self, from: $0) }
    }

    /// Records that `root` uses `buildDirectory` now, creating the directory for a first build.
    static func refresh(root: URL, buildDirectory: URL, now: Date = Date()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(BuildDirectoryRecord(root: root.canonicalFileURL.path, lastUsed: now))
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        try data.write(to: url(buildDirectory: buildDirectory), options: .atomic)
    }
}
