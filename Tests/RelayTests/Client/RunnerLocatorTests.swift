import Foundation
@testable import Relay
import Testing

struct RunnerLocatorTests {
  /// A scratch tree: <root>/home, <root>/home/app/sub (the current directory), <root>/elsewhere.
  private struct Tree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    var home: URL { root.appendingPathComponent("home") }
    var app: URL { home.appendingPathComponent("app") }
    var current: URL { app.appendingPathComponent("sub") }

    init() throws {
      try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ token: String, under directory: URL) throws -> URL {
      let url = RunnerInfo.defaultURL(rootURL: directory)
      try RunnerInfo(url: "http://127.0.0.1:8100/", token: token, udid: "SIM").write(to: url)
      return url
    }

    func locate(_ explicitPath: String? = nil, environment: [String: String] = [:]) throws -> URL {
      try RunnerLocator.locate(explicitPath: explicitPath, environment: environment, currentDirectory: current, home: home)
    }
  }

  @Test func prefersOptionThenEnvironmentThenTheHomeCopy() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    #expect(throws: RunnerUnavailableError.self) { try tree.locate() }

    let home = try tree.write("home", under: tree.home)
    #expect(try tree.locate() == home)
    // A file in the current directory or a parent is not read, however near it is.
    let app = try tree.write("app", under: tree.app)
    let current = try tree.write("current", under: tree.current)
    #expect(try tree.locate() == home)

    let other = try tree.write("other", under: tree.root.appendingPathComponent("elsewhere"))
    #expect(try tree.locate(environment: [RunnerLocator.environmentKey: other.path]) == other)
    // --runner wins over the environment, and relative paths start at the current directory.
    #expect(try tree.locate("../.relay/runner.json", environment: [RunnerLocator.environmentKey: other.path]) == app)
    #expect(try tree.locate(".relay/runner.json") == current)
    // An empty variable is ignored.
    #expect(try tree.locate(environment: [RunnerLocator.environmentKey: ""]) == home)
  }

  @Test func aRunnerJSONInTheCurrentDirectoryIsNotReadButIsMentioned() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let app = try tree.write("app", under: tree.app)

    // Nothing at the home copy: the error says so, and where the ignored file is (a parent here).
    let message = try #require(throws: RunnerUnavailableError.self) { try tree.locate() }.description
    #expect(message.contains("no runner.json at \(tree.home.path)/.relay/runner.json"))
    #expect(message.contains(".relay/runner.json in \(tree.app.path) is no longer read; pass --runner \(app.path) to use it"))
    // The nearest one is named.
    try tree.write("current", under: tree.current)
    let nearest = try #require(throws: RunnerUnavailableError.self) { try tree.locate() }.description
    #expect(nearest.contains(".relay/runner.json in \(tree.current.path) is no longer read"))
    #expect(!nearest.contains("in \(tree.app.path) is"))

    // Without such a file, no mention; and an option or a variable that names a missing file does not either.
    let clean = try Tree()
    defer { try? FileManager.default.removeItem(at: clean.root) }
    #expect(try #require(throws: RunnerUnavailableError.self) { try clean.locate() }.description.contains("no longer read") == false)
    #expect(try #require(throws: RunnerUnavailableError.self) { try tree.locate("missing.json") }.description.contains("no longer read") == false)
  }

  @Test func theHomeCopyIsNotMentionedAsAnIgnoredFile() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    // The home copy is found from the directories below it, so it is never the ignored one.
    #expect(RunnerLocator.legacyFile(currentDirectory: tree.current, home: tree.home) == nil)
    try tree.write("home", under: tree.home)
    #expect(RunnerLocator.legacyFile(currentDirectory: tree.current, home: tree.home) == nil)
    let app = try tree.write("app", under: tree.app)
    #expect(RunnerLocator.legacyFile(currentDirectory: tree.current, home: tree.home) == app.standardizedFileURL)
  }

  @Test func givenPathMustExist() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    try tree.write("home", under: tree.home)
    // No fallback to another runner when the requested one is gone.
    #expect(throws: RunnerUnavailableError.self) { try tree.locate("missing.json") }
    #expect(throws: RunnerUnavailableError.self) { try tree.locate(environment: [RunnerLocator.environmentKey: "/nonexistent/runner.json"]) }
  }

  @Test func removesTheSharedCopyOnlyWhileItIsOurs() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let url = try tree.write("newer", under: tree.home)
    RunnerInfo.remove(at: url, ifTokenIs: "older")
    #expect(FileManager.default.fileExists(atPath: url.path))
    RunnerInfo.remove(at: url, ifTokenIs: "newer")
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

