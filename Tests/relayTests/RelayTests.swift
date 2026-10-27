import Foundation
@testable import relay
import Testing

struct ArgumentsTests {
    @Test func parsesStartOptions() throws {
        let command = try Arguments.parse(["start", "--udid", "ABC", "--port", "9000", "--team-id", "TEAM", "--rebuild"])
        var expected = StartOptions(udid: "ABC", port: 9000, teamID: "TEAM")
        expected.rebuild = true
        #expect(command == .start(expected))
    }

    @Test func startRequiresUDID() {
        #expect(throws: ArgumentError.self) { try Arguments.parse(["start"]) }
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

    @Test func noArgumentsShowsHelp() throws {
        #expect(try Arguments.parse([]) == .help)
    }
}

struct RunnerLauncherTests {
    @Test func parsesReadyLine() {
        let line = "RELAY_RUNNER_READY port=8100 addresses=en0=192.168.1.5,utun3=fd00::1"
        #expect(RunnerLauncher.parseReadyLine(line) == ["192.168.1.5", "fd00::1"])
    }

    @Test func ignoresOtherLines() {
        #expect(RunnerLauncher.parseReadyLine("Test Case started") == nil)
    }

    @Test func simulatorUsesLoopback() {
        let hosts = RunnerLauncher.candidateHosts(isSimulator: true, udid: "SIM", tunnelAddress: "fd00::1", markerAddresses: ["10.0.0.2"])
        #expect(hosts == ["127.0.0.1"])
    }

    @Test func devicePrefersTunnelAndDropsLinkLocal() {
        let hosts = RunnerLauncher.candidateHosts(
            isSimulator: false,
            udid: "DEV",
            tunnelAddress: "fd00::1",
            markerAddresses: ["fd00::1", "192.168.1.5", "169.254.3.4"]
        )
        #expect(hosts == ["fd00::1", "DEV.coredevice.local", "192.168.1.5"])
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

struct BenchTests {
    @Test func percentilePicksNearestRank() {
        let sorted: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(Bench.percentile(sorted, 0.5) == 6)
        #expect(Bench.percentile(sorted, 0.9) == 9)
        #expect(Bench.percentile([], 0.5) == 0)
    }
}
