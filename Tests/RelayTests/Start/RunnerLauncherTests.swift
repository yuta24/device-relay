import Foundation
@testable import Relay
import Testing

struct RunnerLauncherTests {
  @Test func testsWriteToTheBuildsDerivedData() {
    let derivedData = URL(fileURLWithPath: "/home/.relay/build/installed/DerivedData-sim")
    let arguments = RunnerLauncher.testArguments(xctestrun: URL(fileURLWithPath: "/d/Build/Products/R.xctestrun"), udid: "SIM",
                                                 derivedData: derivedData)
    #expect(arguments == ["xcodebuild", "test-without-building", "-xctestrun", "/d/Build/Products/R.xctestrun",
                          "-destination", "id=SIM", "-derivedDataPath", derivedData.path])
  }

  @Test func parsesReadyLine() {
    let line = "RELAY_RUNNER_READY port=8100 addresses=en0=192.168.1.5,utun3=fd00::1"
    #expect(RunnerLauncher.parseReadyLine(line) == ["192.168.1.5", "fd00::1"])
  }

  @Test func parsesSimulatorReadyLine() {
    // A simulator's runner listens on loopback only and reports just that address.
    #expect(RunnerLauncher.parseReadyLine("RELAY_RUNNER_READY port=8100 addresses=lo0=127.0.0.1") == ["127.0.0.1"])
  }

  @Test func ignoresOtherLines() {
    #expect(RunnerLauncher.parseReadyLine("Test Case started") == nil)
  }

  @Test func simulatorUsesLoopback() {
    let hosts = RunnerLauncher.candidateHosts(isSimulator: true, udid: "SIM", tunnelAddress: "fd00::1", markerAddresses: ["10.0.0.2"], allowWiFi: true)
    #expect(hosts == ["127.0.0.1"])
  }

  @Test func devicePrefersTunnelAndDropsLinkLocal() {
    let hosts = RunnerLauncher.candidateHosts(
      isSimulator: false,
      udid: "DEV",
      tunnelAddress: "fd00::1",
      markerAddresses: ["fd00::1", "192.168.1.5", "169.254.3.4"],
      allowWiFi: true
    )
    #expect(hosts == ["fd00::1", "DEV.coredevice.local", "192.168.1.5"])
  }

  @Test func deviceProbesOnlyTheTunnelByDefault() {
    let markers = ["192.168.1.5", "fd7a::1"]
    let withTunnel = RunnerLauncher.candidateHosts(
      isSimulator: false, udid: "DEV", tunnelAddress: "fd00::1", markerAddresses: markers, allowWiFi: false
    )
    #expect(withTunnel == ["fd00::1", "DEV.coredevice.local"])
    // Even before devicectl reports a tunnel, Wi-Fi addresses are not tried.
    let withoutTunnel = RunnerLauncher.candidateHosts(
      isSimulator: false, udid: "DEV", tunnelAddress: nil, markerAddresses: markers, allowWiFi: false
    )
    #expect(withoutTunnel == ["DEV.coredevice.local"])
  }

  @Test func checksPingAndTreatsOnly200AsAlive() {
    let monitor = LivenessMonitor()
    #expect(monitor.path == "/ping")
    #expect(monitor.isAlive(status: 200))
    // /ping never goes through the busy gate, so a 409 is not the runner.
    for status in [nil, 401, 409, 500] as [Int?] {
      #expect(!monitor.isAlive(status: status))
    }
  }

  @Test func givesUpAfterConsecutiveFailuresOnly() {
    var monitor = LivenessMonitor()
    var results = [monitor.record(status: nil), monitor.record(status: nil)]
    // A healthy answer resets the count.
    results.append(monitor.record(status: 200))
    #expect(results == [false, false, false])
    #expect(monitor.consecutiveFailures == 0)
    results = (0 ..< LivenessMonitor.failureLimit).map { _ in monitor.record(status: 409) }
    #expect(results == Array(repeating: false, count: LivenessMonitor.failureLimit - 1) + [true])
  }

  /// A runner built before /ping answers it with 404 after checking the token.
  @Test func fallsBackToHealthForRunnersWithoutPing() {
    var monitor = LivenessMonitor()
    _ = monitor.record(status: nil)
    let gaveUp = monitor.record(status: 404)
    #expect(!gaveUp)
    #expect(monitor.path == "/health")
    #expect(monitor.consecutiveFailures == 0)
    // On /health a busy runner is alive, and a 404 is now a failure.
    #expect(monitor.isAlive(status: 409))
    #expect(!monitor.isAlive(status: 404))
    let results = (0 ..< LivenessMonitor.failureLimit).map { _ in monitor.record(status: 404) }
    #expect(results == Array(repeating: false, count: LivenessMonitor.failureLimit - 1) + [true])
    #expect(monitor.path == "/health")
  }

  @Test func bracketsIPv6InURL() {
    #expect(RunnerLauncher.url(host: "fd00::1", port: 8100)?.absoluteString == "http://[fd00::1]:8100/")
    #expect(RunnerLauncher.url(host: "10.0.0.2", port: 8100)?.absoluteString == "http://10.0.0.2:8100/")
  }

  @Test func findsNestedTunnelAddress() {
    let json = Data(#"{"result":{"connectionProperties":{"tunnelState":"connected","tunnelIPAddress":"fdb2::1"}}}"#.utf8)
    #expect(RunnerLauncher.findTunnelAddress(inDevicectlJSON: json) == "fdb2::1")
  }

  @Test func detectsUITestingInitializationFailure() {
    let line = #"2026-10-27 16:41:08.305411+0900 RelayRunnerUITests-Runner[4774:518973] [Default] Failed to initialize for UI testing: Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000 "Timed out while enabling automation mode." UserInfo={NSLocalizedDescription=Timed out while enabling automation mode.}"#
    #expect(RunnerLauncher.startupFailure(in: line) == StartupFailure(
      message: "Failed to initialize for UI testing: Timed out while enabling automation mode.",
      isUITestingSetup: true
    ))
  }

  @Test func readsTheSDKVersionFromTheXCTestRunName() {
    let name = "RelayRunner_iphonesimulator27.2-arm64-x86_64.xctestrun"
    #expect(XCTestRunSelection.sdkVersion(ofFileNamed: name, platform: "iphonesimulator") == "27.2")
    #expect(XCTestRunSelection.sdkVersion(ofFileNamed: "RelayRunner_iphoneos26.0.1-arm64.xctestrun", platform: "iphoneos") == "26.0.1")
    #expect(XCTestRunSelection.sdkVersion(ofFileNamed: "RelayRunner_iphoneos27.0.xctestrun", platform: "iphoneos") == "27.0")
    #expect(XCTestRunSelection.sdkVersion(ofFileNamed: name, platform: "iphoneos") == nil)
    #expect(XCTestRunSelection.sdkVersion(ofFileNamed: "RelayRunner.xctestrun", platform: "iphonesimulator") == nil)
    #expect(XCTestRunSelection.sameVersion("27.0", "27"))
    #expect(!XCTestRunSelection.sameVersion("27.2", "27.20"))
    #expect(XCTestRunSelection.isVersion("27.2") && !XCTestRunSelection.isVersion("27.") && !XCTestRunSelection.isVersion("xcrun: error"))
  }

  /// Xcode names the file after its SDK but builds both into the same, shared products, so the file to use is the
  /// one the last build wrote, and only while that build's SDK is this Xcode's.
  @Test func picksTheXCTestRunOfTheLastBuild() {
    let products = URL(fileURLWithPath: "/build/DerivedData-sim/Build/Products")
    func file(_ version: String, _ seconds: TimeInterval) -> XCTestRunFile {
      XCTestRunFile(url: products.appendingPathComponent("RelayRunner_iphonesimulator\(version)-arm64-x86_64.xctestrun"),
                    modified: Date(timeIntervalSinceReferenceDate: seconds))
    }
    let old = file("26.0", 100), current = file("27.2", 200), earlier = file("27.0", 50)
    let files = [old, current, earlier]

    // After a build: the file it wrote, though another sorts first by name.
    #expect(XCTestRunSelection.built(files, since: Date(timeIntervalSinceReferenceDate: 150)) == current.url)
    let rebuiltOld = file("26.0", 300)
    #expect(XCTestRunSelection.built([rebuiltOld, current], since: Date(timeIntervalSinceReferenceDate: 299.5)) == rebuiltOld.url)
    // A clock coarser than the build start still picks the newest.
    #expect(XCTestRunSelection.built(files, since: Date(timeIntervalSinceReferenceDate: 1000)) == current.url)
    #expect(XCTestRunSelection.built([], since: Date()) == nil)

    // Reused: the last build, if it is for this SDK.
    #expect(XCTestRunSelection.reusable(files, platform: "iphonesimulator", sdkVersion: "27.2") == .reuse(current.url))
    // Another Xcode: even with a file named for its SDK, the products are the last build's, so rebuild.
    #expect(XCTestRunSelection.reusable(files, platform: "iphonesimulator", sdkVersion: "27.0") == .otherSDK(current.url))
    #expect(XCTestRunSelection.reusable(files, platform: "iphonesimulator", sdkVersion: "28.0") == .otherSDK(current.url))
    // xcrun could not tell the SDK: reuse the last build, as before.
    #expect(XCTestRunSelection.reusable(files, platform: "iphonesimulator", sdkVersion: nil) == .reuse(current.url))
    #expect(XCTestRunSelection.reusable([], platform: "iphonesimulator", sdkVersion: "27.2") == XCTestRunSelection.Reuse.none)
    // Written in the same instant: the higher version.
    #expect(XCTestRunSelection.newest([file("27.0", 10), file("27.2", 10)])?.url == file("27.2", 10).url)
  }

  /// XCTest waits `XCUIApplicationStateTimeout` (60 s by default) for automation mode, which a device may
  /// not enable until someone enters its passcode. The scheme passes a longer one to the runner as two arguments, so it
  /// reaches NSUserDefaults as a key and a value.
  @Test func schemePassesTheApplicationStateTimeoutToTheRunner() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scheme = try String(contentsOf: root.appendingPathComponent("Runner/RelayRunner.xcodeproj/xcshareddata/xcschemes/RelayRunner.xcscheme"), encoding: .utf8)
    let testAction = try #require(scheme.range(of: "<TestAction").flatMap { start in
      scheme.range(of: "</TestAction>", range: start.upperBound ..< scheme.endIndex).map { scheme[start.lowerBound ..< $0.upperBound] }
    })
    #expect(testAction.contains(#"shouldUseLaunchSchemeArgsEnv = "NO""#))
    #expect(testAction.contains(#"argument = "-XCUIApplicationStateTimeout""#))
    #expect(testAction.contains(#"argument = "120""#))
  }

  /// Enabling automation mode may wait for the passcode on the device, so a timeout points there first.
  @Test func startupFailureHintsAskForThePasscodeFirstOnADevice() {
    let setup = StartupFailure(message: "Failed to initialize for UI testing: Timed out while enabling automation mode.", isUITestingSetup: true)
    let hints = RunnerLauncher.startupFailureHints(for: setup, isSimulator: false)
    #expect(hints.count == 3)
    #expect(hints.first?.contains("passcode") == true)
    #expect(hints.contains { $0.contains("Enable UI Automation") })
    #expect(hints.contains { $0.contains("unlock") })
  }

  @Test func startupFailureHintsOnASimulatorSuggestOneRetry() {
    let setup = StartupFailure(message: "Failed to initialize for UI testing: Timed out while enabling automation mode.", isUITestingSetup: true)
    let hints = RunnerLauncher.startupFailureHints(for: setup, isSimulator: true)
    #expect(hints == ["this is usually transient on a simulator; run relay start again once"])
    #expect(!hints.contains { $0.contains("passcode") || $0.contains("Enable UI Automation") || $0.contains("unlock") })
  }

  @Test func startupFailureHintsAreEmptyForATestFailure() {
    let failure = StartupFailure(message: "** TEST FAILED **", isUITestingSetup: false)
    #expect(RunnerLauncher.startupFailureHints(for: failure, isSimulator: false).isEmpty)
    #expect(RunnerLauncher.startupFailureHints(for: failure, isSimulator: true).isEmpty)
  }

  @Test func detectsTestFailures() {
    #expect(RunnerLauncher.startupFailure(in: "** TEST EXECUTE FAILED **") == StartupFailure(message: "** TEST EXECUTE FAILED **", isUITestingSetup: false))
    #expect(RunnerLauncher.startupFailure(in: "** TEST FAILED **")?.isUITestingSetup == false)
    let testCase = "Test Case '-[RelayRunnerUITests.RelayRunnerUITests testRunServer]' failed (60.123 seconds)."
    #expect(RunnerLauncher.startupFailure(in: testCase)?.message == testCase)
  }

  @Test func ignoresNormalRunnerOutput() {
    let lines = [
      "Test Case '-[RelayRunnerUITests.RelayRunnerUITests testRunServer]' started.",
      "Test Case '-[RelayRunnerUITests.RelayRunnerUITests testRunServer]' passed (8.971 seconds).",
      "\t Executed 1 test, with 0 failures (0 unexpected) in 8.971 (8.976) seconds",
      "** TEST EXECUTE SUCCEEDED **",
      "RELAY_RUNNER_READY port=8100 addresses=en0=192.168.1.5",
      "nw_listener_socket_inbox_create_socket setsockopt SO_NECP_LISTENUUID failed [2: No such file or directory]"
    ]
    for line in lines {
      #expect(RunnerLauncher.startupFailure(in: line) == nil)
    }
  }
}

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct StartLogTests {
  @Test func logsAreNamedByPortAndNeverShared() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamp = "20261029-120000"

    // Two starts in the same second, on different ports.
    let a = try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8100)
    let b = try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8101)
    #expect(a.lastPathComponent == "start-20261029-120000-8100.log")
    #expect(b.lastPathComponent == "start-20261029-120000-8101.log")
    #expect(try Data(contentsOf: a).isEmpty)

    // A restart on the same port in the same second does not read or truncate the previous log.
    try Data("ready: http://127.0.0.1:8100/\n".utf8).write(to: a)
    let again = try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8100)
    #expect(again.lastPathComponent == "start-20261029-120000-8100-2.log")
    #expect(try Data(contentsOf: again).isEmpty)
    #expect(try String(contentsOf: a, encoding: .utf8) == "ready: http://127.0.0.1:8100/\n")
    #expect(try RunnerLauncher.createLog("start", in: directory, stamp: stamp, port: 8100).lastPathComponent == "start-20261029-120000-8100-3.log")

    // relay install --build has no port.
    #expect(try RunnerLauncher.createLog("build", in: directory, stamp: stamp, port: nil).lastPathComponent == "build-20261029-120000.log")
    #expect(throws: SetupError.self) {
      try RunnerLauncher.createLog("start", in: directory.appendingPathComponent("missing"), stamp: stamp, port: 8100)
    }
  }
}
