import Foundation

/// Exit status of the runner commands, so scripts and agents can tell failures apart without parsing.
enum RunnerExitCode: Int32 {
  case success = 0
  /// A local failure: a device in use, a failed build, no simulator, a missing file, an unreadable runner.json,
  /// a screenshot that could not be saved.
  case failure = 1
  /// A command line that is wrong: an unknown option, a missing or invalid value, options that do not go
  /// together, an invalid session name, `$RELAY_RUNNER` with `$RELAY_SESSION`, a scenario step that is wrong.
  case usage = 2
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
    case 200 ..< 300: self = .success
    case 401: self = .unauthorized
    case 409: self = .busy
    case 422: self = .actionFailed
    case 400 ..< 500: self = .badRequest
    default: self = .runnerError
    }
  }
}

struct RunnerControlOptions: Equatable {
  var operation: RunnerOperation
  /// `--runner <path>`; nil uses what `RunnerLocator` describes.
  var runnerPath: String?
  /// `--session <name>` (see `RelaySession`); nil uses `$RELAY_SESSION`, else `~/.relay/runner.json`.
  var session: String?
  /// `relay find --require`: no element is a failure (exit 6), not `"count":0` with exit 0. With
  /// `find --gone`, an element still there is the failure.
  var requireMatch = false
}

/// runner.json as read once: where it is, what it says, and the runner URL.
struct RunnerConnection {
  let infoURL: URL
  let info: RunnerInfo
  let baseURL: URL
}

/// `RunnerControl.connect` failed; the reason is already printed (see `RunnerControl`).
struct RunnerControlFailure: Error {
  let code: Int32
}

/// Runs one runner command: finds runner.json, sends the operation, and prints the result.
///
/// The output is JSON, on success and on failure: the runner's JSON as it came, or, for a failure on this
/// side (no runner.json, no connection, an app that is not installed, ...), `{"ok":false,"code":"<code>",
/// "error":"..."}` with a `code` of `RelayErrorCode`. It goes to stdout; `relay:` lines on stderr are hints
/// for people. Exceptions: a screenshot is saved to a file whose absolute path is printed instead, and with
/// `-o -` the image is the stdout, so a failure's JSON goes to stderr then. A usage error (exit 2) prints
/// no JSON, only two `relay:` lines (see `CLIOutput.usageError`).
enum RunnerControl {
  /// Allowance for a request on top of the operation's own waiting (`RunnerOperation.waitTime`).
  static let baseTimeout: TimeInterval = 30

  static func run(_ options: RunnerControlOptions) -> Int32 {
    let command = options.operation.commandName
    switch connect(runnerPath: options.runnerPath, session: options.session, command: command,
                   failureOutput: failureHandle(for: options.operation)) {
    case .success(let connection): return perform(options.operation, on: connection, requireMatch: options.requireMatch)
    case .failure(let failure): return failure.code
    }
  }

  /// Where the JSON of a failure goes: stdout, except for `screenshot -o -`, whose stdout is the image.
  static func failureHandle(for operation: RunnerOperation) -> FileHandle {
    if case .screenshot(let screenshot) = operation, screenshot.output == "-" {
      return .standardError
    }
    return .standardOutput
  }

  /// Finds and reads runner.json. On failure the reason is already printed and the error carries the exit status.
  /// Split from `perform` so `relay run` reads the file once for all its steps. `command` names the command for
  /// the "see relay <command> --help" line of a usage error.
  static func connect(
    runnerPath: String?, session: String? = nil, command: String? = nil, failureOutput: FileHandle = .standardOutput
  ) -> Result<RunnerConnection, RunnerControlFailure> {
    let infoURL: URL
    let info: RunnerInfo
    do {
      infoURL = try RunnerLocator.locate(explicitPath: runnerPath, session: session)
      info = try RunnerInfo.read(from: infoURL)
    } catch let error as RunnerUnavailableError {
      return .failure(RunnerControlFailure(code: fail(.runnerUnavailable, error.description, exit: .unavailable, to: failureOutput)))
    } catch let error as SessionSelectionError {
      return .failure(RunnerControlFailure(code: CLIOutput.usageError(error.description, command: command)))
    } catch {
      return .failure(RunnerControlFailure(code: fail(.runnerInfoInvalid, "cannot read runner info: \(error)", exit: .failure, to: failureOutput)))
    }
    guard let baseURL = URL(string: info.url) else {
      return .failure(RunnerControlFailure(code: fail(.runnerInfoInvalid, "invalid url in \(infoURL.path): \(info.url)", exit: .failure,
                                                      to: failureOutput)))
    }
    return .success(RunnerConnection(infoURL: infoURL, info: info, baseURL: baseURL))
  }

