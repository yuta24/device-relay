import Foundation
@testable import Relay
import Testing

struct HingeTests {
  @Test func parsesAnglesAliasesAndScenario() throws {
    for (text, angle) in [("open", 180.0), ("close", 0), ("half", 90), ("120.25", 120.25), ("0", 0), ("180", 180)] {
      #expect(try Arguments.parse(["hinge", text, "--session", "hinge"]) == .runner(.init(operation: .hinge(angle), session: "hinge")))
      #expect(try Scenario.action(["hinge", text]) == .runner(.hinge(angle)))
    }
    #expect(try Arguments.parse(["hinge"]) == .runner(.init(operation: .hinge(nil))))
    for text in ["-1", "181", "nan", "inf", "", "book"] {
      #expect(throws: ArgumentError.self) { try Arguments.parse(["hinge", text]) }
    }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["hinge", "90", "120"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["hinge", "--timeout", "2"]) }
    #expect(RunnerOperation.hinge(nil).commandName == "hinge")
    #expect(RunnerOperation.hinge(nil).request.method == "GET")
    #expect(RunnerOperation.hinge(90).request.method == "POST")
    #expect(RunnerOperation.hinge(90).request.body?["angle"] as? Double == 90)
  }

  @Test func deviceOrientationValuesAndTimeout() {
    for (name, value) in [("portrait", "portrait"), ("portraitUpsideDown", "pud"),
                          ("landscapeLeft", "landscape-left"), ("landscapeRight", "landscape-right")] {
      #expect(RunnerRequestValues.hingeOrientation(name) == value)
    }
    #expect(RunnerRequestValues.hingeOrientation("unknown") == nil)
    #expect(RunnerControl.baseTimeout + RunnerOperation.hinge(180).waitTime >= 10 + 20)
    #expect(RunnerControl.baseTimeout + RunnerOperation.orientation("portrait").waitTime >= 8 + 20)
  }

  private func perform(_ body: String, status: Int = 200, angle: Double? = 90) throws -> (Int32, [String: Any]?) {
    let connection = RunnerConnection(infoURL: URL(fileURLWithPath: "/tmp/runner.json"),
                                      info: RunnerInfo(url: "http://runner.invalid/", token: "secret", udid: "SIM"),
                                      baseURL: URL(string: "http://runner.invalid/")!)
    let pipe = Pipe()
    let exit = RunnerControl.perform(.hinge(angle), on: connection, failureOutput: pipe.fileHandleForWriting) { request in
      #expect(request.timeoutInterval >= 30)
      #expect(request.url?.path == "/hinge")
      #expect(request.httpMethod == (angle == nil ? "GET" : "POST"))
      return RunnerResponse(status: status, body: Data(body.utf8))
    }
    try pipe.fileHandleForWriting.close()
    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
    return (exit, data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func interpretsConfirmedAnglesAndRefusals() throws {
    #expect(try perform(#"{"ok":true,"angle":94.6,"mechanicalAngle":90,"display":3}"#).0 == 0)
    #expect(try perform(#"{"ok":true,"angle":118.5,"mechanicalAngle":120,"display":3}"#, angle: nil).0 == 0)
    // The physical-device / missing-capability refusal is an action failure, never success.
    let refusal = try perform(#"{"ok":false,"code":"hinge_unavailable","error":"simulator only"}"#, status: 422)
    #expect(refusal.0 == 6)
    #expect(refusal.1?["code"] as? String == "hinge_unavailable")
    #expect(try perform(#"{"ok":false,"code":"hinge_failed","error":"timeout"}"#, status: 422).0 == 6)
    #expect(try perform(#"{"ok":false,"code":"busy"}"#, status: 409).0 == 5)
    #expect(try perform(#"{"ok":false,"code":"invalid_request"}"#, status: 400).0 == 7)
  }

  @Test func oldOrUnconfirmedRunnersNeedRebuild() throws {
    for body in [#"{"ok":true}"#, #"{"ok":true,"angle":94.6,"mechanicalAngle":89,"display":3}"#,
                 #"{"ok":true,"angle":true,"mechanicalAngle":90,"display":3}"#,
                 #"{"ok":true,"angle":94.6,"mechanicalAngle":181,"display":3}"#,
                 #"{"angle":94.6,"mechanicalAngle":90,"display":3}"#] {
      let (exit, failure) = try perform(body)
      #expect(exit == 8)
      #expect(failure?["code"] as? String == "runner_bad_response")
      #expect((failure?["error"] as? String)?.contains("relay start --rebuild") == true)
    }
    #expect(try perform(#"{"ok":false,"code":"not_found"}"#, status: 404).0 == 8)
  }

  /// Compile the same non-simulator branch as an iPhone device build and exercise all entry points.
  /// It must return before resolving or calling any of the guest HID functions, even on a Mac.
  @Test func nonSimulatorRunnerRefusesEveryEntryPoint() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-hinge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let main = directory.appendingPathComponent("main.m")
    try #"""
    #import "RelayHinge.h"
    int main(void) {
      @autoreleasepool {
        if ([RelayHinge hasHinge]) return 1;
        for (NSDictionary *r in @[[RelayHinge readAngle], [RelayHinge setAngle:90], [RelayHinge setOrientation:@"portrait"]]) {
          if (![r[@"ok"] isEqual:@NO] || ![r[@"code"] isEqual:@"hinge_unavailable"]) return 2;
        }
        puts("refused");
      }
    }
    """#.write(to: main, atomically: true, encoding: .utf8)
    let runner = root.appendingPathComponent("Runner/RelayRunnerUITests")
    let binary = directory.appendingPathComponent("guard-test")
    try Shell.xcrun(["clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", "-I", runner.path,
                     runner.appendingPathComponent("RelayHinge.m").path, main.path, "-o", binary.path], timeout: 30)
    #expect(try Shell.run(binary.path, [], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines) == "refused")
  }
}
