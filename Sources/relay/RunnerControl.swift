import Foundation

/// Exit status of the runner commands, so scripts and agents can tell failures apart without parsing.
enum RunnerExitCode: Int32 {
    case success = 0
    /// Invalid arguments, an unreadable runner.json, or a screenshot that could not be saved.
    case usage = 1
    /// No runner.json, or nothing answered at its URL (connection refused or timed out, or this Mac
    /// refused the connection, as a sandbox that blocks localhost does).
    case unavailable = 3
    /// 401: the token in runner.json is not the running runner's (a stale file, or another runner on the port).
    case unauthorized = 4
    /// 409: another command is running. Safe to retry.
    case busy = 5
    /// 422: XCUI could not do it (no keyboard focus, element not found or ambiguous, ...).
    case actionFailed = 6
    /// 400 and the other 4xx: the runner rejected the request.
    case badRequest = 7
    /// 5xx or anything unexpected from the runner.
    case runnerError = 8

    init(status: Int) {
        switch status {
        case 200..<300: self = .success
        case 401: self = .unauthorized
        case 409: self = .busy
        case 422: self = .actionFailed
        case 400..<500: self = .badRequest
        default: self = .runnerError
        }
    }
}

struct RunnerControlOptions: Equatable {
    var operation: RunnerOperation
    /// `--runner <path>`; nil searches as `RunnerLocator` describes.
    var runnerPath: String?
    /// `--session <name>` (see `RelaySession`); nil uses `$RELAY_SESSION` or searches.
    var session: String?
    /// `relay find --require`: no element is a failure (exit 6), not `"count":0` with exit 0.
    var requireMatch = false
}

/// runner.json as read once: where it is, what it says, and the runner URL.
struct RunnerConnection {
    let infoURL: URL
    let info: RunnerInfo
    let baseURL: URL
}

/// `RunnerControl.connect` failed; the reason is already on stderr.
struct RunnerControlFailure: Error {
    let code: Int32
}

/// Runs one runner command: finds runner.json, sends the operation, and prints the result.
///
/// The runner's JSON goes to stdout as is on success and to stderr otherwise; `relay:` lines on stderr
/// are hints for people. A screenshot is saved to a file whose absolute path is printed instead.
enum RunnerControl {
    /// Allowance for a request on top of the operation's own waiting (`RunnerOperation.waitTime`).
    static let baseTimeout: TimeInterval = 30

    static func run(_ options: RunnerControlOptions) -> Int32 {
        switch connect(runnerPath: options.runnerPath, session: options.session) {
        case .success(let connection): return perform(options.operation, on: connection, requireMatch: options.requireMatch)
        case .failure(let failure): return failure.code
        }
    }

    /// Finds and reads runner.json. On failure the reason is already on stderr and the error carries the exit status.
    /// Split from `perform` so `relay run` reads the file once for all its steps.
    static func connect(runnerPath: String?, session: String? = nil) -> Result<RunnerConnection, RunnerControlFailure> {
        let infoURL: URL
        let info: RunnerInfo
        do {
            infoURL = try RunnerLocator.locate(explicitPath: runnerPath, session: session)
            info = try RunnerInfo.read(from: infoURL)
        } catch let error as RunnerUnavailableError {
            return .failure(RunnerControlFailure(code: fail(error.description, code: .unavailable)))
        } catch let error as SessionSelectionError {
            return .failure(RunnerControlFailure(code: fail(error.description, code: .usage)))
        } catch {
            return .failure(RunnerControlFailure(code: fail("cannot read runner info: \(error)", code: .usage)))
        }
        guard let baseURL = URL(string: info.url) else {
            return .failure(RunnerControlFailure(code: fail("invalid url in \(infoURL.path): \(info.url)", code: .usage)))
        }
        return .success(RunnerConnection(infoURL: infoURL, info: info, baseURL: baseURL))
    }

