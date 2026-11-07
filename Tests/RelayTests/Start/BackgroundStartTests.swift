import Foundation
@testable import Relay
import Testing

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct BackgroundStartTests {
    @Test func readsProgressFromTheLog() {
        var progress = BackgroundStart.Progress()
        #expect(BackgroundStart.handle(line: "relay: building runner (log: /x/build.log)", progress: &progress) == "relay: building runner (log: /x/build.log)")
        #expect(!progress.launched)
        #expect(BackgroundStart.handle(line: "relay: launching runner on SIM (log: /x/runner.log)", progress: &progress) != nil)
        #expect(progress.launched)
        #expect(progress.udid == "SIM")
        // xcodebuild output and the Ctrl-C hint stay in the log.
        #expect(BackgroundStart.handle(line: "** TEST EXECUTE FAILED **", progress: &progress) == nil)
        #expect(BackgroundStart.handle(line: "relay: press Ctrl-C to stop the runner", progress: &progress) == nil)
        #expect(progress.readyURL == nil)
        #expect(BackgroundStart.handle(line: "ready: http://127.0.0.1:8100/", progress: &progress) == nil)
        #expect(progress.readyURL == "http://127.0.0.1:8100/")
    }

    @Test func namesTheDeviceOnlyFromItsOwnRunnerInfo() {
        let mine = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM-A", name: "iPhone A", pid: 100)
        #expect(BackgroundStart.device(runnerInfo: mine, pid: 100, udid: "SIM-A") == "iPhone A (SIM-A)")
        // A start on another port in the same second wrote runner.json after this one.
        let other = RunnerInfo(url: "http://127.0.0.1:8101/", token: "u", udid: "SIM-B", name: "iPhone B", pid: 200)
        #expect(BackgroundStart.device(runnerInfo: other, pid: 100, udid: "SIM-A") == "SIM-A")
        #expect(BackgroundStart.device(runnerInfo: nil, pid: 100, udid: "SIM-A") == "SIM-A")
        #expect(BackgroundStart.device(runnerInfo: nil, pid: 100, udid: nil) == nil)
    }

    @Test func startsOnlyWhenNothingAnswersAtTheRunnerURL() throws {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro")
        #expect(BackgroundStart.conflict(with: existing, port: 8100, ping: .unreachable("refused"), owner: nil) == nil)

        let alive = try #require(BackgroundStart.conflict(with: existing, port: 8100, ping: .alive(busy: false, busyForMs: nil), owner: 1234))
        #expect(alive.contains("already running at http://127.0.0.1:8100/ (iPhone 17 Pro, relay start pid 1234)"))
        #expect(alive.contains("relay stop"))
        #expect(alive.contains("--port"))

        // Another runner with another token on the same port.
        let unauthorized = try #require(BackgroundStart.conflict(with: existing, port: 8100, ping: .status(401), owner: nil))
        #expect(unauthorized.contains("401"))
        #expect(unauthorized.contains("another runner"))
        #expect(unauthorized.contains("relay stop"))
        #expect(unauthorized.contains("--port"))

        let other = try #require(BackgroundStart.conflict(with: existing, port: 8100, ping: .status(404), owner: nil))
        #expect(other.contains("HTTP 404"))
        #expect(other.contains("--port"))
    }

    @Test func startsOnAnotherPortWhateverAnswersAtTheRunnerURL() {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        for ping: RunnerPing in [.alive(busy: true, busyForMs: 10), .status(401), .status(404), .unreachable("refused")] {
            #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: ping, owner: 1234) == nil)
        }
    }

    @Test func doesNotPingARunnerOnAnotherPort() {
        let existing = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        var pinged = false
        func ping() -> RunnerPing {
            pinged = true
            return .alive(busy: false, busyForMs: nil)
        }
        #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: ping(), owner: nil) == nil)
        #expect(!pinged)
        #expect(BackgroundStart.conflict(with: existing, port: 8100, ping: ping(), owner: nil) != nil)
        #expect(pinged)
    }

    @Test func refusesWhenTheRunnerURLHasNoPort() {
        for url in ["http://127.0.0.1/", "not a url"] {
            let existing = RunnerInfo(url: url, token: "t", udid: "SIM")
            #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: .status(401), owner: nil) != nil)
            #expect(BackgroundStart.conflict(with: existing, port: 8101, ping: .unreachable("refused"), owner: nil) == nil)
        }
    }

    @Test func statusHelpListsTheExitStatuses() {
        #expect(flattened(Arguments.usage).contains("4 if it answers 401"))
        #expect(flattened(Arguments.usage(for: "status")).contains("4 the token was rejected (401)"))
    }

    @Test func describesWaitStatus() {
        #expect(BackgroundStart.describe(0) == "status 0")
        #expect(BackgroundStart.describe(1 << 8) == "status 1")
        #expect(BackgroundStart.describe(65 << 8) == "status 65")
        #expect(BackgroundStart.describe(9) == "signal 9")
    }
}

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

struct SessionConflictTests {
    private let existing = RunnerInfo(url: "http://127.0.0.1:8101/", token: "t", udid: "SIM", name: "iPhone 17")

    @Test func aRunnerThatStillAnswersIsAConflict() throws {
        let message = try #require(BackgroundStart.conflict(session: "a", with: existing, ping: .alive(busy: false, busyForMs: nil)))
        #expect(message.contains("relay stop --session a"))
        #expect(message.contains("iPhone 17"))
    }

    /// A port another session took since answers 401 to this token: that is not this session's runner.
    @Test func anythingElseIsNot() {
        for ping in [RunnerPing.status(401), .status(404), .unreachable("refused"), .refusedByOS("EPERM")] {
            #expect(BackgroundStart.conflict(session: "a", with: existing, ping: ping) == nil)
        }
    }
}
