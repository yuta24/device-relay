import CoreGraphics
import Foundation
@testable import relay
import Testing

struct ArgumentsTests {
    @Test func parsesStartOptions() throws {
        let command = try Arguments.parse(["start", "--udid", "ABC", "--port", "9000", "--team-id", "ABCDE12345", "--rebuild"])
        var expected = StartOptions(udid: "ABC", port: 9000, portGiven: true, teamID: "ABCDE12345")
        expected.rebuild = true
        #expect(command == .start(expected))
    }

    @Test func startPicksTheDeviceWithoutUDID() throws {
        #expect(try Arguments.parse(["start"]) == .start(StartOptions()))
        #expect(try Arguments.parse(["start", "--device", "iPhone 17", "--project", "../relay"])
            == .start(StartOptions(device: "iPhone 17", project: "../relay")))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--udid", "A", "--device", "B"]) }
    }

    @Test func startAndDoctorNarrowTheCandidates() throws {
        #expect(try Arguments.parse(["start", "--simulator", "--os", "26.5"]) == .start(StartOptions(simulator: true, os: "26.5")))
        #expect(try Arguments.parse(["start", "--device", "iPhone 17", "--os", "27"]) == .start(StartOptions(device: "iPhone 17", os: "27")))
        #expect(try Arguments.parse(["doctor", "--simulator"]) == .doctor(DoctorOptions(simulator: true)))
        #expect(try Arguments.parse(["doctor", "--os", "27.0"]) == .doctor(DoctorOptions(os: "27.0")))
        #expect(try Arguments.parse(["devices", "--os", "26"]) == .devices(json: false, os: "26"))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--os", "iOS 27"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["doctor", "--os"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["devices", "--os", "latest"]) }
    }

    @Test func rejectsMalformedTeamID() {
        #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--team-id", "TEAM"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--team-id", "abcde12345"]) }
    }

    @Test func parsesSetupCommands() throws {
        #expect(try Arguments.parse(["devices"]) == .devices(json: false, os: nil))
        #expect(try Arguments.parse(["devices", "--json"]) == .devices(json: true, os: nil))
        #expect(try Arguments.parse(["doctor", "--device", "iPad"]) == .doctor(DoctorOptions(device: "iPad")))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["doctor", "--udid", "A", "--device", "B"]) }
        #expect(try Arguments.parse(["config"]) == .config(ConfigOptions(action: .show)))
        #expect(try Arguments.parse(["config", "set", "teamID", "ABCDE12345"]) == .config(ConfigOptions(action: .set("teamID", "ABCDE12345"))))
        #expect(try Arguments.parse(["config", "unset", "teamID"]) == .config(ConfigOptions(action: .unset("teamID"))))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "get", "team"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "set", "teamID"]) }
    }

    @Test func rejectsInvalidPort() {
        #expect(throws: ArgumentError.self) { try Arguments.parse(["start", "--udid", "A", "--port", "70000"]) }
    }

    @Test func parsesBenchTap() throws {
        let command = try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--count", "3", "--tap", "10,20.5"])
        var expected = BenchOptions(url: "http://127.0.0.1:8100", count: 3)
        expected.tap = (10, 20.5)
        #expect(command == .bench(expected))
    }

    @Test func parsesBenchMode() throws {
        let command = try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--tap", "1,2", "--mode", "xcui"])
        var expected = BenchOptions(url: "http://127.0.0.1:8100")
        expected.tap = (1, 2)
        expected.mode = "xcui"
        #expect(command == .bench(expected))
    }

    @Test func rejectsUnknownBenchMode() {
        #expect(throws: ArgumentError.self) {
            try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--mode", "fast"])
        }
    }

    @Test func parsesBenchToken() throws {
        let command = try Arguments.parse(["bench", "--url", "http://127.0.0.1:8100", "--token", "abc"])
        var expected = BenchOptions(url: "http://127.0.0.1:8100")
        expected.token = "abc"
        #expect(command == .bench(expected))
    }

    @Test func parsesAllowWiFi() throws {
        #expect(try Arguments.parse(["start", "--udid", "A"]) == .start(StartOptions(udid: "A")))
        var expected = StartOptions(udid: "A")
        expected.allowWiFi = true
        #expect(try Arguments.parse(["start", "--udid", "A", "--allow-wifi"]) == .start(expected))
    }

    @Test func noArgumentsShowsHelp() throws {
        #expect(try Arguments.parse([]) == .help)
    }
}

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
        results = (0..<LivenessMonitor.failureLimit).map { _ in monitor.record(status: 409) }
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
        let results = (0..<LivenessMonitor.failureLimit).map { _ in monitor.record(status: 404) }
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
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scheme = try String(contentsOf: root.appendingPathComponent("Runner/RelayRunner.xcodeproj/xcshareddata/xcschemes/RelayRunner.xcscheme"), encoding: .utf8)
        let testAction = try #require(scheme.range(of: "<TestAction").flatMap { start in
            scheme.range(of: "</TestAction>", range: start.upperBound..<scheme.endIndex).map { scheme[start.lowerBound..<$0.upperBound] }
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

struct RunnerOutputLineBufferTests {
    @Test func splitsOnNewlines() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("one\ntwo\n\nthr".utf8)) == ["one", "two", ""])
        #expect(buffer.append(Data("ee\n".utf8)) == ["three"])
        #expect(buffer.finish() == nil)
    }

    @Test func stripsCarriageReturnsOfCRLF() {
        var buffer = RunnerOutputLineBuffer()
        let lines = buffer.append(Data("RELAY_RUNNER_READY port=8100 addresses=en0=10.0.0.2\r\n** TEST EXECUTE FAILED **\r\r\n".utf8))
        #expect(lines == ["RELAY_RUNNER_READY port=8100 addresses=en0=10.0.0.2", "** TEST EXECUTE FAILED **"])
        #expect(RunnerLauncher.parseReadyLine(lines[0]) == ["10.0.0.2"])
        #expect(RunnerLauncher.startupFailure(in: lines[1])?.message == "** TEST EXECUTE FAILED **")
    }

    @Test func handlesCRLFSplitAcrossChunks() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("relay-runner GET /health -> 200 1ms\r".utf8)).isEmpty)
        #expect(buffer.append(Data("\nnext".utf8)) == ["relay-runner GET /health -> 200 1ms"])
    }

    @Test func keepsLoneCarriageReturnsInsideALine() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("a\rb\n".utf8)) == ["a\rb"])
    }

    @Test func decodesMultibyteCharactersSplitAcrossChunks() {
        var buffer = RunnerOutputLineBuffer()
        let bytes = Array("ログ🎉\r\n".utf8)
        // Cut inside the 3-byte "グ" and inside the 4-byte emoji.
        #expect(buffer.append(Data(bytes[..<4])).isEmpty)
        #expect(buffer.append(Data(bytes[4..<8])).isEmpty)
        #expect(buffer.append(Data(bytes[8...])) == ["ログ🎉"])
    }

    @Test func emitsTheUnterminatedLastLineOnFinish() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("done\r\n** TEST EXECUTE SUCCEEDED **\r".utf8)) == ["done"])
        #expect(buffer.finish() == "** TEST EXECUTE SUCCEEDED **")
        #expect(buffer.finish() == nil)
    }

    @Test func cutsLinesLongerThanTheLimit() {
        var buffer = RunnerOutputLineBuffer(maxLineLength: 8)
        #expect(buffer.append(Data("abcdefghij".utf8)) == ["abcdefgh"])
        #expect(buffer.append(Data("klmnopqrst".utf8)) == ["ijklmnop"])
        #expect(buffer.append(Data("u\n".utf8)) == ["qrstu"])
    }

    @Test func neverCutsInsideAMultibyteCharacter() {
        var buffer = RunnerOutputLineBuffer(maxLineLength: 8)
        // "グ" occupies bytes 6..<9, so the first piece stops before it.
        #expect(buffer.append(Data("abcdefグhi".utf8)) == ["abcdef"])
        #expect(buffer.append(Data("\n".utf8)) == ["グhi"])
    }
}

struct BenchTests {
    @Test func percentilePicksNearestRank() {
        let sorted: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(Bench.percentile(sorted, 0.5) == 6)
        #expect(Bench.percentile(sorted, 0.9) == 9)
        #expect(Bench.percentile([], 0.5) == 0)
    }

    @Test func tokenOptionWinsOverRunnerInfo() throws {
        var options = BenchOptions(url: "http://127.0.0.1:8100")
        options.token = "from-option"
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try Bench.token(options, infoURL: missing) == "from-option")
    }

    @Test func tokenFallsBackToRunnerInfo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let infoURL = directory.appendingPathComponent(RunnerInfo.fileName)
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "from-file", udid: "SIM").write(to: infoURL)

        #expect(try Bench.token(BenchOptions(url: "http://127.0.0.1:8100"), infoURL: infoURL) == "from-file")
        RunnerInfo.remove(at: infoURL)
        #expect(throws: SetupError.self) { try Bench.token(BenchOptions(url: "http://127.0.0.1:8100"), infoURL: infoURL) }
    }
}

