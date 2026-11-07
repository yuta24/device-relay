import Foundation
@testable import Relay
import Testing

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
        #expect(try Bench.resolveTarget(options, environment: [:], home: missing).token == "from-option")
    }

    @Test func tokenFallsBackToRunnerInfo() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let infoURL = RunnerLocator.userURL(home: home)
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "from-file", udid: "SIM").write(to: infoURL)

        let options = BenchOptions(url: "http://127.0.0.1:8100")
        #expect(try Bench.resolveTarget(options, environment: [:], home: home).token == "from-file")
        RunnerInfo.remove(at: infoURL)
        #expect(throws: RunnerUnavailableError.self) { try Bench.resolveTarget(options, environment: [:], home: home) }
    }
}
