import Foundation

/// The external commands relay reads the host's state with (`simctl`, `devicectl`, `security`, ...).
/// Tests replace them with canned output.
struct HostCommands {
    /// `xcrun <args>`; stdout and stderr merged. Throws `ShellError` on a nonzero status.
    var xcrun: ([String]) throws -> String
    /// `xcrun devicectl <args> --json-output <file>`, returning the JSON document devicectl wrote.
    var devicectlJSON: ([String]) throws -> Data
    /// `<executable> <args>` for tools outside xcrun (`/usr/bin/security`, `/usr/bin/xcode-select`); stdout
    /// and stderr merged.
    var run: (_ executable: String, _ args: [String]) throws -> String

    static let live = HostCommands(
        xcrun: { try Shell.xcrun($0) },
        devicectlJSON: { args in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("relay-devicectl-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) }
            try Shell.xcrun(["devicectl"] + args + ["--json-output", output.path, "--quiet"])
            return try Data(contentsOf: output)
        },
        run: { try Shell.run($0, $1) }
    )
}

/// A setup problem found before anything is built or launched (no device, no Team ID, ...). Printed
/// without the usage text, which would bury the explanation.
struct SetupError: Error, CustomStringConvertible {
    let description: String
}

enum UserHome {
    /// `$HOME` like the shell's `~`, else the account's home directory. `homeDirectoryForCurrentUser`
    /// alone ignores `$HOME`, which keeps relay from being pointed at a scratch home.
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