    /// Sends one operation and prints the result; returns the exit status.
    /// `requireMatch` (`find --require`): a `/find` that returns no element fails with exit 6, as a tap of a
    /// missing element does, so `find --timeout` checks the screen as well as waits for it.
    static func perform(_ operation: RunnerOperation, on connection: RunnerConnection, requireMatch: Bool = false) -> Int32 {
        let infoURL = connection.infoURL
        let info = connection.info
        var client = RunnerClient(baseURL: connection.baseURL, token: info.token)
        client.timeout = baseTimeout + operation.waitTime
        let resolved: RunnerOperation
        do {
            resolved = try operation.resolvingHostAlias(info.hostBundleID)
        } catch {
            return fail("\(error)", code: .usage)
        }
        if case .launch(let bundleID) = resolved {
            let device = info.name ?? info.udid
            switch AppInstallCheck.state(of: bundleID, udid: info.udid, hostBundleID: info.hostBundleID) {
            case .notInstalled:
                write(AppInstallCheck.notInstalledBody(bundleID: bundleID, device: device), to: .standardError)
                return fail(AppInstallCheck.notInstalledHint(bundleID: bundleID, device: device), code: .actionFailed)
            case .unknown(let reason?):
                FileHandle.standardError.write(Data("relay: \(AppInstallCheck.uncheckedHint(bundleID: bundleID, reason: reason))\n".utf8))
            case .installed, .unknown(nil):
                break
            }
        }
        let request = resolved.request
        let response: RunnerResponse
        do {
            response = try request.method == "GET" ? client.get(request.path) : client.post(request.path, json: request.body ?? [:])
        } catch {
            if RunnerConnectionError.isRefusedByOS(error) {
                // Not "is relay start running?": the runner may be fine, and restarting it would not help.
                return fail("cannot reach the runner at \(info.url): \(RunnerConnectionError.refusedByOSHint) (runner info: \(infoURL.path))",
                            code: .unavailable)
            }
            let reason = (error as? URLError)?.code == .timedOut
                ? timeoutReason(for: resolved, seconds: Int(client.timeout))
                : "is relay start running?"
            return fail("cannot reach the runner at \(info.url) (\(error.localizedDescription)); \(reason) (runner info: \(infoURL.path))",
                        code: .unavailable)
        }

        let code = RunnerExitCode(status: response.status)
        guard code == .success else {
            write(response.body, to: .standardError)
            if let hint = hint(for: code, errorCode: RunnerErrorCode.parse(body: response.body), infoURL: infoURL) {
                FileHandle.standardError.write(Data("relay: \(hint)\n".utf8))
            }
            return code.rawValue
        }

        if requireMatch, !hasElements(response.body) {
            write(response.body, to: .standardError)
            return fail("no element matched", code: .actionFailed)
        }

        if case .screenshot(let screenshot) = operation {
            do {
                if let path = try save(response.body, screenshot, session: info.session) {
                    print(path)
                }
            } catch {
                return fail("cannot save the screenshot: \(error)", code: .usage)
            }
            if screenshot.isResized, let summary = screenshotSummary(response.headers) {
                FileHandle.standardError.write(Data("relay: \(summary)\n".utf8))
            }
        } else {
            write(response.body, to: .standardOutput)
        }
        return code.rawValue
    }

    /// What follows "cannot reach the runner" when a request timed out. The runner is fine but still at the
    /// operation, and every other command gets 409 until it ends. XCTest can't be interrupted, and after a
    /// `/launch` it may hold on for minutes more (298 s in all for an app that isn't installed).
    static func timeoutReason(for operation: RunnerOperation, seconds: Int) -> String {
        guard case .launch = operation else {
            return "no response within \(seconds)s; check it with relay ping"
        }
        return "no response within \(seconds)s; the runner is still waiting for the app and stays busy until XCTest gives up, "
            + "which can take minutes more. Wait until relay ping shows \"busy\":false, or if you started this runner, "
            + "relay stop and relay start again"
    }

