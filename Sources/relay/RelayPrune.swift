import Darwin
import Foundation

/// Removes the logs, test results and build directories that pile up as relay is used, at the start of every
/// `relay start` (and the `record-` logs at `relay record start`). It only reads a few directories and lock files, and a
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
///
/// A whole `~/.relay/build/<dir>` goes when the runner project it was built from no longer exists, or when
/// relay has not used it for `buildUnusedMaxAge` (only its `BuildDirectoryRecord` tells). A directory from before
/// that record has `DerivedData-*/info.plist` to name its project, which is enough for the first rule only.
/// `installed` belongs to `relay install`. Being in use is told by `StartBuildClaim` and runner.json; when either
/// cannot tell (a relay before them, or a start that took its lock a moment ago), nothing goes in that run.
///
/// Moving a directory away holds its `BuildLock` exclusively and looks at all of this once more first. A `relay start`
/// writes its claim before it takes that lock, so another start is either seen here, or finds the directory gone
/// when it gets the lock and builds; it never sees half a directory, and never loses one it is launching from.
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
    /// A month covers a version or a worktree put aside for a holiday or another project and picked up again. A
    /// build takes minutes and tens to hundreds of MB, so it stays longer than a log, and a wrong guess is one rebuild.
    static let buildUnusedMaxAge: TimeInterval = 30 * 24 * 60 * 60
    /// `relay install` and `relay uninstall` look after this one (`RunnerProject.buildDirectory`).
    static let installedBuildName = "installed"
    /// A build directory being removed. Hidden, so it is never taken for a build.
    static let removingPrefix = ".removing-"

    /// A log or a test result, and when it was last modified.
    struct Item: Equatable {
        var url: URL
        var modified: Date
    }

    /// What one run did.
    struct Outcome: Equatable {
        var removedLogs = 0
        var removedTestResults = 0
        var removedBuildDirectories = 0
        /// `<path>: <reason>` of what could not be removed.
        var failures: [String] = []

        /// One line for the terminal, only when something could not be removed.
        var problem: String? {
            guard let first = failures.first else { return nil }
            let plural = failures.count == 1 ? "" : "s"
            return "cannot remove \(failures.count) old log\(plural), test result\(plural) or build\(plural) (\(first))"
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

    /// Whether the directory `name` under `builds` is due, whatever is running. A directory only goes on the word
    /// of what it holds, and only if that word fits its name: `buildDirectory(root:)` of the recorded root, or for
    /// an earlier directory `<last path component>-<hash>`, as the path Xcode saw may be spelled differently.
    static func isBuildDirectoryDue(_ name: String, home: URL, now: Date) -> Bool {
        let directory = buildsDirectory(home: home).appendingPathComponent(name, isDirectory: true)
        if let record = BuildDirectoryRecord.read(buildDirectory: directory) {
            let root = URL(fileURLWithPath: record.root, isDirectory: true)
            guard record.root.hasPrefix("/"), RunnerProject.buildDirectory(root: root, home: home).lastPathComponent == name else {
                return false
            }
            return !RunnerProject.contains(root) || now.timeIntervalSince(record.lastUsed) > buildUnusedMaxAge
        }
        let paths = xcodeWorkspacePaths(in: directory)
        return !paths.isEmpty && paths.allSatisfy { path in
            guard path.hasSuffix("/" + RunnerProject.projectPath) else { return false }
            let root = URL(fileURLWithPath: String(path.dropLast(RunnerProject.projectPath.count + 1)), isDirectory: true)
            return isNamed(name, afterRoot: root) && !RunnerProject.contains(root)
        }
    }

    /// `<root's last path component>-<12 hex digits>`.
    private static func isNamed(_ name: String, afterRoot root: URL) -> Bool {
        let prefix = root.lastPathComponent + "-"
        guard name.hasPrefix(prefix) else { return false }
        let hash = name.dropFirst(prefix.count)
        return hash.count == 12 && hash.allSatisfy(\.isHexDigit)
    }

    // MARK: - What is there

    /// Who holds each port's `relay start` lock. This process's own port is one of them.
    private static func portLockHolders(home: URL) -> [Int: StartLock.Holder] {
        let directory = StartLock.url(port: 0, home: home).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var holders: [Int: StartLock.Holder] = [:]
        for name in names where name.hasPrefix("start-") && name.hasSuffix(".lock") {
            if let port = Int(name.dropFirst("start-".count).dropLast(".lock".count)),
               let holder = StartLock.holder(of: StartLock.url(port: port, home: home)) {
                holders[port] = holder
            }
        }
        return holders
    }

    /// The ports whose `relay start` holds its lock. This process's own port is one of them.
    static func lockedPorts(home: URL) -> Set<Int> {
        Set(portLockHolders(home: home).keys)
    }

    /// The ports the runner.json files name, which covers a runner still running after its `relay start` was
    /// killed (`flock` went with the process). One left by a `kill -9` counts until `relay stop` cleans it up.
    static func runnerInfoPorts(home: URL) -> Set<Int> {
        Set(runnerInfos(home: home).map(Recording.port(of:)))
    }

    private static func runnerInfos(home: URL) -> [RunnerInfo] {
        let files = [RunnerLocator.userURL(home: home)] + RelaySession.names(home: home).map { RelaySession.infoURL(name: $0, home: home) }
        return files.compactMap { try? RunnerInfo.read(from: $0) }
    }

    /// The build directories (by name) in use by other `relay start`s and by runners, or nil when something
    /// running does not say which is its own, so that any of them could be. The lock of `ownPort` is the caller's,
    /// and a runner.json of that port that names nothing is one left behind, as nothing else can be running there.
    static func buildDirectoriesInUse(home: URL, ownPort: Int?) -> Set<String>? {
        var names = Set<String>()
        for (port, holder) in portLockHolders(home: home) where port != ownPort {
            guard let claim = StartBuildClaim.read(port: port, home: home), claim.pid == holder.pid else { return nil }
            names.insert(claim.buildDirectory)
        }
        for info in runnerInfos(home: home) {
            if let name = info.buildDirectory {
                names.insert(name)
            } else if Recording.port(of: info) != ownPort {
                return nil
            }
        }
        return names
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
        for root in subdirectories(of: buildsDirectory(home: home)) where !root.lastPathComponent.hasPrefix(".") {
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

    private static func buildsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".relay/build", isDirectory: true)
    }

    /// `WorkspacePath` of each `DerivedData-*/info.plist` Xcode wrote in a build directory.
    private static func xcodeWorkspacePaths(in directory: URL) -> [String] {
        derivedDataNames(in: directory).compactMap { name in
            let plist = directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("info.plist")
            return (try? Data(contentsOf: plist))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["WorkspacePath"] as? String
        }
    }

    private static func derivedDataNames(in directory: URL) -> [String] {
        subdirectories(of: directory).map(\.lastPathComponent).filter { $0.hasPrefix("DerivedData-") }
    }

    // MARK: - Running

    /// Removes what is due. `ownPort` is the port of the `relay start` calling this, which holds its lock:
    /// nothing else can be running on it, so its results are looked at like those of an idle port, and every
    /// result written on a port gets removed in time by the next start there. `includeTestResults` is false
    /// for `relay record start`, which has only its logs to look after. `ownBuildDirectory` is the name of the build
    /// directory the caller uses; without it (`relay record start`, or a runner project not found) no build
    /// directory goes, as the caller's could be any of them.
    @discardableResult
    static func run(
        home: URL = UserHome.url,
        ownPort: Int? = nil,
        ownBuildDirectory: String? = nil,
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
        if let ownBuildDirectory {
            removeBuildDirectories(home: home, ownPort: ownPort, own: ownBuildDirectory, now: now, remove: remove, outcome: &outcome)
        }
        for (port, directory) in testResultDirectories(home: home) {
            if let port, port != ownPort, activePorts.contains(port) { continue }
            for url in testResultsToRemove(testResults(in: directory), now: now)
            where removeItem(url, remove: remove, failures: &outcome.failures) {
                outcome.removedTestResults += 1
            }
        }
        return outcome
    }

    /// At the start of `relay start`, with the port's lock held. The runner project is looked up here as
    /// `StartSetup.prepare` does next; when that fails, so does the start.
    static func atStart(port: Int, project: String?) {
        let own = (try? RunnerProject.resolve(explicitPath: project)).map { RunnerProject.buildDirectory(root: $0.root).lastPathComponent }
        if let own {
            try? StartBuildClaim(pid: getpid(), buildDirectory: own).write(port: port)
        }
        report(run(ownPort: port, ownBuildDirectory: own))
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

    /// Removes what a run before this one left under a `removingPrefix` name, and the build directories that are due.
    private static func removeBuildDirectories(home: URL, ownPort: Int?, own: String, now: Date, remove: (URL) throws -> Void,
                                               outcome: inout Outcome) {
        let builds = buildsDirectory(home: home)
        let names = subdirectories(of: builds).map(\.lastPathComponent).sorted()
        // Under a name of its own first, so one run removes it even if another is at it or the one that named it
        // is still running: that one finds its name gone, which counts as removed.
        for name in names where name.hasPrefix(removingPrefix) {
            let leftover = builds.appendingPathComponent(name, isDirectory: true)
            let renamed = builds.appendingPathComponent(removingName(), isDirectory: true)
            if rename(leftover.path, renamed.path) == 0 {
                _ = removeItem(renamed, remove: remove, failures: &outcome.failures)
            }
        }
        guard var inUse = buildDirectoriesInUse(home: home, ownPort: ownPort) else { return }
        inUse.formUnion([own, installedBuildName])
        for name in names where !name.hasPrefix(".") && !inUse.contains(name) && isBuildDirectoryDue(name, home: home, now: now) {
            if let moved = moveAside(name, home: home, ownPort: ownPort, now: now, failures: &outcome.failures),
               removeItem(moved, remove: remove, failures: &outcome.failures) {
                outcome.removedBuildDirectories += 1
            }
        }
    }

    /// Moves a build directory due for removal to a `removingPrefix` name, unless a `relay start` has come for it
    /// since it was found (see the top of this file). Returns the new place, or nil when it stays.
    private static func moveAside(_ name: String, home: URL, ownPort: Int?, now: Date, failures: inout [String]) -> URL? {
        let builds = buildsDirectory(home: home)
        let directory = builds.appendingPathComponent(name, isDirectory: true)
        let relayDirectory = home.appendingPathComponent(".relay", isDirectory: true)
        var locks: [BuildLock] = []
        defer { locks.forEach { $0.release() } }
        // The two names `RunnerLauncher` builds into, which may not be there yet.
        for derivedData in Set(derivedDataNames(in: directory) + ["DerivedData-sim", "DerivedData-device"]) {
            guard let lock = try? BuildLock(derivedData: directory.appendingPathComponent(derivedData, isDirectory: true), relayDirectory: relayDirectory),
                  lock.tryExclusive() else { return nil }
            locks.append(lock)
        }
        guard let inUse = buildDirectoriesInUse(home: home, ownPort: ownPort), !inUse.contains(name),
              isBuildDirectoryDue(name, home: home, now: now) else { return nil }
        let moved = builds.appendingPathComponent(removingName(), isDirectory: true)
        guard rename(directory.path, moved.path) == 0 else {
            let error = errno
            // Gone already: another start took it first and counts it.
            if error != ENOENT {
                failures.append("\(directory.path): \(String(cString: strerror(error)))")
            }
            return nil
        }
        return moved
    }

    private static func removingName() -> String {
        removingPrefix + UUID().uuidString
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
