import Darwin
import Foundation

/// Removes the logs and test results that pile up as relay is used, at the start of every `relay start`
/// (and the `record-` logs at `relay record start`). It only reads a few directories and lock files, and a
/// failure never stops the command: the worst case is that the files stay until the next start.
///
/// Only what relay and its xcodebuild wrote is looked at, by exact place and name:
/// - `~/.relay/logs/<kind>-<yyyyMMdd>-<HHmmss>[-<session>][-<port>][-<n>].log` (`RunnerLauncher.createLog`)
/// - `~/.relay/build/*/TestData/port-<port>/Logs/Test/*.xcresult` (`RunnerLauncher.testDataURL`)
/// - `~/.relay/build/*/DerivedData-*/Logs/Test/*.xcresult`, where earlier versions wrote them
///
/// What is in use stays, by what the running processes hold rather than by age alone: a runner can be
/// quiet for days, and xcodebuild writes a running test's result inside `Staging`, which leaves the
/// bundle's own modification time at the moment it started. A port is in use while a `relay start` holds
/// its `StartLock` or a runner.json names it. Starts running side by side are safe: each takes a listing and
/// removes only what is outside its limits, and what another one removed first counts as removed.
enum RelayPrune {
    static let logKinds: Set<String> = ["start", "build", "runner", "record"]
    /// A week covers looking into a failure after a weekend or a few days on something else.
    static let logMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Stays whatever its age, per kind: after a long break the last runs are still there to compare. Parallel
    /// sessions share it, and 20 is a few restarts of each. A build log is about 150 KB, the others less.
    static let logsKeptPerKind = 20
    /// Per directory, so per port. The newest is usually the run in progress or the last one, and the others
    /// are the runs before it, for comparing with a failure; nothing in relay reads them.
    static let testResultsKept = 3
    /// A result this recent stays beyond `testResultsKept`, for a writer the locks do not tell about (an
    /// earlier version of relay writing to `DerivedData-*`). The next start removes it once it is older.
    static let testResultGrace: TimeInterval = 60 * 60

    /// A log or a test result, and when it was last modified.
    struct Item: Equatable {
        var url: URL
        var modified: Date
    }

    /// What one run did.
    struct Outcome: Equatable {
        var removedLogs = 0
        var removedTestResults = 0
        /// `<path>: <reason>` of what could not be removed.
        var failures: [String] = []

        /// One line for the terminal, only when something could not be removed.
        var problem: String? {
            guard let first = failures.first else { return nil }
            return "cannot remove \(failures.count) old log\(failures.count == 1 ? "" : "s") or test result\(failures.count == 1 ? "" : "s") (\(first))"
        }
    }

    // MARK: - What to remove

