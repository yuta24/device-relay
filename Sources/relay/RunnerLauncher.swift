import Foundation

/// A failure reported by xcodebuild before the runner answered /health.
struct StartupFailure: Equatable {
    var message: String
    /// XCTest could not take control of the device (automation mode disabled, device locked, ...).
    var isUITestingSetup: Bool
}

/// Counts consecutive failed liveness checks once the runner is ready.
///
/// The check is `GET /ping`, which the runner answers on its HTTP queue without the busy gate: it is 200
/// even while a command runs, and it never makes a user's request fail with 409. A runner built before
/// `/ping` (an old `.xctestrun` reused without `--rebuild`) answers 404; the monitor then falls back to
/// `/health`, where 409 also means alive.
struct LivenessMonitor {
    static let interval: TimeInterval = 3
    static let failureLimit = 3

    private(set) var path = "/ping"
    private(set) var consecutiveFailures = 0

    var usesLegacyHealth: Bool { path == "/health" }

    /// Only 200 is alive, plus 409 (busy) on the legacy `/health` check. Anything else, including no
    /// response or a 401 from something else listening on the port, counts as a failure.
    func isAlive(status: Int?) -> Bool {
        status == 200 || (usesLegacyHealth && status == 409)
    }

    /// Records one check and returns true once the runner should be considered dead.
    mutating func record(status: Int?) -> Bool {
        if !usesLegacyHealth, status == 404 {
            // The runner answered with a valid token, so it is alive; it just predates /ping.
            path = "/health"
            consecutiveFailures = 0
            return false
        }
        consecutiveFailures = isAlive(status: status) ? 0 : consecutiveFailures + 1
        return consecutiveFailures >= Self.failureLimit
    }
}

/// Builds, launches, and locates the resident XCTest runner.
final class RunnerLauncher {
    static let scheme = "RelayRunner"
    static let readyMarker = "RELAY_RUNNER_READY"

    private let options: StartOptions
    private let udid: String
    private let isSimulator: Bool
    /// Saved in runner.json for `relay status`.
    private let deviceName: String?
    /// The runner root (see `RunnerProject`).
    private let rootURL: URL
    /// `DerivedData-sim` / `DerivedData-device` go here (`RunnerProject.buildDirectory`).
    private let buildURL: URL
    /// `~/.relay`: logs and runner.json. Nothing goes to the current directory, which is usually the
    /// app's repository.
    private let stateURL: URL
    /// The copy of `runner.json` for runner commands run in other directories (see `RunnerLocator`).
    private let userInfoURL: URL?
    /// Called once the runner answers and runner.json is written, before `ready:` is printed.
    var onReady: (() -> Void)?
    /// Generated per launch. The runner gets only its hash, through the environment (never the command
    /// line), so the token itself never reaches xcodebuild or the xcresult bundle.
    private let token = RunnerAuth.generateToken()
    private var process: Process?
    private var runnerURL: URL?
    private var markerAddresses: [String] = []
    private var startupFailure: StartupFailure?
    private var isStopping = false
    private let lock = NSLock()

    init(
        options: StartOptions,
        udid: String,
        isSimulator: Bool,
        rootURL: URL,
        buildURL: URL,
        deviceName: String? = nil,
        stateURL: URL = RunnerLocator.userURL().deletingLastPathComponent(),
        userInfoURL: URL? = RunnerLocator.userURL()
    ) {
        self.options = options
        self.udid = udid
        self.isSimulator = isSimulator
        self.rootURL = rootURL
        self.buildURL = buildURL
        self.deviceName = deviceName
        self.stateURL = stateURL
        self.userInfoURL = userInfoURL
    }

