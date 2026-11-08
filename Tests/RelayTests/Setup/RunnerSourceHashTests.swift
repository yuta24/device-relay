import Foundation
@testable import Relay
import Testing

struct RunnerSourceHashTests {
  /// A runner root with `Runner/` (including per-user and hidden files that don't count) and shared sources.
  private struct Root {
    let url: URL

    init() throws {
      url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let pbxproj = """
      A /* RunnerAuth.swift */ = {isa = PBXFileReference; path = ../Sources/Relay/Shared/RunnerAuth.swift; sourceTree = "<group>"; };
      B /* RelayRunnerUITests.swift */ = {isa = PBXFileReference; path = RelayRunnerUITests/RelayRunnerUITests.swift; sourceTree = "<group>"; };
      """
      try write(pbxproj, to: "Runner/RelayRunner.xcodeproj/project.pbxproj")
      try write("<Scheme/>", to: "Runner/RelayRunner.xcodeproj/xcshareddata/xcschemes/RelayRunner.xcscheme")
      try write("tests", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")
      try write("plist", to: "Runner/RelayRunnerUITests/Info.plist")
      try write("auth", to: "Sources/Relay/Shared/RunnerAuth.swift")
      try write("cli", to: "Sources/Relay/main.swift")
      try write("per user", to: "Runner/RelayRunner.xcodeproj/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate")
      try write("finder", to: "Runner/.DS_Store")
    }

    func write(_ text: String, to path: String) throws {
      let file = url.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() {
      try? FileManager.default.removeItem(at: url)
    }
  }

  @Test func coversRunnerAndTheSharedSourcesItCompilesOnly() throws {
    let root = try Root()
    defer { root.remove() }
    #expect(try RunnerSourceHash.files(root: root.url) == [
      "Runner/RelayRunner.xcodeproj/project.pbxproj",
      "Runner/RelayRunner.xcodeproj/xcshareddata/xcschemes/RelayRunner.xcscheme",
      "Runner/RelayRunnerUITests/Info.plist",
      "Runner/RelayRunnerUITests/RelayRunnerUITests.swift",
      "Sources/Relay/Shared/RunnerAuth.swift"
    ])
  }

  @Test func changesWithAnyCoveredFileOnly() throws {
    let root = try Root()
    defer { root.remove() }
    let original = try RunnerSourceHash.compute(root: root.url)
    #expect(original.count == 64)
    #expect(try RunnerSourceHash.compute(root: root.url) == original)

    // Not built from: the CLI's own sources, per-user Xcode state, hidden files.
    try root.write("cli changed", to: "Sources/Relay/main.swift")
    try root.write("moved a window", to: "Runner/RelayRunner.xcodeproj/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate")
    try root.write("finder again", to: "Runner/.DS_Store")
    #expect(try RunnerSourceHash.compute(root: root.url) == original)

    for (path, text) in [("Runner/RelayRunnerUITests/RelayRunnerUITests.swift", "tests // a comment"),
                         ("Sources/Relay/Shared/RunnerAuth.swift", "auth "),
                         ("Runner/RelayRunner.xcodeproj/xcshareddata/xcschemes/RelayRunner.xcscheme", "<Scheme a=\"1\"/>")] {
      let before = try String(contentsOf: root.url.appendingPathComponent(path), encoding: .utf8)
      try root.write(text, to: path)
      #expect(try RunnerSourceHash.compute(root: root.url) != original, "\(path)")
      try root.write(before, to: path)
      #expect(try RunnerSourceHash.compute(root: root.url) == original, "\(path)")
    }

    // A new file under Runner/ counts too.
    try root.write("", to: "Runner/RelayRunnerUITests/New.swift")
    #expect(try RunnerSourceHash.compute(root: root.url) != original)
  }

  @Test func doesNotDependOnTheOrderFilesAreListedIn() {
    let a = (path: "Runner/a.swift", contents: Data("a".utf8))
    let b = (path: "Runner/b.swift", contents: Data("b".utf8))
    let c = (path: "Sources/Relay/Shared/c.swift", contents: Data("c".utf8))
    let hash = RunnerSourceHash.digest([a, b, c])
    #expect(RunnerSourceHash.digest([c, a, b]) == hash)
    #expect(RunnerSourceHash.digest([b, c, a]) == hash)
  }