struct RunnerSelectionTests {
  @Test func order() throws {
    let both = ["RELAY_RUNNER": "env.json", "RELAY_SESSION": "env"]
    #expect(try RunnerLocator.selection(explicitPath: "x.json", session: nil, environment: both) == .file(source: "--runner", path: "x.json"))
    #expect(try RunnerLocator.selection(explicitPath: nil, session: "s", environment: both) == .session(source: "--session", name: "s"))
    #expect(try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_RUNNER": "env.json"])
      == .file(source: "$RELAY_RUNNER", path: "env.json"))
    #expect(try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_SESSION": "env"])
      == .session(source: "$RELAY_SESSION", name: "env"))
    #expect(try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_SESSION": "", "RELAY_RUNNER": ""]) == .defaultRunner)
  }

  @Test func twoVariablesOrTwoOptionsAreErrors() {
    #expect(throws: SessionSelectionError.self) {
      try RunnerLocator.selection(explicitPath: nil, session: nil, environment: ["RELAY_RUNNER": "r.json", "RELAY_SESSION": "s"])
    }
    #expect(throws: SessionSelectionError.self) {
      try RunnerLocator.selection(explicitPath: "r.json", session: "s", environment: [:])
    }
  }

  /// The whole point: a session never lands on the default runner.json or another session's.
  @Test func aSessionNeverFallsBack() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
    // The home copy, a file in the project, and another session's exist.
    try info.write(to: RunnerLocator.userURL(home: home))
    let project = home.appendingPathComponent("project")
    try info.write(to: RunnerInfo.defaultURL(rootURL: project))
    try info.write(to: RelaySession.infoURL(name: "other", home: home))

    for environment in [[:], ["RELAY_SESSION": "mine"]] {
      #expect(throws: RunnerUnavailableError.self) {
        try RunnerLocator.locate(explicitPath: nil, session: environment.isEmpty ? "mine" : nil, environment: environment,
                                 currentDirectory: project, home: home)
      }
    }

    try info.write(to: RelaySession.infoURL(name: "mine", home: home))
    #expect(try RunnerLocator.locate(explicitPath: nil, session: "mine", environment: [:], currentDirectory: project, home: home).path
      == home.path + "/.relay/sessions/mine/runner.json")
    // Without a session, the home copy, wherever the command runs: the project's own file is not read.
    for directory in [project, home] {
      #expect(try RunnerLocator.locate(explicitPath: nil, environment: [:], currentDirectory: directory, home: home, warn: { _ in }).path
        == home.path + "/.relay/runner.json")
    }
  }

  @Test func aRecordingOfAMissingSessionIsNotAnother() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("{}".utf8).write(to: { () -> URL in
      let url = Recording.stateURL(port: 8100, home: home)
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      return url
    }())
    #expect(throws: RunnerUnavailableError.self) {
      try Recording.stateURLOfRunner(runnerPath: nil, session: "mine", home: home, environment: [:], currentDirectory: home)
    }
    #expect(throws: RunnerUnavailableError.self) {
      try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: ["RELAY_SESSION": "mine"], currentDirectory: home)
    }
    // Without a session, the only state file, as before.
    #expect(try Recording.stateURLOfRunner(runnerPath: nil, home: home, environment: [:], currentDirectory: home)?.lastPathComponent
      == "recording-8100.json")
  }

  @Test func benchUsesTheSessionsRunnerJSONOnly() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "default", udid: "SIM").write(to: RunnerLocator.userURL(home: home))
    var options = BenchOptions(url: "")
    options.session = "mine"
    #expect(throws: RunnerUnavailableError.self) { try Bench.resolveTarget(options, environment: [:], home: home) }

    try RunnerInfo(url: "http://127.0.0.1:8101/", token: "mine", udid: "SIM").write(to: RelaySession.infoURL(name: "mine", home: home))
    let target = try Bench.resolveTarget(options, environment: [:], home: home)
    #expect(target.url == "http://127.0.0.1:8101/")
    #expect(target.token == "mine")
    // The session from the environment is the same.
    #expect(try Bench.resolveTarget(BenchOptions(url: ""), environment: ["RELAY_SESSION": "mine"], home: home).token == "mine")
  }

  @Test func benchFindsTheRunnerLikeTheOtherCommands() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // Nothing to find: exit 3 (RunnerUnavailableError), whatever else is given.
    #expect(throws: RunnerUnavailableError.self) { try Bench.resolveTarget(BenchOptions(url: ""), environment: [:], home: home) }
    #expect(throws: RunnerUnavailableError.self) { try Bench.resolveTarget(BenchOptions(url: "http://127.0.0.1:9"), environment: [:], home: home) }

    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "default", udid: "SIM").write(to: RunnerLocator.userURL(home: home))
    let file = home.appendingPathComponent("other.json")
    try RunnerInfo(url: "http://127.0.0.1:8200/", token: "other", udid: "SIM").write(to: file)

    // ~/.relay/runner.json without options; --runner and $RELAY_RUNNER pick a file.
    var target = try Bench.resolveTarget(BenchOptions(url: ""), environment: [:], home: home)
    #expect((target.url, target.token) == ("http://127.0.0.1:8100/", "default"))
    var options = BenchOptions(url: "")
    options.runnerPath = file.path
    target = try Bench.resolveTarget(options, environment: [:], home: home)
    #expect((target.url, target.token) == ("http://127.0.0.1:8200/", "other"))
    target = try Bench.resolveTarget(BenchOptions(url: ""), environment: ["RELAY_RUNNER": file.path], home: home)
    #expect(target.token == "other")
    options.runnerPath = home.appendingPathComponent("missing.json").path
    #expect(throws: RunnerUnavailableError.self) { try Bench.resolveTarget(options, environment: [:], home: home) }
  }

  @Test func benchUrlAndTokenOverrideTheFile() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "default", udid: "SIM").write(to: RunnerLocator.userURL(home: home))
    // --url alone keeps the token of the file; --token alone keeps its URL.
    var target = try Bench.resolveTarget(BenchOptions(url: "http://127.0.0.1:9999"), environment: [:], home: home)
    #expect((target.url, target.token) == ("http://127.0.0.1:9999", "default"))
    var options = BenchOptions(url: "")
    options.token = "given"
    target = try Bench.resolveTarget(options, environment: [:], home: home)
    #expect((target.url, target.token) == ("http://127.0.0.1:8100/", "given"))
    // With both, nothing is read, so there need not be a runner.json.
    let empty = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: empty) }
    options.url = "http://127.0.0.1:9999"
    target = try Bench.resolveTarget(options, environment: [:], home: empty)
    #expect((target.url, target.token) == ("http://127.0.0.1:9999", "given"))
  }

  @Test func benchNeedsNoUrlAndTakesRunnerButNotWithSession() throws {
    #expect(try Arguments.parse(["bench"]) == .bench(BenchOptions(url: "")))
    var options = BenchOptions(url: "")
    options.runnerPath = "r.json"
    #expect(try Arguments.parse(["bench", "--runner", "r.json"]) == .bench(options))
    #expect(try Arguments.parse(["bench", "--runner=r.json", "--count=3"]) == .bench({ var o = options; o.count = 3; return o }()))
    #expect(throws: ArgumentError.self) { try Arguments.parse(["bench", "--runner", "r.json", "--session", "a"]) }
  }
}

