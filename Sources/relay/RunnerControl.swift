import Foundation

/// Exit status of the runner commands, so scripts and agents can tell failures apart without parsing.
enum RunnerExitCode: Int32 {
    case success = 0
    /// Invalid arguments, an unreadable runner.json, or a screenshot that could not be saved.
    case usage = 1
    /// No runner.json, or nothing answered at its URL (connection refused or timed out).
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
}

/// Runs one runner command: finds runner.json, sends the operation, and prints the result.
///
/// The runner's JSON goes to stdout as is on success and to stderr otherwise; `relay:` lines on stderr
/// are hints for people. A screenshot is saved to a file whose absolute path is printed instead.
enum RunnerControl {
    /// Allowance for a request on top of the operation's own waiting (`RunnerOperation.waitTime`).
    static let baseTimeout: TimeInterval = 30

    static func run(_ options: RunnerControlOptions) -> Int32 {
        let infoURL: URL
        let info: RunnerInfo
        do {
            infoURL = try RunnerLocator.locate(explicitPath: options.runnerPath)
            info = try RunnerInfo.read(from: infoURL)
        } catch let error as RunnerUnavailableError {
            return fail(error.description, code: .unavailable)
        } catch {
            return fail("cannot read runner info: \(error)", code: .usage)
        }
        guard let baseURL = URL(string: info.url) else {
            return fail("invalid url in \(infoURL.path): \(info.url)", code: .usage)
        }

        var client = RunnerClient(baseURL: baseURL, token: info.token)
        client.timeout = baseTimeout + options.operation.waitTime
        let request = options.operation.request
        let response: RunnerResponse
        do {
            response = try request.method == "GET" ? client.get(request.path) : client.post(request.path, json: request.body ?? [:])
        } catch {
            let reason = (error as? URLError)?.code == .timedOut
                ? "no response within \(Int(client.timeout))s; check it with relay ping"
                : "is relay start running?"
            return fail("cannot reach the runner at \(info.url) (\(error.localizedDescription)); \(reason) (runner info: \(infoURL.path))",
                        code: .unavailable)
        }

        let code = RunnerExitCode(status: response.status)
        guard code == .success else {
            write(response.body, to: .standardError)
            if let hint = hint(for: code, infoURL: infoURL) {
                FileHandle.standardError.write(Data("relay: \(hint)\n".utf8))
            }
            return code.rawValue
        }

        if case .screenshot(let screenshot) = options.operation {
            do {
                if let path = try save(response.body, screenshot) {
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

    static func hint(for code: RunnerExitCode, infoURL: URL) -> String? {
        switch code {
        case .unauthorized:
            return "the runner rejected the token in \(infoURL.path); the file is stale or belongs to another relay start (check --runner, $RELAY_RUNNER, or restart relay start)"
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
    static func save(_ image: Data, _ screenshot: RunnerScreenshot, now: Date = Date()) throws -> String? {
        if screenshot.output == "-" {
            FileHandle.standardOutput.write(image)
            return nil
        }
        let url = screenshotURL(screenshot, now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url)
        return url.path
    }

    /// `-o` resolved against the current directory, or `$TMPDIR/relay/screenshot-<time>.<ext>`: outside the
    /// working tree, so screenshots do not show up in the app repository's `git status`.
    static func screenshotURL(
        _ screenshot: RunnerScreenshot,
        now: Date = Date(),
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
            .appendingPathComponent("screenshot-\(formatter.string(from: now)).\(screenshot.fileExtension)")
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
