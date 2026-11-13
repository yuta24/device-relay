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
}
