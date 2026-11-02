import Darwin
import Foundation

/// `relay record start|stop|status`: records the screen of the simulator the runner runs on, with
/// `simctl io <udid> recordVideo`. Devices are not supported yet.
struct RecordOptions: Equatable {
    enum Action: Equatable {
        /// `--output`, resolved later (`Recording.outputURL`). `force`: replace an existing file.
        case start(output: String?, maxDuration: TimeInterval, force: Bool = false)
        case stop
        case status(json: Bool)
        /// The detached process `record start` runs (`RecordSupervisor`); not in the usage.
        case supervise(udid: String, output: String, maxDuration: TimeInterval)
    }

    var action: Action
    /// `--runner <path>`; nil searches as `RunnerLocator` describes.
    var runnerPath: String?
    /// `--port <n>` of `record stop` and `record status`: the state file of that runner port, without runner.json.
    var port: Int?
}

/// What `record start` keeps in `~/.relay/recording-<port>.json` (mode 0600, like runner.json) while it
/// records, one per runner port: `record stop`, `record status`, and the cleanup of `relay stop` read it.
struct RecordingState: Codable, Equatable {
    /// The `simctl io … recordVideo` process, which `record stop` sends SIGINT to.
    var pid: Int32
    /// When that process started. With `pid` and its name, it tells the process apart from one that reuses
    /// the pid after it exited (see `Recording.isRecordingProcess`).
    var processStartedAt: Date
    /// The detached `relay record supervise` that runs simctl and enforces `maxDuration`.
    var supervisorPid: Int32
    /// The absolute path of the video.
    var output: String
    var udid: String
    var port: Int
    /// When the recording started (whole seconds).
    var startedAt: Date
    var maxDuration: TimeInterval
    /// The log with simctl's output and the supervisor's `relay:` lines.
    var log: String

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created 0600 with O_EXCL, as RunnerInfo.write does.
        unlink(url.path)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw ArgumentError(description: "cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    static func read(from url: URL) throws -> RecordingState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingState.self, from: Data(contentsOf: url))
    }
}

enum Recording {
    /// Long enough for a flow worth showing, short enough that a forgotten recording does not fill the disk.
    static let defaultMaxDuration: TimeInterval = 600
    /// simctl prints this once it writes frames.
    static let startedMarker = "Recording started"
    /// The supervisor's line with the simctl pid.
    static let pidMarker = "relay: recording with simctl pid "
    /// How long `record start` waits for `startedMarker`.
    static let startTimeout: TimeInterval = 15
    /// How long simctl gets to write the video after SIGINT (a few seconds for minutes of video).
    static let stopTimeout: TimeInterval = 30
    /// When a runner URL has no port, as `relay start`'s default.
    static let defaultPort = 8100

    // MARK: - Pure helpers

    static func simctlArguments(udid: String, output: String) -> [String] {
        ["simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", output]
    }

    /// The arguments of the detached supervisor, which `Arguments.parse` reads back.
    static func superviseArguments(udid: String, output: String, maxDuration: TimeInterval) -> [String] {
        ["record", "supervise", "--udid", udid, "--output", output, "--max-duration", "\(maxDuration)"]
    }

