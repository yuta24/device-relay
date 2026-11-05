import Darwin
import Foundation
@testable import relay
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
        let logs = (0..<25).map { item(logName("runner", $0), age: 30 * day + Double($0)) }
        let removed = RelayPrune.logsToRemove(logs, now: now, activePorts: [])
        #expect(RelayPrune.logsKeptPerKind == 20)
        #expect(names(removed) == Set((20..<25).map { logName("runner", $0) }))
    }

    @Test func keepsEverythingWithinTheAge() {
        let logs = (0..<100).map { item(logName("runner", $0), age: Double($0) * 60) }
        #expect(RelayPrune.logsToRemove(logs, now: now, activePorts: []).isEmpty)
        let older = [item(logName("runner", 1000), age: RelayPrune.logMaxAge - 1), item(logName("runner", 1001), age: RelayPrune.logMaxAge + 1)]
        #expect(names(RelayPrune.logsToRemove(logs + older, now: now, activePorts: [])) == [logName("runner", 1001)])
    }

    @Test func countsEachKindOnItsOwn() {
        let logs = ["start", "build", "runner", "record"].flatMap { kind in
            (0..<21).map { item(logName(kind, $0), age: 10 * day + Double($0)) }
        }
        let removed = RelayPrune.logsToRemove(logs, now: now, activePorts: [])
        #expect(names(removed) == Set(["start", "build", "runner", "record"].map { logName($0, 20) }))
    }

    /// A runner quiet for longer than the age, with newer logs of other runs around it.
    @Test func keepsTheNewestOfEachKindOnAPortInUse() {
        let others = (0..<30).map { item(logName("runner", $0, suffix: "-8200"), age: 8 * day + Double($0)) }
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
        let logs = (0..<25).map { item(logName("record", $0), age: 30 * day + Double($0)) }
        let removed = names(RelayPrune.logsToRemove(logs, now: now, activePorts: [], protectedNames: [logName("record", 24)]))
        #expect(removed == Set((20..<24).map { logName("record", $0) }))
    }

    @Test func leavesWhatItCannotRead() {
        let logs = (0..<30).map { item("notes-\($0).log", age: 100 * day) }
        #expect(RelayPrune.logsToRemove(logs, now: now, activePorts: []).isEmpty)
    }
}

struct PruneTestResultSelectionTests {
    @Test func keepsTheNewest() {
        let results = (0..<6).map { item("r\($0).xcresult", age: day * Double($0 + 1)) }
        #expect(RelayPrune.testResultsKept == 3)
        #expect(names(RelayPrune.testResultsToRemove(results.shuffled(), now: now)) == ["r3.xcresult", "r4.xcresult", "r5.xcresult"])
    }

    @Test func keepsWhatWasWrittenAMomentAgo() {
        let recent = (0..<6).map { item("r\($0).xcresult", age: Double($0)) }
        #expect(RelayPrune.testResultsToRemove(recent, now: now).isEmpty)
    }

    @Test func aFewAreAlwaysLeft() {
        let results = (0..<3).map { item("r\($0).xcresult", age: 100 * day) }
        #expect(RelayPrune.testResultsToRemove(results, now: now).isEmpty)
        #expect(RelayPrune.testResultsToRemove([], now: now).isEmpty)
    }
}