    func run() throws -> Int32 {
        let derivedData = buildURL.appendingPathComponent(isSimulator ? "DerivedData-sim" : "DerivedData-device", isDirectory: true)
        let logsURL = stateURL.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let stamp = Self.timestamp()

        let xctestrun: URL
        let platform = XCTestRunSelection.platform(isSimulator: isSimulator)
        var reusable: URL?
        if options.rebuild {
            reusable = nil
        } else {
            let files = Self.xctestrunFiles(in: derivedData)
            let sdkVersion = files.isEmpty ? nil : Self.sdkVersion(platform: platform)
            switch XCTestRunSelection.reusable(files, platform: platform, sdkVersion: sdkVersion) {
            case .reuse(let url):
                reusable = url
            case .none:
                reusable = nil
            case .otherSDK(let file):
                reusable = nil
                info("\(file.lastPathComponent) (the last build) is not for this Xcode's \(platform) SDK \(sdkVersion ?? "?"); rebuilding")
            }
        }
        let bundleIDPrefix = options.bundleIDPrefix ?? RunnerBundleID.prefix(configured: nil, teamID: options.teamID).prefix
        let expectedHost = RunnerBundleID.host(prefix: bundleIDPrefix)
        if let existing = reusable, let built = RunnerBundleID.builtHost(xctestrun: existing),
           RunnerBundleID.needsRebuild(built: built, expected: expectedHost, projectUsesPrefix: projectUsesBundleIDPrefix()) {
            info(RunnerBundleID.rebuildNote(built: built, expectedPrefix: bundleIDPrefix))
            reusable = nil
        }
        if let existing = reusable {
            xctestrun = existing
            info("reusing \(existing.lastPathComponent)")
            if let data = try? Data(contentsOf: existing), !Self.passesApplicationStateTimeout(xctestrun: data) {
                info("note: \(Self.staleApplicationStateTimeoutNote(root: rootURL))")
            }
        } else {
            let buildLogURL = try Self.createLog("build", in: logsURL, stamp: stamp, port: options.port)
            info("building runner (log: \(buildLogURL.path))")
            let buildLog = try FileHandle(forWritingTo: buildLogURL)
            defer { try? buildLog.close() }
            let buildArguments = Self.buildArguments(
                projectURL: rootURL.appendingPathComponent(RunnerProject.projectPath),
                destination: "id=\(udid)",
                derivedData: derivedData,
                teamID: options.teamID,
                bundleIDPrefix: bundleIDPrefix
            )
            let buildStart = Date()
            try Shell.xcrun(buildArguments, log: buildLog, echo: options.verbose)
            guard let built = XCTestRunSelection.built(Self.xctestrunFiles(in: derivedData), since: buildStart) else {
                throw ArgumentError(description: "build succeeded but no .xctestrun was found under \(derivedData.path)")
            }
            xctestrun = built
        }

        if StartCancellation.isRequested {
            info("stopped before launching the runner")
            return 1
        }
        let runnerLogURL = try Self.createLog("runner", in: logsURL, stamp: stamp, port: options.port)
        info("launching runner on \(udid) (log: \(runnerLogURL.path))")
        let process = try launch(xctestrun: xctestrun, derivedData: derivedData, logURL: runnerLogURL)
        installSignalHandlers()
        if StartCancellation.isRequested {
            // SIGTERM arrived before the handlers above were installed.
            shutdown()
        }

        let deadline = Date().addingTimeInterval(options.readyTimeout)
        var tunnelAddress: String?
        var lastTunnelLookup = Date.distantPast
        while process.isRunning, Date() < deadline, currentRunnerURL() == nil, currentStartupFailure() == nil {
            if !isSimulator, Date().timeIntervalSince(lastTunnelLookup) > 5 {
                tunnelAddress = Self.tunnelAddress(udid: udid)
                lastTunnelLookup = Date()
            }
            let hosts = Self.candidateHosts(
                isSimulator: isSimulator,
                udid: udid,
                tunnelAddress: tunnelAddress,
                markerAddresses: currentMarkerAddresses(),
                allowWiFi: options.allowWiFi
            )
            // /health rather than /ping: it runs XCUI on the main queue, so 200 means commands can run.
            for host in hosts {
                guard let url = Self.url(host: host, port: options.port) else { continue }
                var client = RunnerClient(baseURL: url, token: token)
                client.timeout = 1.5
                if let response = try? client.get("/health"), response.status == 200 {
                    setRunnerURL(url)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        if currentRunnerURL() == nil, let failure = currentStartupFailure() {
            info("runner failed to start: \(failure.message)")
            for hint in Self.startupFailureHints(for: failure, isSimulator: isSimulator) {
                info("hint: \(hint)")
            }
            info("see \(runnerLogURL.path)")
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus != 0 ? process.terminationStatus : 1
        }

        let infoURL = stateURL.appendingPathComponent(RunnerInfo.fileName)
        if let url = currentRunnerURL() {
            // pid and startedAt let relay stop find this process, and tell it from one that reuses the pid.
            var runnerInfo = RunnerInfo(url: url.absoluteString, token: token, udid: udid, name: deviceName,
                                        pid: getpid(), startedAt: RelayProcess.currentStartTime())
            // What was built, which differs from expectedHost for a project that ignores the prefix.
            runnerInfo.hostBundleID = RunnerBundleID.builtHost(xctestrun: xctestrun) ?? expectedHost
            do {
                // The token goes only to the 0600 file: stdout often ends up in CI logs and terminal scrollback.
                try runnerInfo.write(to: infoURL)
            } catch {
                info("cannot save the runner token: \(error)")
                shutdown()
                process.waitUntilExit()
                return 1
            }
            if let userInfoURL, userInfoURL.standardizedFileURL != infoURL.standardizedFileURL {
                // Only a convenience for other directories, so a failure is not fatal. The latest runner wins.
                do {
                    try runnerInfo.write(to: userInfoURL)
                    info("runner commands in other directories read \(userInfoURL.path)")
                } catch {
                    info("cannot save \(userInfoURL.path): \(error)")
                }
            }
            onReady?()
            print("ready: \(url.absoluteString)")
            print("token: \(infoURL.path)")
            info("press Ctrl-C to stop the runner")
            if !superviseUntilExit(process: process, url: url) {
                info("runner stopped answering liveness checks (\(LivenessMonitor.failureLimit) in a row); stopping xcodebuild")
                info("see \(runnerLogURL.path)")
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
                removeRunnerInfo(at: infoURL)
                return 1
            }
        } else if process.isRunning {
            info("runner did not answer /health within \(Int(options.readyTimeout))s; addresses reported: \(currentMarkerAddresses())")
            let reachability = options.allowWiFi ? "over the CoreDevice tunnel or Wi-Fi" : "over the CoreDevice tunnel (or pass --allow-wifi)"
            info("check \(runnerLogURL.path); the device must be reachable from this Mac \(reachability)")
        }

        process.waitUntilExit()
        removeRunnerInfo(at: infoURL)
        info("runner exited with status \(process.terminationStatus)")
        return process.terminationStatus
    }

    /// Checks `/ping` every few seconds until xcodebuild exits. Returns false when the runner stopped
    /// answering while xcodebuild kept running (a crashed runner otherwise leaves relay waiting forever).
    private func superviseUntilExit(process: Process, url: URL) -> Bool {
        var monitor = LivenessMonitor()
        var lastCheck = Date()
        var client = RunnerClient(baseURL: url, token: token)
        client.timeout = 2
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.5)
            guard !currentIsStopping(), Date().timeIntervalSince(lastCheck) >= LivenessMonitor.interval else { continue }
            lastCheck = Date()
            let status = (try? client.get(monitor.path))?.status
            // A failure while Ctrl-C is shutting the runner down is expected.
            guard !currentIsStopping(), process.isRunning else { continue }
            let wasLegacy = monitor.usesLegacyHealth
            if monitor.record(status: status) {
                return false
            }
            if !wasLegacy, monitor.usesLegacyHealth {
                info("runner has no /ping (built before it); checking /health instead, which can make requests fail with 409. Restart with --rebuild")
            }
        }
        return true
    }

    // MARK: - Process

    static func buildArguments(projectURL: URL, destination: String, derivedData: URL, teamID: String?, bundleIDPrefix: String) -> [String] {
        var args = [
            "xcodebuild", "build-for-testing",
            "-project", projectURL.path,
            "-scheme", scheme,
            "-destination", destination,
            "-derivedDataPath", derivedData.path
        ]
        if let teamID {
            args += ["-allowProvisioningUpdates", "RELAY_DEVELOPMENT_TEAM=\(teamID)"]
        }
        args.append(RunnerBundleID.buildArgument(prefix: bundleIDPrefix))
        return args
    }

    private func projectUsesBundleIDPrefix() -> Bool {
        let pbxproj = rootURL.appendingPathComponent(RunnerProject.projectPath).appendingPathComponent("project.pbxproj")
        return (try? String(contentsOf: pbxproj, encoding: .utf8)).map { RunnerBundleID.projectUsesPrefix(pbxproj: $0) } ?? false
    }

    /// `-derivedDataPath` is the build's: without it xcodebuild writes the test logs and the xcresult
    /// bundle to `~/Library/Developer/Xcode/DerivedData/RelayRunner-*`, outside `~/.relay`.
    static func testArguments(xctestrun: URL, udid: String, derivedData: URL) -> [String] {
        [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", "id=\(udid)",
            "-derivedDataPath", derivedData.path
        ]
    }

    private func launch(xctestrun: URL, derivedData: URL, logURL: URL) throws -> Process {
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = Self.testArguments(xctestrun: xctestrun, udid: udid, derivedData: derivedData)
        // xcodebuild forwards TEST_RUNNER_-prefixed variables to the test process without the prefix.
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_RUNNER_RELAY_RUNNER_PORT"] = "\(options.port)"
        environment["TEST_RUNNER_\(RunnerAuth.tokenHashEnvironmentKey)"] = RunnerAuth.tokenHash(token)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var lines = RunnerOutputLineBuffer()
        let verbose = options.verbose
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of output: the pipe is drained, so nothing is lost by stopping here.
                handle.readabilityHandler = nil
                try? log.close()
                if let line = lines.finish() {
                    self?.handleRunnerLine(line, verbose: verbose)
                }
                return
            }
            // The log keeps the raw bytes, including lines too long for the buffer.
            log.write(data)
            for line in lines.append(data) {
                self?.handleRunnerLine(line, verbose: verbose)
            }
        }

