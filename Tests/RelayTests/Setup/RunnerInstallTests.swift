import Foundation
@testable import Relay
import Testing

struct RunnerInstallTests {
  private static let pbxproj = """
  A /* RunnerAuth.swift */ = {isa = PBXFileReference; path = ../Sources/Relay/Shared/RunnerAuth.swift; sourceTree = "<group>"; };
  B /* Shared.swift */ = {isa = PBXFileReference; path = "../Sources/Relay/Shared/Shared.swift"; sourceTree = "<group>"; };
  C /* RelayRunnerUITests.swift */ = {isa = PBXFileReference; path = RelayRunnerUITests.swift; sourceTree = "<group>"; };
  D = {isa = PBXFileReference; path = ../Sources/Relay/Shared/RunnerAuth.swift; sourceTree = "<group>"; };
  """

  /// <root>/checkout (a git checkout: it has `.git`) with Runner/ and the shared sources, and <root>/home.
  private struct Tree {
    let root: URL
    var checkout: URL { root.appendingPathComponent("checkout") }
    var home: URL { root.appendingPathComponent("home") }
    var installed: URL { RunnerProject.installedRoot(home: home) }

    init() throws {
      root = try temporaryDirectory()
      let project = checkout.appendingPathComponent(RunnerProject.projectPath)
      try FileManager.default.createDirectory(at: project.appendingPathComponent("xcuserdata"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
      try RunnerInstallTests.pbxproj.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
      try write("test", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")
      try write("auth", to: "Sources/Relay/Shared/RunnerAuth.swift")
      try write("shared", to: "Sources/Relay/Shared/Shared.swift")
      try write("cli", to: "Sources/Relay/main.swift")
    }

    func write(_ text: String, to path: String) throws {
      let url = checkout.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func installedText(_ path: String) -> String? {
      try? String(contentsOf: installed.appendingPathComponent(path), encoding: .utf8)
    }
  }

  private func source(_ tree: Tree, commit: String = String(repeating: "a", count: 40)) -> CheckoutRunnerSource {
    var commands = FakeHost().commands
    commands.run = { executable, args, _ in
      guard executable == "/usr/bin/git", args.suffix(2) == ["rev-parse", "HEAD"] else { throw ShellError(args: args, status: 1, output: "") }
      return commit + "\n"
    }
    return CheckoutRunnerSource(root: tree.checkout, commands: commands)
  }

  @Test func findsTheSharedSourcesTheProjectCompiles() {
    #expect(CheckoutRunnerSource.referencedFiles(pbxproj: Self.pbxproj)
      == ["Sources/Relay/Shared/RunnerAuth.swift", "Sources/Relay/Shared/Shared.swift"])
  }

  @Test func copiesTheRunnerAndRecordsTheVersion() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let build = RunnerProject.buildDirectory(root: tree.installed, home: tree.home)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    let record = try RunnerInstaller.install(from: source(tree), home: tree.home, now: Date(timeIntervalSince1970: 0))
    #expect(record == RunnerInstallRecord(relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40),
                                          source: tree.checkout.path, installedAt: "1970-01-01T00:00:00Z"))
    #expect(RunnerInstallRecord.read(root: tree.installed) == record)
    #expect(RunnerProject.contains(tree.installed))
    #expect(tree.installedText("Runner/RelayRunnerUITests/RelayRunnerUITests.swift") == "test")
    #expect(tree.installedText("Sources/Relay/Shared/Shared.swift") == "shared")
    // Only what the project compiles, and no per-user Xcode state.
    #expect(tree.installedText("Sources/Relay/main.swift") == nil)
    #expect(!FileManager.default.fileExists(atPath: tree.installed.appendingPathComponent(RunnerProject.projectPath + "/xcuserdata").path))
    // Builds of the replaced sources are dropped.
    #expect(!FileManager.default.fileExists(atPath: build.path))
    // No staging directories are left behind.
    let entries = try FileManager.default.contentsOfDirectory(atPath: tree.installed.deletingLastPathComponent().path)
    #expect(entries.sorted() == ["build", "runner"])
  }

  @Test func reinstallingReplacesThePreviousCopy() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try RunnerInstaller.install(from: source(tree), home: tree.home)
    try "stale".write(to: tree.installed.appendingPathComponent("Runner/leftover.txt"), atomically: true, encoding: .utf8)
    try tree.write("test v2", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")

    let record = try RunnerInstaller.install(from: source(tree, commit: String(repeating: "b", count: 40)), home: tree.home)
    #expect(record.commit == String(repeating: "b", count: 40))
    #expect(tree.installedText("Runner/RelayRunnerUITests/RelayRunnerUITests.swift") == "test v2")
    #expect(tree.installedText("Runner/leftover.txt") == nil)
  }