  /// Sends one operation and prints the result; returns the exit status.
  /// `requireMatch` (`find --require`): a `/find` that returns no element fails with exit 6, as a tap of a
  /// missing element does, so `find --timeout` checks the screen as well as waits for it.
  /// `failureOutput` replaces where the JSON of a failure goes (`failureHandle(for:)`), for tests.
  static func perform(_ operation: RunnerOperation, on connection: RunnerConnection, requireMatch: Bool = false,
                      failureOutput: FileHandle? = nil) -> Int32 {
    let infoURL = connection.infoURL
    let info = connection.info
    let failureOutput = failureOutput ?? failureHandle(for: operation)
    var client = RunnerClient(baseURL: connection.baseURL, token: info.token)
    client.timeout = baseTimeout + operation.waitTime
    let resolved: RunnerOperation
    do {
      resolved = try operation.resolvingHostAlias(info.hostBundleID)
    } catch {
      return fail(.runnerInfoInvalid, "\(error)", exit: .failure, to: failureOutput)
    }
    if let bundleID = resolved.installRequiredBundleID {
      let device = info.name ?? info.udid
      switch AppInstallCheck.state(of: bundleID, udid: info.udid, hostBundleID: info.hostBundleID) {
      case .notInstalled:
        CLIOutput.writeLine(AppInstallCheck.notInstalledBody(bundleID: bundleID, device: device), to: failureOutput)
        CLIOutput.note(AppInstallCheck.notInstalledHint(bundleID: bundleID, device: device))
        return RunnerExitCode.actionFailed.rawValue
      case .unknown(let reason?):
        CLIOutput.note(AppInstallCheck.uncheckedHint(bundleID: bundleID, reason: reason,
                                                     waits: resolved.commandName == "launch"))
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
        return fail(.runnerUnavailable,
                    "cannot reach the runner at \(info.url): \(RunnerConnectionError.refusedByOSHint) (runner info: \(infoURL.path))",
                    exit: .unavailable, to: failureOutput)
      }
      let timedOut = (error as? URLError)?.code == .timedOut
      let reason = timedOut ? timeoutReason(for: resolved, seconds: Int(client.timeout)) : "is relay start running?"
      return fail(timedOut ? .runnerTimeout : .runnerUnavailable,
                  "cannot reach the runner at \(info.url) (\(error.localizedDescription)); \(reason) (runner info: \(infoURL.path))",
                  exit: .unavailable, to: failureOutput)
    }

    let code = RunnerExitCode(status: response.status)
    guard code == .success else {
      CLIOutput.writeLine(failureBody(of: response), to: failureOutput)
      if let hint = hint(for: code, errorCode: RunnerErrorCode.parse(body: response.body), infoURL: infoURL) {
        CLIOutput.note(hint)
      }
      return code.rawValue
    }

    if case .type(_, _, _, clear: true) = resolved, !answerSays("cleared", response.body) {
      // A runner from before `clear` ignored it: the text went in after what the field held.
      return fail(.runnerBadResponse, "the runner's /type answer has no cleared; it predates type --clear and typed without "
        + "clearing the field (relay start --rebuild builds a current one)", exit: .runnerError, to: failureOutput)
    }
    if case .find(_, _, _, _, gone: true) = resolved {
      guard let gone = goneAnswer(response.body) else {
        // A runner from before `gone` ignored it and waited for an element to appear instead.
        return fail(.runnerBadResponse, "the runner's /find answer has no gone; it predates find --gone (relay start --rebuild "
          + "builds a current one)", exit: .runnerError, to: failureOutput)
      }
      if requireMatch, !gone {
        CLIOutput.writeLine(stillPresentBody(response.body), to: failureOutput)
        CLIOutput.note("an element still matches; wait longer (repeat find --gone --timeout <s>) or check the screen with relay screenshot")
        return RunnerExitCode.actionFailed.rawValue
      }
    } else if requireMatch, !hasElements(response.body) {
      CLIOutput.writeLine(noMatchBody(response.body), to: failureOutput)
      return RunnerExitCode.actionFailed.rawValue
    }

    if case .screenshot(let screenshot) = operation {
      do {
        if let path = try save(response.body, screenshot, session: info.session) {
          print(path)
        }
      } catch {
        return fail(.screenshotSaveFailed, "cannot save the screenshot: \(error)", exit: .failure, to: failureOutput)
      }
      if screenshot.isResized, let summary = screenshotSummary(response.headers) {
        CLIOutput.note(summary)
      }
    } else {
      CLIOutput.writeLine(response.body, to: .standardOutput)
    }
    return code.rawValue
  }