    /// The kind and the ports a log's name can stand for, or nil when relay did not name it. What follows the
    /// time can be read two ways (`-<port>-<n>` or `-<session>-<port>`, and a session can be all digits), so
    /// both of the last two numbers count: a log wrongly tied to a port is only kept longer.
    static func parseLogName(_ name: String) -> (kind: String, ports: Set<Int>)? {
        guard name.hasSuffix(".log") else { return nil }
        let parts = name.dropLast(".log".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, logKinds.contains(String(parts[0])), isDigits(parts[1], count: 8), isDigits(parts[2], count: 6) else {
            return nil
        }
        let ports = parts.dropFirst(3).suffix(2).compactMap { $0.allSatisfy(\.isASCII) ? Int($0) : nil }
        return (String(parts[0]), Set(ports))
    }

    /// The logs past `logMaxAge` and outside the newest `logsKeptPerKind` of their kind. On a port in use, the
    /// newest log of each kind stays too: that is what its `relay start` is writing, quiet or not. Later logs of
    /// one port are always newer, since one `relay start` runs per port at a time. So is a name in `protectedNames`.
    static func logsToRemove(_ logs: [Item], now: Date, activePorts: Set<Int>, protectedNames: Set<String> = []) -> [URL] {
        var kinds: [String: [(item: Item, ports: Set<Int>)]] = [:]
        for log in logs {
            guard let parsed = parseLogName(log.url.lastPathComponent) else { continue }
            kinds[parsed.kind, default: []].append((log, parsed.ports))
        }
        var removed: [URL] = []
        for entries in kinds.values {
            let sorted = entries.sorted { isNewer($0.item, than: $1.item) }
            var portsSeen = Set<Int>()
            for (index, entry) in sorted.enumerated() {
                let isCurrentOfPort = !entry.ports.intersection(activePorts).subtracting(portsSeen).isEmpty
                portsSeen.formUnion(entry.ports)
                if index >= logsKeptPerKind, !isCurrentOfPort, !protectedNames.contains(entry.item.url.lastPathComponent),
                   now.timeIntervalSince(entry.item.modified) > logMaxAge {
                    removed.append(entry.item.url)
                }
            }
        }
        return removed
    }

    /// The results of one directory outside the newest `testResultsKept` and older than `testResultGrace`.
    static func testResultsToRemove(_ results: [Item], now: Date) -> [URL] {
        results.sorted(by: isNewer).dropFirst(testResultsKept)
            .filter { now.timeIntervalSince($0.modified) > testResultGrace }
            .map(\.url)
    }

    // MARK: - What is there

    /// The ports whose `relay start` holds its lock. This process's own port is one of them.
    static func lockedPorts(home: URL) -> Set<Int> {
        let directory = StartLock.url(port: 0, home: home).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name -> Int? in
            guard name.hasPrefix("start-"), name.hasSuffix(".lock"),
                  let port = Int(name.dropFirst("start-".count).dropLast(".lock".count)),
                  StartLock.holder(of: StartLock.url(port: port, home: home)) != nil else { return nil }
            return port
        })
    }

    /// The ports the runner.json files name, which covers a runner still running after its `relay start` was
    /// killed (`flock` went with the process). One left by a `kill -9` counts until `relay stop` cleans it up.
    static func runnerInfoPorts(home: URL) -> Set<Int> {
        let files = [RunnerLocator.userURL(home: home)] + RelaySession.names(home: home).map { RelaySession.infoURL(name: $0, home: home) }
        return Set(files.compactMap { (try? RunnerInfo.read(from: $0)).map(Recording.port(of:)) })
    }

    /// The logs named by recordings' state files. A recording can outlive what the age tells, and state files
    /// of ended recordings only keep one more log for a while.
    static func recordingLogNames(home: URL) -> Set<String> {
        Set(Recording.stateURLs(home: home).compactMap { url in
            (try? RecordingState.read(from: url)).map { URL(fileURLWithPath: $0.log).lastPathComponent }
        })
    }

    /// The regular files in `~/.relay/logs` named as a log of one of `kinds`.
    static func logs(home: URL, kinds: Set<String> = logKinds) -> [Item] {
        let directory = home.appendingPathComponent(".relay/logs", isDirectory: true)
        return items(in: directory, keys: [.isRegularFileKey], accept: \.isRegularFile).filter {
            parseLogName($0.url.lastPathComponent).map { kinds.contains($0.kind) } == true
        }
    }

    /// Each directory that test results go to, with the port it belongs to; nil in the earlier `DerivedData-*`.
    static func testResultDirectories(home: URL) -> [(port: Int?, directory: URL)] {
        var found: [(port: Int?, directory: URL)] = []
        for root in subdirectories(of: home.appendingPathComponent(".relay/build", isDirectory: true)) {
            for port in subdirectories(of: root.appendingPathComponent("TestData", isDirectory: true)) {
                let name = port.lastPathComponent
                guard name.hasPrefix("port-"), let number = Int(name.dropFirst("port-".count)) else { continue }
                found.append((number, port.appendingPathComponent("Logs/Test", isDirectory: true)))
            }
            for derivedData in subdirectories(of: root) where derivedData.lastPathComponent.hasPrefix("DerivedData-") {
                found.append((nil, derivedData.appendingPathComponent("Logs/Test", isDirectory: true)))
            }
        }
        return found
    }

    /// The `.xcresult` bundles directly in `directory`. Not `LogStoreManifest.plist`, which stays xcodebuild's:
    /// it runs as usual with an entry whose bundle is gone, and drops that entry the next time it writes the file.
    static func testResults(in directory: URL) -> [Item] {
        items(in: directory, keys: [.isDirectoryKey], accept: \.isDirectory).filter { $0.url.pathExtension == "xcresult" }
    }

    // MARK: - Running

    /// Removes what is due. `ownPort` is the port of the `relay start` calling this, which holds its lock:
    /// nothing else can be running on it, so its results are looked at like those of an idle port, and every
    /// result written on a port gets removed in time by the next start there. `includeTestResults` is false
    /// for `relay record start`, which has only its logs to look after.
    @discardableResult
    static func run(
        home: URL = UserHome.url,
        ownPort: Int? = nil,
        kinds: Set<String> = logKinds,
        includeTestResults: Bool = true,
        now: Date = Date(),
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Outcome {
        let activePorts = lockedPorts(home: home).union(runnerInfoPorts(home: home))
        var outcome = Outcome()
        let removedLogs = logsToRemove(logs(home: home, kinds: kinds), now: now, activePorts: activePorts,
                                       protectedNames: recordingLogNames(home: home))
        for url in removedLogs where removeItem(url, remove: remove, failures: &outcome.failures) {
            outcome.removedLogs += 1
        }
        guard includeTestResults else { return outcome }
        for (port, directory) in testResultDirectories(home: home) {
            if let port, port != ownPort, activePorts.contains(port) { continue }
            for url in testResultsToRemove(testResults(in: directory), now: now)
            where removeItem(url, remove: remove, failures: &outcome.failures) {
                outcome.removedTestResults += 1
            }
        }
        return outcome
    }

    /// At the start of `relay start`, with the port's lock held.
    static func atStart(port: Int) {
        report(run(ownPort: port))
    }

    /// At `relay record start`: a runner that stays up can record many times with no `relay start` in between.
    static func atRecordStart() {
        report(run(kinds: ["record"], includeTestResults: false))
    }

    /// Removing is what relay start is expected to do, so it says nothing unless that failed.
    private static func report(_ outcome: Outcome) {
        if let problem = outcome.problem {
            CLIOutput.note(problem)
        }
    }

    /// Whether `url` is gone now. What another `relay start` removed first, even halfway through, counts as
    /// removed: that one finishes it, and a second try here covers it stopping in between.
    private static func removeItem(_ url: URL, remove: (URL) throws -> Void, failures: inout [String]) -> Bool {
        var failure: Error?
        for _ in 0..<2 {
            do {
                try remove(url)
                return true
            } catch {
                if !exists(url) { return true }
                failure = error
            }
        }
        failures.append("\(url.path): \(failure?.localizedDescription ?? "unknown error")")
        return false
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }

    private static func isDigits(_ text: Substring, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Newest first; the name (it holds the time) decides within one second.
    private static func isNewer(_ first: Item, than second: Item) -> Bool {
        first.modified != second.modified
            ? first.modified > second.modified
            : first.url.lastPathComponent > second.url.lastPathComponent
    }

    /// Real directories only: a symbolic link leads somewhere that is not relay's to clean.
    private static func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// The entries of `directory` that `accept` lets through, with their dates. One without a date stays out.
    private static func items(in directory: URL, keys: Set<URLResourceKey>, accept: (URLResourceValues) -> Bool?) -> [Item] {
        let allKeys = keys.union([.contentModificationDateKey])
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(allKeys))) ?? []
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: allKeys), accept(values) == true,
                  let modified = values.contentModificationDate else { return nil }
            return Item(url: url, modified: modified)
        }
    }
}