  @Test func tellsNamesAndContentsApart() {
    // The same bytes split differently between names and contents, or between files.
    let joined = RunnerSourceHash.digest([(path: "ab", contents: Data("c".utf8))])
    #expect(RunnerSourceHash.digest([(path: "a", contents: Data("bc".utf8))]) != joined)
    #expect(RunnerSourceHash.digest([(path: "x", contents: Data("ab".utf8)), (path: "y", contents: Data())])
      != RunnerSourceHash.digest([(path: "x", contents: Data("a".utf8)), (path: "y", contents: Data("b".utf8))]))
    // Renaming a file changes the hash.
    #expect(RunnerSourceHash.digest([(path: "a", contents: Data("c".utf8))]) != RunnerSourceHash.digest([(path: "b", contents: Data("c".utf8))]))
    #expect(RunnerSourceHash.digest([]) != RunnerSourceHash.digest([(path: "a", contents: Data())]))
  }

  /// The real checkout: fast enough to run on every relay start, and covering the shared sources the project names.
  @Test func hashesThisCheckoutQuickly() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let files = try RunnerSourceHash.files(root: root)
    #expect(files.contains("Runner/RelayRunnerUITests/RelayRunnerUITests.swift"))
    #expect(files.contains("Runner/RelayRunnerUITests/Info.plist"))
    #expect(files.contains("Sources/Relay/Shared/RunnerAuth.swift"))
    #expect(!files.contains("Sources/Relay/main.swift"))
    let start = Date()
    _ = try RunnerSourceHash.compute(root: root)
    #expect(Date().timeIntervalSince(start) < 1)
  }

  /// `Sources/Relay/Shared/` holds exactly the CLI sources the Runner project compiles: moving a file in or out
  /// of it without updating the project (or the other way round) fails here.
  @Test func sharedDirectoryMatchesTheProjectReferences() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pbxproj = try String(contentsOf: root.appendingPathComponent("Runner/RelayRunner.xcodeproj/project.pbxproj"), encoding: .utf8)
    let shared = "Sources/Relay/Shared"
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(shared).path)
      .filter { $0.hasSuffix(".swift") }
      .map { "\(shared)/\($0)" }
    #expect(!files.isEmpty)
    #expect(CheckoutRunnerSource.referencedFiles(pbxproj: pbxproj).sorted() == files.sorted())
  }

  @Test func failsWithoutTheProject() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(throws: (any Error).self) { try RunnerSourceHash.compute(root: missing) }
  }
}

struct RunnerBuildPlanTests {
  private let xctestrun = URL(fileURLWithPath: "/build/DerivedData-sim/Build/Products/RelayRunner_iphonesimulator27.2-arm64.xctestrun")
  private let hash = String(repeating: "a", count: 64)
  private let otherHash = String(repeating: "b", count: 64)
  private let prefix = "dev.devicerelay.local"

  private func decide(rebuild: Bool = false, selection: XCTestRunSelection.Reuse? = nil, stamp: RunnerBuildStamp?) -> RunnerBuildPlan {
    RunnerBuildPlan.decide(rebuild: rebuild, selection: selection ?? .reuse(xctestrun), platform: "iphonesimulator", sdkVersion: "27.2",
                           stamp: stamp, sourceHash: hash, bundleIDPrefix: prefix, relayVersion: "0.2.0")
  }

  @Test func reusesABuildOfTheSameSourcesAndRelay() {
    #expect(decide(stamp: RunnerBuildStamp(sourceHash: hash, relayVersion: "0.2.0", bundleIDPrefix: "dev.devicerelay.local")) == .reuse(xctestrun))
  }

  @Test func rebuildsWhenTheSourcesChanged() {
    guard case .build(let reason?) = decide(stamp: RunnerBuildStamp(sourceHash: otherHash, relayVersion: "0.2.0", bundleIDPrefix: "dev.devicerelay.local")) else {
      Issue.record("expected a build with a reason")
      return
    }
    #expect(reason.contains("runner sources changed"))
    #expect(reason.contains("bbbbbbbbbbbb -> aaaaaaaaaaaa"))
  }

