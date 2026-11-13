import Darwin
import Foundation
@testable import Relay
import Testing

// The cleanup of logs and test results (RelayPrune). Everything is in a temporary directory used as the home.

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let day: TimeInterval = 24 * 60 * 60

private func logName(_ kind: String = "runner", _ index: Int = 0, suffix: String = "-8100") -> String {
  "\(kind)-20260101-\(String(format: "%06d", index))\(suffix).log"
}

private func item(_ name: String, age: TimeInterval) -> RelayPrune.Item {
  RelayPrune.Item(url: URL(fileURLWithPath: "/logs/\(name)"), modified: now.addingTimeInterval(-age))
}

private func names(_ urls: [URL]) -> Set<String> {
  Set(urls.map(\.lastPathComponent))
}

/// A home in a temporary directory, removed by `clean`, and how to fill it.
private struct Home {
  let url: URL

  init() throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("relay-prune-\(UUID().uuidString)", isDirectory: true)
      .canonicalFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  var logs: URL { url.appendingPathComponent(".relay/logs", isDirectory: true) }

  func testDirectory(port: Int, root: String = "installed") -> URL {
    url.appendingPathComponent(".relay/build/\(root)/TestData/port-\(port)/Logs/Test", isDirectory: true)
  }

  func legacyDirectory(_ name: String = "DerivedData-sim", root: String = "installed") -> URL {
    url.appendingPathComponent(".relay/build/\(root)/\(name)/Logs/Test", isDirectory: true)
  }

  @discardableResult
  func addFile(_ name: String, in directory: URL, age: TimeInterval) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    try Data("x".utf8).write(to: file)
    try setAge(age, of: file)
    return file
  }

  /// A bundle with a file in it, as xcodebuild leaves it. Its date is set last, as a directory's date moves with its entries.
  @discardableResult
  func addResult(_ index: Int, in directory: URL, age: TimeInterval) throws -> URL {
    let bundle = directory.appendingPathComponent("Test-RelayRunner-\(index).xcresult", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Data"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
    try setAge(age, of: bundle)
    return bundle
  }

  func setAge(_ age: TimeInterval, of file: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
  }

  func exists(_ file: URL) -> Bool {
    FileManager.default.fileExists(atPath: file.path)
  }

  func clean() {
    try? FileManager.default.removeItem(at: url)
  }
}

struct PruneLogNameTests {
  @Test func readsTheNamesRelayGives() throws {
    #expect(RelayPrune.parseLogName("runner-20260101-120000-8100.log")?.kind == "runner")
    #expect(RelayPrune.parseLogName("runner-20260101-120000-8100.log")?.ports == [8100])
    #expect(RelayPrune.parseLogName("start-20260101-120000-agent-1-8101.log")?.ports == [1, 8101])
    #expect(RelayPrune.parseLogName("record-20260101-120000-a.b_c-8101-2.log")?.ports == [8101, 2])
    // relay install --build has no port.
    #expect(RelayPrune.parseLogName("build-20260101-120000.log")?.ports == [])
  }

  /// A session named like a number makes `-<session>-<port>` and `-<port>-<n>` look alike: both stand.
  @Test func bothReadingsOfTwoNumbersCount() {
    #expect(RelayPrune.parseLogName("runner-20260101-120000-8100-8101.log")?.ports == [8100, 8101])
  }

  @Test func aNameRelayDidNotGiveIsNotALog() {
    for name in [
      "notes.log", "runner.log", "runner-8100.log", "runner-2026-120000-8100.log", "runner-20260101-1200-8100.log",
      "other-20260101-120000-8100.log", "runner-20260101-120000-8100.txt", "runner-20260101-120000-8100.log.bak",
      "Runner-20260101-120000-8100.log", "runner-2026010a-120000.log", "runner-２０２６０１０１-120000.log"
    ] {
      #expect(RelayPrune.parseLogName(name) == nil, "\(name)")
    }
  }
}

struct PruneLogSelectionTests {
  @Test func keepsTheNewestOfAKindWhateverTheirAge() {
    let logs = (0 ..< 25).map { item(logName("runner", $0), age: 30 * day + Double($0)) }
    let removed = RelayPrune.logsToRemove(logs, now: now, activePorts: [])
    #expect(RelayPrune.logsKeptPerKind == 20)
    #expect(names(removed) == Set((20 ..< 25).map { logName("runner", $0) }))
  }

  @Test func keepsEverythingWithinTheAge() {
    let logs = (0 ..< 100).map { item(logName("runner", $0), age: Double($0) * 60) }
    #expect(RelayPrune.logsToRemove(logs, now: now, activePorts: []).isEmpty)
    let older = [item(logName("runner", 1000), age: RelayPrune.logMaxAge - 1), item(logName("runner", 1001), age: RelayPrune.logMaxAge + 1)]
    #expect(names(RelayPrune.logsToRemove(logs + older, now: now, activePorts: [])) == [logName("runner", 1001)])
  }

