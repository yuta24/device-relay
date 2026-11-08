import Foundation
@testable import Relay
import Testing

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct RunnerStatusTests {
  private let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro",
                                pid: 1234, startedAt: Date(timeIntervalSince1970: 1_800_000_000))

  @Test func parsesPing() {
    #expect(RunnerPing.parse(RunnerResponse(status: 200, body: Data(#"{"ok":true,"busy":false,"busyForMs":null}"#.utf8)))
      == .alive(busy: false, busyForMs: nil))
    #expect(RunnerPing.parse(RunnerResponse(status: 200, body: Data(#"{"ok":true,"busy":true,"busyForMs":1200}"#.utf8)))
      == .alive(busy: true, busyForMs: 1200))
    #expect(RunnerPing.parse(RunnerResponse(status: 401, body: Data())) == .status(401))
  }

  @Test func exitCodes() {
    #expect(RunnerPing.alive(busy: true, busyForMs: 5).exitCode == .success)
    #expect(RunnerPing.unreachable("refused").exitCode == .unavailable)
    #expect(RunnerPing.refusedByOS("Operation not permitted").exitCode == .unavailable)
    #expect(RunnerPing.status(401).exitCode == .unauthorized)
    #expect(RunnerPing.status(404).exitCode == .badRequest)
    #expect(RunnerPing.check(RunnerInfo(url: "not a url", token: "t", udid: "SIM")).exitCode == .unavailable)
  }

  @Test func text() throws {
    let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/home/.relay/runner.json"), info: info,
                                     processRunning: true, ping: .alive(busy: true, busyForMs: 1200))
    let text = RunnerStatus.text(report, timeZone: try #require(TimeZone(identifier: "UTC")))
    #expect(text == """
    url:         http://127.0.0.1:8100/
    device:      iPhone 17 Pro (SIM)
    pid:         1234 (relay start running)
    started:     2027-01-15 08:00:00 +0000
    ping:        ok (busy for 1200 ms)
    runner:      not reported (the runner predates build reporting)
    runner.json: /home/.relay/runner.json
    """)
  }

  @Test func textWithoutProcessInfo() {
    let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"),
                                     processRunning: nil, ping: .unreachable("refused"))
    #expect(RunnerStatus.text(report) == """
    url:         http://127.0.0.1:8100/
    device:      SIM
    ping:        no answer (refused)
    runner.json: /r.json
    """)
  }

  @Test func aConnectionTheOSRefusedSaysSo() throws {
    let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"),
                                     processRunning: true, ping: .refusedByOS("Operation not permitted"))
    #expect(RunnerStatus.text(report).contains(
      "ping:        no answer: the OS refused the connection (Operation not permitted); relay may be in a sandbox that blocks localhost"))
    let object = try #require(try JSONSerialization.jsonObject(with: RunnerStatus.json(report)) as? [String: Any])
    let ping = try #require(object["ping"] as? [String: Any])
    #expect(ping["refusedByOS"] as? Bool == true)
    #expect(ping["error"] as? String == "Operation not permitted")
    // Like no answer, it does not keep a new relay start from trying the port.
    #expect(BackgroundStart.conflict(with: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"), port: 8100,
                                     ping: .refusedByOS("Operation not permitted"), owner: nil) == nil)
  }

  @Test func json() throws {
    let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info, processRunning: false, ping: .status(401))
    let object = try #require(try JSONSerialization.jsonObject(with: RunnerStatus.json(report)) as? [String: Any])
    #expect(object["alive"] as? Bool == false)
    #expect(object["pid"] as? Int == 1234)
    #expect(object["processRunning"] as? Bool == false)
    #expect(object["name"] as? String == "iPhone 17 Pro")
    #expect(object["startedAt"] as? String == "2027-01-15T08:00:00Z")
    #expect((object["ping"] as? [String: Any])?["status"] as? Int == 401)
    #expect(object["token"] == nil)

    let alive = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info, processRunning: true, ping: .alive(busy: false, busyForMs: nil))
    let aliveObject = try #require(try JSONSerialization.jsonObject(with: RunnerStatus.json(alive)) as? [String: Any])
    #expect(aliveObject["alive"] as? Bool == true)
    let ping = try #require(aliveObject["ping"] as? [String: Any])
    #expect(ping["busy"] as? Bool == false)
    #expect(ping["busyForMs"] is NSNull)
  }
}
