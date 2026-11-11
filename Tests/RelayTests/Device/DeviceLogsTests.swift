import Darwin
import Foundation
@testable import Relay
import Testing

// relay logs. UDIDs, names, paths, and log lines are dummies; no simulator or device is used.

/// What a command wrote to stdout through `LogTools.write`.
final class CapturedOutput: Sendable {
  private let data = Locked(Data())
  let isClosed: Bool

  init(closed: Bool = false) {
    isClosed = closed
  }

  func write(_ chunk: Data) -> Bool {
    guard !isClosed else { return false }
    data.withLock { $0.append(chunk) }
    return true
  }

  var lines: [String] {
    String(decoding: data.value, as: UTF8.self).split(separator: "\n").map(String.init)
  }

  var objects: [[String: Any]] {
    lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
  }

  var object: [String: Any] { objects.first ?? [:] }
}

let fakeSimctlJSON = #"""
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
{"udid":"SIM-ON","name":"Test Sim","state":"Booted","isAvailable":true},
{"udid":"SIM-OFF","name":"Off Sim","state":"Shutdown","isAvailable":true}]}}
"""#

let fakeDevicectlJSON = #"""
{"result":{"devices":[
{"identifier":"a","hardwareProperties":{"udid":"DEV-ON","platform":"iOS","marketingName":"iPhone 14 Pro"},
 "connectionProperties":{"tunnelState":"connected","transportType":"wired","pairingState":"paired"},
 "deviceProperties":{"name":"Test Phone","osVersionNumber":"26.7.1"}},
{"identifier":"b","hardwareProperties":{"udid":"DEV-OFF","platform":"iOS"},
 "connectionProperties":{"tunnelState":"unavailable"},"deviceProperties":{"name":"Away Phone"}}]}}