  /// An extracted release has no commit, even inside another repository, whose commit git would answer with.
  @Test func aReleaseRecordsNoCommit() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try FileManager.default.removeItem(at: tree.checkout.appendingPathComponent(".git"))
    let record = try RunnerInstaller.install(from: source(tree), home: tree.home)
    #expect(record.commit == nil)
    #expect(RunnerInstallRecord.read(root: tree.installed)?.commit == nil)
  }

  @Test func aFailedInstallKeepsThePreviousCopy() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try RunnerInstaller.install(from: source(tree), home: tree.home)
    try FileManager.default.removeItem(at: tree.checkout.appendingPathComponent("Sources/Relay/Shared/Shared.swift"))

    #expect(throws: (any Error).self) { try RunnerInstaller.install(from: source(tree), home: tree.home) }
    #expect(tree.installedText("Sources/Relay/Shared/Shared.swift") == "shared")
    let entries = try FileManager.default.contentsOfDirectory(atPath: tree.installed.deletingLastPathComponent().path)
    #expect(entries == ["runner"])
  }

  @Test func refusesToInstallFromTheInstalledCopy() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try RunnerInstaller.install(from: source(tree), home: tree.home)
    #expect(throws: SetupError.self) {
      try RunnerInstaller.install(from: CheckoutRunnerSource(root: tree.installed, commands: FakeHost().commands), home: tree.home)
    }
  }

  @Test func removingKeepsTheConfigAndRunnerInfo() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    #expect(try RunnerInstaller.remove(home: tree.home) == false)
    try RunnerInstaller.install(from: source(tree), home: tree.home)
    try RelayConfig(teamID: "ABCDE12345").write(to: RelayConfig.defaultURL(home: tree.home))
    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "S").write(to: RunnerLocator.userURL(home: tree.home))

    var lines: [String] = []
    #expect(try InstallCommand.run(InstallOptions(remove: true), home: tree.home, output: { lines.append($0) }) == 0)
    #expect(lines == ["removed \(tree.installed.path)"])
    #expect(!FileManager.default.fileExists(atPath: tree.installed.path))
    #expect(try RelayConfig.read(from: RelayConfig.defaultURL(home: tree.home)).teamID == "ABCDE12345")
    #expect(FileManager.default.fileExists(atPath: RunnerLocator.userURL(home: tree.home).path))
  }

  @Test func installCommandCopiesFromTheGivenCheckout() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    var lines: [String] = []
    #expect(try InstallCommand.run(InstallOptions(project: tree.checkout.path), commands: FakeHost().commands, home: tree.home, output: { lines.append($0) }) == 0)
    #expect(lines.first?.hasPrefix("installed the runner to \(tree.installed.path)") == true)
    // The fake has no git, so no commit is recorded.
    #expect(RunnerInstallRecord.read(root: tree.installed)?.commit == nil)
  }

  @Test func installBuildWritesTheBuildLog() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let logs = tree.home.appendingPathComponent(".relay/logs")
    var builds: [(args: [String], echo: Bool)] = []
    var lines: [String] = []
    let status = try InstallCommand.run(InstallOptions(project: tree.checkout.path, build: true, verbose: true), commands: FakeHost().commands,
                                        home: tree.home, build: { args, log, echo in
                                          log.write(Data("** TEST BUILD SUCCEEDED **\n".utf8))
                                          builds.append((args, echo))
                                        }, output: { lines.append($0) })
    #expect(status == 0)
    #expect(builds.count == 1)
    #expect(builds.first?.echo == true)
    #expect(builds.first?.args.contains("generic/platform=iOS Simulator") == true)
    // Built from the installed copy's sources, and recorded so relay start reuses it.
    let sourceHash = try RunnerSourceHash.compute(root: tree.installed)
    #expect(builds.first?.args.contains("RELAY_RUNNER_SOURCE_HASH=\(sourceHash)") == true)
    let derivedData = RunnerProject.buildDirectory(root: tree.installed, home: tree.home).appendingPathComponent("DerivedData-sim")
    #expect(RunnerBuildStamp.read(derivedData: derivedData) == RunnerBuildStamp(sourceHash: sourceHash, relayVersion: RelayVersion.current,
                                                                                bundleIDPrefix: "dev.devicerelay.local"))
    #expect(builds.first?.args.contains("RELAY_BUNDLE_ID_PREFIX=dev.devicerelay.local") == true)
    let record = BuildDirectoryRecord.read(buildDirectory: derivedData.deletingLastPathComponent())
    #expect(record?.root == tree.installed.canonicalFileURL.path)
    let files = try FileManager.default.contentsOfDirectory(atPath: logs.path)
    #expect(files.count == 1)
    #expect(files.first?.hasPrefix("build-") == true && files.first?.hasSuffix(".log") == true)
    let log = logs.appendingPathComponent(files[0])
    #expect(try String(contentsOf: log, encoding: .utf8) == "** TEST BUILD SUCCEEDED **\n")
    #expect(lines.contains { $0.contains("(log: \(log.path))") })
  }

  @Test func aFailedInstallBuildPointsToTheLog() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    #expect {
      try InstallCommand.run(InstallOptions(project: tree.checkout.path, build: true), commands: FakeHost().commands, home: tree.home,
                             build: { args, _, _ in throw ShellError(args: args, status: 65, output: "error: boom") }, output: { _ in })
    } throws: { error in
      let description = String(describing: error)
      return error is SetupError && description.contains("error: boom") && description.contains("see \(tree.home.path)/.relay/logs/build-")
    }
    // The copy stays installed, and nothing records a build relay start could reuse.
    #expect(RunnerProject.contains(tree.installed))
    let derivedData = RunnerProject.buildDirectory(root: tree.installed, home: tree.home).appendingPathComponent("DerivedData-sim")
    #expect(RunnerBuildStamp.read(derivedData: derivedData) == nil)
  }

  /// The installed copy holds the files the checkout's runner is built from, so a build of either is the
  /// same sources; Xcode's per-user state in the checkout (dropped from the copy) does not count.
  @Test func theInstalledCopyHashesLikeItsCheckout() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try tree.write("state", to: "\(RunnerProject.projectPath)/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate")
    try RunnerInstaller.install(from: source(tree), home: tree.home)
    #expect(try RunnerSourceHash.compute(root: tree.installed) == RunnerSourceHash.compute(root: tree.checkout))
    try tree.write("test changed", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")
    #expect(try RunnerSourceHash.compute(root: tree.installed) != RunnerSourceHash.compute(root: tree.checkout))
  }

  @Test func detectsAnOutdatedInstall() {
    let record = RunnerInstallRecord(relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40), source: "/src/relay",
                                     installedAt: "")
    #expect(record.staleness(checkout: nil) == nil)
    #expect(record.staleness(checkout: ("/src/relay", String(repeating: "a", count: 40))) == nil)
    #expect(record.staleness(checkout: ("/src/relay", String(repeating: "b", count: 40)))?.contains("aaaaaaaaaaaa") == true)
    // Another checkout's commit says nothing about this install.
    #expect(record.staleness(checkout: ("/other/relay", String(repeating: "b", count: 40))) == nil)
    #expect(record.staleness(currentVersion: "9.9.9", checkout: nil)?.contains("relay \(RelayVersion.current), but this is relay 9.9.9") == true)
  }

  @Test func comparesTheRecordedSourceCanonically() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let alias = tree.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tree.checkout)
    // Recorded through a symbolic link (or as /private/tmp/...) by an older relay.
    let record = RunnerInstallRecord(relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40), source: alias.path,
                                     installedAt: "")
    #expect(record.staleness(checkout: (tree.checkout.path, String(repeating: "b", count: 40)))?.contains("aaaaaaaaaaaa") == true)
    #expect(CheckoutRunnerSource(root: alias).location == tree.checkout.path)
  }

  @Test func checksOnlyTheInstalledCopy() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    #expect(RunnerInstaller.staleness(root: tree.checkout, source: .currentDirectory) { nil } == nil)
    try FileManager.default.createDirectory(at: tree.installed, withIntermediateDirectories: true)
    #expect(RunnerInstaller.staleness(root: tree.installed, source: .installed) { nil }?.contains("install.json") == true)
    try RunnerInstaller.install(from: source(tree), home: tree.home)
    #expect(RunnerInstaller.staleness(root: tree.installed, source: .installed, commands: FakeHost().commands) { tree.checkout } == nil)
  }

  @Test func parsesInstallCommands() throws {
    #expect(try Arguments.parse(["runner", "install"]) == .install(InstallOptions()))
    #expect(try Arguments.parse(["runner", "install", "--project", "..", "--build"]) == .install(InstallOptions(project: "..", build: true)))
    #expect(try Arguments.parse(["runner", "install", "--build", "--verbose"]) == .install(InstallOptions(build: true, verbose: true)))
    #expect(try Arguments.parse(["runner", "uninstall"]) == .install(InstallOptions(remove: true)))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["runner", "uninstall", "--verbose"]) }
    // The old form, without an app, until the next release.
    #expect(try Arguments.parse(["install"]) == .install(InstallOptions(legacy: true)))
    #expect(try Arguments.parse(["install", "--project", "..", "--build"]) == .install(InstallOptions(project: "..", build: true, legacy: true)))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["install", "--remove", "--verbose"]) }
    #expect(try Arguments.parse(["install", "--remove"]) == .install(InstallOptions(remove: true, legacy: true)))
    #expect(try Arguments.parse(["uninstall"]) == .install(InstallOptions(remove: true, legacy: true)))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["install", "--remove", "--build"]) }
    #expect(throws: ArgumentError.self) { try Arguments.parse(["uninstall", "--build"]) }
    #expect(try Arguments.parse(["--version"]) == .version)
  }
}