  /// A build from before the stamp may be from any sources, and is the case relay could not tell before.
  @Test func rebuildsABuildWithoutARecord() {
    guard case .build(let reason?) = decide(stamp: nil) else {
      Issue.record("expected a build with a reason")
      return
    }
    #expect(reason.contains("no record"))
  }

  @Test func rebuildsABuildOfAnotherRelay() {
    guard case .build(let reason?) = decide(stamp: RunnerBuildStamp(sourceHash: hash, relayVersion: "0.1.0", bundleIDPrefix: "dev.devicerelay.local")) else {
      Issue.record("expected a build with a reason")
      return
    }
    #expect(reason.contains("relay 0.1.0"))
  }

  @Test func theSDKCheckAndRebuildComeFirst() {
    let stamp = RunnerBuildStamp(sourceHash: hash, relayVersion: "0.2.0", bundleIDPrefix: "dev.devicerelay.local")
    #expect(decide(rebuild: true, stamp: stamp) == .build(reason: nil))
    #expect(decide(selection: XCTestRunSelection.Reuse.none, stamp: stamp) == .build(reason: nil))
    guard case .build(let reason?) = decide(selection: .otherSDK(xctestrun), stamp: stamp) else {
      Issue.record("expected a build with a reason")
      return
    }
    #expect(reason.contains("is not for this Xcode's iphonesimulator SDK 27.2"))
  }

  @Test func stampRoundTripsNextToTheXCTestRun() throws {
    let derivedData = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: derivedData) }
    #expect(RunnerBuildStamp.read(derivedData: derivedData) == nil)
    let stamp = RunnerBuildStamp(sourceHash: hash, relayVersion: "0.2.0", bundleIDPrefix: "dev.devicerelay.local")
    try stamp.write(derivedData: derivedData)
    #expect(RunnerBuildStamp.url(derivedData: derivedData).deletingLastPathComponent().path.hasSuffix("Build/Products"))
    #expect(RunnerBuildStamp.read(derivedData: derivedData) == stamp)
    RunnerBuildStamp.remove(derivedData: derivedData)
    #expect(RunnerBuildStamp.read(derivedData: derivedData) == nil)
  }

  @Test func buildArgumentsCarryTheVersionIntoTheBuild() {
    let args = RunnerLauncher.buildArguments(projectURL: URL(fileURLWithPath: "/r/Runner/RelayRunner.xcodeproj"), destination: "id=SIM",
                                             derivedData: URL(fileURLWithPath: "/d"), teamID: nil, sourceHash: hash,
                                             bundleIDPrefix: "dev.devicerelay.local")
    #expect(args.contains("RELAY_RUNNER_SOURCE_HASH=\(hash)"))
    #expect(args.contains("RELAY_RUNNER_VERSION=\(RelayVersion.current)"))
  }

  /// The UI test bundle's Info.plist expands the settings relay passes, which the runner reads back.
  @Test func runnerInfoPlistExpandsTheBuildSettings() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Runner/RelayRunnerUITests/Info.plist"))
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    #expect(plist["RelayRunnerSourceHash"] == "$(\(RunnerBuildVersion.sourceHashSetting))")
    #expect(plist["RelayRunnerVersion"] == "$(\(RunnerBuildVersion.versionSetting))")
    let pbxproj = try String(contentsOf: root.appendingPathComponent("Runner/RelayRunner.xcodeproj/project.pbxproj"), encoding: .utf8)
    #expect(pbxproj.components(separatedBy: "INFOPLIST_FILE = RelayRunnerUITests/Info.plist;").count == 3)
  }
}

struct RunnerBuildVersionTests {
  private let hash = String(repeating: "a", count: 64)

  @Test func parsesTheRunnerObjectOfPingAndHealth() {
    let body = Data(#"{"ok":true,"busy":false,"busyForMs":null,"runner":{"version":"0.2.0","sourceHash":"\#(hash)"}}"#.utf8)
    #expect(RunnerBuildVersion.parse(responseBody: body) == RunnerBuildVersion(version: "0.2.0", sourceHash: hash))
    // A build without relay's settings reports nulls (or empty strings).
    #expect(RunnerBuildVersion.parse(responseBody: Data(#"{"runner":{"version":null,"sourceHash":""}}"#.utf8))
      == RunnerBuildVersion(version: nil, sourceHash: nil))
    // An old runner has no runner object.
    #expect(RunnerBuildVersion.parse(responseBody: Data(#"{"ok":true,"busy":false}"#.utf8)) == nil)
    #expect(RunnerBuildVersion.parse(responseBody: Data("not json".utf8)) == nil)
  }

