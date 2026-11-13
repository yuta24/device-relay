import Darwin
import Foundation
@testable import Relay
import Testing

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

struct RunnerSessionsListTests {
  private func info(_ url: String, name: String? = "iPhone 17", session: String? = nil) -> RunnerInfo {
    RunnerInfo(url: url, token: "t", udid: "SIM", name: name, pid: 42, session: session)
  }

  @Test func rowsListTheDefaultRunnerAndEverySessionThatHasOne() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(RunnerSessions.rows(home: home, ping: { _ in .unreachable("") }, processRunning: { _ in nil }).isEmpty)

    try info("http://127.0.0.1:8100/").write(to: RunnerLocator.userURL(home: home))
    try info("http://127.0.0.1:8101/", session: "a").write(to: RelaySession.infoURL(name: "a", home: home))
    try info("http://127.0.0.1:8102/", session: "b").write(to: RelaySession.infoURL(name: "b", home: home))
    // Ended: only its directory and its free lock are left.
    try StartLock.acquire(session: "ended", home: home).release()
    // Still booting or building: its lock is held and there is no runner.json yet.
    let starting = try StartLock.acquire(session: "starting", home: home)
    defer { starting.release() }

    // Read again for a moment until the ended session's lock reads as free, as it may linger: see onceReleased.
    var rows: [RunnerSessions.Row] = []
    #expect(becomesTrue {
      rows = RunnerSessions.rows(home: home, ping: { $0.url.contains("8102") ? .unreachable("refused") : .alive(busy: $0.url.contains("8101"), busyForMs: nil) },
                                 processRunning: { $0.url.contains("8102") ? nil : 42 })
      return rows.map(\.label) == ["(default)", "a", "b", "starting"]
    })
    #expect(rows.map(\.label) == ["(default)", "a", "b", "starting"])
    #expect(rows.map(\.state) == [.running, .busy, .noAnswer, .starting])
    #expect(rows.map(\.processRunning) == [true, true, false, true])
    #expect(rows[3].pid == getpid())
    #expect(rows[3].info == nil)
  }

  @Test func stateOfEachAnswer() {
    #expect(RunnerSessions.state(for: .alive(busy: false, busyForMs: nil)) == .running)
    #expect(RunnerSessions.state(for: .alive(busy: true, busyForMs: 3)) == .busy)
    #expect(RunnerSessions.state(for: .status(401)) == .rejected)
    #expect(RunnerSessions.state(for: .unreachable("")) == .noAnswer)
    #expect(RunnerSessions.state(for: .refusedByOS("")) == .unknown)
  }

  @Test func table() {
    let url = URL(fileURLWithPath: "/r.json")
    let table = RunnerSessions.table([
      .init(session: nil, state: .running, info: RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM-1"), infoURL: url, pid: 7, processRunning: true),
      .init(session: "agent-1", state: .noAnswer, info: info("http://127.0.0.1:8101/"), infoURL: url, pid: 42, processRunning: false),
      .init(session: "s", state: .starting, infoURL: url, pid: 9, processRunning: true)
    ])
    #expect(table == """
    SESSION    STATE      DEVICE           URL                     PID
    (default)  running    SIM-1            http://127.0.0.1:8100/  7
    agent-1    no answer  iPhone 17 (SIM)  http://127.0.0.1:8101/  42 (exited)
    s          starting   -                -                       9
    """)
    #expect(RunnerSessions.table([]) == "no runners")
  }

  @Test func json() throws {
    let url = URL(fileURLWithPath: "/r.json")
    let data = RunnerSessions.json([
      .init(session: nil, state: .running, info: info("http://127.0.0.1:8100/"), infoURL: url, pid: 42, processRunning: true,
            ping: .alive(busy: false, busyForMs: nil)),
      .init(session: "s", state: .starting, infoURL: url, pid: nil, processRunning: false)
    ])
    let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(objects.count == 2)
    #expect(objects[0]["session"] is NSNull)
    #expect(objects[0]["alive"] as? Bool == true)
    #expect(objects[0]["url"] as? String == "http://127.0.0.1:8100/")
    #expect(objects[0]["pid"] as? Int == 42)
    #expect(objects[1]["session"] as? String == "s")
    #expect(objects[1]["state"] as? String == "starting")
    #expect(objects[1]["url"] is NSNull)
    // The token stays in the 0600 file.
    #expect(!String(decoding: data, as: UTF8.self).contains("\"token\""))
  }

  @Test func statusShowsTheSession() {
    let report = RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info("http://127.0.0.1:8101/", session: "a"),
                                     processRunning: true, ping: .alive(busy: false, busyForMs: nil))
    #expect(RunnerStatus.text(report).hasPrefix("session:"))
    let object = (try? JSONSerialization.jsonObject(with: RunnerStatus.json(report))) as? [String: Any]
    #expect(object?["session"] as? String == "a")
  }
}