  @Test func countsEachKindOnItsOwn() {
    let logs = ["start", "build", "runner", "record"].flatMap { kind in
      (0 ..< 21).map { item(logName(kind, $0), age: 10 * day + Double($0)) }
    }
    let removed = RelayPrune.logsToRemove(logs, now: now, activePorts: [])
    #expect(names(removed) == Set(["start", "build", "runner", "record"].map { logName($0, 20) }))
  }

  /// A runner quiet for longer than the age, with newer logs of other runs around it.
  @Test func keepsTheNewestOfEachKindOnAPortInUse() {
    let others = (0 ..< 30).map { item(logName("runner", $0, suffix: "-8200"), age: 8 * day + Double($0)) }
    let current = item(logName("runner", 100, suffix: "-8100"), age: 20 * day)
    let earlier = item(logName("runner", 101, suffix: "-8100"), age: 21 * day)
    let session = item(logName("runner", 102, suffix: "-agent-8300"), age: 22 * day)
    let logs = others + [current, earlier, session]
    let removed = names(RelayPrune.logsToRemove(logs, now: now, activePorts: [8100, 8300]))
    #expect(!removed.contains(current.url.lastPathComponent))
    #expect(!removed.contains(session.url.lastPathComponent))
    // Only the newest: what an earlier relay start on that port wrote is no longer written to.
    #expect(removed.contains(earlier.url.lastPathComponent))
    let withoutPorts = names(RelayPrune.logsToRemove(logs, now: now, activePorts: []))
    #expect(withoutPorts.contains(current.url.lastPathComponent))
  }

  @Test func keepsTheLogOfARecording() {
    let logs = (0 ..< 25).map { item(logName("record", $0), age: 30 * day + Double($0)) }
    let removed = names(RelayPrune.logsToRemove(logs, now: now, activePorts: [], protectedNames: [logName("record", 24)]))
    #expect(removed == Set((20 ..< 24).map { logName("record", $0) }))
  }

  @Test func leavesWhatItCannotRead() {
    let logs = (0 ..< 30).map { item("notes-\($0).log", age: 100 * day) }
    #expect(RelayPrune.logsToRemove(logs, now: now, activePorts: []).isEmpty)
  }
}

struct PruneTestResultSelectionTests {
  @Test func keepsTheNewest() {
    let results = (0 ..< 6).map { item("r\($0).xcresult", age: day * Double($0 + 1)) }
    #expect(RelayPrune.testResultsKept == 3)
    #expect(names(RelayPrune.testResultsToRemove(results.shuffled(), now: now)) == ["r3.xcresult", "r4.xcresult", "r5.xcresult"])
  }

  @Test func keepsWhatWasWrittenAMomentAgo() {
    let recent = (0 ..< 6).map { item("r\($0).xcresult", age: Double($0)) }
    #expect(RelayPrune.testResultsToRemove(recent, now: now).isEmpty)
  }

  @Test func aFewAreAlwaysLeft() {
    let results = (0 ..< 3).map { item("r\($0).xcresult", age: 100 * day) }
    #expect(RelayPrune.testResultsToRemove(results, now: now).isEmpty)
    #expect(RelayPrune.testResultsToRemove([], now: now).isEmpty)
  }
}