"""#

/// A log line of `log --style ndjson`, as the probe app wrote them.
func fakeLogLine(_ message: String, time: String = "2026-11-11 09:20:48.096118+0900", type: String = "Default",
                 uuid: String = "11111111-2222-3333-4444-555555555555", event: String = "logEvent") -> Data {
  let object: [String: Any] = [
    "eventType": event, "messageType": type, "timestamp": time, "eventMessage": message, "processID": 4242,
    "processImagePath": "/Users/someone/Library/Developer/CoreSimulator/Devices/SIM-ON/data/Containers/Bundle/Application/X/Probe.app/Probe",
    "processImageUUID": uuid, "subsystem": "com.example.probe", "category": ""
  ]
  return try! JSONSerialization.data(withJSONObject: object)
}

typealias FakeStream = @Sendable (_ executable: String, _ args: [String], _ timeout: TimeInterval?, _ stop: LogStop,
                                  _ onLine: @escaping @Sendable (Data) -> Bool) throws -> LogToolExit

/// A stream that hands over `lines` and ends with `exit`.
func fakeStream(_ lines: [Data], exit: LogToolExit = LogToolExit(status: 0), calls: Locked<[[String]]>? = nil) -> FakeStream {
  { _, args, _, _, onLine in
    calls?.withLock { $0.append(args) }
    for line in lines where !onLine(line) {
      return LogToolExit(status: 0, stopped: .consumer)
    }
    return exit
  }
}

func fakeLogTools(
  home: URL,
  output: CapturedOutput = CapturedOutput(),
  environment: [String: String] = [:],
  xcrun: @escaping @Sendable ([String]) throws -> String = { _ in "" },
  devicectl: @escaping @Sendable ([String]) throws -> Data = { _ in Data() },
  run: @escaping @Sendable (String, [String], URL, TimeInterval, LogStop?) throws -> LogToolExit = { _, _, _, _, _ in LogToolExit(status: 0) },
  stream: @escaping FakeStream = fakeStream([])
) -> LogTools {
  LogTools(
    commands: HostCommands(
      xcrun: { args, _ in
        if args.prefix(3) == ["simctl", "list", "devices"] { return fakeSimctlJSON }
        return try xcrun(args)
      },
      devicectlJSON: { args, _ in
        if args == ["list", "devices"] { return Data(fakeDevicectlJSON.utf8) }
        return try devicectl(args)
      },
      run: { _, _, _ in "" }
    ),
    run: run,
    stream: stream,
    write: { output.write($0) },
    environment: environment,
    home: home,
    currentDirectory: home,
    temporaryDirectory: home.appendingPathComponent("tmp", isDirectory: true)
  )
}

/// A thin 64-bit Mach-O header with one LC_UUID load command.
func fakeMachO(uuid: [UInt8]) -> Data {
  func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
  var bytes = le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(2) + le(2) + le(24 + 16) + le(0) + le(0)
  bytes += le(0x19) + le(16) + [UInt8](repeating: 0, count: 8) // an unrelated command first
  bytes += le(0x1B) + le(24) + uuid
  return Data(bytes)
}

/// An `.app` with Info.plist and a Mach-O executable, as `simctl get_app_container` points at.
func fakeApp(in directory: URL, executable: String = "Probe", uuid: [UInt8] = Array(0x11 ... 0x20)) throws -> URL {
  let app = directory.appendingPathComponent("\(executable).app", isDirectory: true)
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0)
  try plist.write(to: app.appendingPathComponent("Info.plist"))
  try fakeMachO(uuid: uuid).write(to: app.appendingPathComponent(executable))
  return app
}

struct DeviceLogLineTests {
  @Test func readsALogLine() throws {
    guard case .entry(let entry) = DeviceLogs.parse(line: fakeLogLine("probe notice", type: "Info")) else {
      Issue.record("not an entry")
      return
    }
    #expect(entry.level == "info")
    #expect(entry.process == "Probe")
    #expect(entry.processID == 4242)
    #expect(entry.subsystem == "com.example.probe")
    #expect(entry.category == nil)
    #expect(entry.message == "probe notice")
    #expect(entry.imageUUID == "11111111-2222-3333-4444-555555555555")
    let json = entry.json
    #expect(json["timestamp"] as? String == "2026-11-11T00:20:48.096118Z")
    #expect(json["category"] is NSNull)
    #expect(json["imageUUID"] == nil)
  }

  @Test func tellsTheOtherLinesApart() {
    #expect(DeviceLogs.parse(line: fakeLogLine("x", event: "activityCreateEvent")) == .otherEvent)
    #expect(DeviceLogs.parse(line: Data(#"{"count":540,"finished":1}"#.utf8)) == .summary)
    #expect(DeviceLogs.parse(line: Data("Filtering the log data using \"process == \\\"Probe\\\"\"".utf8))
      == .notice("Filtering the log data using \"process == \\\"Probe\\\"\""))
    #expect(DeviceLogs.parse(line: Data("  ".utf8)) == .notice(""))
    #expect(DeviceLogs.parse(line: Data("Timestamp  Thread  Type".utf8)) == .invalid("a line that is not JSON"))
    #expect(DeviceLogs.parse(line: Data(#"{"broken":"#.utf8)) == .invalid("a line that is not JSON"))
    #expect(DeviceLogs.parse(line: Data(#"{"a":1}"#.utf8)) == .invalid("a JSON line without eventType"))
    #expect(DeviceLogs.parse(line: fakeLogLine("x", time: "yesterday")) == .invalid("a log line without a readable timestamp"))
  }

  @Test func collectorKeepsTheWindowAndTheApp() {
    let since = LogTime.parse("2026-11-11 09:20:00+0900")!
    let until = LogTime.parse("2026-11-11 09:21:00+0900")!
    let filter = LogFilter(bundleID: "com.example.probe", executablePath: "/x/Probe.app/Probe", imageUUIDs: ["AAAA-1"])
    var collector = LogCollector(since: since, until: until, filter: filter)
    let added1 = collector.add(fakeLogLine("early", time: "2026-11-11 09:19:59.9+0900", uuid: "aaaa-1"))
    #expect(added1)
    let added2 = collector.add(fakeLogLine("kept", time: "2026-11-11 09:20:30+0900", uuid: "aaaa-1"))
    #expect(added2)
    let added3 = collector.add(fakeLogLine("other build", time: "2026-11-11 09:20:31+0900", uuid: "BBBB-2"))
    #expect(added3)
    let added4 = collector.add(fakeLogLine("late", time: "2026-11-11 09:21:01+0900", uuid: "AAAA-1"))
    #expect(added4)
    let added5 = collector.add(fakeLogLine("x", event: "signpostEvent"))
    #expect(added5)
    let added6 = collector.add(Data(#"{"count":5,"finished":1}"#.utf8))
    #expect(added6)
    #expect(collector.entries.map(\.message) == ["kept"])
    #expect(collector.skipped == 1)
    #expect(collector.failure == nil)
    let added7 = collector.add(Data("garbage".utf8))
    #expect(!added7)
    #expect(collector.failure?.code == .logsUnavailable)
    #expect(collector.failure?.message.contains("line 7") == true)
    #expect(filter.predicate == #"process == "Probe""#)
    #expect(filter.json["imageUUIDs"] as? [String] == ["AAAA-1"])
    #expect(!filter.keeps(LogEntry(date: since)))
  }

  @Test func collectorStopsWhenThereIsTooMuch() {
    var collector = LogCollector(since: nil, until: nil, filter: nil, maxBytes: 500)
    let added8 = collector.add(fakeLogLine("a"))
    #expect(added8)
    let added9 = collector.add(fakeLogLine("b"))
    #expect(added9)
    let added10 = collector.add(fakeLogLine("c"))
    #expect(!added10)
    #expect(collector.failure?.message.contains("larger than") == true)
    #expect(collector.entries.count == 2)
  }

  @Test func machOUUIDs() {
    let uuid: [UInt8] = Array(0x11 ... 0x20)
    #expect(MachO.uuids(fakeMachO(uuid: uuid)) == ["11121314-1516-1718-191A-1B1C1D1E1F20"])
    // A fat file with two slices.
    let slice = fakeMachO(uuid: uuid)
    func be(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    var fat = be(0xCAFE_BABE) + be(2)
    fat += be(0x0100_000C) + be(0) + be(64) + be(UInt32(slice.count)) + be(0)
    fat += be(0x0100_0007) + be(3) + be(256) + be(UInt32(slice.count)) + be(0)
    var data = Data(fat)
    data += Data(count: 64 - data.count) + slice
    data += Data(count: 256 - data.count) + slice
    #expect(MachO.uuids(data).count == 2)

    // A slice far into the file (a large first slice) is read at its offset.
    let other = fakeMachO(uuid: Array(0x21 ... 0x30))
    let far = 3 << 20
    var large = Data(be(0xCAFE_BABE) + be(2) + be(0x0100_0007) + be(3) + be(64) + be(UInt32(slice.count)) + be(0)
      + be(0x0100_000C) + be(0) + be(UInt32(far)) + be(UInt32(other.count)) + be(0))
    large += Data(count: 64 - large.count) + slice
    large += Data(count: far - large.count) + other
    #expect(MachO.uuids(large) == ["11121314-1516-1718-191A-1B1C1D1E1F20", "21222324-2526-2728-292A-2B2C2D2E2F30"])
    // The same in a fat file with 64-bit offsets.
    var wide = Data(be(0xCAFE_BABF) + be(1) + be(0x0100_000C) + be(0) + be(0) + be(UInt32(far)) + be(0) + be(UInt32(other.count)) + be(0) + be(0))
    wide += Data(count: far - wide.count) + other
    #expect(MachO.uuids(wide) == ["21222324-2526-2728-292A-2B2C2D2E2F30"])
    // A 64-bit offset past Int.max (a broken header) skips that slice, not the others.
    var overflow = Data(be(0xCAFE_BABF) + be(2)
      + be(0x0100_000C) + be(0) + be(0x8000_0000) + be(0) + be(0) + be(UInt32(other.count)) + be(0) + be(0)
      + be(0x0100_000C) + be(0) + be(0) + be(128) + be(0) + be(UInt32(other.count)) + be(0) + be(0))
    overflow += Data(count: 128 - overflow.count) + other
    #expect(MachO.uuids(overflow) == ["21222324-2526-2728-292A-2B2C2D2E2F30"])
    // A slice offset past the end.
    #expect(MachO.uuids(Data(be(0xCAFE_BABE) + be(1) + be(0) + be(0) + be(UInt32(far)) + be(0) + be(0))).isEmpty)
    #expect(MachO.uuids(Data("not a binary".utf8)).isEmpty)
    #expect(MachO.uuids(Data()).isEmpty)
    // A load command of size 0 is not followed forever.
    var broken = [UInt8](fakeMachO(uuid: uuid))
    broken[36] = 0
    #expect(MachO.uuids(Data(broken)).isEmpty)
  }

  @Test func toolArguments() {
    let since = Date(timeIntervalSince1970: 1_794_356_400.9)
    #expect(DeviceLogs.epoch(since) == "@1794356400")
    #expect(DeviceLogs.showArguments(udid: "SIM-ON", since: since, predicate: #"process == "Probe""#)
      == ["simctl", "spawn", "SIM-ON", "log", "show", "--style", "ndjson", "--info", "--debug", "--start", "@1794356400",
          "--predicate", #"process == "Probe""#])
    #expect(DeviceLogs.streamArguments(udid: "SIM-ON", predicate: nil)
      == ["simctl", "spawn", "SIM-ON", "log", "stream", "--style", "ndjson", "--level", "debug"])
    #expect(DeviceLogs.collectArguments(udid: "DEV-ON", since: since, output: "/w/d.logarchive")
      == ["collect", "--device-udid", "DEV-ON", "--start", "@1794356400", "--output", "/w/d.logarchive"])
    #expect(DeviceLogs.archiveArguments(path: "/a.logarchive", since: nil) == ["show", "--archive", "/a.logarchive", "--style", "ndjson", "--info", "--debug"])
    #expect(DeviceLogs.predicate(process: #"A "quoted" \ name"#) == #"process == "A \"quoted\" \\ name""#)
  }

  @Test func reasonsOfAFailure() {
    #expect(DeviceLogs.reason(LogToolExit(status: 15, timedOut: true), tool: "log show", timeout: 60) == "log show timed out after 60 s")
    #expect(DeviceLogs.reason(LogToolExit(status: 64, stderr: "getpwuid_r did not find a match for uid 501\n\nlog: Bad predicate\n"),
                              tool: "log show", timeout: 60) == "log show failed (64): log: Bad predicate")
    #expect(DeviceLogs.reason(LogToolExit(status: 1), tool: "log show", timeout: 60) == "log show failed (1)")
    let long = DeviceLogs.reason(LogToolExit(status: 1, stderr: String(repeating: "x", count: 500)), tool: "t", timeout: 1)
    #expect(long.count < 230)
    #expect(DeviceLogs.isPermissionDenied(LogToolExit(status: 77)))
    #expect(DeviceLogs.isPermissionDenied(LogToolExit(status: 1, stderr: "log: Must be admin to run 'collect' command")))
    #expect(!DeviceLogs.isPermissionDenied(LogToolExit(status: 1, stderr: "other")))
    #expect(DeviceLogs.collectHint(udid: "DEV-ON", since: Date(timeIntervalSince1970: 100))
      == "sudo log collect --device-udid DEV-ON --start @100 --output <dir>/device.logarchive, "
      + "then relay logs --archive <dir>/device.logarchive --udid DEV-ON")
  }

  @Test func whyFollowEnded() {
    #expect(DeviceLogs.followFailure(state: nil, exit: LogToolExit(status: 0, stopped: .signal(SIGINT))) == nil)
    #expect(DeviceLogs.followFailure(state: nil, exit: LogToolExit(status: 0, stopped: .overlongLine))?.message.contains("longer") == true)
    #expect(DeviceLogs.followFailure(state: nil, exit: LogToolExit(status: 0))?.message.contains("ended by itself") == true)
    let mine = LogFailure(code: .logsUnavailable, message: "mine")
    #expect(DeviceLogs.followFailure(state: mine, exit: LogToolExit(status: 0, stopped: .consumer)) == mine)
    #expect(DeviceLogs.signalName(SIGTERM) == "SIGTERM")
    #expect(DeviceLogs.signalName(SIGHUP) == "SIGHUP")
    #expect(DeviceLogs.signalName(SIGUSR1) == "signal \(SIGUSR1)")
  }
}

struct LogTargetTests {
  @Test func udidReadsNoRunnerJSON() throws {
    let home = try temporaryHome()
    // Both variables set would be a usage error for a lookup; --udid does not look.
    let tools = fakeLogTools(home: home, environment: ["RELAY_SESSION": "a", "RELAY_RUNNER": "/x.json"])
    #expect(try LogTarget.resolve(LogTargetOptions(udid: "SIM-ON"), tools: tools) == LogTarget(udid: "SIM-ON"))
    #expect(throws: ArgumentError.self) { try LogTarget.resolve(LogTargetOptions(), tools: tools) }
  }

  @Test func aSessionGivesTheUDIDAndTheHostApp() throws {
    let home = try temporaryHome()
    let info = RunnerInfo(url: "http://127.0.0.1:8101/", token: "t", udid: "SIM-ON", name: "Test Sim", hostBundleID: "dev.example.Host", session: "a")
    try info.write(to: RelaySession.infoURL(name: "a", home: home))
    let tools = fakeLogTools(home: home)
    let target = try #require(try LogTarget.resolve(LogTargetOptions(session: "a"), tools: tools))
    #expect(target.udid == "SIM-ON")
    #expect(try target.bundleID("host") == "dev.example.Host")
    #expect(try target.bundleID("com.example.app") == "com.example.app")
    #expect(throws: LogFailure.self) { try LogTarget(udid: "X").bundleID("host") }
    #expect(throws: LogFailure.self) { try LogTarget(udid: "X", info: RunnerInfo(url: "u", token: "t", udid: "X")).bundleID("host") }
  }

  @Test func noRunnerIsExit3UnlessOptional() throws {
    let home = try temporaryHome()
    let tools = fakeLogTools(home: home)
    #expect(try LogTarget.resolve(LogTargetOptions(), tools: tools, optional: true) == nil)
    do {
      _ = try LogTarget.resolve(LogTargetOptions(session: "missing"), tools: tools, optional: true)
      Issue.record("should fail")
    } catch let failure as LogFailure {
      #expect(failure.code == .runnerUnavailable)
      #expect(failure.status == 3)
    }
    let broken = RelaySession.infoURL(name: "b", home: home)
    try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: broken)
    #expect(throws: LogFailure.self) { try LogTarget.resolve(LogTargetOptions(session: "b"), tools: tools) }
  }

  @Test func findsTheSimulatorOrTheDevice() throws {
    let tools = fakeLogTools(home: try temporaryHome())
    #expect(try LogTarget(udid: "sim-on").device(tools: tools).kind == .simulator)
    #expect(try LogTarget(udid: "DEV-ON").device(tools: tools).name == "Test Phone")
    #expect(throws: LogFailure.self) { try LogTarget(udid: "NOPE").device(tools: tools) }
    let device = try LogTarget(udid: "DEV-ON").device(tools: tools)
    #expect(LogTarget.json(device)["kind"] as? String == "device")
  }
}

struct DeviceLogsCommandTests {
  private let now = LogTime.parse("2026-11-11 09:25:00+0900")!

  private func options(_ udid: String, _ change: (inout LogsOptions) -> Void = { _ in }) -> LogsOptions {
    var options = LogsOptions()
    options.target.udid = udid
    change(&options)
    return options
  }

  @Test func readsTheLogOfABootedSimulator() throws {
    let output = CapturedOutput()
    let calls = Locked<[[String]]>([])
    let lines = [fakeLogLine("probe notice"), fakeLogLine("x", event: "activityCreateEvent"), Data(#"{"count":2,"finished":1}"#.utf8)]
    let tools = fakeLogTools(home: try temporaryHome(), output: output, stream: fakeStream(lines, calls: calls))
    #expect(DeviceLogs.run(options("SIM-ON"), tools: tools, now: now) == 0)
    let object = output.object
    #expect(object["ok"] as? Bool == true)
    #expect(object["backend"] as? String == "simctl")
    #expect(object["count"] as? Int == 1)
    #expect(object["skippedEvents"] as? Int == 1)
    #expect(object["filter"] is NSNull)
    let range = try #require(object["range"] as? [String: Any])
    #expect(range["requestedSince"] as? String == "2026-11-11T00:20:00Z")
    #expect(range["firstEntryAt"] as? String == "2026-11-11T00:20:48.096118Z")
    #expect((object["device"] as? [String: Any])?["udid"] as? String == "SIM-ON")
    #expect(calls.value.first?.prefix(5) == ["simctl", "spawn", "SIM-ON", "log", "show"])
  }

  @Test func keepsTheLinesOfTheApp() throws {
    let home = try temporaryHome()
    let app = try fakeApp(in: home)
    let output = CapturedOutput()
    let calls = Locked<[[String]]>([])
    let lines = [fakeLogLine("mine", uuid: "11121314-1516-1718-191A-1B1C1D1E1F20"), fakeLogLine("an earlier build")]
    let tools = fakeLogTools(home: home, output: output, xcrun: { args in
      #expect(args == ["simctl", "get_app_container", "SIM-ON", "com.example.probe", "app"])
      return app.path + "\n"
    }, stream: fakeStream(lines, calls: calls))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.bundleID = "com.example.probe" }, tools: tools, now: now) == 0)
    let object = output.object
    #expect((object["entries"] as? [[String: Any]])?.map { $0["message"] as? String } == ["mine"])
    #expect((object["filter"] as? [String: Any])?["executablePath"] as? String == app.appendingPathComponent("Probe").path)
    #expect((object["limitations"] as? [String])?.contains(DeviceLogs.bundleLimitation) == true)
    #expect(calls.value.first?.suffix(2) == ["--predicate", #"process == "Probe""#])
  }

  @Test func anAppThatIsNotThereIsLogAppUnavailable() throws {
    let home = try temporaryHome()
    let output = CapturedOutput()
    let missing = fakeLogTools(home: home, output: output, xcrun: { _ in throw ShellError(args: [], status: 2, output: "") })
    #expect(DeviceLogs.run(options("SIM-ON") { $0.bundleID = "com.example.none" }, tools: missing, now: now) == 1)
    #expect(output.object["code"] as? String == "log_app_unavailable")

    // An app without a readable executable.
    let app = home.appendingPathComponent("Empty.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Empty"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Info.plist"))
    let second = CapturedOutput()
    let empty = fakeLogTools(home: home, output: second, xcrun: { _ in app.path })
    #expect(DeviceLogs.run(options("SIM-ON") { $0.bundleID = "com.example.empty" }, tools: empty, now: now) == 1)
    #expect(second.object["code"] as? String == "log_app_unavailable")
  }

  @Test func aShutDownSimulatorOrAnUnknownUDIDIsDeviceUnavailable() throws {
    for udid in ["SIM-OFF", "NOPE", "DEV-OFF"] {
      let output = CapturedOutput()
      #expect(DeviceLogs.run(options(udid), tools: fakeLogTools(home: try temporaryHome(), output: output), now: now) == 1)
      #expect(output.object["code"] as? String == "device_unavailable", "\(udid)")
    }
  }

  @Test func aDeviceNeedsAnAdministrator() throws {
    let output = CapturedOutput()
    let tools = fakeLogTools(home: try temporaryHome(), output: output, run: { executable, args, _, _, _ in
      #expect(executable == "/usr/bin/log")
      #expect(args.prefix(3) == ["collect", "--device-udid", "DEV-ON"])
      return LogToolExit(status: 77, stderr: "log: Must be admin to run 'collect' command\n")
    })
    #expect(DeviceLogs.run(options("DEV-ON"), tools: tools, now: now) == 1)
    #expect(output.object["code"] as? String == "logs_permission_denied")
    #expect((output.object["hint"] as? String)?.hasPrefix("sudo log collect --device-udid DEV-ON --start @") == true)
  }

  @Test func aDeviceLogCollectedAsAnAdministratorIsRead() throws {
    let output = CapturedOutput()
    let tools = fakeLogTools(home: try temporaryHome(), output: output, stream: fakeStream([fakeLogLine("from the device")]))
    #expect(DeviceLogs.run(options("DEV-ON"), tools: tools, now: now) == 0)
    #expect(output.object["backend"] as? String == "log collect")
    #expect(output.object["count"] as? Int == 1)
    let failed = CapturedOutput()
    let failing = fakeLogTools(home: try temporaryHome(), output: failed, run: { _, _, _, _, _ in LogToolExit(status: 1, stderr: "no device") })
    #expect(DeviceLogs.run(options("DEV-ON"), tools: failing, now: now) == 1)
    #expect(failed.object["error"] as? String == "log collect failed (1): no device")
  }

  @Test func whatADeviceCannotDo() throws {
    for (change, code) in [({ (o: inout LogsOptions) in o.follow = true }, "logs_follow_unsupported"),
                           ({ (o: inout LogsOptions) in o.bundleID = "com.example.app" }, "logs_filter_unsupported")] {
      let output = CapturedOutput()
      #expect(DeviceLogs.run(options("DEV-ON", change), tools: fakeLogTools(home: try temporaryHome(), output: output), now: now) == 1)
      #expect(output.object["code"] as? String == code)
    }
  }

  @Test func readsAnArchive() throws {
    let home = try temporaryHome()
    let archive = home.appendingPathComponent("d.logarchive", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let output = CapturedOutput()
    let calls = Locked<[[String]]>([])
    let tools = fakeLogTools(home: home, output: output, stream: fakeStream([fakeLogLine("archived")], calls: calls))
    var options = LogsOptions()
    options.archive = "d.logarchive"
    #expect(DeviceLogs.run(options, tools: tools, now: now) == 0)
    #expect(output.object["backend"] as? String == "archive")
    #expect(output.object["device"] is NSNull)
    #expect(output.object["deviceVerified"] as? Bool == false)
    #expect((output.object["range"] as? [String: Any])?["requestedSince"] is NSNull)
    #expect(calls.value.first == ["show", "--archive", archive.path, "--style", "ndjson", "--info", "--debug"])

    let withUDID = CapturedOutput()
    options.target.udid = "DEV-ON"
    #expect(DeviceLogs.run(options, tools: fakeLogTools(home: home, output: withUDID, stream: fakeStream([])), now: now) == 0)
    #expect((withUDID.object["device"] as? [String: Any])?["udid"] as? String == "DEV-ON")

    let filtered = CapturedOutput()
    options.bundleID = "com.example.app"
    #expect(DeviceLogs.run(options, tools: fakeLogTools(home: home, output: filtered), now: now) == 1)
    #expect(filtered.object["code"] as? String == "logs_filter_unsupported")

    let missing = CapturedOutput()
    var none = LogsOptions()
    none.archive = "nope.logarchive"
    #expect(DeviceLogs.run(none, tools: fakeLogTools(home: home, output: missing), now: now) == 1)
    #expect(missing.object["code"] as? String == "logs_unavailable")
  }

  @Test func writesANewFileWithMinusO() throws {
    let home = try temporaryHome()
    let output = CapturedOutput()
    let tools = fakeLogTools(home: home, output: output, stream: fakeStream([fakeLogLine("saved")]))
    let options = options("SIM-ON") { $0.output = "app.json" }
    #expect(DeviceLogs.run(options, tools: tools, now: now) == 0)
    let file = home.appendingPathComponent("app.json")
    #expect(output.object["path"] as? String == file.path)
    #expect(output.object["entries"] == nil)
    let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(saved["count"] as? Int == 1)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    let again = CapturedOutput()
    #expect(DeviceLogs.run(options, tools: fakeLogTools(home: home, output: again, stream: fakeStream([])), now: now) == 1)
    #expect(again.object["code"] as? String == "logs_save_failed")
  }

  @Test func toolFailuresAndStops() throws {
    let cases: [(LogToolExit, Int32, String)] = [
      (LogToolExit(status: 64, stderr: "log: Bad predicate"), 1, "log show failed (64): log: Bad predicate"),
      (LogToolExit(status: 15, timedOut: true), 1, "log show timed out after 60 s"),
      (LogToolExit(status: 2, stopped: .signal(SIGINT)), 130, "stopped by SIGINT before log show ended"),
      (LogToolExit(status: 2, stopped: .overlongLine), 1, "log show printed a line longer than 1 MiB")
    ]
    for (exit, status, message) in cases {
      let output = CapturedOutput()
      let tools = fakeLogTools(home: try temporaryHome(), output: output, stream: fakeStream([], exit: exit))
      #expect(DeviceLogs.run(options("SIM-ON"), tools: tools, now: now) == status)
      #expect(output.object["error"] as? String == message)
    }
    let garbage = CapturedOutput()
    let tools = fakeLogTools(home: try temporaryHome(), output: garbage, stream: fakeStream([Data("garbage".utf8)]))
    #expect(DeviceLogs.run(options("SIM-ON"), tools: tools, now: now) == 1)
    #expect(garbage.object["code"] as? String == "logs_unavailable")
  }

  @Test func usageAndRunnerFailures() throws {
    let output = CapturedOutput()
    let home = try temporaryHome()
    #expect(DeviceLogs.run(options("SIM-ON") { $0.since = .at(now.addingTimeInterval(60)) }, tools: fakeLogTools(home: home, output: output),
                           now: now) == 2)
    #expect(output.lines.isEmpty)
    var session = LogsOptions()
    session.target.session = "missing"
    #expect(DeviceLogs.run(session, tools: fakeLogTools(home: home, output: output), now: now) == 3)
    #expect(output.object["code"] as? String == "runner_unavailable")
    #expect(DeviceLogs.run(LogsOptions(), tools: fakeLogTools(home: home, environment: ["RELAY_SESSION": "a", "RELAY_RUNNER": "/r"]),
                           now: now) == 2)
  }

  @Test func followPrintsNDJSONUntilASignal() throws {
    let output = CapturedOutput()
    let lines = [Data("Filtering the log data using \"x\"".utf8), Data(), fakeLogLine("one"), fakeLogLine("x", event: "activityCreateEvent"),
                 fakeLogLine("two")]
    let tools = fakeLogTools(home: try temporaryHome(), output: output,
                             stream: fakeStream(lines, exit: LogToolExit(status: 0, stopped: .signal(SIGTERM))))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true }, tools: tools, now: now) == 143)
    let objects = output.objects
    #expect(objects.map { $0["type"] as? String } == ["start", "log", "log", "end"])
    #expect(objects.last?["count"] as? Int == 2)
    #expect(objects.last?["reason"] as? String == "SIGTERM")
    #expect(objects[1]["message"] as? String == "one")
  }

  @Test func followEndsAtOnceWhenALineIsStuck() throws {
    // stream returned while a line was still being written: nothing more is written, and the status is the signal's.
    let output = CapturedOutput()
    let stuck = LogToolExit(status: SIGINT, stopped: .signal(SIGINT), deliveryAbandoned: true)
    let tools = fakeLogTools(home: try temporaryHome(), output: output, stream: fakeStream([fakeLogLine("one")], exit: stuck))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true }, tools: tools, now: now) == 130)
    #expect(output.objects.map { $0["type"] as? String } == ["start", "log"])
    let ended = LogToolExit(status: 0, deliveryAbandoned: true)
    let file = fakeLogTools(home: try temporaryHome(), output: CapturedOutput(), stream: fakeStream([], exit: ended))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true; $0.output = "s.ndjson" }, tools: file, now: now) == 1)
  }

  @Test func followWritesTheFileAndASummary() throws {
    let home = try temporaryHome()
    let output = CapturedOutput()
    let tools = fakeLogTools(home: home, output: output, stream: fakeStream([fakeLogLine("one")], exit: LogToolExit(status: 0, stopped: .signal(SIGINT))))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true; $0.output = "f.ndjson" }, tools: tools, now: now) == 130)
    #expect(output.objects.count == 1)
    #expect(output.object["ok"] as? Bool == true)
    #expect(output.object["count"] as? Int == 1)
    let file = try String(contentsOf: home.appendingPathComponent("f.ndjson"), encoding: .utf8)
    #expect(file.split(separator: "\n").count == 3)
    let again = CapturedOutput()
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true; $0.output = "f.ndjson" }, tools: fakeLogTools(home: home, output: again),
                           now: now) == 1)
    #expect(again.object["code"] as? String == "logs_save_failed")
  }

  @Test func followErrorsAfterTheStart() throws {
    // A line that is not a log line.
    let output = CapturedOutput()
    let tools = fakeLogTools(home: try temporaryHome(), output: output, stream: fakeStream([fakeLogLine("one"), Data("garbage".utf8)]))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true }, tools: tools, now: now) == 1)
    let error = try #require(output.objects.last)
    #expect(error["type"] as? String == "error")
    #expect(error["partial"] as? Bool == true)
    #expect(error["count"] as? Int == 1)

    // log stream ending by itself, with -o.
    let home = try temporaryHome()
    let ended = CapturedOutput()
    let endedTools = fakeLogTools(home: home, output: ended, stream: fakeStream([], exit: LogToolExit(status: 1, stderr: "gone")))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true; $0.output = "e.ndjson" }, tools: endedTools, now: now) == 1)
    #expect(ended.object["ok"] as? Bool == false)
    #expect(ended.object["partial"] as? Bool == true)

    // A closed stdout.
    let closed = fakeLogTools(home: try temporaryHome(), output: CapturedOutput(closed: true), stream: fakeStream([fakeLogLine("one")]))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true }, tools: closed, now: now) == 1)
  }

  @Test func followAfterTheStartStopsWhenStdoutCloses() throws {
    // Open for the start line, closed for the first log line.
    final class Once: Sendable {
      let writes = Locked(0)
      func write(_: Data) -> Bool { writes.withLock { $0 += 1; return $0 == 1 } }
    }
    let once = Once()
    var tools = fakeLogTools(home: try temporaryHome(), stream: fakeStream([fakeLogLine("one"), fakeLogLine("two")]))
    tools.write = { once.write($0) }
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true }, tools: tools, now: now) == 1)
    #expect(once.writes.value == 2)
  }

  @Test func followKeepsOnlyTheApp() throws {
    let home = try temporaryHome()
    let app = try fakeApp(in: home)
    let output = CapturedOutput()
    let lines = [fakeLogLine("mine", uuid: "11121314-1516-1718-191A-1B1C1D1E1F20"), fakeLogLine("not mine")]
    let tools = fakeLogTools(home: home, output: output, xcrun: { _ in app.path },
                             stream: fakeStream(lines, exit: LogToolExit(status: 0, stopped: .signal(SIGINT))))
    #expect(DeviceLogs.run(options("SIM-ON") { $0.follow = true; $0.bundleID = "com.example.probe" }, tools: tools, now: now) == 130)
    #expect(output.objects.filter { $0["type"] as? String == "log" }.map { $0["message"] as? String } == ["mine"])
  }

  @Test func theLiveToolsAndTheWorkDirectory() throws {
    let tools = LogTools.live
    #expect(tools.home == UserHome.url)
    var copy = tools
    copy.temporaryDirectory = try temporaryHome()
    let work = try copy.makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    #expect(try FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions] as? Int == 0o700)
    let output = CapturedOutput()
    copy.write = { output.write($0) }
    copy.writeLine(Data("a".utf8))
    copy.writeLine(Data("b\n".utf8))
    #expect(output.lines == ["a", "b"])
    #expect(LogFailure(code: .logsUnavailable, message: "m", hint: "h").body == CLIOutput.failureBody(.logsUnavailable, "m", extra: ["hint": "h"]))
  }
}
