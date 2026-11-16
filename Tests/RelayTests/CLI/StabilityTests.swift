import Foundation
@testable import Relay
import Testing

struct StabilityTests {
  @Test func parsesCommandAndScenarioWithTheSameDefaults() throws {
    #expect(try Arguments.parse(["wait", "--stable"]) == .runner(.init(operation: .waitStable(.init(), bundleID: nil))))
    let parsed = try Arguments.parse(["wait", "--stable", "--for=1", "--timeout=3", "--bundle-id=host", "--require", "--session=stable"])
    #expect(parsed == .runner(.init(operation: .waitStable(.init(duration: 1, timeout: 3), bundleID: "host"),
                                    session: "stable", requireMatch: true)))
    #expect(try Scenario.parse(Scenario.lines(of: "tap 20 30\nwait --stable --for 1 --timeout 3 --require")).last?.action
      == .runner(.waitStable(.init(duration: 1, timeout: 3), bundleID: nil), requireMatch: true))
    for words in [["wait"], ["wait", "--stable=true"], ["wait", "--stable", "extra"],
                  ["wait", "--stable", "--for", "0"], ["wait", "--stable", "--for", "5.1"],
                  ["wait", "--stable", "--timeout", "11"], ["wait", "--stable", "--timeout", "nan"],
                  ["wait", "--stable", "--for", "1", "--for", "2"], ["tap", "1", "2", "--stable"], ["wait", "--stable", "--bundle-id", ""]] {
      #expect(throws: ArgumentError.self) { try Arguments.parse(words) }
    }
  }

  @Test func requestResolvesHostAndAllowsCaptureToFinish() throws {
    let operation = try RunnerOperation.waitStable(.init(duration: 1, timeout: 3), bundleID: "host").resolvingHostAlias("example.host")
    #expect(operation.commandName == "wait")
    #expect(operation.request.path == "/wait")
    #expect(operation.request.method == "POST")
    #expect(operation.request.body?["stable"] as? Bool == true)
    #expect(operation.request.body?["for"] as? Double == 1)
    #expect(operation.request.body?["timeout"] as? Double == 3)
    #expect(operation.request.body?["bundleId"] as? String == "example.host")
    #expect(RunnerControl.baseTimeout + operation.waitTime >= 3 + RunnerStability.captureAllowance + 20)
  }

  private func perform(_ body: String, status: Int = 200, require: Bool = false) throws -> (Int32, [String: Any]?) {
    let connection = RunnerConnection(infoURL: URL(fileURLWithPath: "/tmp/runner.json"),
                                      info: RunnerInfo(url: "http://runner.invalid/", token: "secret", udid: "SIM"),
                                      baseURL: URL(string: "http://runner.invalid/")!)
    let pipe = Pipe()
    let result = RunnerControl.perform(.waitStable(.init(timeout: 2), bundleID: nil), on: connection,
                                       requireMatch: require, failureOutput: pipe.fileHandleForWriting) { request in
      #expect(request.timeoutInterval == 2 + RunnerStability.captureAllowance + RunnerControl.baseTimeout)
      #expect(request.url?.path == "/wait")
      return RunnerResponse(status: status, body: Data(body.utf8))
    }
    try pipe.fileHandleForWriting.close()
    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
    return (result, data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func timeoutSucceedsUnlessRequiredAndPreservesMeasurements() throws {
    #expect(try perform(#"{"ok":true,"stable":false,"waitedMs":2000}"#).0 == 0)
    #expect(try perform(#"{"ok":true,"stable":true,"waitedMs":600}"#, require: true).0 == 0)
    let (status, failure) = try perform(#"{"ok":true,"stable":false,"waitedMs":2000}"#, require: true)
    #expect(status == 6)
    #expect(failure?["code"] as? String == "screen_not_stable")
    #expect(failure?["stable"] as? Bool == false)
    #expect(failure?["waitedMs"] as? Int == 2000)
  }

  @Test func oldAndMalformedRunnersFailWithRebuildHint() throws {
    for body in [#"{"ok":true}"#, #"{"stable":1,"waitedMs":0}"#, #"{"stable":true}"#,
                 #"{"stable":true,"waitedMs":true}"#, #"{"stable":true,"waitedMs":-1}"#] {
      let (status, failure) = try perform(body)
      #expect(status == 8)
      #expect(failure?["code"] as? String == "runner_bad_response")
      #expect((failure?["error"] as? String)?.contains("relay start --rebuild") == true)
    }
    let (status, failure) = try perform(#"{"ok":false,"code":"not_found","error":"no such route"}"#, status: 404)
    #expect(status == 8)
    #expect(failure?["code"] as? String == "runner_bad_response")
    // A current runner's field error stays a bad request with its own message.
    #expect(try perform(#"{"ok":false,"code":"invalid_request","error":"bundleId: expected a non-empty string"}"#, status: 400).0 == 7)
    #expect(try perform(#"{"ok":false,"code":"busy"}"#, status: 409).0 == 5)
    #expect(try perform(#"{"ok":false,"code":"xcui_failed"}"#, status: 422).0 == 6)
  }
}
