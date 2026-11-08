import Foundation
@testable import Relay
import Testing

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

struct SessionNameTests {
  @Test func validNames() {
    for name in ["a", "agent-1", "Agent_1", "a.b", "0", String(repeating: "x", count: RelaySession.maxNameLength)] {
      #expect(RelaySession.isValidName(name), "\(name)")
    }
  }

  @Test func invalidNames() {
    for name in ["", ".", "..", ".hidden", "-a", "_a", "a/b", "../a", "a b", "a\n", "セッション", "a:b",
                 String(repeating: "x", count: RelaySession.maxNameLength + 1)] {
      #expect(!RelaySession.isValidName(name), "\(name)")
    }
  }

  @Test func resolvePrefersTheOption() throws {
    #expect(try RelaySession.resolve(flag: "a", environment: ["RELAY_SESSION": "b"]) == "a")
    #expect(try RelaySession.resolve(flag: nil, environment: ["RELAY_SESSION": "b"]) == "b")
    #expect(try RelaySession.resolve(flag: nil, environment: ["RELAY_SESSION": ""]) == nil)
    #expect(try RelaySession.resolve(flag: nil, environment: [:]) == nil)
  }

  @Test func resolveRejectsAnInvalidVariable() {
    #expect {
      try RelaySession.resolve(flag: nil, environment: ["RELAY_SESSION": "../x"])
    } throws: { error in
      "\(error)".contains("$RELAY_SESSION") && "\(error)".contains("../x")
    }
  }
}

struct SessionFilesTests {
  @Test func paths() throws {
    let home = URL(fileURLWithPath: "/h", isDirectory: true)
    #expect(RelaySession.infoURL(name: "a", home: home).path == "/h/.relay/sessions/a/runner.json")
    #expect(RelaySession.lockURL(name: "a", home: home).path == "/h/.relay/sessions/a/session.lock")
    #expect(StartLock.deviceURL(udid: "abc-1", home: home).path == "/h/.relay/locks/device-ABC-1.lock")
  }

  @Test func namesAreTheValidDirectories() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(RelaySession.names(home: home).isEmpty)
    for name in ["b", "a", ".DS_Store"] {
      try FileManager.default.createDirectory(at: RelaySession.directory(name: name, home: home), withIntermediateDirectories: true)
    }
    #expect(RelaySession.names(home: home) == ["a", "b"])
  }

  @Test func runnerInfoKeepsTheSessionAndOldFilesStillRead() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let url = home.appendingPathComponent("runner.json")
    try RunnerInfo(url: "u", token: "t", udid: "SIM", session: "a").write(to: url)
    #expect(try RunnerInfo.read(from: url).session == "a")
    try Data(#"{"url":"u","token":"t","udid":"SIM"}"#.utf8).write(to: url)
    #expect(try RunnerInfo.read(from: url).session == nil)
  }

  @Test func logsNameTheSession() throws {
    let directory = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamp = "20261104-120000"
    #expect(try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8101, session: "a").lastPathComponent
      == "start-20261104-120000-a-8101.log")
    #expect(try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8101).lastPathComponent == "start-20261104-120000-8101.log")
  }

  @Test func defaultOutputsNameTheSession() {
    let now = Date(timeIntervalSince1970: 0)
    let temporary = URL(fileURLWithPath: "/t", isDirectory: true)
    let shot = RunnerControl.screenshotURL(RunnerScreenshot(output: nil), now: now, session: "a", temporaryDirectory: temporary)
    #expect(shot.lastPathComponent.hasPrefix("screenshot-a-"))
    #expect(!RunnerControl.screenshotURL(RunnerScreenshot(output: nil), now: now, temporaryDirectory: temporary).lastPathComponent.hasPrefix("screenshot-a-"))
    #expect(Recording.outputURL(nil, now: now, session: "a", temporaryDirectory: temporary).lastPathComponent.hasPrefix("relay-recording-a-"))
  }

  @Test func testDataIsPerPortAndOutsideTheBuild() {
    let build = URL(fileURLWithPath: "/h/.relay/build/installed", isDirectory: true)
    #expect(RunnerLauncher.testDataURL(buildURL: build, port: 8101).path == "/h/.relay/build/installed/TestData/port-8101")
    #expect(RunnerLauncher.testDataURL(buildURL: build, port: 8101) != RunnerLauncher.testDataURL(buildURL: build, port: 8102))
  }
}

struct PortPickerTests {
  private func lockInHome(_ home: URL) -> (Int) throws -> StartLock? {
    { try StartLock.tryAcquire(port: $0, home: home) }
  }

  @Test func theDefaultPortIsLeftToStartsWithoutASession() {
    #expect(!PortPicker.sessionRange.contains(8100))
  }

  @Test func picksTheFirstPortThatIsBothUnlockedAndFree() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let held = try StartLock.acquire(port: 9001, home: home)
    defer { held.release() }

    let picked = try PortPicker.pick(range: 9001 ... 9004, isFree: { $0 != 9002 }, lock: lockInHome(home))
    defer { picked.lock.release() }
    #expect(picked.port == 9003)

    // The lock is held, so the next start moves on, and the one given up for a taken port is free again.
    let next = try PortPicker.pick(range: 9001 ... 9004, isFree: { _ in true }, lock: lockInHome(home))
    defer { next.lock.release() }
    #expect(next.port == 9002)
  }

  @Test func noPortLeftIsAnError() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect {
      try PortPicker.pick(range: 9001 ... 9002, isFree: { _ in false }, lock: lockInHome(home))
    } throws: { "\($0)".contains("--port") && "\($0)".contains("9001") }
  }

  @Test func isFreeSeesAListeningPort() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    #expect(!PortPicker.isFree(Int(in_port_t(bigEndian: address.sin_port))))
  }
}
