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
/// even while a command runs, and it never makes a user's request fail with 409. A runner built from
/// sources older than `/ping` answers 404; the monitor then falls back to `/health`, where 409 also means
/// alive. relay rebuilds when the sources change (`RunnerBuildPlan`), so that takes an installed copy
/// (`relay runner install`) older than `/ping`, which `relay start` already reports as out of date.
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
///
/// Sendable, checked by the compiler: everything that changes after `init` is in `state`. The pipe's handler
/// and the signal handlers run on other threads than `run()`.
final class RunnerLauncher: Sendable {
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
  /// The file `relay start` writes: `runner.json` in `stateURL`, or the session's (see `RelaySession`).
  private let infoURL: URL
  /// The copy of `runner.json` for runner commands run in other directories (see `RunnerLocator`).
  /// A session has none: its file is the only one that names its runner.
  private let userInfoURL: URL?
  /// Called once the runner answers and runner.json is written, before `ready:` is printed.
  var onReady: (@Sendable () -> Void)? {
    get { state.value.onReady }
    set { state.withLock { $0.onReady = newValue } }
  }
  /// Generated per launch. The runner gets only its hash, through the environment (never the command
  /// line), so the token itself never reaches xcodebuild or the xcresult bundle.
  private let token = RunnerAuth.generateToken()
  private let state = Locked(State())

