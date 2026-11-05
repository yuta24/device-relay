import Foundation
import Testing
@testable import relay

/// `Shell.run` with real processes. Each test ends in about a second or less, far below the 30 s its sleep
/// would take if `run` waited for it.
struct ShellTests {
    private static let bound: TimeInterval = 15

    /// Stops the process that outlives a script, whose pid the script printed on its first line.
    private func killDaemon(printedIn output: String) {
        if let pid = output.split(separator: "\n").first.flatMap({ Int32($0) }) {
            kill(pid, SIGKILL)
        }
    }

    private func temporaryLog() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-shell-\(UUID().uuidString).log")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        return (url, try FileHandle(forWritingTo: url))
    }

    // MARK: - As before

    @Test func returnsStdoutAndStderrMerged() throws {
        let output = try Shell.run("/bin/sh", ["-c", "echo out; echo err >&2"], timeout: 30)
        #expect(output.split(separator: "\n").sorted() == ["err", "out"])
    }

    @Test func aFailureHasItsStatusAndOutput() {
        do {
            try Shell.run("/bin/sh", ["-c", "echo boom; exit 3"], timeout: 30)
            Issue.record("should fail")
        } catch let error as ShellError {
            #expect(error.status == 3)
            #expect(error.output == "boom\n")
            #expect(error.timedOutAfter == nil)
            #expect(error.description == "sh -c echo boom; exit 3 failed (3)\nboom")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func aProgramThatCannotRunThrowsAtOnce() {
        #expect(throws: (any Error).self) { try Shell.run("/nonexistent/tool", [], timeout: nil) }
    }

    @Test func readsMoreThanThePipeHolds() throws {
        let output = try Shell.run("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=512 2>/dev/null"], timeout: 30)
        #expect(output.utf8.count == 512 * 1024)
    }

    @Test func writesTheOutputToTheLog() throws {
        let log = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        try Shell.run("/bin/echo", ["logged"], log: log.handle, timeout: 30)
        try log.handle.close()
        #expect(try String(contentsOf: log.url, encoding: .utf8) == "logged\n")
    }

    // MARK: - The time limit

    @Test func stopsAProcessAtItsTimeLimit() {
        let start = Date()
        do {
            try Shell.run("/bin/sleep", ["30"], timeout: 0.2)
            Issue.record("should time out")
        } catch let error as ShellError {
            #expect(error.timedOutAfter == 0.2)
            #expect(error.status == SIGTERM)
            #expect(error.description == "sleep 30 timed out after 0.2 s")
        } catch {
            Issue.record("\(error)")
        }
        #expect(Date().timeIntervalSince(start) < Self.bound)
    }

    @Test func killsAProcessThatIgnoresSIGTERM() {
        // A loop and not one long sleep, which would inherit the ignored signal and stay behind.
        let script = #"trap "" TERM; echo started; while :; do /bin/sleep 0.1; done"#
        let start = Date()
        do {
            try Shell.run("/bin/sh", ["-c", script], timeout: 0.2)
            Issue.record("should time out")
        } catch let error as ShellError {
            #expect(error.timedOutAfter == 0.2)
            #expect(error.status == SIGKILL)
            #expect(error.output.hasPrefix("started\n"))
            #expect(error.description.contains("timed out after 0.2 s"))
        } catch {
            Issue.record("\(error)")
        }
        #expect(Date().timeIntervalSince(start) < Self.bound)
    }

    /// It answered SIGTERM with status 0, but the output may be cut short: what it printed is no answer.
    @Test func aProcessThatEndsWellOnSIGTERMStillTimedOut() {
        let script = #"trap "exit 0" TERM; echo started; while :; do /bin/sleep 0.1; done"#
        #expect {
            try Shell.run("/bin/sh", ["-c", script], timeout: 0.2)
        } throws: { ($0 as? ShellError)?.timedOutAfter == 0.2 }
    }

    @Test func aTimeoutSaysWhereToLookForTheToolsWithAService() {
        let simctl = ShellError(args: ["simctl", "list", "devices", "--json"], status: 15, output: "", timedOutAfter: 30)
        #expect(simctl.timeoutSummary == "xcrun simctl list devices --json timed out after 30 s")
        #expect(simctl.description == "xcrun simctl list devices --json timed out after 30 s; check that xcrun simctl list devices answers")
        let devicectl = ShellError(args: ["devicectl", "list", "devices"], status: 15, output: "partial\n", timedOutAfter: 60)
        #expect(devicectl.description.hasPrefix("xcrun devicectl list devices timed out after 60 s; check that xcrun devicectl list devices answers"))
        #expect(devicectl.description.hasSuffix("\npartial"))
        let other = ShellError(tool: "security", args: ["find-identity"], status: 15, output: "", timedOutAfter: 30)
        #expect(other.description == "security find-identity timed out after 30 s")
    }

    // MARK: - A process that outlives the command and holds its pipe

    @Test func returnsWhenAProcessItLeftBehindHoldsThePipe() throws {
        let start = Date()
        let output = try Shell.run("/bin/sh", ["-c", "/bin/sleep 30 & echo $!; echo hi"], timeout: nil)
        killDaemon(printedIn: output)
        #expect(output.hasSuffix("\nhi\n"))
        #expect(Date().timeIntervalSince(start) < Self.bound)
    }

    @Test func aFailureIsReportedWhenAProcessItLeftBehindHoldsThePipe() {
        do {
            let output = try Shell.run("/bin/sh", ["-c", "/bin/sleep 30 & echo $!; echo hi; exit 7"], timeout: 30)
            killDaemon(printedIn: output)
            Issue.record("should fail")
        } catch let error as ShellError {
            killDaemon(printedIn: error.output)
            #expect(error.status == 7)
            #expect(error.timedOutAfter == nil)
            #expect(error.output.hasSuffix("\nhi\n"))
        } catch {
            Issue.record("\(error)")
        }
    }

    /// The caller closes the log when `run` returns, and writing to a closed `FileHandle` is fatal.
    @Test func nothingIsWrittenAfterItReturns() throws {
        let log = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        // The late line comes well after `run` gave up on the pipe (1 s after the shell ended, later on a busy
        // machine), and then it holds the pipe a little longer. The wait below lets it come.
        let output = try Shell.run("/bin/sh", ["-c", "(/bin/sleep 2; echo late; /bin/sleep 0.2) & echo hi"], log: log.handle, timeout: nil)
        try log.handle.close()
        Thread.sleep(forTimeInterval: 1.5)
        #expect(output == "hi\n")
        #expect(try String(contentsOf: log.url, encoding: .utf8) == "hi\n")
    }
}
