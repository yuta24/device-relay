import Darwin
import Foundation

/// `relay start --background`: runs the same `relay start` detached from the terminal and waits until the
/// runner is ready, so a script or an agent gets its prompt back with the runner running.
///
/// The detached process is a new session (no controlling terminal, so closing the terminal does not
/// stop it) with stdin from /dev/null and stdout/stderr to `~/.relay/logs/start-<time>.log`. This process
/// reads that log: `ready: <url>` is success; the detached process exiting first, or no `ready:` in
/// time, is failure, and then the detached process is stopped like `relay stop` does, so neither it nor
/// its xcodebuild is left running.
enum BackgroundStart {
    /// Set for the detached `relay start`, which then stops a build when told to (`StartCancellation`).
    static let detachedEnvironmentKey = "RELAY_START_DETACHED"
    /// Time to boot a simulator and build the runner before it is launched; `--ready-timeout` then applies.
    static let launchTimeout: TimeInterval = 1800
    /// The detached `relay start` reports a startup failure itself; this is on top of `--ready-timeout`.
    static let readyGrace: TimeInterval = 15
    /// How long the detached process gets to stop the runner and shut down a simulator after SIGTERM.
    static let stopTimeout: TimeInterval = 60

    static var isDetachedChild: Bool {
        ProcessInfo.processInfo.environment[detachedEnvironmentKey] == "1"
    }

    /// What the log of the detached `relay start` says so far.
    struct Progress: Equatable {
        var readyURL: String?
        /// The runner was launched (the build is done), so `--ready-timeout` starts.
        var launched = false
    }

