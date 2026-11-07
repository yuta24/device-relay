import Foundation
@testable import Relay
import Testing

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct RelayProcessTests {
    private let started = Date(timeIntervalSince1970: 1_800_000_000.75)

    private func snapshot(executable: String = "/usr/local/bin/relay", arguments: [String] = ["relay", "start", "--udid", "SIM"],
                          startedAt: Date? = nil) -> RelayProcess.Snapshot {
        RelayProcess.Snapshot(startedAt: startedAt ?? started, executable: executable, arguments: arguments)
    }

    @Test func matchesTheRelayStartThatWroteRunnerInfo() {
        // runner.json keeps whole seconds.
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RelayProcess.isRelayStart(snapshot(), startedAt: recorded, executableName: "relay"))
    }

    @Test func rejectsAReusedPid() {
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        // Another process that started later with the same pid.
        #expect(!RelayProcess.isRelayStart(snapshot(startedAt: started.addingTimeInterval(5)), startedAt: recorded, executableName: "relay"))
        // Same start time, but not relay start.
        #expect(!RelayProcess.isRelayStart(snapshot(executable: "/bin/sleep", arguments: ["sleep", "120"]), startedAt: recorded, executableName: "relay"))
        #expect(!RelayProcess.isRelayStart(snapshot(arguments: ["relay", "screenshot"]), startedAt: recorded, executableName: "relay"))
        #expect(!RelayProcess.isRelayStart(snapshot(arguments: ["relay"]), startedAt: recorded, executableName: "relay"))
    }

    @Test func parsesProcArgs() {
        var buffer = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/usr/local/bin/relay".utf8) + [0, 0, 0, 0]
        for argument in ["relay", "start", "--device", "iPhone 17 Pro"] + ["HOME=/Users/test"] {
            buffer += Array(argument.utf8) + [0]
        }
        #expect(RelayProcess.parseProcessArguments(buffer) == ["relay", "start", "--device"])
        #expect(RelayProcess.parseProcessArguments([1, 0]) == nil)
        // argc larger than what follows.
        var short = withUnsafeBytes(of: Int32(5)) { Array($0) }
        short += Array("/bin/x".utf8) + [0] + Array("x".utf8) + [0]
        #expect(RelayProcess.parseProcessArguments(short) == nil)
    }

    @Test func readsThisProcess() throws {
        let snapshot = try #require(RelayProcess.snapshot(pid: getpid()))
        #expect(abs(snapshot.startedAt.timeIntervalSinceNow) < 24 * 3600)
        #expect(!snapshot.executable.isEmpty)
        #expect(snapshot.arguments.first != nil)
        #expect(RelayProcess.exists(getpid()))
        #expect(RelayProcess.snapshot(pid: -1) == nil)
        // This test process is not relay start, whatever its start time.
        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", pid: getpid(), startedAt: RelayProcess.currentStartTime())
        #expect(RelayProcess.runningRelayStart(info) == nil)
    }

    @Test func findsChildProcesses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(RelayProcess.descendants(of: getpid()).contains(process.processIdentifier))
        #expect(RelayProcess.descendants(of: process.processIdentifier).isEmpty)
    }
}
