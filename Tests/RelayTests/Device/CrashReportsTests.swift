import Darwin
import Foundation
@testable import Relay
import Testing

// relay crashes. UDIDs, names, paths, and reports are dummies; no simulator or device is used.

/// A `.ips` as a simulator app's crash writes it: a metadata line, then the report.
func fakeIPS(udid: String = "SIM-ON", bundleID: String = "com.example.probe", capture: String? = "2026-11-11 09:20:54.6059 +0900") -> Data {
  let header: [String: Any] = ["app_name": "Probe", "timestamp": "2026-11-11 09:20:59.00 +0900", "bundleID": bundleID, "bug_type": "309", "name": "Probe"]
  var body: [String: Any] = [
    "procName": "Probe",
    "procPath": "/Users/USER/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/X/Probe.app/Probe",
    "bundleInfo": ["CFBundleIdentifier": bundleID]
  ]
  body["captureTime"] = capture
  return try! JSONSerialization.data(withJSONObject: header) + Data("\n".utf8) + JSONSerialization.data(withJSONObject: body, options: .prettyPrinted)
}

let fakeDeviceFilesJSON = #"""
{"info":{"outcome":"success"},"result":{"deviceIdentifier":"x","domain":"systemCrashLogs","files":[
{"name":"Probe-2026-11-10-120000.ips","relativePath":"Probe-2026-11-10-120000.ips",
 "metadata":{"lastModDate":"2026-11-10T03:00:00.000Z","size":100},"resources":{"isDirectory":false,"isSymbolicLink":false}},
{"name":"Probe-2026-11-11-091500.ips","relativePath":"Probe-2026-11-11-091500.ips",
 "metadata":{"lastModDate":"2026-11-11T00:15:00.000Z","size":200},"resources":{"isDirectory":false,"isSymbolicLink":false}},
{"name":"Retired","relativePath":"Retired","metadata":{"lastModDate":"2026-11-11T00:16:00.000Z"},"resources":{"isDirectory":true}},
{"name":"Other-2026-11-11-091600.ips","relativePath":"Retired/Other-2026-11-11-091600.ips",
 "metadata":{"lastModDate":"2026-11-11T00:16:00.000Z","size":300},"resources":{"isDirectory":false}},
{"name":"notes.txt","relativePath":"notes.txt","metadata":{"lastModDate":"2026-11-11T00:17:00.000Z"},"resources":{}},
{"name":"link.ips","relativePath":"link.ips","metadata":{},"resources":{"isSymbolicLink":true}}]}}
"""#

struct CrashReportParsingTests {
  @Test func aSimulatorReportIsMatchedByTheUDIDInItsPath() throws {
    let modified = Date(timeIntervalSince1970: 1)
    guard case .report(let report) = CrashReports.simulatorReport(name: "Probe-1.ips", data: fakeIPS(udid: "sim-on"), modified: modified, udid: "SIM-ON") else {
      Issue.record("not matched")
      return
    }
    #expect(report.process == "Probe")
    #expect(report.bundleID == "com.example.probe")
    #expect(report.bundleIDVerified)
    #expect(report.occurredAt.map { LogTime.string($0) } == "2026-11-11T00:20:54.605900Z")
    #expect(report.timeBasis == "captured")
    #expect(report.modifiedAt == modified)
    #expect(CrashReports.simulatorReport(name: "a.ips", data: fakeIPS(udid: "SIM-OTHER"), modified: nil, udid: "SIM-ON") == .elsewhere)
    #expect(CrashReports.simulatorReport(name: "a.ips", data: Data("not json\n{}".utf8), modified: nil, udid: "SIM-ON") == .unreadable)
    #expect(CrashReports.simulatorReport(name: "a.ips", data: Data("{}".utf8), modified: nil, udid: "SIM-ON") == .unreadable)
    #expect(CrashReports.simulatorReport(name: "a.ips", data: Data("{}\n{}".utf8), modified: nil, udid: "SIM-ON") == .unreadable)
    // Without captureTime, the metadata's timestamp.
    guard case .report(let late) = CrashReports.simulatorReport(name: "b.ips", data: fakeIPS(capture: nil), modified: nil, udid: "SIM-ON") else {
      Issue.record("not matched")
      return
    }
    #expect(late.occurredAt.map { LogTime.string($0) } == "2026-11-11T00:20:59Z")
  }

  @Test func aDeviceListHasOnlyTheIPSFiles() throws {
    let reports = try CrashReports.deviceReports(json: Data(fakeDeviceFilesJSON.utf8))
    #expect(reports.map(\.relativePath) == ["Probe-2026-11-10-120000.ips", "Probe-2026-11-11-091500.ips", "Retired/Other-2026-11-11-091600.ips"])
    let first = reports[0]
    #expect(first.processHint == "Probe")
    #expect(first.bundleID == nil)
    #expect(!first.bundleIDVerified)
    #expect(first.timeBasis == "modified")
    #expect(first.size == 100)
    #expect(first.modifiedAt.map { LogTime.string($0) } == "2026-11-10T03:00:00Z")
    let json = first.json()
    #expect(json["process"] is NSNull)
    #expect(json["path"] == nil)
    #expect(json["sourcePath"] == nil)
    #expect(throws: (any Error).self) { try CrashReports.deviceReports(json: Data("{}".utf8)) }
  }

  @Test func processHints() {
    #expect(CrashReports.processHint(name: "Probe-2026-11-11-092059.ips") == "Probe")
    #expect(CrashReports.processHint(name: "My-App-2026-11-11-092059.000.ips") == "My-App")
    #expect(CrashReports.processHint(name: "-2026-11-11-092059.ips") == nil)
    #expect(CrashReports.processHint(name: "JetsamEvent.ips") == nil)
  }

  @Test func selectsByTimeOrName() throws {
    let reports = try CrashReports.deviceReports(json: Data(fakeDeviceFilesJSON.utf8))
    let since = LogTime.parse("2026-11-11T00:00:00Z")!
    #expect(CrashReports.select(reports, since: since, name: nil).map(\.name) == ["Probe-2026-11-11-091500.ips", "Other-2026-11-11-091600.ips"])
    // A name is chosen whatever its time.
    #expect(CrashReports.select(reports, since: since, name: "Probe-2026-11-10-120000.ips").count == 1)
    #expect(CrashReports.select(reports, since: since, name: "Other-2026-11-11-091600.ips").isEmpty)
  }

  @Test func savesWithoutReplacing() throws {
    let directory = try temporaryHome()
    let saved = try CrashReports.saveNew(Data("a".utf8), name: "a.ips", in: directory)
    #expect(try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int == 0o600)
    #expect(throws: SetupError.self) { try CrashReports.saveNew(Data("b".utf8), name: "a.ips", in: directory) }
    #expect(try String(contentsOf: saved, encoding: .utf8) == "a")

    let source = directory.appendingPathComponent("source")
    try Data("c".utf8).write(to: source)
    let moved = try CrashReports.moveNew(source, name: "c.ips", in: directory)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? Int == 0o600)
    try Data("d".utf8).write(to: source)
    #expect(throws: SetupError.self) { try CrashReports.moveNew(source, name: "c.ips", in: directory) }
  }

  @Test func findsWhatDevicectlCopied() throws {
    let directory = try temporaryHome()
    #expect(CrashReports.copiedFile(at: directory.appendingPathComponent("none")) == nil)
    let file = directory.appendingPathComponent("f.ips")
    try Data("x".utf8).write(to: file)
    #expect(CrashReports.copiedFile(at: file) == file)
    let folder = directory.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(CrashReports.copiedFile(at: folder) == nil)
    try Data("y".utf8).write(to: folder.appendingPathComponent("inner.ips"))
    #expect(CrashReports.copiedFile(at: folder)?.lastPathComponent == "inner.ips")
    try Data("z".utf8).write(to: folder.appendingPathComponent("second.ips"))
    #expect(CrashReports.copiedFile(at: folder) == nil)
  }
}

struct CrashReportsCommandTests {
  private let now = LogTime.parse("2026-11-11 09:30:00+0900")!

  /// A home whose DiagnosticReports has this simulator's report, another simulator's, an unreadable one,
  /// and an old one.
  private func homeWithReports() throws -> URL {
    let home = try temporaryHome()
    let reports = CrashReports.diagnosticReports(home: home)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    try fakeIPS().write(to: reports.appendingPathComponent("Probe-2026-11-11-092059.ips"))
    try fakeIPS(bundleID: "com.example.other").write(to: reports.appendingPathComponent("Other-2026-11-11-092100.ips"))
    try fakeIPS(udid: "SIM-ELSE").write(to: reports.appendingPathComponent("Probe-2026-11-11-092200.ips"))
    try Data("garbage".utf8).write(to: reports.appendingPathComponent("Broken-2026-11-11-092300.ips"))
    try Data("not a report".utf8).write(to: reports.appendingPathComponent("notes.txt"))
    let old = reports.appendingPathComponent("Old-2026-01-01-000000.ips")
    try fakeIPS(capture: "2026-01-01 00:00:00 +0900").write(to: old)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_767_193_200)], ofItemAtPath: old.path)
    return home
  }

  private func options(_ udid: String, _ change: (inout CrashesOptions) -> Void = { _ in }) -> CrashesOptions {
    var options = CrashesOptions()
    options.target.udid = udid
    change(&options)
    return options
  }

  @Test func listsTheReportsOfTheSimulator() throws {
    let home = try homeWithReports()
    let output = CapturedOutput()
    // The files were written now, and their crash times are this morning: since 1 day from now covers them.
    let tools = fakeLogTools(home: home, output: output)
    #expect(CrashReports.run(options("SIM-ON"), tools: tools, now: now) == 0)
    let object = output.object
    #expect(object["backend"] as? String == "DiagnosticReports")
    #expect(object["unreadable"] as? Int == 1)
    let reports = try #require(object["reports"] as? [[String: Any]])
    #expect(Set(reports.compactMap { $0["name"] as? String }) == ["Probe-2026-11-11-092059.ips", "Other-2026-11-11-092100.ips"])
    #expect(reports.allSatisfy { ($0["sourcePath"] as? String)?.hasPrefix(CrashReports.diagnosticReports(home: home).path) == true })

    let one = CapturedOutput()
    #expect(CrashReports.run(options("SIM-ON") { $0.bundleID = "com.example.probe" }, tools: fakeLogTools(home: home, output: one), now: now) == 0)
    #expect((one.object["reports"] as? [[String: Any]])?.count == 1)
    #expect((one.object["filter"] as? [String: Any])?["bundleID"] as? String == "com.example.probe")

    let named = CapturedOutput()
    #expect(CrashReports.run(options("SIM-ON") { $0.name = "Old-2026-01-01-000000.ips" }, tools: fakeLogTools(home: home, output: named),
                             now: now) == 0)
    #expect(named.object["count"] as? Int == 1)

    let missing = CapturedOutput()
    #expect(CrashReports.run(options("SIM-ON") { $0.name = "Nope.ips" }, tools: fakeLogTools(home: home, output: missing), now: now) == 1)
    #expect(missing.object["code"] as? String == "crashes_unavailable")
  }

  @Test func savesTheSimulatorReports() throws {
    let home = try homeWithReports()
    let out = home.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let output = CapturedOutput()
    let change: (inout CrashesOptions) -> Void = { $0.output = "out"; $0.bundleID = "com.example.probe" }
    #expect(CrashReports.run(options("SIM-ON", change), tools: fakeLogTools(home: home, output: output), now: now) == 0)
    let path = try #require((output.object["reports"] as? [[String: Any]])?.first?["path"] as? String)
    #expect(path == out.appendingPathComponent("Probe-2026-11-11-092059.ips").path)
    #expect(FileManager.default.contents(atPath: path)
      == FileManager.default.contents(atPath: CrashReports.diagnosticReports(home: home).appendingPathComponent("Probe-2026-11-11-092059.ips").path))

    // Again: the file is there, and is not replaced.
    let again = CapturedOutput()
    #expect(CrashReports.run(options("SIM-ON", change), tools: fakeLogTools(home: home, output: again), now: now) == 1)
    #expect(again.object["code"] as? String == "crashes_save_failed")
    #expect(again.object["ok"] as? Bool == false)
    #expect(((again.object["reports"] as? [[String: Any]])?.first?["error"] as? String)?.contains("already exists") == true)

    let noDirectory = CapturedOutput()
    #expect(CrashReports.run(options("SIM-ON") { $0.output = "missing" }, tools: fakeLogTools(home: home, output: noDirectory), now: now) == 1)
    #expect(noDirectory.object["code"] as? String == "crashes_save_failed")
  }

  @Test func listsTheReportsOfADevice() throws {
    let output = CapturedOutput()
    let tools = fakeLogTools(home: try temporaryHome(), output: output, devicectl: { args in
      #expect(args == ["device", "info", "files", "--device", "DEV-ON", "--domain-type", "systemCrashLogs"])
      return Data(fakeDeviceFilesJSON.utf8)
    })
    #expect(CrashReports.run(options("DEV-ON") { $0.since = .ago(3600) }, tools: tools, now: now) == 0)
    let object = output.object
    #expect(object["backend"] as? String == "devicectl")
    #expect(object["count"] as? Int == 2)
    #expect((object["limitations"] as? [String]) == CrashReports.deviceLimitations)
  }

  @Test func savesTheOneADeviceReportNames() throws {
    let home = try temporaryHome()
    let out = home.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let output = CapturedOutput()
    let tools = fakeLogTools(home: home, output: output, devicectl: { args in
      if args.prefix(3) == ["device", "copy", "from"] {
        let destination = try #require(args.firstIndex(of: "--destination").map { args[$0 + 1] })
        #expect(args.contains("Retired/Other-2026-11-11-091600.ips"))
        try Data("copied".utf8).write(to: URL(fileURLWithPath: destination))
        return Data("{}".utf8)
      }
      return Data(fakeDeviceFilesJSON.utf8)
    })
    #expect(CrashReports.run(options("DEV-ON") { $0.name = "Retired/Other-2026-11-11-091600.ips"; $0.output = "out" }, tools: tools, now: now) == 0)
    let saved = out.appendingPathComponent("Other-2026-11-11-091600.ips")
    #expect(FileManager.default.contents(atPath: saved.path) == Data("copied".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Other-2026-11-11-091600.ips"])

    // devicectl copying nothing.
    let nothing = CapturedOutput()
    let empty = fakeLogTools(home: home, output: nothing, devicectl: { args in
      args.prefix(3) == ["device", "copy", "from"] ? Data("{}".utf8) : Data(fakeDeviceFilesJSON.utf8)
    })
    #expect(CrashReports.run(options("DEV-ON") { $0.name = "Probe-2026-11-10-120000.ips"; $0.output = "out" }, tools: empty, now: now) == 1)
    #expect(nothing.object["code"] as? String == "crashes_save_failed")
  }

  @Test func whatADeviceCannotDo() throws {
    let home = try temporaryHome()
    let filter = CapturedOutput()
    #expect(CrashReports.run(options("DEV-ON") { $0.bundleID = "com.example.probe" }, tools: fakeLogTools(home: home, output: filter), now: now) == 1)
    #expect(filter.object["code"] as? String == "crash_filter_unsupported")
    try FileManager.default.createDirectory(at: home.appendingPathComponent("out"), withIntermediateDirectories: true)
    #expect(CrashReports.run(options("DEV-ON") { $0.output = "out" }, tools: fakeLogTools(home: home), now: now) == 2)
    let away = CapturedOutput()
    #expect(CrashReports.run(options("DEV-OFF"), tools: fakeLogTools(home: home, output: away), now: now) == 1)
    #expect(away.object["code"] as? String == "device_unavailable")
    let failing = CapturedOutput()
    let tools = fakeLogTools(home: home, output: failing, devicectl: { _ in throw SetupError(description: "no tunnel") })
    #expect(CrashReports.run(options("DEV-ON"), tools: tools, now: now) == 1)
    #expect(failing.object["code"] as? String == "crashes_unavailable")
  }

  @Test func usageAndRunnerFailures() throws {
    let home = try temporaryHome()
    #expect(CrashReports.run(options("SIM-ON") { $0.since = .at(now.addingTimeInterval(1)) }, tools: fakeLogTools(home: home), now: now) == 2)
    let output = CapturedOutput()
    var session = CrashesOptions()
    session.target.session = "missing"
    #expect(CrashReports.run(session, tools: fakeLogTools(home: home, output: output), now: now) == 3)
    #expect(output.object["code"] as? String == "runner_unavailable")
    let unknown = CapturedOutput()
    #expect(CrashReports.run(options("NOPE"), tools: fakeLogTools(home: home, output: unknown), now: now) == 1)
    #expect(unknown.object["code"] as? String == "device_unavailable")
  }
}