struct RunnerAuthTests {
    @Test func generatesDistinct32ByteHexTokens() {
        let tokens = (0..<20).map { _ in RunnerAuth.generateToken() }
        for token in tokens {
            #expect(token.count == RunnerAuth.tokenByteCount * 2)
            #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        #expect(Set(tokens).count == tokens.count)
    }

    @Test func parsesBearerHeader() {
        #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: "Bearer abc123") == "abc123")
        #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: "bearer abc123") == "abc123")
        #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: "  Bearer   abc123  ") == "abc123")
        #expect(RunnerAuth.authorizationHeader(token: "abc") == "Bearer abc")
    }

    @Test func rejectsMalformedHeaders() {
        for header in [nil, "", "Bearer", "Bearer ", "Basic abc123", "abc123", "Bearerabc123"] {
            #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: header) == nil)
        }
    }

    @Test func comparesTokens() {
        #expect(RunnerAuth.constantTimeEquals("abc", "abc"))
        #expect(RunnerAuth.constantTimeEquals("", ""))
        #expect(!RunnerAuth.constantTimeEquals("abc", "abd"))
        #expect(!RunnerAuth.constantTimeEquals("abc", "ab"))
        #expect(!RunnerAuth.constantTimeEquals("ab", "abc"))
        #expect(!RunnerAuth.constantTimeEquals("", "a"))
        // A prefix padded with NUL bytes must not match through the zero padding.
        #expect(!RunnerAuth.constantTimeEquals("abc", "abc\u{0}"))
    }

    @Test func authorizesOnlyTheMatchingBearerToken() {
        let token = RunnerAuth.generateToken()
        let hash = RunnerAuth.tokenHash(token)
        #expect(RunnerAuth.isAuthorized(authorizationHeader: "Bearer \(token)", tokenHash: hash))
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: nil, tokenHash: hash))
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: "Bearer \(RunnerAuth.generateToken())", tokenHash: hash))
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: "Basic \(token)", tokenHash: hash))
        // Knowing the hash (e.g. from an xcresult bundle) is not enough to authenticate.
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: "Bearer \(hash)", tokenHash: hash))
    }

    @Test func hashesTokensWithSHA256() {
        // FIPS 180-2 test vector.
        #expect(RunnerAuth.tokenHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let token = RunnerAuth.generateToken()
        #expect(RunnerAuth.tokenHash(token) == RunnerAuth.tokenHash(token))
        #expect(RunnerAuth.tokenHash(token) != token)
    }

    @Test func normalizesTheHashFromTheEnvironment() {
        let hash = RunnerAuth.tokenHash("abc")
        #expect(RunnerAuth.normalizedTokenHash(hash) == hash)
        #expect(RunnerAuth.normalizedTokenHash(" \(hash.uppercased()) ") == hash)
        for invalid in ["", "abc", String(hash.dropLast()), hash + "0", String(hash.dropLast()) + "g"] {
            #expect(RunnerAuth.normalizedTokenHash(invalid) == nil, "\(invalid)")
        }
    }
}

struct RunnerInfoTests {
    @Test func writesOwnerOnlyFileAndReadsItBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        let info = RunnerInfo(url: "http://[fd00::1]:8100/", token: RunnerAuth.generateToken(), udid: "DEVICE")

        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url) == info)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(json?["url"] == "http://[fd00::1]:8100/")
    }

    @Test func replacesLooserExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])

        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url) == info)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func writeFailureThrowsAndKeepsWhatIsInTheWay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        let marker = url.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())

        #expect(throws: SetupError.self) {
            try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: url)
        }
        RunnerInfo.remove(at: url)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func removeDeletesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: url)
        RunnerInfo.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct RunnerHTTPFramingTests {
    private func parse(_ text: String) -> RunnerHTTPFraming.Result {
        RunnerHTTPFraming.parseHead(Data(text.utf8))
    }

    private func status(_ text: String) -> Int? {
        if case .failure(let failure) = parse(text) { return failure.status }
        return nil
    }

    @Test func parsesHeadAndBodyOffset() {
        let text = "POST /tap?x=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 7\r\nAuthorization: Bearer t\r\n\r\n{\"a\":1}"
        guard case .head(let head, let headerLength) = parse(text) else {
            Issue.record("expected a head")
            return
        }
        #expect(head.method == "POST")
        #expect(head.target == "/tap?x=1")
        #expect(head.contentLength == 7)
        #expect(head.headers["authorization"] == "Bearer t")
        #expect(headerLength == text.utf8.count - 7)
    }

    @Test func missingContentLengthMeansNoBody() {
        guard case .head(let head, _) = parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n") else {
            Issue.record("expected a head")
            return
        }
        #expect(head.contentLength == 0)
    }

    @Test func waitsForTheBlankLine() {
        #expect(parse("GET /health HTTP/1.1\r\nHost: x\r\n") == .incomplete)
        #expect(parse("") == .incomplete)
    }

    /// `Content-Length: -1` used to pass `Int(_:)` and crash the runner with an invalid range.
    @Test func rejectsNegativeAndNonNumericContentLength() {
        for value in ["-1", "+5", "abc", "", "1.5", "0x10", " 5 5", "99999999999999999999999"] {
            #expect(status("POST /tap HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n") == 400, "\(value)")
        }
    }

    @Test func rejectsConflictingContentLengths() {
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n") == 400)
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: 5, 6\r\n\r\n") == 400)
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: 5,\r\n\r\n") == 400)
    }

    @Test func acceptsRepeatedEqualContentLengths() {
        guard case .head(let head, _) = parse("POST /tap HTTP/1.1\r\nContent-Length: 5\r\ncontent-length: 5, 5\r\n\r\n") else {
            Issue.record("expected a head")
            return
        }
        #expect(head.contentLength == 5)
    }

    @Test func rejectsOversizedBodiesUpFront() {
        let tooLarge = RunnerHTTPFraming.maxBodySize + 1
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: \(tooLarge)\r\n\r\n") == 413)
    }

    @Test func limitsTheHeadSize() {
        let filler = String(repeating: "a", count: RunnerHTTPFraming.maxHeaderSize)
        // Still waiting for the terminator, but already past the limit.
        #expect(status("GET / HTTP/1.1\r\nX: \(filler)") == 431)
        // Complete, but too large.
        #expect(status("GET / HTTP/1.1\r\nX: \(filler)\r\n\r\n") == 431)
        // Just under the limit is fine.
        let fits = String(repeating: "a", count: RunnerHTTPFraming.maxHeaderSize - 100)
        #expect(status("GET / HTTP/1.1\r\nX: \(fits)\r\n\r\n") == nil)
    }

    /// A chunked body used to be read as empty, and its bytes then parsed as the next request.
    @Test func rejectsTransferEncoding() {
        #expect(status("POST /tap HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n") == 501)
        #expect(status("POST /tap HTTP/1.1\r\ntransfer-encoding: identity\r\nContent-Length: 5\r\n\r\n") == 501)
        #expect(status("GET /health HTTP/1.1\r\nTransfer-Encoding: \r\n\r\n") == 501)
    }

    @Test func rejectsInvalidRequestLineAndEncoding() {
        #expect(status("GARBAGE\r\n\r\n") == 400)
        var bytes = Data("GET /\u{FF} HTTP/1.1\r\n\r\n".utf8)
        bytes[5] = 0xFF
        if case .failure(let failure) = RunnerHTTPFraming.parseHead(bytes) {
            #expect(failure.status == 400)
        } else {
            Issue.record("expected invalid UTF-8 to be rejected")
        }
    }
}

struct RunnerKeyboardTests {
    @Test func parsesKeyNamesAndAliases() {
        #expect(RunnerKey(name: "return") == .return)
        #expect(RunnerKey(name: "Enter") == .return)
        #expect(RunnerKey(name: "delete") == .delete)
        #expect(RunnerKey(name: "BACKSPACE") == .delete)
        #expect(RunnerKey(name: "space") == .space)
        for unknown in ["", "home", "returns", " return", "\n"] {
            #expect(RunnerKey(name: unknown) == nil, "\(unknown.debugDescription)")
        }
    }

    @Test func parsesKeysArrayInOrder() throws {
        #expect(try RunnerKey.parse(["delete", "delete", "return"]) == [.delete, .delete, .return])
        #expect(try RunnerKey.parse([String]()) == [])
    }

    @Test func rejectsInvalidKeysArrays() {
        #expect(throws: RunnerKeyError.notAnArray) { try RunnerKey.parse("return") }
        #expect(throws: RunnerKeyError.notAString) { try RunnerKey.parse(["return", 1]) }
        #expect(throws: RunnerKeyError.unknownKey("f1")) { try RunnerKey.parse(["return", "f1"]) }
        #expect(RunnerKeyError.unknownKey("f1").description == "key: unsupported key 'f1' (expected return, delete, space)")
    }