    /// Updates `progress` with one line of the log and returns the line to show while waiting, if any.
    /// The `relay:` lines tell what is going on (building, launching); the rest is in the log.
    static func handle(line: String, progress: inout Progress) -> String? {
        if line.hasPrefix("ready: ") {
            progress.readyURL = String(line.dropFirst("ready: ".count)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("relay: launching runner on ") {
            progress.launched = true
        }
        // The detached process cannot be stopped with Ctrl-C.
        guard line.hasPrefix("relay: "), !line.contains("press Ctrl-C") else { return nil }
        return line
    }

    /// Why a new runner must not start, given the runner in runner.json and its `/ping` answer; nil when
    /// nothing answered there. Any answer means something listens at that URL: a runner whose token is not
    /// the one in runner.json (401) would make the new runner's port clash all the same.
    static func conflict(with existing: RunnerInfo, ping: RunnerPing, owner: Int32?) -> String? {
        switch ping {
        case .unreachable:
            return nil
        case .alive:
            let process = owner.map { ", relay start pid \($0)" } ?? ""
            return "a runner is already running at \(existing.url) (\(existing.name ?? existing.udid)\(process)); "
                + "stop it with relay stop, or use it as it is"
        case .status(let status):
            let what = status == 401
                ? "answered 401 to the token in runner.json: another runner than the one runner.json names is probably running there"
                : "answered HTTP \(status) to /ping: something else is listening there"
            return "\(existing.url) \(what); stop it (relay stop, or the relay start that launched it), "
                + "or start on another port with --port"
        }
    }

    static func run(_ options: StartOptions, home: URL = UserHome.url) -> Int32 {
        let infoURL = RunnerLocator.userURL(home: home)
        if let existing = try? RunnerInfo.read(from: infoURL),
           let conflict = conflict(with: existing, ping: RunnerPing.check(existing), owner: RelayProcess.runningRelayStart(existing)) {
            return fail(conflict, code: .usage)
        }

        let logsURL = infoURL.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        let logURL = logsURL.appendingPathComponent("start-\(RunnerLauncher.timestamp()).log")
        let pid: pid_t
        do {
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
            pid = try spawnDetached(arguments: options.foregroundArguments, logURL: logURL)
        } catch {
            return fail("cannot start relay start in the background: \(error)", code: .usage)
        }
        info("started relay start in the background (pid \(pid), log: \(logURL.path))")

        let interrupted = InterruptFlag()
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { interrupted.set() }
            source.resume()
            signalSources.append(source)
        }

        var reader = LogReader(url: logURL)
        var progress = Progress()
        var processes = ProcessTree(root: pid)
        let started = Date()
        var launchedAt: Date?
        var exitStatus: Int32?
        var lastTreeUpdate = Date.distantPast
        while true {
            for line in reader.readLines() {
                if let shown = handle(line: line, progress: &progress) {
                    FileHandle.standardError.write(Data("\(shown)\n".utf8))
                }
            }
            if progress.launched, launchedAt == nil {
                launchedAt = Date()
            }
            if let url = progress.readyURL {
                return ready(url: url, pid: pid, logURL: logURL, infoURL: infoURL)
            }
            if let status = exitStatus ?? reap(pid) {
                // Read what it wrote just before exiting, which may be `ready:` after all.
                exitStatus = status
                for line in reader.readLines() {
                    if let shown = handle(line: line, progress: &progress) {
                        FileHandle.standardError.write(Data("\(shown)\n".utf8))
                    }
                }
                if progress.readyURL != nil { continue }
                processes.terminateLeftovers()
                return failed(
                    "relay start exited (\(describe(status))) before the runner was ready",
                    logURL: logURL, code: .usage
                )
            }
            if interrupted.isSet {
                stop(pid, processes: &processes)
                return failed("interrupted; stopped relay start before the runner was ready", logURL: logURL, code: .usage)
            }
            let deadline = launchedAt.map { $0.addingTimeInterval(options.readyTimeout + readyGrace) } ?? started.addingTimeInterval(launchTimeout)
            if Date() >= deadline {
                stop(pid, processes: &processes)
                let what = launchedAt == nil
                    ? "the runner was not launched within \(Int(launchTimeout))s (booting or building)"
                    : "the runner did not become ready within \(Int(options.readyTimeout))s of its launch"
                return failed("\(what); stopped relay start", logURL: logURL, code: .unavailable)
            }
            if Date().timeIntervalSince(lastTreeUpdate) >= 1 {
                processes.update()
                lastTreeUpdate = Date()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func ready(url: String, pid: pid_t, logURL: URL, infoURL: URL) -> Int32 {
        print("ready: \(url)")
        if let runnerInfo = try? RunnerInfo.read(from: infoURL) {
            print("device: \(runnerInfo.name.map { "\($0) (\(runnerInfo.udid))" } ?? runnerInfo.udid)")
        }
        print("pid: \(pid)")
        print("log: \(logURL.path)")
        print("token: \(infoURL.path)")
        info("the runner keeps running after this terminal closes; relay status shows it, relay stop stops it")
        return RunnerExitCode.success.rawValue
    }

    /// Runs this executable with `arguments` as a new session, with stdin from /dev/null and stdout and
    /// stderr appended to `logURL`. Signals ignored here (SIGINT while waiting) are reset in the child.
    static func spawnDetached(arguments: [String], logURL: URL) throws -> pid_t {
        let executable = RelayProcess.currentExecutable
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaults, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var environment = ProcessInfo.processInfo.environment
        environment[detachedEnvironmentKey] = "1"
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw ArgumentError(description: "posix_spawn \(executable): \(String(cString: strerror(result)))")
        }
        return pid
    }

    /// Sends SIGTERM, which the detached `relay start` handles like Ctrl-C (stopping its build, the runner,
    /// and a simulator it booted), and waits. If it does not exit in time, it and what it started are killed.
    private static func stop(_ pid: pid_t, processes: inout ProcessTree) {
        info("stopping relay start (pid \(pid))")
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(stopTimeout)
        while Date() < deadline {
            if reap(pid) != nil {
                processes.terminateLeftovers()
                return
            }
            processes.update()
            Thread.sleep(forTimeInterval: 0.2)
        }
        info("relay start did not exit within \(Int(stopTimeout))s; killing it and the processes it started")
        processes.update()
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        processes.terminateLeftovers(signal: SIGKILL)
    }

    /// The exit status of `pid` if it has exited (reaping it), else nil.
    private static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return status }
        // ECHILD: already reaped, which only `stop` does.
        return result < 0 && errno == ECHILD ? 0 : nil
    }

    /// "status 1" or "signal 9" for a `waitpid` status.
    static func describe(_ status: Int32) -> String {
        let signal = status & 0x7f
        return signal == 0 ? "status \((status >> 8) & 0xff)" : "signal \(signal)"
    }

    static let tailLineCount = 20
    static let tailLineWidth = 300

    private static func failed(_ reason: String, logURL: URL, code: RunnerExitCode) -> Int32 {
        let lines = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        let tail = lines.reversed().drop { $0.isEmpty }.prefix(tailLineCount).reversed()
        if !tail.isEmpty {
            info("last lines of \(logURL.path):")
            // xcodebuild's compiler invocations run to thousands of characters; the log has them in full.
            let shown = tail.map { $0.count > tailLineWidth ? "  \($0.prefix(tailLineWidth))…" : "  \($0)" }
            FileHandle.standardError.write(Data((shown.joined(separator: "\n") + "\n").utf8))
        }
        return fail("\(reason) (log: \(logURL.path))", code: code)
    }

    private static func info(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: RunnerExitCode) -> Int32 {
        info(message)
        return code.rawValue
    }
}

/// Set from a signal handler, read by the waiting loop.
private final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// New lines of a file another process appends to.
private struct LogReader {
    let url: URL
    private var handle: FileHandle?
    private var lines = RunnerOutputLineBuffer()

