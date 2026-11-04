import Foundation

/// The `code` of the JSON relay prints itself when a command fails before, or instead of, a runner
/// answer: `{"ok":false,"code":"<code>","error":"<message for people>"}`, the shape the runner's errors have
/// (see `RunnerErrorCode`). The runner never answers these. Part of the CLI's output: never rename one.
enum RelayErrorCode: String, CaseIterable {
    /// Exit 3: no runner.json, or nothing answered at its URL (refused, or this Mac refused the connection).
    case runnerUnavailable = "runner_unavailable"
    /// Exit 3: the request timed out. The runner may still be at it, and answers 409 until it is done.
    case runnerTimeout = "runner_timeout"
    /// Exit 1: runner.json cannot be read or is unusable (an invalid url, no host app for `host`).
    case runnerInfoInvalid = "runner_info_invalid"
    /// Exit 8: the runner answered an error that is not a JSON object (an older runner, or something else on the port).
    case runnerBadResponse = "runner_bad_response"
    /// Exit 1: the screenshot arrived but could not be written to the file.
    case screenshotSaveFailed = "screenshot_save_failed"
    /// Exit 6: `relay launch` of an app that is not installed; nothing was sent to the runner.
    case appNotInstalled = "app_not_installed"
    /// Exit 1: `relay devices` could not list the devices or simulators.
    case devicesUnavailable = "devices_unavailable"
    /// Exit 1: `relay record status` could not find or read the recording state.
    case recordingUnavailable = "recording_unavailable"
    /// Exit 1: the local part of a host command failed in a way that has no code of its own.
    case failed
}

/// What relay prints for people and for scripts, and where.
///
/// A command that prints JSON prints one JSON object on stdout on failure too, and `relay:` lines (hints,
/// warnings) go to stderr. A usage error (exit 2) is only two `relay:` lines on stderr.
enum CLIOutput {
    /// `{"ok":false,"code":...,"error":...}` plus `extra` keys, on one line, without a line break.
    static func failureBody(code: String, message: String, extra: [String: Any] = [:]) -> Data {
        var object = extra
        object["ok"] = false
        object["code"] = code
        object["error"] = message
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func failureBody(_ code: RelayErrorCode, _ message: String, extra: [String: Any] = [:]) -> Data {
        failureBody(code: code.rawValue, message: message, extra: extra)
    }

    /// `data` and a line break (unless it ends with one) to `handle`.
    static func writeLine(_ data: Data, to handle: FileHandle = .standardOutput) {
        handle.write(data)
        if data.last != UInt8(ascii: "\n") {
            handle.write(Data("\n".utf8))
        }
    }

    /// `relay: <message>` on stderr.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }

    /// A usage error: the problem and where to read more, two lines on stderr, and exit status 2. The whole
    /// usage text is not printed: it would bury the one line that says what is wrong.
    static func usageError(_ message: String, command: String? = nil) -> Int32 {
        FileHandle.standardError.write(Data(usageMessage(message, command: command).utf8))
        return RunnerExitCode.usage.rawValue
    }

    /// The text of `usageError`: `relay: <message>` and `relay: see <help command>`.
    static func usageMessage(_ message: String, command: String? = nil) -> String {
        "relay: \(message)\nrelay: see \(Arguments.helpCommand(for: command))\n"
    }
}

extension Arguments {
    /// The command whose `--help` explains `name`: `relay <name> --help` when it has its own help, else `relay --help`.
    static func helpCommand(for name: String?) -> String {
        guard let name, name == "skill" || runnerUsages[name] != nil || lifecycleUsages[name] != nil else {
            return "relay --help"
        }
        return "relay \(name) --help"
    }
}