struct PruneRunTests {
    @Test func removesOldLogsAndLeavesOtherFiles() throws {
        let home = try Home()
        defer { home.clean() }
        let kept = try (0..<20).map { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
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
        try (0..<25).forEach { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
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
            for index in 0..<5 {
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
        try (0..<5).forEach { try home.addResult($0, in: directory, age: day * Double($0 + 1)) }
        let manifest = try home.addFile("LogStoreManifest.plist", in: directory, age: 100 * day)
        let attachment = try home.addFile("attachment.png", in: directory, age: 100 * day)
        // Not a bundle, and not where results go.
        let file = try home.addFile("Test-file.xcresult", in: directory, age: 100 * day)
        let unknownPort = home.url.appendingPathComponent(".relay/build/installed/TestData/mine/Logs/Test", isDirectory: true)
        let unknownDerivedData = home.legacyDirectory("Other")
        let elsewhere = try (0..<5).flatMap { [try home.addResult($0, in: unknownPort, age: 100 * day), try home.addResult($0, in: unknownDerivedData, age: 100 * day)] }
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
        let results = try (0..<5).map { try home.addResult($0, in: target.appendingPathComponent("TestData/port-8100/Logs/Test", isDirectory: true), age: day * Double($0 + 1)) }
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
        let inUse = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8101), age: day * Double($0 + 1)) }
        let idle = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8102), age: day * Double($0 + 1)) }
        let current = try home.addFile(logName("runner", 100, suffix: "-agent-8101"), in: home.logs, age: 50 * day)
        let idleLog = try home.addFile(logName("runner", 101, suffix: "-8102"), in: home.logs, age: 50 * day)
        try (0..<20).forEach { try home.addFile(logName("runner", $0, suffix: "-8200"), in: home.logs, age: 30 * day) }
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
        let results = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
        #expect(RelayPrune.run(home: home.url, ownPort: 8100, now: now).removedTestResults == 2)
        #expect(results.prefix(3).allSatisfy(home.exists))
    }

    /// A left runner.json of the same port must not stop that port's results from ever being cleaned.
    @Test func aLeftRunnerInfoDoesNotKeepTheOwnPortFromBeingCleaned() throws {
        let home = try Home()
        defer { home.clean() }
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: RunnerLocator.userURL(home: home.url))
        let results = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
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
        let first = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
        let second = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8101), age: day * Double($0 + 1)) }
        let log = try home.addFile(logName("runner", 100, suffix: "-a-8101"), in: home.logs, age: 50 * day)
        try (0..<20).forEach { try home.addFile(logName("runner", $0, suffix: "-8200"), in: home.logs, age: 30 * day) }
        #expect(RelayPrune.run(home: home.url, ownPort: 8200, now: now).removedTestResults == 0)
        #expect((first + second).allSatisfy(home.exists))
        #expect(home.exists(log))
    }

    @Test func aRecordingKeepsItsLog() throws {
        let home = try Home()
        defer { home.clean() }
        let log = try home.addFile(logName("record", 100, suffix: "-8200"), in: home.logs, age: 50 * day)
        let other = try home.addFile(logName("record", 101, suffix: "-8201"), in: home.logs, age: 50 * day)
        try (0..<20).forEach { try home.addFile(logName("record", $0), in: home.logs, age: 30 * day) }
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
            try (0..<21).map { try home.addFile(logName(kind, $0), in: home.logs, age: 30 * day + Double($0)) }
        }
        let results = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
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
        try (0..<21).forEach { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
        chmod(home.logs.path, 0o555)
        let outcome = RelayPrune.run(home: home.url, now: now)
        #expect(outcome.removedLogs == 0)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.contains(logName("runner", 20)) == true)
        #expect(outcome.problem?.hasPrefix("cannot remove 1 old log or test result (") == true)
    }

    @Test func aDirectoryItCannotReadIsLeftAlone() throws {
        let home = try Home()
        defer {
            chmod(home.logs.path, 0o755)
            home.clean()
        }
        try (0..<21).forEach { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
        chmod(home.logs.path, 0o000)
        #expect(RelayPrune.run(home: home.url, now: now) == RelayPrune.Outcome())
    }

    /// Another relay start removed it between the listing and the removal, or while this one was at it.
    @Test func whatAnotherRemovedCountsAsRemoved() throws {
        let home = try Home()
        defer { home.clean() }
        let results = try (0..<5).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
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
        let results = try (0..<4).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
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
        try (0..<5).forEach { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
        let outcome = RelayPrune.run(home: home.url, now: now, remove: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(outcome.removedTestResults == 0)
        #expect(outcome.failures.count == 2)
        #expect(outcome.problem?.hasPrefix("cannot remove 2 old logs or test results (") == true)
        #expect(outcome.problem?.contains("\n") == false)
        #expect(RelayPrune.Outcome().problem == nil)
    }

    @Test func twoAtTheSameTimeLeaveTheSameFiles() async throws {
        let home = try Home()
        defer { home.clean() }
        let results = try (0..<40).map { try home.addResult($0, in: home.testDirectory(port: 8100), age: day * Double($0 + 1)) }
        let logs = try (0..<60).map { try home.addFile(logName("runner", $0), in: home.logs, age: 30 * day + Double($0)) }
        let url = home.url
        let outcomes = await withTaskGroup(of: RelayPrune.Outcome.self) { group in
            for _ in 0..<4 {
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