  /// The body of a runner error as the runner sent it, or, when it is not a JSON object (an older runner, or
  /// something else on the port), one in the same shape that says what came.
  static func failureBody(of response: RunnerResponse) -> Data {
    if (try? JSONSerialization.jsonObject(with: response.body)) is [String: Any] {
      return response.body
    }
    let text = String(decoding: response.body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return CLIOutput.failureBody(.runnerBadResponse, "the runner answered HTTP \(response.status)" + (text.isEmpty ? "" : ": \(text)"),
                                 extra: ["status": response.status])
  }

  /// `find --require` with no match: the `/find` answer (its `count`, `elements`) as an `element_not_found` failure.
  static func noMatchBody(_ body: Data) -> Data {
    var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    object["ok"] = false
    object["code"] = RunnerErrorCode.elementNotFound.rawValue
    object["error"] = "no element matched"
    return CLIOutput.json(object, fallback: body)
  }

  /// `find --gone --require` with an element left: the `/find` answer (its `count`, `elements`, `gone`) as an
  /// `element_still_present` failure.
  static func stillPresentBody(_ body: Data) -> Data {
    var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    object["ok"] = false
    object["code"] = RelayErrorCode.elementStillPresent.rawValue
    object["error"] = "an element still matched when the timeout ran out"
    return CLIOutput.json(object, fallback: body)
  }

  /// Whether an answer has `key` set to true.
  static func answerSays(_ key: String, _ body: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return value.boolValue
  }

  /// The `gone` of a `/find` answer, nil when there is none (a runner from before `gone`).
  static func goneAnswer(_ body: Data) -> Bool? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let gone = object["gone"] as? NSNumber, CFGetTypeID(gone) == CFBooleanGetTypeID() else { return nil }
    return gone.boolValue
  }

  /// What follows "cannot reach the runner" when a request timed out. The runner is fine but still at the
  /// operation, and every other command gets 409 until it ends. XCTest can't be interrupted, and after a
  /// `/launch` it may hold on for minutes more (298 s in all for an app that isn't installed).
  static func timeoutReason(for operation: RunnerOperation, seconds: Int) -> String {
    switch operation {
    case .launch, .open: break
    case .type, .key:
      // Only `typeText`, the fallback when the runner can't synthesize text, waits for the app to idle.
      return "no response within \(seconds)s; the runner may be waiting for the app to become idle and stays busy until "
        + "XCTest gives up (up to about 3 minutes). Wait until relay ping shows \"busy\":false, then check the text "
        + "with relay find"
    default:
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
    case .typingFailed:
      return "some of the text may have been typed: check the field's value with relay find, clear it if needed, "
        + "then send it again"
    case .clearFailed:
      return "the field kept some text and nothing was typed: check its value with relay find. If it got shorter, "
        + "send relay type --clear again (it deletes up to \(RunnerClearing.maxDeletes) characters when select all does not work); "
        + "if not, the app keeps or refills it"
    case .elementNotFound:
      return "check the screen with relay find --type … or relay source, or wait for the element with --timeout <s>"
    case .elementAmbiguous:
      return "add --type, --label, or --id, or pick one of the candidates with --index <n>"
    case .touchModeUnavailable:
      return "send it again without --mode, or with the mode the error names"
    case .coveredByOtherApp:
      return "something covers the app (a system alert, Control Center, …): check with relay screenshot or "
        + "relay find --type alert --bundle-id com.apple.springboard, close it, then send it again"
    case .elementPointCovered:
      return "another control covers the touch point: check hit in the response and relay screenshot; reveal the target or use screenshot coordinates"
    case .remoteViewPositionUnknown:
      return "the element is in a view another process draws (the share sheet) and its frame is not on the screen: "
        + "find it in relay screenshot and tap it by coordinates (relay tap <x> <y>)"
    case .openFailed:
      return "check the URL's scheme and that the app that handles it is installed; relay open <url> --bundle-id <id> "
        + "sends it to that app"
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

  /// Prints a failure of this side as JSON to `output`, and returns the exit status.
  private static func fail(_ code: RelayErrorCode, _ message: String, exit: RunnerExitCode, to output: FileHandle) -> Int32 {
    CLIOutput.writeLine(CLIOutput.failureBody(code, message), to: output)
    return exit.rawValue
  }
}