    /// Tab and escape have no key on the iPhone software keyboard, so they are rejected rather than
    /// typed as a "\t" character or silently dropped.
    @Test func rejectsTabAndEscape() {
        for name in ["tab", "Tab", "escape", "esc"] {
            #expect(RunnerKey(name: name) == nil, "\(name)")
        }
        #expect(throws: RunnerKeyError.unknownKey("tab")) { try RunnerKey.parse(["return", "tab"]) }
        #expect(throws: RunnerKeyError.unknownKey("esc")) { try RunnerKey.parse(["esc"]) }
    }

    @Test func requiresNonEmptyTextWithoutKeys() throws {
        #expect(try RunnerTyping.text("hello", keyCount: 0) == "hello")
        #expect(throws: RunnerTextError.missing) { try RunnerTyping.text(nil, keyCount: 0) }
        #expect(throws: RunnerTextError.missing) { try RunnerTyping.text("", keyCount: 0) }
        #expect(throws: RunnerTextError.notAString) { try RunnerTyping.text(123, keyCount: 0) }
    }

    @Test func allowsAbsentOrEmptyTextWithKeys() throws {
        #expect(try RunnerTyping.text(nil, keyCount: 1) == "")
        #expect(try RunnerTyping.text("", keyCount: 1) == "")
        #expect(try RunnerTyping.text("abc", keyCount: 2) == "abc")
    }