  private struct State {
    var onReady: (@Sendable () -> Void)?
    var process: Process?
    var runnerURL: URL?
    var markerAddresses: [String] = []
    var startupFailure: StartupFailure?
    var isStopping = false
    var signalSources: [DispatchSourceSignal] = []
  }

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
    if let session = options.session {
      self.infoURL = RelaySession.infoURL(name: session, home: stateURL.deletingLastPathComponent())
      self.userInfoURL = nil
    } else {
      self.infoURL = stateURL.appendingPathComponent(RunnerInfo.fileName)
      self.userInfoURL = userInfoURL
    }
  }

  func run() throws -> Int32 {
    let derivedData = buildURL.appendingPathComponent(isSimulator ? "DerivedData-sim" : "DerivedData-device", isDirectory: true)
    let logsURL = stateURL.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
    let stamp = Self.timestamp()
    if let session = options.session {
      info("session \(session) (\(infoURL.path)), port \(options.port)")
    }

    let platform = XCTestRunSelection.platform(isSimulator: isSimulator)
    // A few milliseconds; computed on every start so a build of other sources is never reused.
    let sourceHash = try RunnerSourceHash.compute(root: rootURL)
    let bundleIDPrefix = options.bundleIDPrefix ?? RunnerBundleID.prefix(configured: nil, teamID: options.teamID).prefix
    func decidePlan(rebuild: Bool) -> RunnerBuildPlan {
      if rebuild {
        return .build(reason: nil)
      }
      let files = Self.xctestrunFiles(in: derivedData)
      let sdkVersion = files.isEmpty ? nil : Self.sdkVersion(platform: platform)
      return RunnerBuildPlan.decide(
        rebuild: false,
        selection: XCTestRunSelection.reusable(files, platform: platform, sdkVersion: sdkVersion),
        platform: platform,
        sdkVersion: sdkVersion,
        stamp: RunnerBuildStamp.read(derivedData: derivedData),
        sourceHash: sourceHash,
        bundleIDPrefix: bundleIDPrefix
      )
    }

    // Shared while this start reads the build, exclusive while it writes one: starts reusing a build run
    // side by side, and a build waits until no start is launching from these products (see BuildLock).
    let buildLock = try BuildLock(derivedData: derivedData, relayDirectory: stateURL)
    let waitStarted = Date()
    // A build finished since this start began (the one it just waited for) satisfies --rebuild too: the
    // products are newer than this start, and decidePlan still checks that they are of these sources.
    func rebuildIsNeeded() -> Bool {
      options.rebuild && RunnerBuildStamp.modified(derivedData: derivedData).map { $0 >= waitStarted } != true
    }
    try buildLock.wait(for: .shared, info: info)
    var plan = decidePlan(rebuild: rebuildIsNeeded())
    if case .build = plan {
      // Going to exclusive gives the shared lock up first, so another start may have finished a build by now.
      try buildLock.wait(for: .exclusive, info: info)
      plan = decidePlan(rebuild: rebuildIsNeeded())
    }
    // With the build lock held, so RelayPrune cannot be moving the directory away right now.
    do {
      try BuildDirectoryRecord.refresh(root: rootURL, buildDirectory: buildURL)
    } catch {
      // Without it, a later start only knows less about this directory and keeps it longer.
      info("cannot record the use of \(buildURL.path): \(error)")
    }

    let xctestrun: URL
    switch plan {
    case .reuse(let existing):
      xctestrun = existing
      info("reusing \(existing.lastPathComponent) (runner sources \(RunnerSourceHash.short(sourceHash)))")
    case .build(let reason):
      if let reason {
        info(reason)
      }
      let buildLogURL = try Self.createLog("build", in: logsURL, stamp: stamp, port: options.port, session: options.session)
      info("building runner from sources \(RunnerSourceHash.short(sourceHash)) (log: \(buildLogURL.path))")
      let buildLog = try FileHandle(forWritingTo: buildLogURL)
      defer { try? buildLog.close() }
      let buildArguments = Self.buildArguments(
        projectURL: rootURL.appendingPathComponent(RunnerProject.projectPath),
        destination: "id=\(udid)",
        derivedData: derivedData,
        teamID: options.teamID,
        sourceHash: sourceHash,
        bundleIDPrefix: bundleIDPrefix
      )
      RunnerBuildStamp.remove(derivedData: derivedData)
      let buildStart = Date()
      // No time limit: a build can rightly take very long, and shows progress in its log. Ctrl-C and relay
      // stop end it (`StartCancellation`).
      try Shell.xcrun(buildArguments, log: buildLog, echo: options.verbose, timeout: nil)
      guard let built = XCTestRunSelection.built(Self.xctestrunFiles(in: derivedData), since: buildStart) else {
        throw SetupError(description: "build succeeded but no .xctestrun was found under \(derivedData.path)")
      }
      do {
        try RunnerBuildStamp(sourceHash: sourceHash, relayVersion: RelayVersion.current, bundleIDPrefix: bundleIDPrefix)
          .write(derivedData: derivedData)
      } catch {
        // Only the next start's reuse depends on it: that start rebuilds.
        info("cannot record the build in \(RunnerBuildStamp.url(derivedData: derivedData).path): \(error)")
      }
      xctestrun = built
    }
    try buildLock.wait(for: .shared, info: info)

    if StartCancellation.isRequested {
      info("stopped before launching the runner")
      return 1
    }
    let runnerLogURL = try Self.createLog("runner", in: logsURL, stamp: stamp, port: options.port, session: options.session)
    info("launching runner on \(udid) (log: \(runnerLogURL.path))")
    let testData = Self.testDataURL(buildURL: buildURL, port: options.port)
    let process = try launch(xctestrun: launchCopy(of: xctestrun, testData: testData), testData: testData, logURL: runnerLogURL)
    installSignalHandlers()
    if StartCancellation.isRequested {
      // SIGTERM arrived before the handlers above were installed.
      shutdown()
    }

    let deadline = Date().addingTimeInterval(options.readyTimeout)
    var tunnelAddress: String?
    var lastTunnelLookup = Date.distantPast
    var readyBody = Data()
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
          readyBody = response.body
          setRunnerURL(url)
          break
        }
      }
      Thread.sleep(forTimeInterval: 0.5)
    }

    // The runner answered, or won't: nothing reads the build from here on, so a rebuild may start.
    buildLock.release()

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

    if let url = currentRunnerURL() {
      let reported = RunnerBuildVersion.parse(responseBody: readyBody)
      if let mismatch = RunnerBuildVersion.mismatch(reported: reported, expectedSourceHash: sourceHash) {
        // A warning, not a failure: it answers and its sources are the current ones (relay just built or
        // checked them); only what it reports is off. Old sources report nothing, and --rebuild can't fix that.
        let hint = reported?.sourceHash == nil
          ? (RunnerProject.isInstalledRoot(rootURL) ? "relay runner install updates the installed copy" : "update the runner sources")
          : "relay start --rebuild builds it again"
        info("warning: \(mismatch); \(hint)")
      } else if let reported {
        info("runner \(reported.summary)")
      }
      // pid and startedAt let relay stop find this process, and tell it from one that reuses the pid.
      // runner is what relay expects it to report, so runner commands never hash the sources.
      // hostBundleID is read from the built app: a project that ignores the prefix (an old relay runner install
      // copy) keeps its own ID.
      let runnerInfo = RunnerInfo(url: url.absoluteString, token: token, udid: udid, name: deviceName,
                                  pid: getpid(), startedAt: RelayProcess.currentStartTime(),
                                  runner: RunnerBuildVersion(version: RelayVersion.current, sourceHash: sourceHash),
                                  hostBundleID: RunnerBundleID.builtHost(xctestrun: xctestrun)
                                    ?? RunnerBundleID.host(prefix: bundleIDPrefix),
                                  session: options.session, buildDirectory: buildURL.lastPathComponent)
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
        info("runner has no /ping (its sources predate it); checking /health instead, which can make requests fail with 409. "
          + "Update the runner sources (relay runner install for the installed copy) and restart")
      }
    }
    return true
  }

  // MARK: - Process

  /// `sourceHash` (`RunnerSourceHash`) and this relay's version go into the runner's Info.plist through
  /// build settings (`RunnerBuildVersion`), for `/ping` and `/health` to report. `bundleIDPrefix` makes the
  /// bundle IDs (`RunnerBundleID`).
  static func buildArguments(projectURL: URL, destination: String, derivedData: URL, teamID: String?,
                             sourceHash: String, bundleIDPrefix: String) -> [String] {
    var args = [
      "xcodebuild", "build-for-testing",
      "-project", projectURL.path,
      "-scheme", scheme,
      "-destination", destination,
      "-derivedDataPath", derivedData.path
    ] + RunnerBuildVersion.buildSettings(sourceHash: sourceHash)
    if let teamID {
      args += ["-allowProvisioningUpdates", "RELAY_DEVELOPMENT_TEAM=\(teamID)"]
    }
    args.append(RunnerBundleID.buildArgument(prefix: bundleIDPrefix))
    return args
  }

  /// Without `-derivedDataPath` xcodebuild writes the test logs and the xcresult bundle to
  /// `~/Library/Developer/Xcode/DerivedData/RelayRunner-*`, outside `~/.relay`. It is `testDataURL`.
  static func testArguments(xctestrun: URL, udid: String, derivedData: URL) -> [String] {
    [
      "xcodebuild", "test-without-building",
      "-xctestrun", xctestrun.path,
      "-destination", "id=\(udid)",
      "-derivedDataPath", derivedData.path
    ]
  }

  /// Where the test run of the runner on `port` writes its logs and xcresult bundle. One directory per port,
  /// next to the build rather than in it: test runs last as long as their runners and may overlap with each
  /// other and with a build, and one port has one `relay start` at a time (`StartLock`).
  static func testDataURL(buildURL: URL, port: Int) -> URL {
    buildURL.appendingPathComponent("TestData", isDirectory: true).appendingPathComponent("port-\(port)", isDirectory: true)
  }

  /// The `.xctestrun` to launch: a copy without XCTest's screen recording (`XCTestRunCapture`), or the build's
  /// own when the copy cannot be written, which still runs (and records) as before.
  private func launchCopy(of xctestrun: URL, testData: URL) -> URL {
    let copy = XCTestRunCapture.url(testData: testData)
    do {
      try XCTestRunCapture.write(from: xctestrun, to: copy)
      return copy
    } catch {
      info("cannot write \(copy.path) (\(error)); launching \(xctestrun.lastPathComponent), "
        + "with which XCTest records the screen for as long as the runner runs")
      return xctestrun
    }
  }

  private func launch(xctestrun: URL, testData: URL, logURL: URL) throws -> Process {
    let log = try FileHandle(forWritingTo: logURL)

    // Not through `Shell`, and without a `CommandTimeout`: the runner stays until it is stopped. `--ready-timeout`
    // and the liveness checks watch it.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = Self.testArguments(xctestrun: xctestrun, udid: udid, derivedData: testData)
    // xcodebuild forwards TEST_RUNNER_-prefixed variables to the test process without the prefix.
    var environment = ProcessInfo.processInfo.environment
    environment["TEST_RUNNER_RELAY_RUNNER_PORT"] = "\(options.port)"
    environment["TEST_RUNNER_\(RunnerAuth.tokenHashEnvironmentKey)"] = RunnerAuth.tokenHash(token)
    process.environment = environment
    process.standardInput = FileHandle.nullDevice

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let lines = Locked(RunnerOutputLineBuffer())
    let verbose = options.verbose
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        // End of output: the pipe is drained, so nothing is lost by stopping here.
        handle.readabilityHandler = nil
        try? log.close()
        if let line = lines.withLock({ $0.finish() }) {
          self?.handleRunnerLine(line, verbose: verbose)
        }
        return
      }
      // The log keeps the raw bytes, including lines too long for the buffer.
      log.write(data)
      for line in lines.withLock({ $0.append(data) }) {
        self?.handleRunnerLine(line, verbose: verbose)
      }
    }

    try process.run()
    state.withLock { $0.process = process }
    return process
  }

  private func handleRunnerLine(_ line: String, verbose: Bool) {
    if let failure = Self.startupFailure(in: line) {
      state.withLock { state in
        // Keep the specific UI testing error over the generic "TEST EXECUTE FAILED" that follows it.
        if state.startupFailure == nil || (failure.isUITestingSetup && state.startupFailure?.isUITestingSetup == false) {
          state.startupFailure = failure
        }
      }
    }
    if let addresses = Self.parseReadyLine(line) {
      state.withLock { $0.markerAddresses = addresses }
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
      state.withLock { $0.signalSources.append(source) }
    }
    StartCancellation.handOver()
  }

  /// The home copy is removed only while it is ours: a later `relay start` may have replaced it.
  private func removeRunnerInfo(at infoURL: URL) {
    RunnerInfo.remove(at: infoURL)
    if let userInfoURL {
      RunnerInfo.remove(at: userInfoURL, ifTokenIs: token)
    }
  }

  private func shutdown() {
    info("stopping runner")
    let process = state.withLock { state in
      state.isStopping = true
      return state.process
    }
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
    state.value.runnerURL
  }

  private func setRunnerURL(_ url: URL) {
    state.withLock { $0.runnerURL = url }
  }

  private func currentIsStopping() -> Bool {
    state.value.isStopping
  }

  private func currentStartupFailure() -> StartupFailure? {
    state.value.startupFailure
  }

  private func currentMarkerAddresses() -> [String] {
    state.value.markerAddresses
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
    guard (try? Shell.xcrun(["devicectl", "device", "info", "details", "--device", udid, "--json-output", output.path],
                            timeout: CommandTimeout.devicectl)) != nil,
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
    guard let output = try? Shell.xcrun(["--sdk", platform, "--show-sdk-version"], timeout: CommandTimeout.query) else { return nil }
    let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return XCTestRunSelection.isVersion(version) ? version : nil
  }

  /// Creates the empty log `<kind>-<stamp>-<port>.log` in `directory` (`<kind>-<stamp>.log` without a port,
  /// `<kind>-<stamp>-<session>-<port>.log` in a session) and returns it. A name that is taken gets `-2`, `-3`,
  /// ...: a log is only ever written by the relay that created it. Two starts in the same second differ by
  /// port (one start per port, see `StartLock`), and a restart on the same port within that second gets the next number.
  static func createLog(_ kind: String, in directory: URL, stamp: String, port: Int?, session: String? = nil) throws -> URL {
    let base = "\(kind)-\(stamp)\(session.map { "-\($0)" } ?? "")\(port.map { "-\($0)" } ?? "")"
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
        throw SetupError(description: "cannot create \(url.path): \(String(cString: strerror(error)))")
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