    init(url: URL) {
        self.url = url
    }

    mutating func readLines() -> [String] {
        if handle == nil {
            handle = try? FileHandle(forReadingFrom: url)
        }
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        return lines.append(data)
    }
}

/// The processes the detached `relay start` started (xcodebuild, simctl), remembered with their start
/// times. If it dies without stopping them, they are no longer its children, so this is how they are found.
private struct ProcessTree {
    let root: pid_t
    private var known: [pid_t: Date] = [:]

    init(root: pid_t) {
        self.root = root
    }

    mutating func update() {
        for pid in RelayProcess.descendants(of: root) where known[pid] == nil {
            if let startedAt = RelayProcess.startTime(pid: pid) {
                known[pid] = startedAt
            }
        }
        // Forget the ones that exited, so a reused pid is never mistaken for them.
        known = known.filter { RelayProcess.startTime(pid: $0.key) == $0.value }
    }

    /// Signals the remembered processes that still run (same pid and start time), deepest first.
    func terminateLeftovers(signal: Int32 = SIGTERM) {
        for (pid, startedAt) in known.sorted(by: { $0.value > $1.value }) where RelayProcess.startTime(pid: pid) == startedAt {
            FileHandle.standardError.write(Data("relay: stopping pid \(pid), which relay start left running\n".utf8))
            kill(pid, signal)
        }
    }
}

/// Lets a detached `relay start` stop cleanly when it gets SIGTERM (from `relay stop`, or from the waiting
/// `relay start --background` on failure) before the runner is launched: it ends the running simctl or
/// xcodebuild, and `relay start` then exits through its usual error path, which shuts down a simulator it
/// booted. After the launch, `RunnerLauncher`'s own signal handling takes over.
///
/// A foreground `relay start` does not install this, so Ctrl-C during a build behaves as before.
enum StartCancellation {
    private static let lock = NSLock()
    private static var requested = false
    private static var sources: [DispatchSourceSignal] = []

    static var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    static func install() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                lock.lock()
                requested = true
                lock.unlock()
                FileHandle.standardError.write(Data("relay: stop requested\n".utf8))
                Shell.terminateRunning()
            }
            source.resume()
            sources.append(source)
        }
    }
}