struct PruneRunTests {
  @Test func removesOldLogsAndLeavesOtherFiles() throws {
    let home = try Home()
    defer { home.clean() }
    let kept = try (0 ..< 20).map { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
    let old = try home.addFile(logName("runner", 99), in: home.logs, age: 40 * day)
    let notes = try home.addFile("notes.log", in: home.logs, age: 400 * day)
    let unknown = try home.addFile("runner-keep.log", in: home.logs, age: 400 * day)
    let outcome = RelayPrune.run(home: home.url, now: now)
    #expect(outcome == RelayPrune.Outcome(removedLogs: 1))
    #expect(!home.exists(old))
    #expect(kept.allSatisfy(home.exists))
    #expect(home.exists(notes))
    #expect(home.exists(unknown))
  }

  @Test func leavesWhatHasARelayNameButIsNotAFile() throws {
    let home = try Home()
    defer { home.clean() }
    try (0 ..< 25).forEach { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
    let directory = home.logs.appendingPathComponent(logName("runner", 50))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try home.setAge(100 * day, of: directory)
    let target = try home.addFile("target.txt", in: home.url, age: 100 * day)
    let link = home.logs.appendingPathComponent(logName("runner", 51))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    RelayPrune.run(home: home.url, now: now)
    #expect(home.exists(directory))
    #expect(home.exists(link))
    #expect(home.exists(target))
  }

  @Test func removesOldResultsPerPortAndInTheEarlierPlace() throws {
    let home = try Home()
    defer { home.clean() }
    var kept: [URL] = []
    var old: [URL] = []
    for directory in [home.testDirectory(port: 8100), home.testDirectory(port: 8101), home.testDirectory(port: 8100, root: "device-relay-abc"),
                      home.legacyDirectory(), home.legacyDirectory("DerivedData-device")] {
      for index in 0 ..< 5 {
        let result = try home.addResult(index, in: directory, age: day * Double(index + 1))
        if index < 3 { kept.append(result) } else { old.append(result) }
      }
    }
    let outcome = RelayPrune.run(home: home.url, ownPort: 8100, now: now)
    #expect(outcome == RelayPrune.Outcome(removedTestResults: old.count))
    #expect(kept.allSatisfy(home.exists))
    #expect(!old.contains(where: home.exists))
  }

  @Test func leavesTheManifestAndOtherFilesOfXcodebuild() throws {
    let home = try Home()
    defer { home.clean() }
    let directory = home.testDirectory(port: 8100)
    try (0 ..< 5).forEach { try home.addResult($0, in: directory, age: day * Double($0 + 1)) }
    let manifest = try home.addFile("LogStoreManifest.plist", in: directory, age: 100 * day)
    let attachment = try home.addFile("attachment.png", in: directory, age: 100 * day)
    // Not a bundle, and not where results go.
    let file = try home.addFile("Test-file.xcresult", in: directory, age: 100 * day)
    let unknownPort = home.url.appendingPathComponent(".relay/build/installed/TestData/mine/Logs/Test", isDirectory: true)
    let unknownDerivedData = home.legacyDirectory("Other")
    let elsewhere = try (0 ..< 5).flatMap { [try home.addResult($0, in: unknownPort, age: 100 * day), try home.addResult($0, in: unknownDerivedData, age: 100 * day)] }
    RelayPrune.run(home: home.url, now: now)
    #expect(home.exists(manifest))
    #expect(home.exists(attachment))
    #expect(home.exists(file))
    #expect(elsewhere.allSatisfy(home.exists))
  }

  @Test func aSymbolicLinkInTheBuildDirectoryIsNotFollowed() throws {
    let home = try Home()
    defer { home.clean() }
    let target = home.url.appendingPathComponent("elsewhere", isDirectory: true)
    let results = try (0 ..< 5).map { try home.addResult($0, in: target.appendingPathComponent("TestData/port-8100/Logs/Test", isDirectory: true), age: day * Double($0 + 1)) }
    let builds = home.url.appendingPathComponent(".relay/build", isDirectory: true)
    try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: builds.appendingPathComponent("linked"), withDestinationURL: target)
    RelayPrune.run(home: home.url, now: now)
    #expect(results.allSatisfy(home.exists))
  }

  @Test func aPortInUseKeepsItsResultsAndItsCurrentLogs() throws {
    let home = try Home()
    defer { home.clean() }
    let held = try StartLock.acquire(port: 8101, home: home.url)
    defer { held.release() }
    let inUse = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8101), age: day * Double($0 + 1)) }
    let idle = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8102), age: day * Double($0 + 1)) }
    let current = try home.addFile(logName("runner", 100, suffix: "-agent-8101"), in: home.logs, age: 50 * day)
    let idleLog = try home.addFile(logName("runner", 101, suffix: "-8102"), in: home.logs, age: 50 * day)
    try (0 ..< 20).forEach { try home.addFile(logName("runner", $0, suffix: "-8200"), in: home.logs, age: 30 * day) }
    let outcome = RelayPrune.run(home: home.url, ownPort: 8100, now: now)
    #expect(inUse.allSatisfy(home.exists))
    #expect(idle.prefix(3).allSatisfy(home.exists))
    #expect(!idle.suffix(2).contains(where: home.exists))
    #expect(home.exists(current))
    #expect(!home.exists(idleLog))
    #expect(outcome.removedTestResults == 2)
  }

  /// The caller's own lock shows like anybody's, but nothing else can be running on that port.
  @Test func theOwnPortIsCleaned() throws {
    let home = try Home()
    defer { home.clean() }
    let held = try StartLock.acquire(port: 8100, home: home.url)
    defer { held.release() }
    let results = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    #expect(RelayPrune.run(home: home.url, ownPort: 8100, now: now).removedTestResults == 2)
    #expect(results.prefix(3).allSatisfy(home.exists))
  }

  /// A left runner.json of the same port must not stop that port's results from ever being cleaned.
  @Test func aLeftRunnerInfoDoesNotKeepTheOwnPortFromBeingCleaned() throws {
    let home = try Home()
    defer { home.clean() }
    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: RunnerLocator.userURL(home: home.url))
    let results = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    #expect(RelayPrune.run(home: home.url, ownPort: 8100, now: now).removedTestResults == 2)
    #expect(results.prefix(3).allSatisfy(home.exists))
  }

  /// A runner whose `relay start` was killed holds no lock any more, but its runner.json is there.
  @Test func aPortARunnerInfoNamesIsInUse() throws {
    let home = try Home()
    defer { home.clean() }
    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: RunnerLocator.userURL(home: home.url))
    try RunnerInfo(url: "http://127.0.0.1:8101/", token: "t", udid: "SIM", session: "a").write(to: RelaySession.infoURL(name: "a", home: home.url))
    #expect(RelayPrune.runnerInfoPorts(home: home.url) == [8100, 8101])
    let first = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    let second = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8101), age: day * Double($0 + 1)) }
    let log = try home.addFile(logName("runner", 100, suffix: "-a-8101"), in: home.logs, age: 50 * day)
    try (0 ..< 20).forEach { try home.addFile(logName("runner", $0, suffix: "-8200"), in: home.logs, age: 30 * day) }
    #expect(RelayPrune.run(home: home.url, ownPort: 8200, now: now).removedTestResults == 0)
    #expect((first + second).allSatisfy(home.exists))
    #expect(home.exists(log))
  }

  @Test func aRecordingKeepsItsLog() throws {
    let home = try Home()
    defer { home.clean() }
    let log = try home.addFile(logName("record", 100, suffix: "-8200"), in: home.logs, age: 50 * day)
    let other = try home.addFile(logName("record", 101, suffix: "-8201"), in: home.logs, age: 50 * day)
    try (0 ..< 20).forEach { try home.addFile(logName("record", $0), in: home.logs, age: 30 * day) }
    try RecordingState(pid: 1, processStartedAt: now, supervisorPid: 2, output: "/tmp/a.mp4", udid: "SIM", port: 8200, startedAt: now,
                       maxDuration: 600, log: log.path, kind: .simulator).write(to: Recording.stateURL(port: 8200, home: home.url))
    RelayPrune.run(home: home.url, now: now)
    #expect(home.exists(log))
    #expect(!home.exists(other))
  }

  @Test func recordStartLooksOnlyAtRecordLogs() throws {
    let home = try Home()
    defer { home.clean() }
    let logs = try ["start", "build", "runner", "record"].flatMap { kind in
      try (0 ..< 21).map { try home.addFile(logName(kind, $0), in: home.logs, age: 30 * day + Double($0)) }
    }
    let results = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    let outcome = RelayPrune.run(home: home.url, kinds: ["record"], includeTestResults: false, now: now)
    #expect(outcome == RelayPrune.Outcome(removedLogs: 1))
    #expect(logs.filter { !home.exists($0) }.map(\.lastPathComponent) == [logName("record", 20)])
    #expect(results.allSatisfy(home.exists))
  }

  @Test func nothingThereIsFine() throws {
    let home = try Home()
    defer { home.clean() }
    #expect(RelayPrune.run(home: home.url, ownPort: 8100, now: now) == RelayPrune.Outcome())
    #expect(RelayPrune.run(home: home.url.appendingPathComponent("no/such/home"), now: now) == RelayPrune.Outcome())
  }

  @Test func emptyDirectoriesAreFine() throws {
    let home = try Home()
    defer { home.clean() }
    try FileManager.default.createDirectory(at: home.logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.url.appendingPathComponent(".relay/build/installed/TestData/port-8100"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.legacyDirectory(), withIntermediateDirectories: true)
    #expect(RelayPrune.run(home: home.url, now: now) == RelayPrune.Outcome())
  }

  @Test func aDirectoryItCannotChangeIsReportedNotThrown() throws {
    let home = try Home()
    defer {
      chmod(home.logs.path, 0o755)
      home.clean()
    }
    try (0 ..< 21).forEach { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
    chmod(home.logs.path, 0o555)
    let outcome = RelayPrune.run(home: home.url, now: now)
    #expect(outcome.removedLogs == 0)
    #expect(outcome.failures.count == 1)
    #expect(outcome.failures.first?.contains(logName("runner", 20)) == true)
    #expect(outcome.problem?.hasPrefix("cannot remove 1 old log, test result or build (") == true)
  }

  @Test func aDirectoryItCannotReadIsLeftAlone() throws {
    let home = try Home()
    defer {
      chmod(home.logs.path, 0o755)
      home.clean()
    }
    try (0 ..< 21).forEach { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
    chmod(home.logs.path, 0o000)
    #expect(RelayPrune.run(home: home.url, now: now) == RelayPrune.Outcome())
  }

  /// Another relay start removed it between the listing and the removal, or while this one was at it.
  @Test func whatAnotherRemovedCountsAsRemoved() throws {
    let home = try Home()
    defer { home.clean() }
    let results = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    let outcome = RelayPrune.run(home: home.url, now: now, remove: { url in
      try FileManager.default.removeItem(at: url)
      throw CocoaError(.fileNoSuchFile)
    })
    #expect(outcome == RelayPrune.Outcome(removedTestResults: 2))
    #expect(!results.suffix(2).contains(where: home.exists))
  }

  /// A second try finishes what the other one left when it stopped halfway.
  @Test func aRemovalThatFailsOnceIsTriedAgain() throws {
    let home = try Home()
    defer { home.clean() }
    let results = try (0 ..< 4).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    let tries = Locked(0)
    let outcome = RelayPrune.run(home: home.url, now: now, remove: { url in
      if tries.withLock({ count in
        count += 1
        return count == 1
      }) {
        throw CocoaError(.fileWriteUnknown)
      }
      try FileManager.default.removeItem(at: url)
    })
    #expect(outcome == RelayPrune.Outcome(removedTestResults: 1))
    #expect(!home.exists(results[3]))
    #expect(tries.value == 2)
  }

  @Test func aRemovalThatKeepsFailingIsOneLineWithTheCount() throws {
    let home = try Home()
    defer { home.clean() }
    try (0 ..< 5).forEach { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    let outcome = RelayPrune.run(home: home.url, now: now, remove: { _ in throw CocoaError(.fileWriteNoPermission) })
    #expect(outcome.removedTestResults == 0)
    #expect(outcome.failures.count == 2)
    #expect(outcome.problem?.hasPrefix("cannot remove 2 old logs, test results or builds (") == true)
    #expect(outcome.problem?.contains("\n") == false)
    #expect(RelayPrune.Outcome().problem == nil)
  }

  @Test func twoAtTheSameTimeLeaveTheSameFiles() async throws {
    let home = try Home()
    defer { home.clean() }
    let results = try (0 ..< 40).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
    let logs = try (0 ..< 60).map { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
    let url = home.url
    let outcomes = await withTaskGroup(of: RelayPrune.Outcome.self) { group in
      for _ in 0 ..< 4 {
        group.addTask { RelayPrune.run(home: url, now: now) }
      }
      return await group.reduce(into: [RelayPrune.Outcome]()) { $0.append($1) }
    }
    #expect(outcomes.allSatisfy { $0.failures.isEmpty })
    #expect(results.prefix(3).allSatisfy(home.exists))
    #expect(!results.dropFirst(3).contains(where: home.exists))
    #expect(logs.prefix(20).allSatisfy(home.exists))
    #expect(!logs.dropFirst(20).contains(where: home.exists))
  }
}

/// A home with runner projects and build directories, for the removal of whole build directories.
private struct Builds {
  static let own = "own-000000000000"
  let home: Home

  init() throws {
    home = try Home()
  }

  var directory: URL { home.url.appendingPathComponent(".relay/build", isDirectory: true) }

  func clean() {
    chmod(directory.path, 0o755)
    home.clean()
  }

  /// A directory holding the runner project, as `RunnerProject.contains` wants it.
  func addRoot(_ name: String = "device-relay") throws -> URL {
    let root = home.url.appendingPathComponent("sources/\(UUID().uuidString)/\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
    return root
  }

  /// The build directory of `root` with its record and some products, used `age` ago.
  func addBuild(root: URL, age: TimeInterval = day) throws -> URL {
    let build = RunnerProject.buildDirectory(root: root, home: home.url)
    try BuildDirectoryRecord.refresh(root: root, buildDirectory: build, now: now.addingTimeInterval(-age))
    try addProducts(build)
    return build
  }

  func addProducts(_ build: URL) throws {
    let products = build.appendingPathComponent("DerivedData-sim/Build/Products", isDirectory: true)
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: products.appendingPathComponent("RelayRunner.xctestrun"))
  }

  /// A build directory an earlier relay left: no record, and `info.plist` as Xcode writes it.
  func addLegacy(_ name: String, workspace: String?, derivedData: String = "DerivedData-sim") throws -> URL {
    let build = directory.appendingPathComponent(name, isDirectory: true)
    try addProducts(build)
    let plist = build.appendingPathComponent(derivedData, isDirectory: true)
    try FileManager.default.createDirectory(at: plist, withIntermediateDirectories: true)
    if let workspace {
      let data = try PropertyListSerialization.data(fromPropertyList: ["LastAccessedDate": now, "WorkspacePath": workspace], format: .xml, options: 0)
      try data.write(to: plist.appendingPathComponent("info.plist"))
    }
    return build
  }

  func workspace(of root: URL) -> String {
    root.appendingPathComponent(RunnerProject.projectPath).path
  }

  func remove(_ root: URL) throws {
    try FileManager.default.removeItem(at: root)
  }

  func run(ownPort: Int? = 8100, own: String? = Builds.own, remove: ((URL) throws -> Void)? = nil) -> RelayPrune.Outcome {
    if let remove {
      return RelayPrune.run(home: home.url, ownPort: ownPort, ownBuildDirectory: own, now: now, remove: remove)
    }
    return RelayPrune.run(home: home.url, ownPort: ownPort, ownBuildDirectory: own, now: now)
  }

  func exists(_ url: URL) -> Bool {
    home.exists(url)
  }

  /// What is left under `~/.relay/build`, hidden names included.
  var entries: Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
  }
}

struct PruneBuildDirectoryTests {
  @Test func theSourceGoneRemovesItEvenIfRecentlyUsed() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    _ = try builds.addBuild(root: root)
    try builds.remove(root)
    #expect(builds.run() == RelayPrune.Outcome(removedBuildDirectories: 1))
    #expect(builds.entries.isEmpty)
  }

  /// The source is there, as with what `mise` keeps until `mise prune`.
  @Test func unusedForTheAgeRemovesItEvenWithTheSourceThere() throws {
    let builds = try Builds()
    defer { builds.clean() }
    #expect(RelayPrune.buildUnusedMaxAge == 30 * day)
    let old = try builds.addBuild(root: try builds.addRoot(), age: RelayPrune.buildUnusedMaxAge + 1)
    let recent = try builds.addBuild(root: try builds.addRoot(), age: RelayPrune.buildUnusedMaxAge - 1)
    #expect(builds.run().removedBuildDirectories == 1)
    #expect(!builds.exists(old))
    #expect(builds.exists(recent))
  }

  /// A clock set back must not make anything look old.
  @Test func usedInTheFutureStays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let build = try builds.addBuild(root: try builds.addRoot(), age: -100 * day)
    #expect(builds.run().removedBuildDirectories == 0)
    #expect(builds.exists(build))
  }

  @Test func theCurrentStartsDirectoryStaysWhateverItsRecordSays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let build = try builds.addBuild(root: root, age: 100 * day)
    try builds.remove(root)
    #expect(builds.run(own: build.lastPathComponent) == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  /// `relay record start`, and a start whose runner project was not found: its directory could be any of them.
  @Test func withoutTheCallersDirectoryNothingGoes() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let build = try builds.addBuild(root: root, age: 100 * day)
    try builds.remove(root)
    #expect(builds.run(own: nil) == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  @Test func installedStays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let installed = RunnerProject.installedRoot(home: builds.home.url)
    let build = RunnerProject.buildDirectory(root: installed, home: builds.home.url)
    #expect(build.lastPathComponent == RelayPrune.installedBuildName)
    try BuildDirectoryRecord.refresh(root: installed, buildDirectory: build, now: now.addingTimeInterval(-100 * day))
    try builds.addProducts(build)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  // MARK: Running starts and runners

  @Test func aStartHoldingItsLockKeepsWhatItClaims() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let claimedRoot = try builds.addRoot()
    let claimed = try builds.addBuild(root: claimedRoot)
    let other = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    try builds.remove(claimedRoot)
    let held = try StartLock.acquire(port: 8101, home: builds.home.url)
    defer { held.release() }
    try StartBuildClaim(pid: getpid(), buildDirectory: claimed.lastPathComponent).write(port: 8101, home: builds.home.url)
    #expect(builds.run().removedBuildDirectories == 1)
    #expect(builds.exists(claimed))
    #expect(!builds.exists(other))
  }

  /// An earlier relay, or a start between taking its lock and writing its claim.
  @Test func aStartThatDoesNotSayKeepsEverything() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let build = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    let held = try StartLock.acquire(port: 8101, home: builds.home.url)
    defer { held.release() }
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
    // A file an earlier start of that port left says nothing about this one.
    try StartBuildClaim(pid: getpid() + 1, buildDirectory: "other-000000000000").write(port: 8101, home: builds.home.url)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  /// Once its start ended, the lock is free and its file means nothing.
  @Test func aClaimWithoutItsLockCountsForNothing() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let build = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    try StartLock.acquire(port: 8101, home: builds.home.url).release()
    try StartBuildClaim(pid: getpid(), buildDirectory: build.lastPathComponent).write(port: 8101, home: builds.home.url)
    // Retried for a moment, as the lock may linger: see onceReleased. A run that finds it held removes nothing.
    #expect(becomesTrue { builds.run().removedBuildDirectories == 1 })
  }

  @Test func aRunnerInfoKeepsTheDirectoryItNames() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let home = builds.home.url
    let first = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    let second = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    let other = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    try RunnerInfo(url: "http://127.0.0.1:8200/", token: "t", udid: "SIM", buildDirectory: first.lastPathComponent)
      .write(to: RunnerLocator.userURL(home: home))
    try RunnerInfo(url: "http://127.0.0.1:8201/", token: "t", udid: "SIM", session: "a", buildDirectory: second.lastPathComponent)
      .write(to: RelaySession.infoURL(name: "a", home: home))
    #expect(builds.run().removedBuildDirectories == 1)
    #expect(builds.exists(first))
    #expect(builds.exists(second))
    #expect(!builds.exists(other))
  }

  /// A runner.json from before the field, of a runner that may run from any of them.
  @Test func aRunnerInfoThatDoesNotSayKeepsEverything() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let build = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    try RunnerInfo(url: "http://127.0.0.1:8200/", token: "t", udid: "SIM").write(to: RunnerLocator.userURL(home: builds.home.url))
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  /// One on the caller's own port is left behind: else one `kill -9` would stop all this until `relay stop`.
  @Test func aRunnerInfoOfTheOwnPortThatDoesNotSayKeepsNothing() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let build = try builds.addBuild(root: try builds.addRoot(), age: 100 * day)
    try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: RunnerLocator.userURL(home: builds.home.url))
    #expect(builds.run().removedBuildDirectories == 1)
    #expect(!builds.exists(build))
  }

  /// `relay start` holds it while it builds or launches from the products; no claim can be read before that here.
  @Test func aDirectoryWhoseBuildLockIsHeldStays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let build = try builds.addBuild(root: root)
    try builds.remove(root)
    let lock = try BuildLock(derivedData: build.appendingPathComponent("DerivedData-device", isDirectory: true),
                             relayDirectory: builds.home.url.appendingPathComponent(".relay", isDirectory: true))
    try lock.wait(for: .shared, info: { _ in })
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
    lock.release()
    // Retried for a moment, as the lock may linger: see onceReleased. A run that finds it held removes nothing.
    #expect(becomesTrue { builds.run().removedBuildDirectories == 1 })
  }

  /// The lock `relay start` waits for is free again once the directory has been moved.
  @Test func removingLeavesTheBuildLockFree() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let build = try builds.addBuild(root: root)
    try builds.remove(root)
    #expect(builds.run().removedBuildDirectories == 1)
    let lock = try BuildLock(derivedData: build.appendingPathComponent("DerivedData-sim", isDirectory: true),
                             relayDirectory: builds.home.url.appendingPathComponent(".relay", isDirectory: true))
    defer { lock.release() }
    // Retried for a moment, as the descriptor prune checked the lock with may linger: see onceReleased.
    #expect(becomesTrue { lock.tryExclusive() })
  }

  // MARK: Directories without the record

  @Test func anEarlierDirectoryGoesWhenItsSourceIsGone() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot("relay-0.3.0")
    let build = try builds.addLegacy("relay-0.3.0-0123456789ab", workspace: builds.workspace(of: root))
    try builds.remove(root)
    #expect(builds.run().removedBuildDirectories == 1)
    #expect(!builds.exists(build))
  }

  /// The age counts only with relay's own record: nothing says when an earlier one was last used.
  @Test func anEarlierDirectoryWithItsSourceThereStays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot("relay-0.3.0")
    let build = try builds.addLegacy("relay-0.3.0-0123456789ab", workspace: builds.workspace(of: root))
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-400 * day)], ofItemAtPath: build.path)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  @Test func anEarlierDirectoryThatSaysNothingStays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let silent = try builds.addLegacy("relay-0.3.0-0123456789ab", workspace: nil)
    let empty = builds.directory.appendingPathComponent("relay-0.2.0-0123456789ab", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let unreadable = try builds.addLegacy("relay-0.1.0-0123456789ab", workspace: nil)
    try Data("not a plist".utf8).write(to: unreadable.appendingPathComponent("DerivedData-sim/info.plist"))
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(silent))
    #expect(builds.exists(empty))
    #expect(builds.exists(unreadable))
  }

  @Test func oneDerivedDataNamingADifferentPlaceKeepsAnEarlierDirectory() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot("relay-0.3.0")
    let there = try builds.addRoot("relay-0.3.0")
    let build = try builds.addLegacy("relay-0.3.0-0123456789ab", workspace: builds.workspace(of: root))
    _ = try builds.addLegacy("relay-0.3.0-0123456789ab", workspace: builds.workspace(of: there), derivedData: "DerivedData-device")
    try builds.remove(root)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(build))
  }

  // MARK: A stray file is not trusted

  @Test func aRecordThatDoesNotFitTheNameKeepsIt() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let stray = builds.directory.appendingPathComponent("device-relay-0123456789ab", isDirectory: true)
    try BuildDirectoryRecord.refresh(root: root, buildDirectory: stray, now: now.addingTimeInterval(-100 * day))
    let relative = builds.directory.appendingPathComponent("relative-0123456789ab", isDirectory: true)
    try FileManager.default.createDirectory(at: relative, withIntermediateDirectories: true)
    try Data(#"{"root":"relative","lastUsed":"2020-01-01T00:00:00Z"}"#.utf8).write(to: BuildDirectoryRecord.url(buildDirectory: relative))
    try builds.remove(root)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(stray))
    #expect(builds.exists(relative))
  }

  @Test func aWorkspacePathThatDoesNotFitTheNameKeepsIt() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot("device-relay")
    let otherName = try builds.addLegacy("something-0123456789ab", workspace: builds.workspace(of: root))
    let noHash = try builds.addLegacy("device-relay-copy", workspace: builds.workspace(of: root))
    let otherProject = try builds.addLegacy("device-relay-0123456789ab", workspace: root.appendingPathComponent("Other.xcodeproj").path)
    try builds.remove(root)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(otherName))
    #expect(builds.exists(noHash))
    #expect(builds.exists(otherProject))
  }

  @Test func whatIsNotARealDirectoryOrIsHiddenStays() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let target = try builds.addBuild(root: root)
    let elsewhere = builds.home.url.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.moveItem(at: target, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
    let hidden = builds.directory.appendingPathComponent(".mine", isDirectory: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try builds.remove(root)
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.exists(elsewhere))
    #expect(builds.entries == [target.lastPathComponent, ".mine"])
  }

  // MARK: Removing

  @Test func aDirectoryItCannotMoveIsOneLine() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let build = try builds.addBuild(root: root)
    try builds.remove(root)
    chmod(builds.directory.path, 0o555)
    let outcome = builds.run()
    #expect(outcome.removedBuildDirectories == 0)
    #expect(outcome.failures.count == 1)
    #expect(outcome.problem?.hasPrefix("cannot remove 1 old log, test result or build (\(build.path): ") == true)
    chmod(builds.directory.path, 0o755)
    #expect(builds.run().removedBuildDirectories == 1)
  }

  /// Moved aside and then not removable: reported, never in the way of a start, and tried again the next time.
  @Test func whatFailsAfterTheMoveIsLeftUnderAHiddenNameAndFinishedNextTime() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let build = try builds.addBuild(root: root)
    try builds.remove(root)
    let outcome = builds.run(remove: { _ in throw CocoaError(.fileWriteNoPermission) })
    #expect(outcome.removedBuildDirectories == 0)
    #expect(outcome.failures.count == 1)
    #expect(!builds.exists(build))
    #expect(builds.entries.count == 1)
    #expect(builds.entries.first?.hasPrefix(RelayPrune.removingPrefix) == true)
    #expect(builds.run().failures.isEmpty)
    #expect(builds.entries.isEmpty)
  }

  @Test func leftoversGoEvenWhenSomethingRunningDoesNotSay() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let leftover = builds.directory.appendingPathComponent(RelayPrune.removingPrefix + "earlier", isDirectory: true)
    try builds.addProducts(leftover)
    let held = try StartLock.acquire(port: 8101, home: builds.home.url)
    defer { held.release() }
    #expect(builds.run() == RelayPrune.Outcome())
    #expect(builds.entries.isEmpty)
  }

  /// Being removed, so its results are no business of the cleanup of test results.
  @Test func testResultsAreNotLookedForInHiddenDirectories() throws {
    let home = try Home()
    defer { home.clean() }
    let results = try (0 ..< 5).map { try home.addResult($0, in: home.testDirectory(port: 8100, root: RelayPrune.removingPrefix + "a"), age: day * Double($0 + 1)) }
    #expect(RelayPrune.run(home: home.url, now: now) == RelayPrune.Outcome())
    #expect(results.allSatisfy(home.exists))
  }

  @Test func manyAtTheSameTimeRemoveEachOnceAndFailNothing() async throws {
    let builds = try Builds()
    defer { builds.clean() }
    var due: [URL] = []
    for index in 0 ..< 8 {
      let root = try builds.addRoot("relay-\(index)")
      let build = try builds.addBuild(root: root)
      // A few files more, so that the removals overlap.
      for file in 0 ..< 200 {
        try Data("x".utf8).write(to: build.appendingPathComponent("DerivedData-sim/\(file)"))
      }
      try builds.remove(root)
      due.append(build)
    }
    let kept = try builds.addBuild(root: try builds.addRoot())
    for index in 0 ..< 3 {
      try builds.addProducts(builds.directory.appendingPathComponent(RelayPrune.removingPrefix + "\(index)", isDirectory: true))
    }
    let home = builds.home.url
    let outcomes = await withTaskGroup(of: RelayPrune.Outcome.self) { group in
      for _ in 0 ..< 6 {
        group.addTask { RelayPrune.run(home: home, ownPort: 8100, ownBuildDirectory: Builds.own, now: now) }
      }
      return await group.reduce(into: [RelayPrune.Outcome]()) { $0.append($1) }
    }
    #expect(outcomes.flatMap(\.failures).isEmpty)
    #expect(outcomes.map(\.removedBuildDirectories).reduce(0, +) == due.count)
    // Each run saw another move some of them after listing; the leftovers of the runs are finished by now.
    #expect(builds.entries == [kept.lastPathComponent])
  }

  // MARK: The record

  @Test func theRecordIsReadBackWithTheCanonicalRoot() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let link = builds.home.url.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let build = RunnerProject.buildDirectory(root: link, home: builds.home.url)
    #expect(build == RunnerProject.buildDirectory(root: root, home: builds.home.url))
    try BuildDirectoryRecord.refresh(root: link, buildDirectory: build, now: now)
    #expect(BuildDirectoryRecord.read(buildDirectory: build) == BuildDirectoryRecord(root: root.canonicalFileURL.path, lastUsed: now))
    let text = try String(contentsOf: BuildDirectoryRecord.url(buildDirectory: build), encoding: .utf8)
    #expect(text.contains(#""lastUsed" : "2033-05-18T03:33:20Z""#))
    #expect(BuildDirectoryRecord.url(buildDirectory: build).lastPathComponent == "relay-build-dir.json")
  }

  /// It is next to the DerivedData, out of everything the hash and Xcode read.
  @Test func theRecordIsOutsideTheSourcesAndTheDerivedData() throws {
    let builds = try Builds()
    defer { builds.clean() }
    let root = try builds.addRoot()
    let file = BuildDirectoryRecord.url(buildDirectory: RunnerProject.buildDirectory(root: root, home: builds.home.url)).standardizedFileURL.path
    #expect(!file.hasPrefix(root.standardizedFileURL.path + "/"))
    #expect(!file.contains("DerivedData"))
  }

  @Test func aRunnerInfoFromBeforeTheFieldStillReads() throws {
    let home = try Home()
    defer { home.clean() }
    let file = home.url.appendingPathComponent("runner.json")
    try Data(#"{"url":"http://127.0.0.1:8100/","token":"t","udid":"SIM"}"#.utf8).write(to: file)
    #expect(try RunnerInfo.read(from: file).buildDirectory == nil)
  }
}
