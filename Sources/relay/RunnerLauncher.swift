import Foundation

/// A failure reported by xcodebuild before the runner answered /health.
struct StartupFailure: Equatable {
    var message: String
    /// XCTest could not take control of the device (automation mode disabled, device locked, ...).
    var isUITestingSetup: Bool
}

/// Counts consecutive failed `/health` checks once the runner is ready.
struct LivenessMonitor {
    static let interval: TimeInterval = 3
    static let failureLimit = 3

    private(set) var consecutiveFailures = 0

    /// 200 is healthy and 409 means the runner is busy with a command. Anything else, including no
    /// response or a 401 from something else listening on the port, counts as a failure.
    static func isAlive(status: Int?) -> Bool {
        status == 200 || status == 409
    }

    /// Records one check and returns true once the runner should be considered dead.
    mutating func record(status: Int?) -> Bool {
        consecutiveFailures = Self.isAlive(status: status) ? 0 : consecutiveFailures + 1
        return consecutiveFailures >= Self.failureLimit
    }
}

/// Builds, launches, and locates the resident XCTest runner.
final class RunnerLauncher {
    static let projectPath = "Runner/RelayRunner.xcodeproj"
    static let scheme = "RelayRunner"
    static let readyMarker = "RELAY_RUNNER_READY"

    private let options: StartOptions
    private let rootURL: URL
    private let stateURL: URL
    /// Generated per launch. The runner gets only its hash, through the environment (never the command
    /// line), so the token itself never reaches xcodebuild or the xcresult bundle.
    private let token = RunnerAuth.generateToken()
    private var process: Process?
    private var runnerURL: URL?
    private var markerAddresses: [String] = []
    private var startupFailure: StartupFailure?
    private var isStopping = false
    private let lock = NSLock()

    init(options: StartOptions, rootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.options = options
        self.rootURL = rootURL
        self.stateURL = rootURL.appendingPathComponent(".relay", isDirectory: true)
    }

    func run() throws -> Int32 {
        guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(Self.projectPath).path) else {
            throw ArgumentError(description: "\(Self.projectPath) not found; run relay from the device-relay repository root")
        }

        let isSimulator = try Self.isSimulator(udid: options.udid)
        let derivedData = stateURL.appendingPathComponent(isSimulator ? "DerivedData-sim" : "DerivedData-device", isDirectory: true)
        let logsURL = stateURL.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        let buildLogURL = logsURL.appendingPathComponent("build-\(stamp).log")
        let runnerLogURL = logsURL.appendingPathComponent("runner-\(stamp).log")

        let xctestrun: URL
        if !options.rebuild, let existing = Self.findXCTestRun(in: derivedData) {
            xctestrun = existing
            info("reusing \(existing.lastPathComponent)")
        } else {
            info("building runner (log: \(buildLogURL.path))")
            FileManager.default.createFile(atPath: buildLogURL.path, contents: nil)
            let buildLog = try FileHandle(forWritingTo: buildLogURL)
            defer { try? buildLog.close() }
            try Shell.xcrun(buildArguments(derivedData: derivedData), log: buildLog, echo: options.verbose)
            guard let built = Self.findXCTestRun(in: derivedData) else {
                throw ArgumentError(description: "build succeeded but no .xctestrun was found under \(derivedData.path)")
            }
            xctestrun = built
        }

        info("launching runner on \(options.udid) (log: \(runnerLogURL.path))")
        let process = try launch(xctestrun: xctestrun, logURL: runnerLogURL)
        installSignalHandlers()

        let deadline = Date().addingTimeInterval(options.readyTimeout)
        var tunnelAddress: String?
        var lastTunnelLookup = Date.distantPast
        while process.isRunning, Date() < deadline, currentRunnerURL() == nil, currentStartupFailure() == nil {
            if !isSimulator, Date().timeIntervalSince(lastTunnelLookup) > 5 {
                tunnelAddress = Self.tunnelAddress(udid: options.udid)
                lastTunnelLookup = Date()
            }
            let hosts = Self.candidateHosts(
                isSimulator: isSimulator,
                udid: options.udid,
                tunnelAddress: tunnelAddress,
                markerAddresses: currentMarkerAddresses(),
                allowWiFi: options.allowWiFi
            )
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
            for hint in Self.startupFailureHints {
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
            do {
                // The token goes only to the 0600 file: stdout often ends up in CI logs and terminal scrollback.
                try RunnerInfo(url: url.absoluteString, token: token, udid: options.udid).write(to: infoURL)
            } catch {
                info("cannot save the runner token: \(error)")
                shutdown()
                process.waitUntilExit()
                return 1
            }
            print("ready: \(url.absoluteString)")
            print("token: \(infoURL.path)")
            info("press Ctrl-C to stop the runner")
            if !superviseUntilExit(process: process, url: url) {
                info("runner stopped answering /health (\(LivenessMonitor.failureLimit) checks in a row); stopping xcodebuild")
                info("see \(runnerLogURL.path)")
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
                RunnerInfo.remove(at: infoURL)
                return 1
            }
        } else if process.isRunning {
            info("runner did not answer /health within \(Int(options.readyTimeout))s; addresses reported: \(currentMarkerAddresses())")
            let reachability = options.allowWiFi ? "over the CoreDevice tunnel or Wi-Fi" : "over the CoreDevice tunnel (or pass --allow-wifi)"
            info("check \(runnerLogURL.path); the device must be reachable from this Mac \(reachability)")
        }

        process.waitUntilExit()
        RunnerInfo.remove(at: infoURL)
        info("runner exited with status \(process.terminationStatus)")
        return process.terminationStatus
    }

    /// Checks `/health` every few seconds until xcodebuild exits. Returns false when the runner stopped
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
            let status = (try? client.get("/health"))?.status
            // A failure while Ctrl-C is shutting the runner down is expected.
            if !currentIsStopping(), process.isRunning, monitor.record(status: status) {
                return false
            }
        }
        return true
    }

    // MARK: - Process

    private func buildArguments(derivedData: URL) -> [String] {
        var args = [
            "xcodebuild", "build-for-testing",
            "-project", rootURL.appendingPathComponent(Self.projectPath).path,
            "-scheme", Self.scheme,
            "-destination", "id=\(options.udid)",
            "-derivedDataPath", derivedData.path
        ]
        if let teamID = options.teamID {
            args += ["-allowProvisioningUpdates", "RELAY_DEVELOPMENT_TEAM=\(teamID)"]
        }
        return args
    }

    private func launch(xctestrun: URL, logURL: URL) throws -> Process {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", "id=\(options.udid)"
        ]
        // xcodebuild forwards TEST_RUNNER_-prefixed variables to the test process without the prefix.
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_RUNNER_RELAY_RUNNER_PORT"] = "\(options.port)"
        environment["TEST_RUNNER_\(RunnerAuth.tokenHashEnvironmentKey)"] = RunnerAuth.tokenHash(token)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var pending = ""
        let verbose = options.verbose
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log.write(data)
            pending += String(decoding: data, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending = String(pending[pending.index(after: newline)...])
                self?.handleRunnerLine(line, verbose: verbose)
            }
        }
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? log.close()
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
    }

    private var signalSources: [DispatchSourceSignal] = []

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

    static let startupFailureHints = [
        "on the device, turn on Settings > Developer > Enable UI Automation",
        "unlock the device and keep it unlocked until the runner is ready"
    ]

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

    private static func isSimulator(udid: String) throws -> Bool {
        let output = try Shell.xcrun(["simctl", "list", "devices", "-j"])
        return output.contains("\"\(udid)\"")
    }

    private static func findXCTestRun(in derivedData: URL) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }.first
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