    /// Whether a `/find` answer lists an element. Its `count` is not used: with `index` it stays the number
    /// of matches while `elements` is empty for an index out of range.
    static func hasElements(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let elements = object["elements"] as? [Any] else { return false }
        return !elements.isEmpty
    }

    /// The `relay:` line for a failure. `errorCode` is the runner's `code`; a runner from before codes sends
    /// none, and then only the exit code picks the hint, as before.
    static func hint(for code: RunnerExitCode, errorCode: RunnerErrorCode? = nil, infoURL: URL) -> String? {
        switch errorCode {
        case .noKeyboardFocus:
            return "tap the text field first (relay tap --id …), then send it again"
        case .elementNotFound:
            return "check the screen with relay find --type … or relay source, or wait for the element with --timeout <s>"
        case .elementAmbiguous:
            return "add --type, --label, or --id, or pick one of the candidates with --index <n>"
        case .touchModeUnavailable:
            return "send it again without --mode, or with the mode the error names"
        case .notFound:
            return "no such endpoint; the runner may be older than this relay (relay start --rebuild builds it again)"
        default:
            break
        }
        switch code {
        case .unauthorized:
            return "the runner rejected the token in \(infoURL.path); the file is stale or belongs to another relay start (check --runner, --session, $RELAY_RUNNER, $RELAY_SESSION, or restart relay start)"
        case .busy:
            return "the runner is running another command; retry, or wait until relay ping shows \"busy\":false"
        default:
            return nil
        }
    }

    /// How the image maps to tap coordinates, from the `/screenshot` headers: `image 471x1024 px, screen
    /// 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)`. Nil when a runner without them answered.
    static func screenshotSummary(_ headers: [String: String]) -> String? {
        // URLSession may change the case of header names.
        func value(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        typealias Header = RunnerRequestValues.ScreenshotHeader
        guard let imageWidth = value(Header.imageWidth), let imageHeight = value(Header.imageHeight),
              let screenWidth = value(Header.screenWidth), let screenHeight = value(Header.screenHeight),
              let scale = value(Header.scale) else { return nil }
        return "image \(imageWidth)x\(imageHeight) px, screen \(screenWidth)x\(screenHeight) pt, \(scale) px/pt (tap in points: px / \(scale))"
    }

    /// Writes the image and returns its absolute path, or writes it to stdout for `-o -` and returns nil.
    static func save(_ image: Data, _ screenshot: RunnerScreenshot, now: Date = Date(), session: String? = nil) throws -> String? {
        if screenshot.output == "-" {
            FileHandle.standardOutput.write(image)
            return nil
        }
        let url = screenshotURL(screenshot, now: now, session: session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url)
        return url.path
    }

    /// `-o` resolved against the current directory, or `$TMPDIR/relay/screenshot-<time>.<ext>`: outside the
    /// working tree, so screenshots do not show up in the app repository's `git status`. A session's name goes
    /// in front of the time, so two sessions never write one file.
    static func screenshotURL(
        _ screenshot: RunnerScreenshot,
        now: Date = Date(),
        session: String? = nil,
        currentDirectory: URL = WorkingDirectory.url,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        if let output = screenshot.output {
            return RunnerLocator.resolve(output, in: currentDirectory)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return temporaryDirectory
            .appendingPathComponent("relay", isDirectory: true)
            .appendingPathComponent("screenshot-\(session.map { "\($0)-" } ?? "")\(formatter.string(from: now)).\(screenshot.fileExtension)")
            .standardizedFileURL
    }

    private static func write(_ body: Data, to handle: FileHandle) {
        handle.write(body)
        if body.last != UInt8(ascii: "\n") {
            handle.write(Data("\n".utf8))
        }
    }

    private static func fail(_ message: String, code: RunnerExitCode) -> Int32 {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
        return code.rawValue
    }
}