        try process.run()
        self.process = process
        return process
    }

    private func handleRunnerLine(_ line: String, verbose: Bool) {
        if let failure = Self.startupFailure(in: line) {
            lock.lock()
            // Keep the specific UI testing error over the generic "TEST EXECUTE FAILED" that follows it.
            if startupFailure == nil || (failure.isUITestingSetup && startupFailure?.isUITestingSetup == false) {
                startupFailure = failure
            }
            lock.unlock()
        }
        if let addresses = Self.parseReadyLine(line) {
            lock.lock()
            markerAddresses = addresses
            lock.unlock()
            info("runner listening; device addresses: \(addresses.joined(separator: ", "))")
        } else if line.hasPrefix("relay-runner ") || verbose {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        } else if line.contains("error:") || line.contains("** TEST") {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
        StartCancellation.handOver()
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// The home copy is removed only while it is ours: a later `relay start` may have replaced it.
    private func removeRunnerInfo(at infoURL: URL) {
        RunnerInfo.remove(at: infoURL)
        if let userInfoURL {
            RunnerInfo.remove(at: userInfoURL, ifTokenIs: token)
        }
    }

    private func shutdown() {
        info("stopping runner")
        lock.lock()
        isStopping = true
        lock.unlock()
        let process = self.process
        guard let url = currentRunnerURL() else {
            // Without a runner URL there is nobody to send /shutdown to, so stop xcodebuild right away.
            if process?.isRunning == true {
                process?.terminate()
            }
            return
        }
        var client = RunnerClient(baseURL: url, token: token)
        client.timeout = 3
        _ = try? client.post("/shutdown")
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    private func currentRunnerURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return runnerURL
    }

    private func setRunnerURL(_ url: URL) {
        lock.lock()
        runnerURL = url
        lock.unlock()
    }

    private func currentIsStopping() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopping
    }

    private func currentStartupFailure() -> StartupFailure? {
        lock.lock()
        defer { lock.unlock() }
        return startupFailure
    }

    private func currentMarkerAddresses() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return markerAddresses
    }

    private func info(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }

    // MARK: - Pure helpers

    /// Parses `RELAY_RUNNER_READY port=8100 addresses=en0=192.168.1.5,utun3=fd00::1` into bare addresses.
    static func parseReadyLine(_ line: String) -> [String]? {
        guard let range = line.range(of: readyMarker) else { return nil }
        let fields = line[range.upperBound...].split(separator: " ")
        guard let field = fields.first(where: { $0.hasPrefix("addresses=") }) else { return [] }
        return field.dropFirst("addresses=".count)
            .split(separator: ",")
            .map { entry in
                guard let equals = entry.firstIndex(of: "=") else { return String(entry) }
                return String(entry[entry.index(after: equals)...])
            }
            .filter { !$0.isEmpty }
    }

    /// What to suggest after a startup failure. A device that cannot start UI testing most often waited for
    /// its passcode while enabling automation mode, so that comes first. On a simulator the same failure is
    /// usually transient. A test failure (`** TEST FAILED **`, ...) has no general fix: the log says why.
    static func startupFailureHints(for failure: StartupFailure, isSimulator: Bool) -> [String] {
        guard failure.isUITestingSetup else { return [] }
        if isSimulator {
            return ["this is usually transient on a simulator; run relay start again once"]
        }
        return [
            "if the device asked for its passcode while enabling automation mode, enter it and run relay start again",
            "on the device, turn on Settings > Developer > Enable UI Automation",
            "unlock the device and keep it unlocked until the runner is ready"
        ]
    }

    /// The note for a reused `.xctestrun` without `applicationStateTimeoutArgument`. `--rebuild` builds the
    /// installed copy as it is, so that copy needs `relay install` first to get the current scheme. Decided
    /// by the root, not how it was found: `--project` or `$RELAY_HOME` can point at the installed copy too.
    static func staleApplicationStateTimeoutNote(root: URL, home: URL = UserHome.url) -> String {
        let prefix = "this runner was built before relay waited longer for automation mode; "
        if RunnerProject.isInstalledRoot(root, home: home) {
            return prefix + "run relay install again, then relay start --rebuild to update it"
        }
        return prefix + "relay start --rebuild to update it"
    }

    /// The launch argument (set in the scheme's test action) that makes XCTest wait 120 s instead of 60 s
    /// for testmanagerd to enable automation mode, which may wait for the passcode on the device. The runner
    /// puts the 60 s default back once it is enabled.
    static let applicationStateTimeoutArgument = "-XCUIApplicationStateTimeout"

    /// Whether an `.xctestrun` passes `applicationStateTimeoutArgument` to the runner, i.e. was built from
    /// a scheme that has it. Format 1 keeps test targets at the top level and format 2 under
    /// `TestConfigurations[].TestTargets[]`, so any nested `CommandLineArguments` counts. False for a plist
    /// that can't be read.
    static func passesApplicationStateTimeout(xctestrun data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        func search(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if let arguments = dictionary["CommandLineArguments"] as? [String], arguments.contains(applicationStateTimeoutArgument) {
                    return true
                }
                return dictionary.values.contains(where: search)
            }
            if let array = value as? [Any] {
                return array.contains(where: search)
            }
            return false
        }
        return search(plist)
    }

    /// Detects xcodebuild output that means the runner will never become ready, e.g.
    /// `... Failed to initialize for UI testing: Error Domain=... "Timed out while enabling automation mode." ...`.
    static func startupFailure(in line: String) -> StartupFailure? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: "Failed to initialize for UI testing") {
            let detail = trimmed[range.upperBound...]
            // Prefer the quoted localized description over the raw NSError dump.
            let parts = detail.split(separator: "\"", omittingEmptySubsequences: false)
            let reason = parts.count >= 3 ? ": \(parts[1])" : String(detail)
            return StartupFailure(message: "Failed to initialize for UI testing\(reason)", isUITestingSetup: true)
        }
        let isTestFailure = trimmed.hasPrefix("** TEST") && trimmed.contains("FAILED **")
            || trimmed.hasPrefix("Test Case '") && trimmed.contains("' failed")
        if isTestFailure {
            return StartupFailure(message: trimmed, isUITestingSetup: false)
        }
        return nil
    }

    /// Hosts to probe, most preferred first: the CoreDevice tunnel works over USB without Wi-Fi.
    /// The interface addresses the runner reports (Wi-Fi and others) are probed only with `allowWiFi`,
    /// because the token would travel there as plain HTTP on a shared network.
    static func candidateHosts(isSimulator: Bool, udid: String, tunnelAddress: String?, markerAddresses: [String], allowWiFi: Bool) -> [String] {
        if isSimulator {
            return ["127.0.0.1"]
        }
        var hosts: [String] = []
        if let tunnelAddress {
            hosts.append(tunnelAddress)
        }
        hosts.append("\(udid).coredevice.local")
        guard allowWiFi else { return hosts }
        // IPv4 link-local addresses (169.254/16) are usually unreachable from the host.
        hosts += markerAddresses.filter { !$0.hasPrefix("169.254.") }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    static func url(host: String, port: Int) -> URL? {
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(formattedHost):\(port)/")
    }

    static func findTunnelAddress(inDevicectlJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findValue(forKey: "tunnelIPAddress", in: object)
    }

    private static func findValue(forKey key: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
            for value in dictionary.values {
                if let found = findValue(forKey: key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findValue(forKey: key, in: value) { return found }
            }
        }
        return nil
    }

    private static func tunnelAddress(udid: String) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("relay-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard (try? Shell.xcrun(["devicectl", "device", "info", "details", "--device", udid, "--json-output", output.path])) != nil,
              let data = try? Data(contentsOf: output) else {
            return nil
        }
        return findTunnelAddress(inDevicectlJSON: data)
    }

    /// The `.xctestrun` files in `Build/Products` and when each was last written.
    private static func xctestrunFiles(in derivedData: URL) -> [XCTestRunFile] {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: products, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "xctestrun" }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return XCTestRunFile(url: url, modified: modified ?? .distantPast)
        }
    }

    /// The SDK version of this Xcode (`DEVELOPER_DIR`, else `xcode-select`'s), e.g. `27.2`; nil if xcrun
    /// cannot tell.
    private static func sdkVersion(platform: String) -> String? {
        guard let output = try? Shell.xcrun(["--sdk", platform, "--show-sdk-version"]) else { return nil }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return XCTestRunSelection.isVersion(version) ? version : nil
    }

    /// Creates the empty log `<kind>-<stamp>-<port>.log` in `directory` (`<kind>-<stamp>.log` without a port)
    /// and returns it. A name that is taken gets `-2`, `-3`, ...: a log is only ever written by the relay
    /// that created it. Two starts in the same second differ by port (one start per port, see `StartLock`),
    /// and a restart on the same port within that second gets the next number.
    static func createLog(_ kind: String, in directory: URL, stamp: String, port: Int?) throws -> URL {
        let base = "\(kind)-\(stamp)\(port.map { "-\($0)" } ?? "")"
        var attempt = 1
        while true {
            let url = directory.appendingPathComponent(attempt == 1 ? "\(base).log" : "\(base)-\(attempt).log")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                return url
            }
            let error = errno
            guard error == EEXIST else {
                throw ArgumentError(description: "cannot create \(url.path): \(String(cString: strerror(error)))")
            }
            attempt += 1
        }
    }

    /// The `<stamp>` of the logs in `~/.relay/logs` (`createLog`).
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
