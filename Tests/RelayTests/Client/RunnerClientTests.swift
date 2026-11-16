import Foundation
@testable import Relay
import Testing

/// The runner's answers and failures as relay reports them, with a fake `RunnerClient.Transport` in place of
/// URLSession: no socket, no runner.
struct RunnerClientTests {
  private let connection = RunnerConnection(
    infoURL: URL(fileURLWithPath: "/tmp/runner.json"),
    info: RunnerInfo(url: "http://runner.invalid:8100/", token: "secret", udid: "SIM"),
    baseURL: URL(string: "http://runner.invalid:8100/")!
  )

  /// Runs `operation` with `transport` and returns the exit status and the JSON of a failure (nil on success).
  private func perform(
    _ operation: RunnerOperation, transport: @escaping RunnerClient.Transport
  ) throws -> (status: Int32, failure: [String: Any]?) {
    let pipe = Pipe()
    let status = RunnerControl.perform(operation, on: connection, failureOutput: pipe.fileHandleForWriting, transport: transport)
    try pipe.fileHandleForWriting.close()
    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
    let failure = data.isEmpty ? nil : try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (status, failure)
  }

  private static func answer(_ status: Int, _ body: String) -> RunnerClient.Transport {
    { _ in RunnerResponse(status: status, body: Data(body.utf8)) }
  }

  @Test func aTimeoutIsRunnerTimeoutAfterTheOperationsWait() throws {
    let timeouts = Locked<[TimeInterval]>([])
    let find = RunnerOperation.find(RunnerElementSelector(identifier: "next"), limit: nil, timeout: 5, bundleID: nil)
    let (status, failure) = try perform(find) { request in
      timeouts.withLock { $0.append(request.timeoutInterval) }
      throw URLError(.timedOut)
    }
    // 30 s for the round trip and the 5 s the runner may wait for the element.
    #expect(timeouts.value == [RunnerControl.baseTimeout + 5])
    #expect(status == RunnerExitCode.unavailable.rawValue)
    #expect(failure?["code"] as? String == RelayErrorCode.runnerTimeout.rawValue)
    #expect((failure?["error"] as? String)?.contains("no response within 35s") == true)
  }

  @Test func anotherFailureToConnectAsksWhetherRelayStartRuns() throws {
    let (status, failure) = try perform(.ping) { _ in throw URLError(.cannotConnectToHost) }
    #expect(status == RunnerExitCode.unavailable.rawValue)
    #expect(failure?["code"] as? String == RelayErrorCode.runnerUnavailable.rawValue)
    #expect((failure?["error"] as? String)?.contains("is relay start running?") == true)
  }