    /// `--output` resolved against the current directory, or `$TMPDIR/relay/relay-recording-<time>.mp4`,
    /// outside the working tree like the screenshots (`RunnerControl.screenshotURL`).
    static func outputURL(
        _ output: String?,
        now: Date = Date(),
        currentDirectory: URL = WorkingDirectory.url,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        if let output {
            return RunnerLocator.resolve(output, in: currentDirectory)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return temporaryDirectory
            .appendingPathComponent("relay", isDirectory: true)
            .appendingPathComponent("relay-recording-\(formatter.string(from: now)).mp4")
            .standardizedFileURL
    }

    /// Why the video cannot be written to `url`, if it cannot: a given directory must exist (relay creates
    /// only its own `$TMPDIR/relay`), the path must not be a directory, and an existing file is replaced only
    /// with `force`. simctl always gets its own --force: the check is here, before anything starts, so the
    /// error is relay's and not one in simctl's log.
    static func outputProblem(_ url: URL, force: Bool = false, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return "\(url.path) is a directory; give a file path such as \(url.appendingPathComponent("recording.mp4").path)"
            }
            if !force {
                return "\(url.path) already exists; pass --force to replace it, or give another --output"
            }
        }
        let parent = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "the directory of \(url.path) does not exist; create \(parent.path) first or give another --output"
        }
        return nil
    }

    static func stateURL(port: Int, home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay", isDirectory: true).appendingPathComponent("recording-\(port).json")
    }

    static func lockURL(port: Int, home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay/locks", isDirectory: true).appendingPathComponent("record-\(port).lock")
    }

    /// The state files in `~/.relay`, for `record stop` and `record status` when there is no runner.json.
    static func stateURLs(home: URL = UserHome.url) -> [URL] {
        let directory = home.appendingPathComponent(".relay", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("recording-") && $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// The port in a state file's name (`recording-8100.json`).
    static func port(ofStateURL url: URL) -> Int? {
        let name = url.lastPathComponent
        guard name.hasPrefix("recording-"), name.hasSuffix(".json") else { return nil }
        return Int(name.dropFirst("recording-".count).dropLast(".json".count))
    }

    /// A state file found without runner.json, for the list in `severalRecordingsMessage`.
    struct Candidate: Equatable {
        var port: Int
        /// nil when the file cannot be read.
        var output: String?
        var recording: Bool
    }

    /// The error of `record stop` and `record status` without runner.json and with several state files.
    static func severalRecordingsMessage(_ candidates: [Candidate]) -> String {
        let lines = candidates.sorted { $0.port < $1.port }.map { candidate in
            let what = candidate.output.map { "\($0) (\(candidate.recording ? "recording" : "ended"))" } ?? "(cannot read the state file)"
            return "  --port \(candidate.port): \(what)"
        }
        return "no runner.json, and recordings of several runner ports:\n\(lines.joined(separator: "\n"))\nchoose one with --port <n>"
    }

    /// The port recordings of the runner in runner.json are kept under.
    static func port(of info: RunnerInfo) -> Int {
        URL(string: info.url)?.port ?? defaultPort
    }

    /// The device runner.json names, as the simulator list sees it.
    enum Target: Equatable {
        case simulator(Device)
        /// Not in the simulator list: a device (or a simulator deleted since).
        case notSimulator
    }

    static func target(udid: String, simulators: [Device]) -> Target {
        simulators.first { $0.kind == .simulator && $0.udid == udid }.map(Target.simulator) ?? .notSimulator
    }

    /// What the log of `record supervise` says so far.
    struct Progress: Equatable {
        var simctlPid: Int32?
        /// simctl printed `Recording started`.
        var started = false
    }

    static func handle(line: String, progress: inout Progress) {
        if line.hasPrefix(pidMarker) {
            progress.simctlPid = Int32(line.dropFirst(pidMarker.count).trimmingCharacters(in: .whitespaces))
        } else if line.trimmingCharacters(in: .whitespaces) == startedMarker {
            progress.started = true
        }
    }

    /// Whether `snapshot` is the simctl that recorded `pid` and `startedAt` in the state: the start time
    /// matches to the second, the executable is simctl, and it runs recordVideo.
    static func isRecordingProcess(_ snapshot: RelayProcess.Snapshot, startedAt: Date) -> Bool {
        abs(snapshot.startedAt.timeIntervalSince1970.rounded(.down) - startedAt.timeIntervalSince1970.rounded(.down)) < 1
            && URL(fileURLWithPath: snapshot.executable).lastPathComponent == "simctl"
            && snapshot.arguments.contains("recordVideo")
    }

    static func isRecording(_ state: RecordingState, snapshot: (Int32) -> RelayProcess.Snapshot? = RelayProcess.snapshot(pid:)) -> Bool {
        guard let process = snapshot(state.pid) else { return false }
        return isRecordingProcess(process, startedAt: state.processStartedAt)
    }

    /// The supervisor's `relay:` lines after the pid (why the recording ended, and how simctl exited), from the log text.
    static func endReason(inLog text: String) -> String? {
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("relay: ") && !$0.hasPrefix(pidMarker) }
            .map { String($0.dropFirst("relay: ".count)) }
        return lines.isEmpty ? nil : lines.joined(separator: "; ")
    }

    static func alreadyRecordingMessage(_ state: RecordingState, url: String) -> String {
        "a recording is already running for the runner at \(url) (\(state.output), simctl pid \(state.pid)); "
            + "stop it with relay record stop, or check it with relay record status"
    }

    static func elapsed(_ state: RecordingState, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(state.startedAt)))
    }

    // MARK: - Commands

    static func run(_ options: RecordOptions) -> Int32 {
        switch options.action {
        case .start(let output, let maxDuration, let force):
            return start(output: output, maxDuration: maxDuration, force: force, runnerPath: options.runnerPath)
        case .stop:
            return stop(runnerPath: options.runnerPath, port: options.port)
        case .status(let json):
            return status(json: json, runnerPath: options.runnerPath, port: options.port)
        case .supervise(let udid, let output, let maxDuration):
            return RecordSupervisor.run(udid: udid, output: output, maxDuration: maxDuration)
        }
    }

    private static func start(output: String?, maxDuration: TimeInterval, force: Bool, runnerPath: String?, home: URL = UserHome.url) -> Int32 {
        let info: RunnerInfo
        do {
            info = try RunnerInfo.read(from: try RunnerLocator.locate(explicitPath: runnerPath, home: home))
        } catch let error as RunnerUnavailableError {
            return fail(error.description, code: .unavailable)
        } catch {
            return fail("cannot read runner info: \(error)", code: .usage)
        }
        let ping = RunnerPing.check(info)
        guard ping.isAlive else {
            return fail("the runner at \(info.url) does not answer (\(ping.summary)); relay status shows it, relay start --background starts one",
                        code: ping.exitCode)
        }

        let simulators: [Device]
        do {
            simulators = try DeviceList.parseSimctl(Data(Shell.xcrun(["simctl", "list", "devices", "--json"]).utf8))
        } catch {
            return fail("cannot list the simulators: \(error)", code: .usage)
        }
        guard case .simulator(let simulator) = target(udid: info.udid, simulators: simulators) else {
            return fail("the runner runs on \(info.name.map { "\($0) (\(info.udid))" } ?? info.udid), which is not a simulator; "
                + "recording a device is not supported yet (simulators only)", code: .usage)
        }
        // simctl also "records" a shut-down simulator, into an empty file.
        guard simulator.isBooted else {
            return fail("the simulator \(simulator.name) (\(simulator.udid)) is \(simulator.state); recording needs it booted",
                        code: .usage)
        }

        let outputURL = outputURL(output)
        if output == nil {
            try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let problem = outputProblem(outputURL, force: force) {
            return fail(problem, code: .usage)
        }

        let port = port(of: info)
        // Held until this process exits, so two record starts for one runner cannot both pass the check below.
        let lockURL = lockURL(port: port, home: home)
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockFD >= 0 else {
            return fail("cannot open \(lockURL.path): \(String(cString: strerror(errno)))", code: .usage)
        }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            return fail("another relay record start for the runner at \(info.url) is starting; check it with relay record status", code: .usage)
        }

        let stateURL = stateURL(port: port, home: home)
        if let existing = try? RecordingState.read(from: stateURL) {
            if isRecording(existing) {
                return fail(alreadyRecordingMessage(existing, url: info.url), code: .usage)
            }
            unlink(stateURL.path)
            note("removed the state of a recording that has ended (\(existing.output) stays)")
        }

        let logsURL = home.appendingPathComponent(".relay/logs", isDirectory: true)
        let logURL: URL
        let supervisor: pid_t
        do {
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
            logURL = try RunnerLauncher.createLog("record", in: logsURL, stamp: RunnerLauncher.timestamp(), port: port)
            supervisor = try BackgroundStart.spawnDetached(
                arguments: superviseArguments(udid: info.udid, output: outputURL.path, maxDuration: maxDuration), logURL: logURL
            )
        } catch {
            return fail("cannot start the recording: \(error)", code: .usage)
        }

        // Ctrl-C while waiting stops the recording rather than leaving it to run until --max-duration.
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
        let deadline = Date().addingTimeInterval(startTimeout)
        while true {
            for line in reader.readLines() {
                handle(line: line, progress: &progress)
            }
            if progress.started, let pid = progress.simctlPid, let processStartedAt = RelayProcess.startTime(pid: pid) {
                let state = RecordingState(
                    pid: pid, processStartedAt: processStartedAt, supervisorPid: supervisor, output: outputURL.path,
                    udid: info.udid, port: port, startedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                    maxDuration: maxDuration, log: logURL.path
                )
                do {
                    try state.write(to: stateURL)
                } catch {
                    kill(pid, SIGINT)
                    return fail("cannot save the recording state: \(error); stopped the recording", code: .usage)
                }
                print(outputURL.path)
                note("recording \(simulator.name) (\(info.udid)) for at most \(Int(maxDuration))s; relay record stop finishes the video "
                    + "(log: \(logURL.path))")
                return RunnerExitCode.success.rawValue
            }
            var status: Int32 = 0
            if waitpid(supervisor, &status, WNOHANG) == supervisor {
                return failed("simctl exited (\(BackgroundStart.describe(status))) before the recording started", logURL: logURL)
            }
            if interrupted.isSet || Date() >= deadline {
                kill(supervisor, SIGTERM)
                waitpid(supervisor, &status, 0)
                let reason = interrupted.isSet ? "interrupted" : "simctl did not report \(startedMarker) within \(Int(startTimeout))s"
                return failed("\(reason); stopped the recording", logURL: logURL)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func stop(runnerPath: String?, port: Int?, home: URL = UserHome.url) -> Int32 {
        let found: (url: URL, state: RecordingState)?
        do {
            found = try locateState(runnerPath: runnerPath, port: port, home: home)
        } catch {
            return fail("\(error)", code: .usage)
        }
        guard let found else {
            print("not recording")
            return RunnerExitCode.success.rawValue
        }
        switch finish(found.state, stateURL: found.url) {
        case .saved(let path):
            print(path)
            return RunnerExitCode.success.rawValue
        case .failed(let message, let code):
            return fail(message, code: code)
        }
    }

    enum Outcome: Equatable {
        case saved(String)
        case failed(String, RunnerExitCode)
    }

    /// Stops the recording if simctl still runs, waits for the video, and removes the state. The state stays
    /// only when simctl does not exit in time, so `record stop` can be run again.
    static func finish(_ state: RecordingState, stateURL: URL) -> Outcome {
        if isRecording(state) {
            kill(state.pid, SIGINT)
            let deadline = Date().addingTimeInterval(stopTimeout)
            while isRecording(state) {
                guard Date() < deadline else {
                    return .failed("simctl (pid \(state.pid)) did not finish writing \(state.output) within \(Int(stopTimeout))s; "
                        + "run relay record stop again, or see \(state.log)", .usage)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            waitForSupervisor(state)
        } else if let reason = endReason(inLog: (try? String(contentsOfFile: state.log, encoding: .utf8)) ?? "") {
            note("the recording had already ended (\(reason))")
        } else {
            note("the recording had already ended")
        }
        unlink(stateURL.path)
        if isShutDown(udid: state.udid) {
            note("the simulator \(state.udid) is no longer booted; the video ends where it shut down")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: state.output)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            let what = FileManager.default.fileExists(atPath: state.output) ? "is empty" : "was not written"
            return .failed("the video \(state.output) \(what); see \(state.log)", .usage)
        }
        return .saved(state.output)
    }

    /// For `relay stop` and the exit of `relay start`: finishes the recording of the runner on `port`, if any,
    /// telling on stderr where the video is (stdout stays theirs).
    static func cleanUp(port: Int, home: URL = UserHome.url) {
        let url = stateURL(port: port, home: home)
        guard let state = try? RecordingState.read(from: url) else { return }
        note("finishing the recording of the runner first")
        switch finish(state, stateURL: url) {
        case .saved(let path):
            note("saved the recording: \(path)")
        case .failed(let message, _):
            note(message)
        }
    }

    private static func status(json: Bool, runnerPath: String?, port: Int?, home: URL = UserHome.url) -> Int32 {
        let found: (url: URL, state: RecordingState)?
        do {
            found = try locateState(runnerPath: runnerPath, port: port, home: home)
        } catch {
            return fail("\(error)", code: .usage)
        }
        guard let found else {
            if json {
                FileHandle.standardOutput.write(Data("{\"recording\":false}\n".utf8))
            } else {
                print("not recording")
            }
            return RunnerExitCode.success.rawValue
        }
        let recording = isRecording(found.state)
        if json {
            FileHandle.standardOutput.write(statusJSON(found.state, recording: recording, stateURL: found.url) + Data("\n".utf8))
        } else {
            print(statusText(found.state, recording: recording, stateURL: found.url))
        }
        return RunnerExitCode.success.rawValue
    }

    static func statusText(_ state: RecordingState, recording: Bool, stateURL: URL, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let rows: [(String, String)] = [
            ("recording", recording
                ? "yes (\(elapsed(state, now: now))s; stops by itself after \(Int(state.maxDuration))s)"
                : "ended (relay record stop prints the video's path)"),
            ("output", state.output),
            ("device", state.udid),
            ("pid", "\(state.pid) (simctl\(recording ? "" : ", exited"))"),
            ("started", RunnerStatus.formatted(state.startedAt, timeZone: timeZone)),
            ("log", state.log),
            ("state", stateURL.path)
        ]
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "\($0.0):\(String(repeating: " ", count: width - $0.0.count + 1))\($0.1)" }.joined(separator: "\n")
    }

    static func statusJSON(_ state: RecordingState, recording: Bool, stateURL: URL, now: Date = Date()) -> Data {
        let object: [String: Any] = [
            "recording": recording,
            "output": state.output,
            "udid": state.udid,
            "port": state.port,
            "pid": NSNumber(value: state.pid),
            "startedAt": ISO8601DateFormatter().string(from: state.startedAt),
            "elapsedSeconds": elapsed(state, now: now),
            "maxDuration": state.maxDuration,
            "log": state.log,
            "state": stateURL.path
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// The recording of `--port`, else of the runner in runner.json, or nil when there is none. Without
    /// runner.json (the runner stopped) and without `--runner` or `$RELAY_RUNNER`, the only state file in
    /// `~/.relay`, if there is one; several are an error that lists them by port.
    private static func locateState(runnerPath: String?, port: Int?, home: URL) throws -> (url: URL, state: RecordingState)? {
        guard let url = try port.map({ stateURL(port: $0, home: home) }) ?? stateURLOfRunner(runnerPath: runnerPath, home: home) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return (url, try RecordingState.read(from: url))
        } catch {
            throw ArgumentError(description: "cannot read \(url.path): \(error)")
        }
    }

    private static func stateURLOfRunner(runnerPath: String?, home: URL) throws -> URL? {
        do {
            let info = try RunnerInfo.read(from: try RunnerLocator.locate(explicitPath: runnerPath, home: home))
            return stateURL(port: port(of: info), home: home)
        } catch is RunnerUnavailableError {
            let explicit = runnerPath != nil || !(ProcessInfo.processInfo.environment[RunnerLocator.environmentKey] ?? "").isEmpty
            let candidates = explicit ? [] : stateURLs(home: home)
            guard candidates.count <= 1 else {
                throw ArgumentError(description: severalRecordingsMessage(candidates.compactMap { url in
                    let state = try? RecordingState.read(from: url)
                    return port(ofStateURL: url).map { Candidate(port: $0, output: state?.output, recording: state.map { isRecording($0) } ?? false) }
                }))
            }
            return candidates.first
        }
    }

    private static func waitForSupervisor(_ state: RecordingState) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, let snapshot = RelayProcess.snapshot(pid: state.supervisorPid),
              snapshot.arguments.dropFirst().prefix(2) == ["record", "supervise"] {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func isShutDown(udid: String) -> Bool {
        guard let output = try? Shell.xcrun(["simctl", "list", "devices", "--json"]),
              let simulators = try? DeviceList.parseSimctl(Data(output.utf8)),
              case .simulator(let simulator) = target(udid: udid, simulators: simulators) else { return false }
        return !simulator.isBooted
    }

    private static func failed(_ reason: String, logURL: URL) -> Int32 {
        let lines = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n") ?? []
        if !lines.isEmpty {
            note("simctl's output (\(logURL.path)):")
            FileHandle.standardError.write(Data((lines.suffix(BackgroundStart.tailLineCount).map { "  \($0)" }.joined(separator: "\n") + "\n").utf8))
        }
        return fail(reason, code: .usage)
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: RunnerExitCode) -> Int32 {
        note(message)
        return code.rawValue
    }
}

/// `relay record supervise`, which `record start` runs detached (a new session, stdin from /dev/null, output
/// to the log), so the recording outlives the terminal and is not stopped by Ctrl-C there. It runs simctl,
/// reports its pid, stops it with SIGINT after `maxDuration`, and exits when it exits.
enum RecordSupervisor {
    static func run(udid: String, output: String, maxDuration: TimeInterval) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = Recording.simctlArguments(udid: udid, output: output)
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("cannot run xcrun simctl: \(error)")
            return 1
        }
        // xcrun executes simctl in its own process, so this is simctl's pid.
        log("recording with simctl pid \(process.processIdentifier)")

        // After the launch, so simctl does not inherit the signals as ignored. Any of them stops the recording.
        let stop = InterruptFlag()
        var sources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { stop.set() }
            source.resume()
            sources.append(source)
        }

        let started = Date()
        var stoppedAt: Date?
        while process.isRunning {
            if stoppedAt == nil, stop.isSet || Date().timeIntervalSince(started) >= maxDuration {
                log(stop.isSet ? "stopping the recording" : "reached --max-duration of \(Int(maxDuration))s; stopped the recording")
                kill(process.processIdentifier, SIGINT)
                stoppedAt = Date()
            }
            if let stoppedAt, Date().timeIntervalSince(stoppedAt) >= Recording.stopTimeout {
                log("simctl did not finish within \(Int(Recording.stopTimeout))s; killing it")
                kill(process.processIdentifier, SIGKILL)
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        log("simctl exited (status \(process.terminationStatus))")
        return process.terminationStatus
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }
}
