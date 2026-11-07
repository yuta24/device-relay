import Foundation

/// The external commands relay reads the host's state with (`simctl`, `devicectl`, `security`, ...).
/// Tests replace them with canned output. Each takes a time limit (see `CommandTimeout`): none of these may
/// run without one.
struct HostCommands: Sendable {
    /// `xcrun <args>`; stdout and stderr merged. Throws `ShellError` on a nonzero status and at the time limit.
    var xcrun: @Sendable (_ args: [String], _ timeout: TimeInterval) throws -> String
    /// `xcrun devicectl <args> --json-output <file>`, returning the JSON document devicectl wrote.
    var devicectlJSON: @Sendable (_ args: [String], _ timeout: TimeInterval) throws -> Data
    /// `<executable> <args>` for tools outside xcrun (`/usr/bin/security`, `/usr/bin/xcode-select`); stdout
    /// and stderr merged.
    var run: @Sendable (_ executable: String, _ args: [String], _ timeout: TimeInterval) throws -> String

    static let live = HostCommands(
        xcrun: { try Shell.xcrun($0, timeout: $1) },
        devicectlJSON: { try devicectlJSON($0, timeout: $1) },
        run: { try Shell.run($0, $1, timeout: $2) }
    )

    /// `xcrun devicectl <args> --json-output <file>`, returning the JSON document devicectl wrote.
    static func devicectlJSON(_ args: [String], timeout: TimeInterval) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("relay-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        try Shell.xcrun(["devicectl"] + args + ["--json-output", output.path, "--quiet"], timeout: timeout)
        return try Data(contentsOf: output)
    }
}

/// A setup problem found before anything is built or launched (no device, no Team ID, ...). Printed
/// without the usage text, which would bury the explanation.
struct SetupError: Error, CustomStringConvertible {
    let description: String
}

enum UserHome {
    /// `$HOME` like the shell's `~`, else the account's home directory. `homeDirectoryForCurrentUser`
    /// alone ignores `$HOME`, which keeps relay from being pointed at a scratch home. Canonical, like
    /// every path relay shows (`URL.canonicalFileURL`).
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).canonicalFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.canonicalFileURL
    }
}

enum WorkingDirectory {
    /// The current directory, canonical. The process sees it with symlinks resolved but without the
    /// `/private` that `canonicalFileURL` drops (`/private/tmp/app` after `cd /tmp/app`).
    static var url: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).canonicalFileURL
    }
}

extension URL {
    /// The form of a path relay shows and compares: symlinks resolved in the part that exists, so the same
    /// place reached through `$HOME`, the current directory, git, or an option is one path. macOS gives
    /// `/tmp/x` and `/var/folders/x` for `/private/tmp/x` and `/private/var/folders/x`. `resolvingSymlinksInPath()`
    /// alone leaves a path that does not exist yet (a skill about to be installed) as it is, `/private` included.
    var canonicalFileURL: URL {
        var existing = standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }
}