  @Test func eprmFromThisMacIsTheSandboxHint() throws {
    // As URLSession reports a connect() that a sandbox refused: an NSURLErrorDomain error over EPERM.
    let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
      NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    ])
    let (status, failure) = try perform(.ping) { _ in throw refused }
    #expect(status == RunnerExitCode.unavailable.rawValue)
    #expect(failure?["code"] as? String == RelayErrorCode.runnerUnavailable.rawValue)
    let message = try #require(failure?["error"] as? String)
    #expect(message.contains(RunnerConnectionError.refusedByOSHint))
    #expect(!message.contains("is relay start running?"))
  }

  @Test func sendsTheTokenAndTheJSONBody() throws {
    let sent = Locked<[URLRequest]>([])
    let (status, failure) = try perform(.button("home")) { request in
      sent.withLock { $0.append(request) }
      return RunnerResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
    }
    #expect(status == RunnerExitCode.success.rawValue)
    #expect(failure == nil)
    let request = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "http://runner.invalid:8100/button")
    #expect(request.value(forHTTPHeaderField: "Authorization") == RunnerAuth.authorizationHeader(token: "secret"))
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
    #expect(body == ["name": "home"])
  }

  @Test func aGETHasItsQueryAndNoBody() throws {
    let sent = Locked<[URLRequest]>([])
    let source = RunnerOperation.source(format: "json", maxDepth: 3, filter: nil, bundleID: nil)
    _ = try perform(source) { request in
      sent.withLock { $0.append(request) }
      // Not 200, so nothing is printed to stdout.
      return RunnerResponse(status: 409, body: Data(#"{"ok":false,"code":"busy","error":"busy"}"#.utf8))
    }
    let request = try #require(sent.value.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "http://runner.invalid:8100/source?format=json&maxDepth=3")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    #expect(request.timeoutInterval == RunnerControl.baseTimeout)
  }

  @Test func eachRunnerStatusHasItsExitStatusAndKeepsTheRunnersError() throws {
    let cases: [(status: Int, code: String, exit: RunnerExitCode)] = [
      (401, RunnerErrorCode.unauthorized.rawValue, .unauthorized),
      (409, RunnerErrorCode.busy.rawValue, .busy),
      (422, RunnerErrorCode.elementNotFound.rawValue, .actionFailed),
      (400, RunnerErrorCode.invalidRequest.rawValue, .badRequest),
      (500, RunnerErrorCode.internalError.rawValue, .runnerError)
    ]
    for item in cases {
      let body = #"{"ok":false,"code":"\#(item.code)","error":"from the runner"}"#
      let (status, failure) = try perform(.tap(RunnerTouch(target: .point(RunnerPoint(x: 1, y: 2)))),
                                          transport: Self.answer(item.status, body))
      #expect(status == item.exit.rawValue, "HTTP \(item.status)")
      // The runner's JSON as it came.
      #expect(failure?["code"] as? String == item.code, "HTTP \(item.status)")
      #expect(failure?["error"] as? String == "from the runner", "HTTP \(item.status)")
    }
  }

  @Test func anAnswerThatIsNotJSONBecomesRunnerBadResponse() throws {
    let (status, failure) = try perform(.foreground, transport: Self.answer(500, "internal oops, not json"))
    #expect(status == RunnerExitCode.runnerError.rawValue)
    #expect(failure?["code"] as? String == RelayErrorCode.runnerBadResponse.rawValue)
    #expect(failure?["status"] as? Int == 500)
    #expect(failure?["error"] as? String == "the runner answered HTTP 500: internal oops, not json")
  }

  @Test func pingReportsTheAnswerAndTheFailures() {
    let info = connection.info
    let timeouts = Locked<[TimeInterval]>([])
    let alive = RunnerPing.checkWithBuild(info, timeout: 2) { request in
      timeouts.withLock { $0.append(request.timeoutInterval) }
      #expect(request.url?.path == "/ping")
      #expect(request.value(forHTTPHeaderField: "Authorization") == RunnerAuth.authorizationHeader(token: "secret"))
      return RunnerResponse(status: 200, body: Data(#"{"ok":true,"busy":true,"busyForMs":40}"#.utf8))
    }
    #expect(alive.ping == .alive(busy: true, busyForMs: 40))
    #expect(timeouts.value == [2])

    #expect(RunnerPing.check(info, transport: Self.answer(401, "")) == .status(401))
    #expect(RunnerPing.check(info) { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }.exitCode == .unavailable)
    if case .refusedByOS = RunnerPing.check(info, transport: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }) {
    } else {
      Issue.record("EPERM is not refusedByOS")
    }
    if case .unreachable = RunnerPing.check(info, transport: { _ in throw URLError(.timedOut) }) {
    } else {
      Issue.record("a timeout is not unreachable")
    }
  }

  /// An adjust that missed exits 6 and keeps what the element shows; a runner from before `/adjust` answers 404.
  @Test func anAdjustThatMissedExits6WithTheValue() throws {
    let adjust = RunnerOperation.adjust(RunnerElementSelector(type: "pickerWheel", index: 1), .pickerValue("31"), timeout: nil, bundleID: nil)
    let missed = #"{"ok":false,"code":"adjust_failed","error":"the picker wheel shows \"30\", not \"31\"","value":"30"}"#
    let (status, failure) = try perform(adjust, transport: Self.answer(422, missed))
    #expect(status == RunnerExitCode.actionFailed.rawValue)
    #expect(failure?["code"] as? String == RunnerErrorCode.adjustFailed.rawValue)
    #expect(failure?["value"] as? String == "30")

    let refused = #"{"ok":false,"code":"element_not_adjustable","error":"the element is a button, not a slider"}"#
    #expect(try perform(adjust, transport: Self.answer(422, refused)).status == RunnerExitCode.actionFailed.rawValue)

    let old = try perform(adjust, transport: Self.answer(404, #"{"ok":false,"code":"not_found","error":"not found"}"#))
    #expect(old.status == RunnerExitCode.badRequest.rawValue)
    #expect(old.failure?["code"] as? String == RunnerErrorCode.notFound.rawValue)

    // The slider's wait: 30 s, and what the runner may take.
    let timeouts = Locked<[TimeInterval]>([])
    let slider = RunnerOperation.adjust(RunnerElementSelector(identifier: "volume"), .position(0.5), timeout: 3, bundleID: nil)
    _ = try perform(slider) { request in
      timeouts.withLock { $0.append(request.timeoutInterval) }
      return RunnerResponse(status: 200, body: Data(#"{"ok":true,"value":"50%","position":0.5}"#.utf8))
    }
    #expect(timeouts.value == [RunnerControl.baseTimeout + 3 + RunnerAdjusting.longestAnswer])
  }

  /// A runner from before `taps` ignores it and taps once: its answer has no `taps`, which relay refuses.
  @Test func aDoubleTapAnsweredWithoutTapsIsABadResponse() throws {
    let double = RunnerOperation.tap(RunnerTouch(target: .point(RunnerPoint(x: 10, y: 20)), taps: 2))
    let (status, failure) = try perform(double, transport: Self.answer(200, #"{"ok":true,"mode":"private"}"#))
    #expect(status == RunnerExitCode.runnerError.rawValue)
    #expect(failure?["code"] as? String == RelayErrorCode.runnerBadResponse.rawValue)
    #expect((failure?["error"] as? String)?.contains("predates tap --count and tapped once") == true)

    let sent = Locked<[URLRequest]>([])
    let (doubled, none) = try perform(double) { request in
      sent.withLock { $0.append(request) }
      return RunnerResponse(status: 200, body: Data(#"{"ok":true,"mode":"private","taps":2}"#.utf8))
    }
    #expect(doubled == RunnerExitCode.success.rawValue)
    #expect(none == nil)
    let body = try JSONSerialization.jsonObject(with: try #require(sent.value.first?.httpBody)) as? [String: Any]
    #expect(body?["taps"] as? Int == 2)

    // One tap needs no taps in the answer, from any runner.
    let single = RunnerOperation.tap(RunnerTouch(target: .point(RunnerPoint(x: 10, y: 20)), taps: 1))
    #expect(try perform(single, transport: Self.answer(200, #"{"ok":true,"mode":"private"}"#)).status == RunnerExitCode.success.rawValue)
  }

  /// A runner from before `onscreen` and `hittable` rejects them as unknown keys of `element` (400), which relay reports as
  /// a runner too old for them rather than a mistake in the command line. Other 400s stay as the runner sent them.
  @Test func aRunnerThatRejectsVisibilityIsABadResponse() throws {
    let old = #"{"ok":false,"code":"invalid_request","error":"invalid field: element: unknown key 'hittable' (expected identifier, label, type, value, index)"}"#
    let operations: [RunnerOperation] = [
      .find(RunnerElementSelector(label: "Play", visibility: .hittable), limit: nil, timeout: nil, bundleID: nil),
      .tap(RunnerTouch(target: .element(RunnerElementSelector(label: "Play", visibility: .hittable)))),
      .press(RunnerTouch(target: .element(RunnerElementSelector(label: "Play", visibility: .hittable)), duration: 1)),
      .adjust(RunnerElementSelector(type: "slider", visibility: .hittable), .position(0.5), timeout: nil, bundleID: nil)
    ]
    for operation in operations {
      let (status, failure) = try perform(operation, transport: Self.answer(400, old))
      #expect(status == RunnerExitCode.runnerError.rawValue, "\(operation.commandName)")
      #expect(failure?["code"] as? String == RelayErrorCode.runnerBadResponse.rawValue, "\(operation.commandName)")
      #expect((failure?["error"] as? String)?.contains("predates --onscreen and --hittable") == true, "\(operation.commandName)")
    }
    let onscreen = RunnerOperation.find(RunnerElementSelector(label: "Play", visibility: .onscreen), limit: nil, timeout: nil, bundleID: nil)
    let onscreenOld = old.replacingOccurrences(of: "'hittable'", with: "'onscreen'")
    let rejected = try perform(onscreen, transport: Self.answer(400, onscreenOld))
    #expect(rejected.failure?["error"] as? String
      == "the runner rejected onscreen in the element: it predates --onscreen and --hittable (relay start --rebuild builds a current one)")

    // Another 400, or the same answer to a selector without them, is the runner's own.
    let other = #"{"ok":false,"code":"invalid_request","error":"invalid field: limit: expected an integer in 1...100"}"#
    let invalid = try perform(onscreen, transport: Self.answer(400, other))
    #expect(invalid.status == RunnerExitCode.badRequest.rawValue && invalid.failure?["code"] as? String == "invalid_request")
    let plain = RunnerOperation.find(RunnerElementSelector(label: "Play"), limit: nil, timeout: nil, bundleID: nil)
    #expect(try perform(plain, transport: Self.answer(400, old)).status == RunnerExitCode.badRequest.rawValue)

    // A current runner gets the key in the element, and its answer (with onscreen) is printed as it came.
    let sent = Locked<[URLRequest]>([])
    let answer = #"{"ok":true,"bundleId":"app","count":1,"elements":[{"index":0,"label":"Play","onscreen":true}],"truncated":false}"#
    let (found, none) = try perform(onscreen) { request in
      sent.withLock { $0.append(request) }
      return RunnerResponse(status: 200, body: Data(answer.utf8))
    }
    #expect(found == RunnerExitCode.success.rawValue && none == nil)
    let body = try JSONSerialization.jsonObject(with: try #require(sent.value.first?.httpBody)) as? [String: Any]
    #expect((body?["element"] as? [String: Any])?["onscreen"] as? Bool == true)
    #expect((body?["element"] as? [String: Any])?["hittable"] == nil)
  }

  /// A runner from before `labelMatch` and `valueMatch` rejects them as unknown keys too: runner_bad_response (exit 8), not a
  /// silently broader match, and a current runner gets the pattern as written.
  @Test func aRunnerThatRejectsPatternsIsABadResponse() throws {
    let old = #"{"ok":false,"code":"invalid_request","error":"invalid field: element: unknown key 'labelMatch' (expected identifier, label, type, value, index, onscreen, hittable)"}"#
    let selector = RunnerElementSelector(labelMatch: try RunnerElementPattern("^Remaining"))
    let operations: [RunnerOperation] = [
      .find(selector, limit: nil, timeout: nil, bundleID: nil),
      .find(selector, limit: nil, timeout: 1, bundleID: nil, gone: true),
      .tap(RunnerTouch(target: .element(selector))),
      .press(RunnerTouch(target: .element(selector), duration: 1)),
      .adjust(selector, .position(0.5), timeout: nil, bundleID: nil)
    ]
    for operation in operations {
      let (status, failure) = try perform(operation, transport: Self.answer(400, old))
      #expect(status == RunnerExitCode.runnerError.rawValue, "\(operation.commandName)")
      #expect(failure?["code"] as? String == RelayErrorCode.runnerBadResponse.rawValue, "\(operation.commandName)")
      #expect(failure?["error"] as? String == "the runner rejected labelMatch in the element: it predates --label-match and "
        + "--value-match (relay start --rebuild builds a current one)", "\(operation.commandName)")
    }
    let value = RunnerOperation.find(RunnerElementSelector(type: "textField", valueMatch: try RunnerElementPattern("^$")),
                                     limit: nil, timeout: nil, bundleID: nil)
    let valueOld = old.replacingOccurrences(of: "'labelMatch'", with: "'valueMatch'")
    #expect((try perform(value, transport: Self.answer(400, valueOld)).failure?["error"] as? String)?
      .hasPrefix("the runner rejected valueMatch in the element") == true)
    // The same words about a key this selector did not send, or a runner's own 400 about the pattern, stay as they came.
    #expect(try perform(value, transport: Self.answer(400, old)).status == RunnerExitCode.badRequest.rawValue)
    let slow = #"{"ok":false,"code":"invalid_request","error":"invalid field: element.labelMatch: the regular expression took more than 1 s"}"#
    let tooSlow = try perform(operations[0], transport: Self.answer(400, slow))
    #expect(tooSlow.status == RunnerExitCode.badRequest.rawValue && tooSlow.failure?["code"] as? String == "invalid_request")

    let sent = Locked<[URLRequest]>([])
    let answer = #"{"ok":true,"bundleId":"app","count":1,"elements":[{"index":0,"label":"Remaining 4:59"}],"truncated":false}"#
    let found = try perform(operations[0]) { request in
      sent.withLock { $0.append(request) }
      return RunnerResponse(status: 200, body: Data(answer.utf8))
    }
    #expect(found.status == RunnerExitCode.success.rawValue)
    let body = try JSONSerialization.jsonObject(with: try #require(sent.value.first?.httpBody)) as? [String: Any]
    #expect(body?["element"] as? [String: String] == ["labelMatch": "^Remaining"])
  }
}

extension RunnerClientTests {
  @Test func scrollingRequiresAcknowledgementOnSuccessAndNotFoundAndRejectsOldRunners() throws {
    let operation = RunnerOperation.scrolling(.find(RunnerElementSelector(identifier: "row"), limit: nil, timeout: nil, bundleID: nil),
                                              RunnerScrolling.Options())
    for (status, body) in [(200, #"{"ok":true,"elements":[]}"#),
                           (422, #"{"ok":false,"code":"element_not_found"}"#),
                           (400, #"{"ok":false,"code":"invalid_request","error":"unknown key 'scroll'"}"#),
                           (400, #"{"ok":false,"code":"invalid_request","error":"timeout: expected 0...10"}"#),
                           (200, #"{"ok":true,"swipes":true}"#), (200, #"{"ok":true,"swipes":-1}"#)] {
      let result = try perform(operation, transport: Self.answer(status, body))
      #expect(result.status == 8)
      #expect(result.failure?["code"] as? String == "runner_bad_response")
      #expect((result.failure?["error"] as? String)?.contains("relay start --rebuild") == true)
    }
    let timeout = Locked(0.0)
    let result = try perform(operation) { request in
      timeout.withLock { $0 = request.timeoutInterval }
      return RunnerResponse(status: 422, body: Data(#"{"ok":false,"code":"element_not_found","swipes":10,"scrollStop":"edge"}"#.utf8))
    }
    #expect(result.status == 6)
    #expect(timeout.value == RunnerControl.baseTimeout + operation.waitTime)
    #expect(result.failure?["scrollStop"] as? String == "edge")
    #expect(try perform(operation, transport: Self.answer(200, #"{"ok":true,"swipes":0,"elements":[{}]}"#)).status == 0)
    #expect(try perform(operation, transport: Self.answer(400, #"{"ok":false,"error":"invalid timeout","swipes":0}"#)).status == 7)
    #expect(try perform(operation, transport: Self.answer(409, #"{"ok":false,"code":"busy"}"#)).status == 5)
  }
}