  @Test func matchesOnlyTheExpectedSources() {
    #expect(RunnerBuildVersion.mismatch(reported: RunnerBuildVersion(version: "0.2.0", sourceHash: hash), expectedSourceHash: hash) == nil)
    let other = RunnerBuildVersion.mismatch(reported: RunnerBuildVersion(version: "0.2.0", sourceHash: String(repeating: "b", count: 64)),
                                            expectedSourceHash: hash)
    #expect(other?.contains("bbbbbbbbbbbb") == true && other?.contains("aaaaaaaaaaaa") == true)
    #expect(RunnerBuildVersion.mismatch(reported: nil, expectedSourceHash: hash)?.contains("does not report") == true)
    #expect(RunnerBuildVersion.mismatch(reported: RunnerBuildVersion(version: nil, sourceHash: nil), expectedSourceHash: hash) != nil)
  }

  @Test func summarizesWithAShortHash() {
    #expect(RunnerBuildVersion(version: "0.2.0", sourceHash: hash).summary == "0.2.0 (sources aaaaaaaaaaaa)")
    #expect(RunnerBuildVersion(version: nil, sourceHash: nil).summary == "unknown version (sources unknown)")
  }

  /// runner.json from an older relay has no `runner`, and still reads.
  @Test func runnerInfoKeepsTheExpectedBuild() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/runner.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM",
                          runner: RunnerBuildVersion(version: "0.2.0", sourceHash: hash))
    try info.write(to: url)
    #expect(try RunnerInfo.read(from: url) == info)
    try Data(#"{"url":"http://127.0.0.1:8100/","token":"t","udid":"SIM"}"#.utf8).write(to: url)
    #expect(try RunnerInfo.read(from: url).runner == nil)
  }

  @Test func statusShowsTheReportedBuildAndAMismatch() {
    let expected = RunnerBuildVersion(version: "0.2.0", sourceHash: hash)
    let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", runner: expected)
    func report(_ ping: RunnerPing, _ runner: RunnerBuildVersion?, info: RunnerInfo = info) -> RunnerStatus.Report {
      RunnerStatus.Report(infoURL: URL(fileURLWithPath: "/r.json"), info: info, processRunning: true, ping: ping, runner: runner)
    }
    let alive = RunnerPing.alive(busy: false, busyForMs: nil)
    #expect(RunnerStatus.runnerSummary(report(alive, expected)) == "0.2.0 (sources aaaaaaaaaaaa)")
    #expect(RunnerStatus.text(report(alive, expected)).contains("runner:      0.2.0 (sources aaaaaaaaaaaa)"))
    let stale = RunnerStatus.runnerSummary(report(alive, RunnerBuildVersion(version: "0.2.0", sourceHash: String(repeating: "b", count: 64))))
    #expect(stale?.contains("but relay built aaaaaaaaaaaa") == true)
    // An old runner, or an old runner.json: nothing breaks.
    #expect(RunnerStatus.runnerSummary(report(alive, nil))?.hasPrefix("not reported") == true)
    let oldInfo = RunnerInfo(url: info.url, token: "t", udid: "SIM")
    #expect(RunnerStatus.runnerSummary(report(alive, expected, info: oldInfo)) == "0.2.0 (sources aaaaaaaaaaaa)")
    #expect(RunnerStatus.runnerSummary(report(.unreachable("refused"), nil, info: oldInfo)) == nil)
    #expect(RunnerStatus.runnerSummary(report(.unreachable("refused"), nil)) == "0.2.0 (sources aaaaaaaaaaaa), from runner.json")

    let object = try? JSONSerialization.jsonObject(with: RunnerStatus.json(report(alive, nil))) as? [String: Any]
    #expect(object?["runner"] is NSNull)
    #expect((object?["expectedRunner"] as? [String: Any])?["sourceHash"] as? String == hash)
  }
}
