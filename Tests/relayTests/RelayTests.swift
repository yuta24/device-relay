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
    @Test func parsesReadyLine() {
        let line = "RELAY_RUNNER_READY port=8100 addresses=en0=192.168.1.5,utun3=fd00::1"
        #expect(RunnerLauncher.parseReadyLine(line) == ["192.168.1.5", "fd00::1"])
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

    @Test func treatsHealthyAndBusyRunnersAsAlive() {
        #expect(LivenessMonitor.isAlive(status: 200))
        #expect(LivenessMonitor.isAlive(status: 409))
        for status in [nil, 401, 404, 500] as [Int?] {
            #expect(!LivenessMonitor.isAlive(status: status))
        }
    }

    @Test func givesUpAfterConsecutiveFailuresOnly() {
        var monitor = LivenessMonitor()
        var results = [monitor.record(status: nil), monitor.record(status: nil)]
        // A busy answer resets the count.
        results.append(monitor.record(status: 409))
        #expect(results == [false, false, false])
        #expect(monitor.consecutiveFailures == 0)
        results = (0..<LivenessMonitor.failureLimit).map { _ in monitor.record(status: nil) }
        #expect(results == Array(repeating: false, count: LivenessMonitor.failureLimit - 1) + [true])
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
        #expect(throws: ArgumentError.self) { try Bench.token(BenchOptions(url: "http://127.0.0.1:8100"), infoURL: infoURL) }
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

        #expect(throws: ArgumentError.self) {
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

struct RunnerRequestValuesTests {
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
}