struct SessionlessWarningTests {
  private let info = RunnerInfo(url: "http://127.0.0.1:8101", token: "token", udid: "UDID")

  /// `locate`, and what it warned about.
  private func locate(session: String? = nil, explicitPath: String? = nil, environment: [String: String] = [:], in home: URL) throws -> (url: URL, warnings: [String]) {
    var warnings: [String] = []
    let url = try RunnerLocator.locate(explicitPath: explicitPath, session: session, environment: environment,
                                       currentDirectory: home, home: home, warn: { warnings.append($0) })
    return (url, warnings)
  }

  @Test func runningMeansARunnerInfoOrAHeldLock() {
    let running = RelaySession.running(
      names: ["building", "ended", "up"],
      hasRunnerInfo: { $0 == "up" },
      isLocked: { $0 == "building" }
    )
    #expect(running == ["building", "up"])
  }

  @Test func aLockIsNotOpenedWhenRunnerInfoAlreadySaysSo() {
    var opened: [String] = []
    _ = RelaySession.running(names: ["up"], hasRunnerInfo: { _ in true }, isLocked: { opened.append($0); return false })
    #expect(opened.isEmpty)
  }

  @Test func messageNamesTheFileAndTheSessions() {
    let url = URL(fileURLWithPath: "/home/.relay/runner.json")
    #expect(RunnerLocator.sessionlessWarning(using: url, sessions: []) == nil)
    #expect(RunnerLocator.sessionlessWarning(using: url, sessions: ["a"])
      == "relay: warning: no session selected; using /home/.relay/runner.json, while session a is running; pass --session or set RELAY_SESSION")
    #expect(RunnerLocator.sessionlessWarning(using: url, sessions: ["a", "b"])
      == "relay: warning: no session selected; using /home/.relay/runner.json, while sessions a, b are running; pass --session or set RELAY_SESSION")
  }

  @Test func aSearchWarnsWhileASessionHasARunnerInfo() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try info.write(to: RunnerLocator.userURL(home: home))
    #expect(try locate(in: home).warnings.isEmpty)

    try info.write(to: RelaySession.infoURL(name: "a", home: home))
    let found = try locate(in: home)
    // It still works: the file is the one the search finds, as without sessions.
    #expect(found.url.path == home.path + "/.relay/runner.json")
    #expect(found.warnings == [RunnerLocator.sessionlessWarning(using: found.url, sessions: ["a"])])
  }

  @Test func aSearchWarnsWhileASessionIsStarting() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try info.write(to: RunnerLocator.userURL(home: home))
    let lock = try StartLock.acquire(session: "a", home: home)
    #expect(try locate(in: home).warnings.count == 1)

    // What an ended session leaves: its directory, and a lock nobody holds.
    lock.release()
    #expect(RelaySession.names(home: home) == ["a"])
    // Retried for a moment, as the lock may linger: see onceReleased.
    #expect(becomesTrue { (try? locate(in: home).warnings.isEmpty) == true })
  }

  @Test func aSelectedRunnerDoesNotWarn() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try info.write(to: RelaySession.infoURL(name: "a", home: home))
    try info.write(to: RelaySession.infoURL(name: "b", home: home))
    let path = RelaySession.infoURL(name: "b", home: home).path

    #expect(try locate(session: "a", in: home).warnings.isEmpty)
    #expect(try locate(environment: ["RELAY_SESSION": "a"], in: home).warnings.isEmpty)
    #expect(try locate(explicitPath: path, in: home).warnings.isEmpty)
    #expect(try locate(environment: ["RELAY_RUNNER": path], in: home).warnings.isEmpty)
  }

  @Test func nothingFoundThrowsWithoutAWarning() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try info.write(to: RelaySession.infoURL(name: "a", home: home))
    var warnings: [String] = []
    #expect(throws: RunnerUnavailableError.self) {
      try RunnerLocator.locate(explicitPath: nil, environment: [:], currentDirectory: home, home: home, warn: { warnings.append($0) })
    }
    #expect(warnings.isEmpty)
  }
}