    /// `{"text": 123, "keys": ["return"]}` used to drop the text silently and press only Return.
    @Test func rejectsNonStringTextWithKeys() throws {
        let body = try JSONSerialization.jsonObject(with: Data(#"{"text":123,"t":true,"n":null,"a":["x"],"o":{}}"#.utf8)) as? [String: Any]
        for name in ["text", "t", "n", "a", "o"] {
            #expect(throws: RunnerTextError.notAString, "\(name)") { try RunnerTyping.text(body?[name], keyCount: 1) }
        }
    }

    @Test func recognizesMissingKeyboardFocus() {
        let issue = "Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: ..."
        #expect(RunnerTyping.isMissingKeyboardFocus(issue))
        #expect(!RunnerTyping.isMissingKeyboardFocus("Application com.example is not running"))
        #expect(RunnerTyping.missingKeyboardFocusMessage(bundleID: "com.apple.mobilesafari") == "no element has keyboard focus in com.apple.mobilesafari")
    }
}

struct RunnerElementTreeTests {
    private func node(_ type: String, children: [RunnerElementNode] = [], truncated: Bool = false) -> RunnerElementNode {
        RunnerElementNode(
            type: type, identifier: "", label: "", value: nil, placeholder: nil, frame: .zero,
            enabled: true, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children,
            truncated: truncated
        )
    }

    @Test func namesElementTypesByRawValue() {
        #expect(RunnerElementTree.typeName(rawValue: 0) == "any")
        #expect(RunnerElementTree.typeName(rawValue: 2) == "application")
        #expect(RunnerElementTree.typeName(rawValue: 9) == "button")
        #expect(RunnerElementTree.typeName(rawValue: 48) == "staticText")
        #expect(RunnerElementTree.typeName(rawValue: 49) == "textField")
        #expect(RunnerElementTree.typeName(rawValue: 75) == "cell")
        #expect(RunnerElementTree.typeName(rawValue: 82) == "statusItem")
        #expect(RunnerElementTree.typeName(rawValue: 83) == "type83")
    }

    @Test func parsesMaxDepth() {
        #expect(RunnerElementTree.maxDepth("0") == 0)
        #expect(RunnerElementTree.maxDepth("3") == 3)
        for invalid in ["", "-1", "1.5", "abc"] {
            #expect(RunnerElementTree.maxDepth(invalid) == nil, "\(invalid)")
        }
    }

    @Test func buildsJSONWithEveryKey() throws {
        var field = node("textField")
        field.identifier = "relay.input"
        field.label = "Name"
        field.value = "hello"
        field.placeholder = "Type here"
        field.frame = CGRect(x: 16, y: 83.3333333, width: 370, height: 34)
        field.hasKeyboardFocus = true
        let object = RunnerElementTree.json(node("application", children: [field]))

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == """
            {"children":[{"children":[],"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":83.333},\
            "hasFocus":false,"hasKeyboardFocus":true,"identifier":"relay.input","label":"Name","placeholder":"Type here","selected":false,\
            "type":"textField","value":"hello"}],"enabled":true,"frame":{"height":0,"width":0,"x":0,"y":0},\
            "hasFocus":false,"hasKeyboardFocus":null,"identifier":"","label":"","placeholder":null,"selected":false,"type":"application",\
            "value":null}
            """)
    }

    @Test func marksTruncatedChildren() {
        let object = RunnerElementTree.json(node("window", truncated: true))
        #expect(object["truncated"] as? Bool == true)
        #expect((object["children"] as? [Any])?.isEmpty == true)
        #expect(RunnerElementTree.json(node("window"))["truncated"] == nil)
    }

    @Test func roundsPoints() throws {
        let object = RunnerElementTree.json(CGPoint(x: 201, y: 213.16666666666666))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == #"{"x":201,"y":213.167}"#)
    }

    private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func element(
        _ type: String, identifier: String = "", label: String = "", placeholder: String? = nil,
        frame: CGRect = CGRect(x: 16, y: 100, width: 370, height: 44), enabled: Bool = true,
        children: [RunnerElementNode] = []
    ) -> RunnerElementNode {
        var element = node(type, children: children)
        element.identifier = identifier
        element.label = label
        element.placeholder = placeholder
        element.frame = frame
        element.enabled = enabled
        return element
    }

    private func filtered(_ children: [RunnerElementNode]) -> [String] {
        let root = element("application", label: "App", frame: screen, children: [element("window", frame: screen, children: children)])
        return RunnerElementTree.interactiveElements(in: root, screen: screen).map { "\($0.type) \($0.label)\($0.identifier)" }
    }

    /// The frame of the nth row of a list, so elements don't overlap.
    private func row(_ index: Int) -> CGRect {
        CGRect(x: 16, y: 100 + 50 * CGFloat(index), width: 370, height: 44)
    }

    @Test func keepsNamedControls() {
        #expect(filtered([
            element("staticText", label: "Settings", frame: row(0)),
            element("button", identifier: "com.apple.settings.general", label: "General", frame: row(1),
                    children: [element("staticText", label: "General", frame: row(1))]),
            element("switch", label: "Airplane Mode", frame: row(2)),
            element("cell", identifier: "row.1", frame: row(3)),
            element("image", label: "photo", frame: row(4)),
            element("other", frame: row(5), children: [element("link", label: "Help", frame: row(5))])
        ]) == ["button Generalcom.apple.settings.general", "switch Airplane Mode", "cell row.1", "link Help"])
    }

    @Test func keepsTextInputsWithoutNames() {
        #expect(filtered([
            element("textField", frame: row(0)),
            element("searchField", placeholder: "Search", frame: row(1)),
            element("button", frame: row(2))
        ]) == ["textField ", "searchField "])
    }

    @Test func dropsDisabledAndOffscreenControls() {
        #expect(filtered([
            element("button", label: "Off", frame: row(0), enabled: false),
            element("cell", label: "Below", frame: CGRect(x: 0, y: 900, width: 402, height: 44)),
            element("cell", label: "Edge", frame: CGRect(x: 0, y: 850, width: 402, height: 44)),
            element("button", label: "Empty", frame: CGRect(x: 10, y: 10, width: 0, height: 20))
        ]) == ["cell Edge"])
    }

    /// The keys are left to relay type, and a control the keyboard covers can't be tapped.
    @Test func dropsTheKeyboardAndWhatItCovers() {
        let keyboard = CGRect(x: 0, y: 538, width: 402, height: 336)
        #expect(filtered([
            element("textField", identifier: "relay.input", frame: CGRect(x: 16, y: 86, width: 370, height: 34)),
            element("button", label: "Submit", frame: CGRect(x: 16, y: 600, width: 370, height: 44)),
            element("keyboard", frame: keyboard, children: [element("key", label: "q", frame: CGRect(x: 0, y: 550, width: 40, height: 40))])
        ]) == ["textField relay.input"])
    }

    /// Settings on iOS 27: the search bar at the bottom covers the middle of the last cell, and the search
    /// field holds two identical Dictate buttons.
    @Test func dropsControlsALaterControlCovers() {
        let dictate = CGRect(x: 342, y: 811, width: 17, height: 22)
        #expect(filtered([
            element("button", label: "StandBy", frame: CGRect(x: 16, y: 709, width: 370, height: 52)),
            element("button", label: "Screen Time", frame: CGRect(x: 16, y: 796, width: 370, height: 52)),
            element("other", frame: CGRect(x: 28, y: 798, width: 346, height: 48), children: [
                element("searchField", label: "Search", frame: CGRect(x: 28, y: 808, width: 346, height: 28), children: [
                    element("button", label: "Dictate", frame: dictate),
                    element("button", label: "Dictate", frame: dictate)
                ])
            ])
        ]) == ["button StandBy", "searchField Search", "button Dictate"])
    }

    /// A control's own contents and the controls before it are not on top of it.
    @Test func keepsControlsUnderTheirContentsAndEarlierControls() {
        #expect(filtered([
            element("button", label: "Background", frame: row(0)),
            element("cell", label: "Row", frame: row(0), children: [element("button", label: "Info", frame: row(0))])
        ]) == ["cell Row", "button Info"])
    }

    /// Table cells often have no label of their own; their texts name them, and tapping a text hits the cell.
    @Test func keepsTheTextsOfUnnamedControls() {
        #expect(filtered([
            element("cell", frame: row(0), children: [
                element("staticText", label: "Wi-Fi", frame: CGRect(x: 30, y: 105, width: 100, height: 30)),
                element("staticText", label: "Off", frame: CGRect(x: 300, y: 105, width: 50, height: 30)),
                element("image", frame: CGRect(x: 360, y: 105, width: 10, height: 30))
            ]),
            element("cell", frame: row(1), enabled: false, children: [element("staticText", label: "Bluetooth", frame: row(1))]),
            element("staticText", label: "Footer", frame: row(2)),
            // Settings: cell > other > button "General" > staticText "General"; the button is enough.
            element("cell", frame: row(3), children: [element("other", frame: row(3), children: [
                element("button", identifier: "com.apple.settings.general", label: "General", frame: row(3),
                        children: [element("staticText", label: "General", frame: row(3))])
            ])])
        ]) == ["staticText Wi-Fi", "staticText Off", "button Generalcom.apple.settings.general"])
    }

    @Test func buildsFilteredJSON() throws {
        var field = element("textField", identifier: "relay.input", placeholder: "Type here",
                            frame: CGRect(x: 16, y: 83.3333333, width: 370, height: 34))
        field.value = "hello"
        let object = RunnerElementTree.filteredJSON([field], filter: .interactive, bundleID: "com.example")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == """
            {"bundleId":"com.example","count":1,"elements":[{"frame":{"height":34,"width":370,"x":16,"y":83.333},\
            "identifier":"relay.input","label":"","placeholder":"Type here","selected":false,"type":"textField","value":"hello"}],\
            "filter":"interactive","ok":true}
            """)
    }

    @Test func writesOneLinePerElement() {
        var field = element("textField", identifier: "relay.input", label: "Name \"first\"\nline", frame: CGRect(x: 16, y: 83.6, width: 370, height: 34))
        field.value = "a/b"
        field.hasKeyboardFocus = true
        var tab = element("button", label: "Home", enabled: false)
        tab.selected = true
        #expect(RunnerElementTree.compactText([field, tab]) == """
            textField label="Name \\"first\\"\\nline" id="relay.input" value="a/b" frame=16,84,370,34 focused
            button label="Home" frame=16,100,370,44 selected disabled

            """)
    }

    @Test func indentsTheWholeTreeInCompactText() {
        let root = element("application", label: "App", frame: screen, children: [
            element("window", frame: screen, children: [element("button", label: "OK")]),
            node("other", truncated: true)
        ])
        #expect(RunnerElementTree.compactText(root) == """
            application label="App" frame=0,0,402,874
              window frame=0,0,402,874
                button label="OK" frame=16,100,370,44
              other frame=0,0,0,0 truncated

            """)
    }
}

struct RunnerElementSelectorTests {
    private func node(
        _ type: String, identifier: String = "", label: String = "", value: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 40), enabled: Bool = true,
        children: [RunnerElementNode] = []
    ) -> RunnerElementNode {
        RunnerElementNode(
            type: type, identifier: identifier, label: label, value: value, placeholder: nil, frame: frame,
            enabled: enabled, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children
        )
    }

    private func selector(_ json: String) throws -> RunnerElementSelector {
        try RunnerElementSelector(json: JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
    }

    private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

    /// application > window > [input, input2, button "History", other > button "History"]
    private var tree: RunnerElementNode {
        node("application", label: "Host", frame: screen, children: [
            node("window", frame: screen, children: [
                node("textField", identifier: "relay.input", value: "hello", frame: CGRect(x: 16, y: 80, width: 370, height: 34)),
                node("textField", identifier: "relay.input2", frame: CGRect(x: 16, y: 130, width: 370, height: 34)),
                node("button", label: "History", frame: CGRect(x: 20, y: 200, width: 40, height: 40)),
                node("other", children: [
                    node("button", label: "History", frame: CGRect(x: 20, y: 300, width: 40, height: 40), enabled: false)
                ])
            ])
        ])
    }

    @Test func parsesSelectors() throws {
        #expect(try selector(#"{"identifier":"relay.input"}"#) == RunnerElementSelector(identifier: "relay.input"))
        #expect(try selector(#"{"label":"History","type":"button","index":1}"#)
            == RunnerElementSelector(label: "History", type: "button", index: 1))
        #expect(try selector(#"{"value":"hello","index":0}"#) == RunnerElementSelector(value: "hello", index: 0))
        #expect(try selector(#"{"type":"type83"}"#) == RunnerElementSelector(type: "type83"))
    }

    @Test func rejectsInvalidSelectors() throws {
        let cases: [(String, RunnerElementSelectorError)] = [
            (#"[]"#, .notAnObject),
            (#""relay.input""#, .notAnObject),
            (#"{}"#, .empty),
            (#"{"index":0}"#, .empty),
            (#"{"id":"relay.input"}"#, .unknownKey("id")),
            (#"{"identifier":""}"#, .notAString("identifier")),
            (#"{"label":1}"#, .notAString("label")),
            (#"{"type":"Button"}"#, .unknownType("Button")),
            (#"{"type":"type9"}"#, .unknownType("type9")),
            (#"{"type":"button","index":-1}"#, .invalidIndex),
            (#"{"type":"button","index":1.5}"#, .invalidIndex),
            (#"{"type":"button","index":true}"#, .invalidIndex),
            (#"{"type":"button","index":"1"}"#, .invalidIndex)
        ]
        for (json, expected) in cases {
            #expect(throws: expected, "\(json)") { try selector(json) }
        }
    }

    @Test func matchesExactlyWithAllConditions() {
        #expect(RunnerElementSelector(identifier: "relay.input").allMatches(in: tree).map(\.node.identifier) == ["relay.input"])
        // Exact: a prefix of the identifier or a different case doesn't match.
        #expect(RunnerElementSelector(identifier: "relay").allMatches(in: tree).isEmpty)
        #expect(RunnerElementSelector(label: "history").allMatches(in: tree).isEmpty)
        #expect(RunnerElementSelector(type: "textField", value: "hello").allMatches(in: tree).count == 1)
        #expect(RunnerElementSelector(identifier: "relay.input2", value: "hello").allMatches(in: tree).isEmpty)
        #expect(RunnerElementSelector(label: "Host", type: "application").allMatches(in: tree).count == 1)
    }

    @Test func numbersMatchesInDocumentOrder() {
        let matches = RunnerElementSelector(type: "button").allMatches(in: tree)
        #expect(matches.map(\.index) == [0, 1])
        #expect(matches.map(\.node.frame.origin.y) == [200, 300])
        #expect(matches.allSatisfy { $0.node.children.isEmpty })
        #expect(RunnerElementSelector(type: "button", index: 1).matches(in: tree).map(\.index) == [1])
        #expect(RunnerElementSelector(type: "button", index: 2).matches(in: tree).isEmpty)
        // `/find` with an index still reports every match in `count`.
        let picked = RunnerElementSelector(type: "button", index: 1)
        let all = picked.allMatches(in: tree)
        let object = RunnerElementLookup.findJSON(picked.picked(from: all), count: all.count, limit: 20, bundleID: "app")
        #expect(object["count"] as? Int == all.count)
        #expect((object["elements"] as? [[String: Any]])?.count == 1)
    }

    @Test func resolvesTheCenterOfTheFrame() throws {
        let target = try RunnerElementSelector(identifier: "relay.input2").resolve(in: tree, screen: screen).get()
        #expect(target.match.node.identifier == "relay.input2")
        #expect(target.point == CGPoint(x: 201, y: 147))
    }

    @Test func resolvesTheVisiblePartOfAFrameOnTheEdge() throws {
        let root = node("application", frame: screen, children: [
            node("cell", label: "Wi-Fi", frame: CGRect(x: 0, y: 854, width: 402, height: 44))
        ])
        let target = try RunnerElementSelector(label: "Wi-Fi").resolve(in: root, screen: screen).get()
        #expect(target.point == CGPoint(x: 201, y: 864))
    }

    /// Frames are in the displayed orientation, so a landscape screen is wider than tall.
    @Test func usesTheLandscapeScreen() throws {
        let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
        let root = node("application", frame: landscape, children: [
            node("textField", identifier: "relay.input2", frame: CGRect(x: 500, y: 100, width: 300, height: 34))
        ])
        let selector = RunnerElementSelector(identifier: "relay.input2")
        #expect(try selector.resolve(in: root, screen: landscape).get().point == CGPoint(x: 650, y: 117))
        #expect(failure(selector.resolve(in: root, screen: screen))?.reason == .offscreen)
    }

    private func failure(_ result: Result<RunnerElementTarget, RunnerElementLookupFailure>) -> RunnerElementLookupFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }

    @Test func reportsMissingAndAmbiguousSelectors() throws {
        let missing = try #require(failure(RunnerElementSelector(identifier: "relay.missing").resolve(in: tree, screen: screen)))
        #expect(missing.reason == .notFound)
        #expect(missing.count == 0)
        #expect(missing.isRetryable)

        let ambiguous = try #require(failure(RunnerElementSelector(type: "textField").resolve(in: tree, screen: screen)))
        #expect(ambiguous.reason == .ambiguous)
        #expect(ambiguous.count == 2)
        #expect(ambiguous.candidates.map(\.node.identifier) == ["relay.input", "relay.input2"])
        #expect(!ambiguous.isRetryable)
        #expect(ambiguous.message == "2 elements match the selector; add conditions or an index")

        let outOfRange = try #require(failure(RunnerElementSelector(type: "textField", index: 2).resolve(in: tree, screen: screen)))
        #expect(outOfRange.reason == .indexOutOfRange)
        #expect(outOfRange.count == 2)
        #expect(outOfRange.isRetryable)
    }

    @Test func listsAtMostFiveCandidates() throws {
        let root = node("application", frame: screen, children: (0..<8).map { _ in node("cell") })
        let ambiguous = try #require(failure(RunnerElementSelector(type: "cell").resolve(in: root, screen: screen)))
        #expect(ambiguous.count == 8)
        #expect((ambiguous.json["candidates"] as? [Any])?.count == 5)
    }

    @Test func rejectsElementsThatCanNotBeTouched() throws {
        let disabled = try #require(failure(RunnerElementSelector(type: "button", index: 1).resolve(in: tree, screen: screen)))
        #expect(disabled.reason == .disabled)
        #expect(disabled.count == 2)
        #expect(disabled.candidates.map(\.index) == [1])

        let root = node("application", frame: screen, children: [
            node("cell", label: "empty", frame: CGRect(x: 10, y: 10, width: 0, height: 44)),
            node("cell", label: "below", frame: CGRect(x: 0, y: 900, width: 402, height: 44)),
            node("cell", label: "touching", frame: CGRect(x: 0, y: 874, width: 402, height: 44))
        ])
        #expect(failure(RunnerElementSelector(label: "empty").resolve(in: root, screen: screen))?.reason == .emptyFrame)
        #expect(failure(RunnerElementSelector(label: "below").resolve(in: root, screen: screen))?.reason == .offscreen)
        #expect(failure(RunnerElementSelector(label: "touching").resolve(in: root, screen: screen))?.reason == .offscreen)
    }

    @Test func buildsFailureJSON() throws {
        let ambiguous = try #require(failure(RunnerElementSelector(label: "History").resolve(in: tree, screen: screen)))
        let data = try JSONSerialization.data(withJSONObject: ambiguous.json, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == """
            {"candidates":[{"enabled":true,"frame":{"height":40,"width":40,"x":20,"y":200},"identifier":"","index":0,\
            "label":"History","type":"button","value":null},{"enabled":false,"frame":{"height":40,"width":40,"x":20,"y":300},\
            "identifier":"","index":1,"label":"History","type":"button","value":null}],"code":"element_ambiguous","count":2,\
            "error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
            """)
    }

    @Test func buildsFindJSONWithALimit() throws {
        let matches = RunnerElementSelector(type: "textField").allMatches(in: tree)
        let object = RunnerElementLookup.findJSON(matches, count: matches.count, limit: 1, bundleID: "dev.devicerelay.local.RelayRunnerHost")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == """
            {"bundleId":"dev.devicerelay.local.RelayRunnerHost","count":2,"elements":[{"enabled":true,\
            "frame":{"height":34,"width":370,"x":16,"y":80},"identifier":"relay.input","index":0,"label":"",\
            "type":"textField","value":"hello"}],"ok":true,"truncated":true}
            """)
    }

    @Test func parsesTimeoutAndLimit() {
        #expect(RunnerElementLookup.timeout(nil) == 0)
        #expect(RunnerElementLookup.timeout(NSNumber(value: 2.5)) == 2.5)
        #expect(RunnerElementLookup.timeout(NSNumber(value: 10)) == 10)
        for invalid: Any in [NSNumber(value: 10.5), NSNumber(value: -1), NSNumber(value: true), "1"] {
            #expect(RunnerElementLookup.timeout(invalid) == nil, "\(invalid)")
        }
        #expect(RunnerElementLookup.findLimit(nil) == RunnerElementLookup.defaultFindLimit)
        #expect(RunnerElementLookup.findLimit(NSNumber(value: 100)) == 100)
        for invalid: Any in [NSNumber(value: 0), NSNumber(value: 101), NSNumber(value: 1.5), NSNumber(value: true), "5"] {
            #expect(RunnerElementLookup.findLimit(invalid) == nil, "\(invalid)")
        }
    }
}

struct RunnerRequestValuesTests {
    @Test func pointsOnTheScreenPassAndOthersAreRejected() throws {
        let portrait = CGSize(width: 402, height: 874)
        func outside(_ x: Double, _ y: Double, _ screen: CGSize = portrait) -> String? {
            RunnerRequestValues.pointOutsideScreen("x, y", x: x, y: y, screen: screen, orientation: "portrait")
        }
        // 0 <= x < width, 0 <= y < height; fractions inside the last point are fine.
        for (x, y) in [(0.0, 0.0), (401.0, 873.0), (401.9, 873.9), (200, 120)] {
            #expect(outside(x, y) == nil)
        }
        for (x, y) in [(402.0, 100.0), (100.0, 874.0), (500.0, 500.0), (-1.0, 10.0), (10.0, -0.5)] {
            #expect(outside(x, y) != nil)
        }
        // The landscape screen swaps the bounds: (800, 100) is inside it but not inside portrait.
        let landscape = CGSize(width: 874, height: 402)
        #expect(outside(800, 100, landscape) == nil)
        #expect(outside(100, 800, landscape) != nil)
        #expect(outside(800, 100) != nil)
        let message = try #require(RunnerRequestValues.pointOutsideScreen("to", x: 900, y: 100.5, screen: landscape, orientation: "landscapeLeft"))
        #expect(message == "to: (900, 100.5) is outside the screen, which is 874x402 points in landscapeLeft "
            + "(0 <= x < 874, 0 <= y < 402; relay health shows the screen)")
        // An unknown (empty) screen rejects nothing.
        #expect(outside(5000, 5000, .zero) == nil)
    }

    private func number(fromJSON text: String) throws -> Double? {
        let object = try JSONSerialization.jsonObject(with: Data("{\"v\":\(text)}".utf8)) as? [String: Any]
        return try RunnerRequestValues.number(#require(object?["v"]))
    }

    @Test func acceptsJSONNumbers() throws {
        #expect(try number(fromJSON: "1") == 1)
        #expect(try number(fromJSON: "0") == 0)
        #expect(try number(fromJSON: "12.5") == 12.5)
        #expect(try number(fromJSON: "-3") == -3)
    }

    /// `{"x": true, "y": 1}` used to be read as a tap at (1, 1).
    @Test func rejectsBooleansAndNonNumbers() throws {
        #expect(try number(fromJSON: "true") == nil)
        #expect(try number(fromJSON: "false") == nil)
        #expect(try number(fromJSON: "\"1\"") == nil)
        #expect(try number(fromJSON: "null") == nil)
        #expect(try number(fromJSON: "[1]") == nil)
    }

    @Test func jpegQualityDefaultsWhenAbsent() {
        #expect(RunnerRequestValues.jpegQuality(nil) == RunnerRequestValues.defaultJPEGQuality)
    }

    @Test func acceptsJPEGQualityInRange() {
        #expect(RunnerRequestValues.jpegQuality("0.05") == 0.05)
        #expect(RunnerRequestValues.jpegQuality("0.5") == 0.5)
        #expect(RunnerRequestValues.jpegQuality("1") == 1)
    }

    /// Unparsable values used to fall back to 0.7, and out-of-range ones were clamped.
    @Test func rejectsInvalidJPEGQuality() {
        for value in ["abc", "", " 0.5", "0", "0.04", "1.01", "2.0", "-0.5", "nan", "inf"] {
            #expect(RunnerRequestValues.jpegQuality(value) == nil, "\(value)")
        }
    }

    @Test func parsesScreenshotSizeQueries() {
        #expect(RunnerRequestValues.screenshotMaxSize("1024") == 1024)
        #expect(RunnerRequestValues.screenshotMaxSize("16") == 16)
        for value in ["15", "0", "-1", "1.5", "", "abc"] {
            #expect(RunnerRequestValues.screenshotMaxSize(value) == nil, "\(value)")
        }
        #expect(RunnerRequestValues.screenshotScale("1") == 1)
        #expect(RunnerRequestValues.screenshotScale("0.1") == 0.1)
        #expect(RunnerRequestValues.screenshotScale("10") == 10)
        for value in ["0", "0.09", "10.5", "-1", "", "nan", "inf"] {
            #expect(RunnerRequestValues.screenshotScale(value) == nil, "\(value)")
        }
    }

    /// iPhone 17 Pro: 1206x2622 pixels, 402x874 points at 3x.
    private let portrait = CGSize(width: 1206, height: 2622)

    @Test func shrinksScreenshotsToTheLongerEdge() {
        #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: 1024, scale: nil)
            == CGSize(width: 471, height: 1024))
        // Landscape keeps the same pixels per point.
        #expect(RunnerRequestValues.screenshotSize(pixels: CGSize(width: 2622, height: 1206), screenScale: 3, maxSize: 1024, scale: nil)
            == CGSize(width: 1024, height: 471))
    }

    @Test func shrinksScreenshotsToPixelsPerPoint() {
        #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: nil, scale: 1)
            == CGSize(width: 402, height: 874))
        #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: nil, scale: 1.5)
            == CGSize(width: 603, height: 1311))
        // Both: the smaller one wins.
        #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: 600, scale: 1)
            == CGSize(width: 276, height: 600))
        #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: 2000, scale: 1)
            == CGSize(width: 402, height: 874))
    }

    @Test func neverEnlargesScreenshots() {
        for (maxSize, scale) in [(nil, nil), (2622, nil), (5000, nil), (nil, 3.0), (nil, 4.0), (4000, 5.0)] as [(Int?, Double?)] {
            #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: maxSize, scale: scale) == portrait,
                    "\(String(describing: maxSize)) \(String(describing: scale))")
        }
    }

    @Test func describesScreenshotsInHeaders() {
        let headers = RunnerRequestValues.screenshotHeaders(image: CGSize(width: 471, height: 1024), screen: CGSize(width: 402, height: 874))
        #expect(headers == [
            "X-Relay-Image-Width": "471", "X-Relay-Image-Height": "1024",
            "X-Relay-Screen-Width": "402", "X-Relay-Screen-Height": "874", "X-Relay-Image-Scale": "1.172"
        ])
        let full = RunnerRequestValues.screenshotHeaders(image: CGSize(width: 2622, height: 1206), screen: CGSize(width: 874, height: 402))
        #expect(full["X-Relay-Image-Scale"] == "3")
    }
}

struct CommandGateTests {
    /// A clock the test moves by hand, in nanoseconds.
    private final class Clock: @unchecked Sendable {
        var now: UInt64 = 5_000_000_000
    }

    @Test func admitsOneCommandAtATime() {
        let gate = CommandGate()
        #expect(gate.tryEnter())
        #expect(!gate.tryEnter())
        gate.leave()
        #expect(gate.tryEnter())
    }

    @Test func reportsElapsedTimeOnlyWhileBusy() {
        let clock = Clock()
        let gate = CommandGate(now: { clock.now })
        #expect(gate.busyForMs() == nil)
        #expect(gate.tryEnter())
        clock.now += 1_234_999_999
        #expect(gate.busyForMs() == 1234)
        // A rejected request doesn't restart the clock.
        #expect(!gate.tryEnter())
        clock.now += 1_000_000
        #expect(gate.busyForMs() == 1235)
        gate.leave()
        #expect(gate.busyForMs() == nil)
    }

    @Test func pingBodyHasNullElapsedTimeWhenIdle() throws {
        let clock = Clock()
        let gate = CommandGate(now: { clock.now })
        let idle = try JSONSerialization.data(withJSONObject: gate.pingBody(), options: [.sortedKeys])
        #expect(String(decoding: idle, as: UTF8.self) == #"{"busy":false,"busyForMs":null,"ok":true}"#)

        #expect(gate.tryEnter())
        clock.now += 3_000_000_000
        let busy = try JSONSerialization.data(withJSONObject: gate.pingBody(), options: [.sortedKeys])
        #expect(String(decoding: busy, as: UTF8.self) == #"{"busy":true,"busyForMs":3000,"ok":true}"#)
    }
}

struct RunnerArgumentsTests {
    private func operation(_ arguments: [String]) throws -> RunnerOperation {
        guard case .runner(let options) = try Arguments.parse(arguments) else {
            Issue.record("not a runner command: \(arguments)")
            return .ping
        }
        return options.operation
    }

    @Test func parsesCommandsWithoutArguments() throws {
        #expect(try operation(["ping"]) == .ping)
        #expect(try operation(["health"]) == .health)
        #expect(try operation(["foreground"]) == .foreground)
        #expect(try operation(["shutdown"]) == .shutdown)
        #expect(throws: ArgumentError.self) { try Arguments.parse(["health", "extra"]) }
    }

    @Test func parsesRunnerPathAnywhere() throws {
        #expect(try Arguments.parse(["health", "--runner", "a.json"])
            == .runner(RunnerControlOptions(operation: .health, runnerPath: "a.json")))
        #expect(try Arguments.parse(["launch", "--runner", "a.json", "com.example"])
            == .runner(RunnerControlOptions(operation: .launch(bundleID: "com.example"), runnerPath: "a.json")))
    }

    @Test func parsesScreenshotFormats() throws {
        #expect(try operation(["screenshot"]) == .screenshot(RunnerScreenshot()))
        #expect(try operation(["screenshot", "-o", "shot.png"]) == .screenshot(RunnerScreenshot(output: "shot.png")))
        #expect(try operation(["screenshot", "--output", "shot.JPG"]) == .screenshot(RunnerScreenshot(format: "jpeg", output: "shot.JPG")))
        #expect(try operation(["screenshot", "--quality", "0.5"]) == .screenshot(RunnerScreenshot(format: "jpeg", quality: 0.5)))
        #expect(try operation(["screenshot", "--format", "jpeg", "-o", "-"]) == .screenshot(RunnerScreenshot(format: "jpeg", output: "-")))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["screenshot", "--format", "png", "--quality", "0.5"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["screenshot", "--quality", "2"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["screenshot", "--format", "gif"]) }
    }

    @Test func parsesScreenshotSize() throws {
        #expect(try operation(["screenshot", "--max-size", "1024"]) == .screenshot(RunnerScreenshot(maxSize: 1024)))
        #expect(try operation(["screenshot", "--scale", "1"]) == .screenshot(RunnerScreenshot(scale: 1)))
        #expect(try operation(["screenshot", "--max-size", "1024", "--scale", "1", "-o", "a.jpg"])
            == .screenshot(RunnerScreenshot(format: "jpeg", maxSize: 1024, scale: 1, output: "a.jpg")))
        for invalid in [["--max-size", "15"], ["--max-size", "1.5"], ["--max-size", "abc"], ["--scale", "0"],
                        ["--scale", "0.09"], ["--scale", "11"], ["--scale", "nan"], ["--max-size", "1024", "--max-size", "512"]] {
            #expect(throws: ArgumentError.self, "\(invalid)") { try Arguments.parse(["screenshot"] + invalid) }
        }
    }

    @Test func parsesSource() throws {
        #expect(try operation(["source"]) == .source(format: nil, maxDepth: nil, filter: nil, bundleID: nil))
        #expect(try operation(["source", "--format", "text", "--max-depth", "3", "--bundle-id", "com.apple.Preferences"])
            == .source(format: "text", maxDepth: 3, filter: nil, bundleID: "com.apple.Preferences"))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--max-depth", "-1"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--bundle-id", ""]) }
    }

    @Test func parsesSourceFilterAndCompactFormat() throws {
        #expect(try operation(["source", "--filter", "interactive"])
            == .source(format: nil, maxDepth: nil, filter: "interactive", bundleID: nil))
        #expect(try operation(["source", "--format", "compact", "--filter", "interactive"])
            == .source(format: "compact", maxDepth: nil, filter: "interactive", bundleID: nil))
        #expect(try operation(["source", "--format", "compact"]) == .source(format: "compact", maxDepth: nil, filter: nil, bundleID: nil))
        // debugDescription can't be filtered.
        #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--format", "text", "--filter", "interactive"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--filter", "buttons"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["source", "--format", "xml"]) }
    }

    @Test func parsesFindSelector() throws {
        #expect(try operation(["find", "--type", "textField"])
            == .find(RunnerElementSelector(type: "textField"), limit: nil, timeout: nil, bundleID: nil))
        #expect(try operation(["find", "--label", "General", "--type", "button", "--index", "1", "--limit", "5", "--timeout", "2.5", "--bundle-id", "b"])
            == .find(RunnerElementSelector(label: "General", type: "button", index: 1), limit: 5, timeout: 2.5, bundleID: "b"))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--index", "0"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--type", "notAType"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--limit", "101"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--timeout", "11"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--id", "b"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["find", "--id", "a", "--duration", "1"]) }
    }

    @Test func parsesTapByPointOrSelector() throws {
        #expect(try operation(["tap", "200", "120.5"]) == .tap(RunnerTouch(target: .point(RunnerPoint(x: 200, y: 120.5)))))
        #expect(try operation(["tap", "--id", "relay.input", "--mode", "xcui", "--timeout", "3"])
            == .tap(RunnerTouch(target: .element(RunnerElementSelector(identifier: "relay.input")), mode: "xcui", timeout: 3)))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "200"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "x", "y"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--id", "a"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--timeout", "1"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--mode", "fast"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["tap", "1", "2", "--duration", "1"]) }
    }

    @Test func parsesPressDuration() throws {
        #expect(try operation(["press", "1", "2", "--duration", "1.5"])
            == .press(RunnerTouch(target: .point(RunnerPoint(x: 1, y: 2)), duration: 1.5)))
        #expect(try operation(["press", "--label", "History", "--bundle-id", "b"])
            == .press(RunnerTouch(target: .element(RunnerElementSelector(label: "History")), bundleID: "b")))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["press", "1", "2", "--duration", "0"]) }
    }

    @Test func parsesSwipe() throws {
        #expect(try operation(["swipe", "200", "700", "200", "200", "--duration", "0.5", "--hold", "0", "--mode", "private"])
            == .swipe(from: RunnerPoint(x: 200, y: 700), to: RunnerPoint(x: 200, y: 200), duration: 0.5, hold: 0, mode: "private"))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["swipe", "1", "2", "3"]) }
    }

    @Test func parsesTypeTextAndKeys() throws {
        #expect(try operation(["type", "hello world"]) == .type(text: "hello world", keys: [], bundleID: nil))
        #expect(try operation(["type", "example.com", "--key", "return", "--key", "Enter", "--bundle-id", "b"])
            == .type(text: "example.com", keys: ["return", "Enter"], bundleID: "b"))
        #expect(try operation(["type", "--key", "delete"]) == .type(text: nil, keys: ["delete"], bundleID: nil))
        // `--` lets text start with a dash; a negative number needs nothing.
        #expect(try operation(["type", "--", "--verbose"]) == .type(text: "--verbose", keys: [], bundleID: nil))
        #expect(try operation(["type", "-5"]) == .type(text: "-5", keys: [], bundleID: nil))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["type"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["type", ""]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["type", "a", "b"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["type", "a", "--key", "tab"]) }
    }

    @Test func readsTypeTextFromStandardInput() throws {
        func parse(_ arguments: [String], input: String) throws -> Command {
            try Arguments.parse(arguments, standardInput: { Data(input.utf8) })
        }
        func type(_ text: String?, keys: [String] = []) -> Command {
            .runner(RunnerControlOptions(operation: .type(text: text, keys: keys, bundleID: nil), runnerPath: nil))
        }
        #expect(try parse(["type", "--stdin"], input: "secret") == type("secret"))
        // Only one trailing line break is dropped.
        #expect(try parse(["type", "--stdin"], input: "secret\n") == type("secret"))
        #expect(try parse(["type", "--stdin"], input: "secret\r\n") == type("secret"))
        #expect(try parse(["type", "--stdin"], input: "two\nlines\n\n") == type("two\nlines\n"))
        #expect(try parse(["type", "--stdin"], input: " -x ") == type(" -x "))
        #expect(try parse(["type", "--key", "return", "--stdin"], input: "secret\n") == type("secret", keys: ["return"]))
        #expect(try parse(["type", "--stdin", "--key", "return"], input: "") == type(nil, keys: ["return"]))
        #expect(throws: ArgumentError.self) { try parse(["type", "--stdin"], input: "\n") }
        #expect(throws: ArgumentError.self) { try parse(["type", "--stdin", "text"], input: "secret") }
        #expect(throws: SetupError.self) { try Arguments.parse(["type", "--stdin"], standardInput: { Data([0xff, 0xfe]) }) }
        // Standard input is read only for --stdin, and --stdin is only a flag of type.
        #expect(try Arguments.parse(["type", "hello"], standardInput: { Issue.record("read stdin"); return Data() }) == type("hello"))
        #expect(throws: ArgumentError.self) { try parse(["key", "return", "--stdin"], input: "") }
    }

    @Test func parsesNamedArguments() throws {
        #expect(try operation(["key", "space"]) == .key("space", bundleID: nil))
        #expect(try operation(["button", "home"]) == .button("home"))
        #expect(try operation(["orientation", "landscapeLeft"]) == .orientation("landscapeLeft"))
        // The alias is resolved before sending, so the runner sees only its own four names.
        #expect(try operation(["orientation", "landscape"]) == .orientation("landscapeLeft"))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["orientation", "portraitUpsideDownish"]) }
        #expect(try operation(["launch", "com.apple.Preferences"]) == .launch(bundleID: "com.apple.Preferences"))
        #expect(try operation(["terminate", "com.apple.Preferences"]) == .terminate(bundleID: "com.apple.Preferences"))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["key", "escape"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["button", "power"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["orientation", "upsideDown"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["launch"]) }
    }

    @Test func showsCommandHelp() throws {
        #expect(try Arguments.parse(["tap", "--help"]) == .commandHelp("tap"))
        #expect(try Arguments.parse(["screenshot", "-h"]) == .commandHelp("screenshot"))
        #expect(try Arguments.parse(["help", "find"]) == .commandHelp("find"))
        #expect(try Arguments.parse(["help", "start"]) == .help)
        #expect(Arguments.usage(for: "swipe").contains("relay swipe <x1> <y1> <x2> <y2>"))
        // Every runner command is in the overall usage.
        for name in Arguments.runnerUsages.keys {
            #expect(Arguments.usage.contains("relay \(name)"))
        }
        #expect(Set(Arguments.runnerCommandOrder) == Set(Arguments.runnerUsages.keys))
    }
}

struct RunnerOperationTests {
    private func body(_ request: RunnerHTTPRequest) throws -> String? {
        try request.body.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
    }

    @Test func buildsGetQueries() {
        #expect(RunnerOperation.health.request.path == "/health")
        #expect(RunnerOperation.screenshot(RunnerScreenshot()).request.path == "/screenshot")
        #expect(RunnerOperation.screenshot(RunnerScreenshot(format: "jpeg", quality: 0.5)).request.path == "/screenshot?format=jpeg&quality=0.5")
        let source = RunnerOperation.source(format: "text", maxDepth: 3, filter: nil, bundleID: "com.apple.Preferences").request
        #expect(source.method == "GET")
        #expect(source.path == "/source?format=text&maxDepth=3&bundleId=com.apple.Preferences")
        #expect(source.body == nil)
        #expect(RunnerOperation.source(format: "compact", maxDepth: nil, filter: "interactive", bundleID: nil).request.path
            == "/source?format=compact&filter=interactive")
        #expect(RunnerOperation.screenshot(RunnerScreenshot(format: "jpeg", maxSize: 1024, scale: 1)).request.path
            == "/screenshot?format=jpeg&maxSize=1024&scale=1.0")
    }

    @Test func buildsTouchBodies() throws {
        let point = RunnerOperation.tap(RunnerTouch(target: .point(RunnerPoint(x: 200, y: 120.5)), mode: "xcui")).request
        #expect(point.method == "POST")
        #expect(point.path == "/tap")
        #expect(try body(point) == #"{"mode":"xcui","x":200,"y":120.5}"#)

        let element = RunnerOperation.press(RunnerTouch(
            target: .element(RunnerElementSelector(label: "General", type: "button", index: 0)),
            duration: 1, timeout: 3, bundleID: "com.apple.Preferences"
        )).request
        #expect(element.path == "/press")
        #expect(try body(element)
            == #"{"bundleId":"com.apple.Preferences","duration":1,"element":{"index":0,"label":"General","type":"button"},"timeout":3}"#)
    }

    @Test func buildsOtherBodies() throws {
        #expect(try body(RunnerOperation.find(RunnerElementSelector(type: "cell"), limit: 5, timeout: nil, bundleID: nil).request)
            == #"{"element":{"type":"cell"},"limit":5}"#)
        #expect(try body(RunnerOperation.swipe(from: RunnerPoint(x: 1, y: 2), to: RunnerPoint(x: 3, y: 4), duration: nil, hold: nil, mode: nil).request)
            == #"{"from":{"x":1,"y":2},"to":{"x":3,"y":4}}"#)
        #expect(try body(RunnerOperation.type(text: "hi", keys: ["return"], bundleID: nil).request) == #"{"keys":["return"],"text":"hi"}"#)
        #expect(try body(RunnerOperation.type(text: nil, keys: ["delete"], bundleID: "b").request) == #"{"bundleId":"b","keys":["delete"]}"#)
        #expect(try body(RunnerOperation.key("space", bundleID: nil).request) == #"{"key":"space"}"#)
        #expect(try body(RunnerOperation.button("home").request) == #"{"name":"home"}"#)
        #expect(try body(RunnerOperation.orientation("portrait").request) == #"{"orientation":"portrait"}"#)
        #expect(try body(RunnerOperation.launch(bundleID: "b").request) == #"{"bundleId":"b"}"#)
        #expect(RunnerOperation.terminate(bundleID: "b").request.path == "/terminate")
        #expect(RunnerOperation.shutdown.request.method == "POST")
    }

    @Test func allowsForWaitsInTheTimeout() {
        #expect(RunnerOperation.health.waitTime == 0)
        #expect(RunnerOperation.find(RunnerElementSelector(type: "cell"), limit: nil, timeout: 5, bundleID: nil).waitTime == 5)
        #expect(RunnerOperation.press(RunnerTouch(target: .point(RunnerPoint(x: 0, y: 0)), duration: 4, timeout: 2)).waitTime == 6)
    }

    /// The runner waits up to XCTest's application state timeout, 120 s when it cannot set it back to 60 s.
    @Test func allowsForTheApplicationStateTimeout() {
        #expect(RunnerOperation.launch(bundleID: "b").waitTime == 120)
        #expect(RunnerOperation.terminate(bundleID: "b").waitTime == 120)
        #expect(RunnerControl.baseTimeout + RunnerOperation.launch(bundleID: "b").waitTime > 120)
    }

    /// 0.1 s per Unicode scalar of text and 1 s per key, several times what was measured.
    @Test func allowsForTypingByLength() {
        #expect(RunnerOperation.type(text: "", keys: [], bundleID: nil).waitTime == 0)
        #expect(RunnerOperation.type(text: nil, keys: ["return"], bundleID: nil).waitTime == 1)
        #expect(abs(RunnerOperation.type(text: "hello", keys: ["delete", "return"], bundleID: nil).waitTime - 2.5) < 1e-9)
        #expect(abs(RunnerOperation.type(text: String(repeating: "a", count: 2500), keys: [], bundleID: nil).waitTime - 250) < 1e-9)
        // Counted in scalars: "é" as e + U+0301 is one character but two scalars.
        #expect(abs(RunnerOperation.type(text: "e\u{301}日本", keys: [], bundleID: nil).waitTime - 0.4) < 1e-9)
        #expect(RunnerOperation.key("return", bundleID: nil).waitTime == 1)
    }
}

struct RunnerLocatorTests {
    /// A scratch tree: <root>/home, <root>/home/app/sub (the current directory), <root>/elsewhere.
    private struct Tree {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        var home: URL { root.appendingPathComponent("home") }
        var app: URL { home.appendingPathComponent("app") }
        var current: URL { app.appendingPathComponent("sub") }

        init() throws {
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        }

        @discardableResult
        func write(_ token: String, under directory: URL) throws -> URL {
            let url = RunnerInfo.defaultURL(rootURL: directory)
            try RunnerInfo(url: "http://127.0.0.1:8100/", token: token, udid: "SIM").write(to: url)
            return url
        }

        func locate(_ explicitPath: String? = nil, environment: [String: String] = [:]) throws -> URL {
            try RunnerLocator.locate(explicitPath: explicitPath, environment: environment, currentDirectory: current, home: home)
        }
    }

    @Test func prefersOptionThenEnvironmentThenParentsThenHome() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        #expect(throws: RunnerUnavailableError.self) { try tree.locate() }

        let home = try tree.write("home", under: tree.home)
        #expect(try tree.locate() == home)
        let app = try tree.write("app", under: tree.app)
        #expect(try tree.locate() == app)
        let current = try tree.write("current", under: tree.current)
        #expect(try tree.locate() == current)

        let other = try tree.write("other", under: tree.root.appendingPathComponent("elsewhere"))
        #expect(try tree.locate(environment: [RunnerLocator.environmentKey: other.path]) == other)
        // --runner wins over the environment, and relative paths start at the current directory.
        #expect(try tree.locate("../.relay/runner.json", environment: [RunnerLocator.environmentKey: other.path]) == app)
        // An empty variable is ignored.
        #expect(try tree.locate(environment: [RunnerLocator.environmentKey: ""]) == current)
    }

    @Test func givenPathMustExist() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try tree.write("home", under: tree.home)
        // No fallback to another runner when the requested one is gone.
        #expect(throws: RunnerUnavailableError.self) { try tree.locate("missing.json") }
        #expect(throws: RunnerUnavailableError.self) { try tree.locate(environment: [RunnerLocator.environmentKey: "/nonexistent/runner.json"]) }
    }

    @Test func searchPathEndsWithTheHomeCopyOnce() {
        let home = URL(fileURLWithPath: "/Users/me")
        let path = RunnerLocator.searchPath(currentDirectory: URL(fileURLWithPath: "/Users/me/src/app"), home: home).map(\.path)
        #expect(path == [
            "/Users/me/src/app/.relay/runner.json", "/Users/me/src/.relay/runner.json", "/Users/me/.relay/runner.json",
            "/Users/.relay/runner.json", "/.relay/runner.json"
        ])
        let outside = RunnerLocator.searchPath(currentDirectory: URL(fileURLWithPath: "/tmp/x"), home: home).map(\.path)
        #expect(outside.last == "/Users/me/.relay/runner.json")
    }

    @Test func removesTheSharedCopyOnlyWhileItIsOurs() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let url = try tree.write("newer", under: tree.home)
        RunnerInfo.remove(at: url, ifTokenIs: "older")
        #expect(FileManager.default.fileExists(atPath: url.path))
        RunnerInfo.remove(at: url, ifTokenIs: "newer")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct RunnerControlTests {
    @Test func tellsAConnectionTheOSRefusedFromNothingListening() {
        // What URLSession reported under a Seatbelt profile that denies localhost (macOS 27).
        let sandboxed = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 1])
        #expect(RunnerConnectionError.isRefusedByOS(sandboxed))
        // Nothing listening: NSURLErrorDomain -1004 over a CFNetwork error with ECONNREFUSED (61).
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            "_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 61,
            NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: -1004, userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 61])
        ])
        #expect(!RunnerConnectionError.isRefusedByOS(refused))
        #expect(!RunnerConnectionError.isRefusedByOS(URLError(.timedOut)))
        // EPERM wrapped in a URL error, in its CFStream fields or as the underlying error.
        #expect(RunnerConnectionError.isRefusedByOS(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                                            userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 1])))
        #expect(RunnerConnectionError.isRefusedByOS(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                                            userInfo: [NSUnderlyingErrorKey: sandboxed])))
        // Error code 1 of another CFStream domain (2 is kCFStreamErrorDomainNetDB) is not EPERM.
        #expect(!RunnerConnectionError.isRefusedByOS(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                                             userInfo: ["_kCFStreamErrorDomainKey": 2, "_kCFStreamErrorCodeKey": 1])))
    }

    @Test func mapsStatusesToExitCodes() {
        #expect(RunnerExitCode(status: 200) == .success)
        #expect(RunnerExitCode(status: 400) == .badRequest)
        #expect(RunnerExitCode(status: 401) == .unauthorized)
        #expect(RunnerExitCode(status: 404) == .badRequest)
        #expect(RunnerExitCode(status: 409) == .busy)
        #expect(RunnerExitCode(status: 422) == .actionFailed)
        #expect(RunnerExitCode(status: 501) == .runnerError)
        #expect(RunnerExitCode(status: 0) == .runnerError)
    }

    @Test func savesScreenshotsUnderTheTemporaryDirectoryByDefault() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-29T01:02:03Z"))
        let temporary = URL(fileURLWithPath: "/private/tmp/t")
        let current = URL(fileURLWithPath: "/work/app")
        let url = RunnerControl.screenshotURL(RunnerScreenshot(format: "jpeg"), now: now, currentDirectory: current, temporaryDirectory: temporary)
        #expect(url.deletingLastPathComponent().path == "/private/tmp/t/relay")
        #expect(url.lastPathComponent.hasPrefix("screenshot-"))
        #expect(url.pathExtension == "jpg")

        #expect(RunnerControl.screenshotURL(RunnerScreenshot(output: "shots/a.png"), currentDirectory: current, temporaryDirectory: temporary).path
            == "/work/app/shots/a.png")
        #expect(RunnerControl.screenshotURL(RunnerScreenshot(output: "/abs/b.png"), currentDirectory: current, temporaryDirectory: temporary).path
            == "/abs/b.png")
    }

    @Test func summarizesScreenshotHeaders() {
        let headers = RunnerRequestValues.screenshotHeaders(image: CGSize(width: 1024, height: 471), screen: CGSize(width: 874, height: 402))
        #expect(RunnerControl.screenshotSummary(headers)
            == "image 1024x471 px, screen 874x402 pt, 1.172 px/pt (tap in points: px / 1.172)")
        // URLSession may hand the names back in another case.
        let lowercased = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        #expect(RunnerControl.screenshotSummary(lowercased) == RunnerControl.screenshotSummary(headers))
        // A runner from before the headers.
        #expect(RunnerControl.screenshotSummary(["Content-Type": "image/png"]) == nil)
    }
}
