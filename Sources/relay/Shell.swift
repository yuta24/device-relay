import Foundation

/// How long relay waits for the host's tools, in seconds. Agents and scripts call relay, so a tool that stops
/// answering must end in an error and not in a relay that never returns. The limits are for a tool that is
/// stuck, not for one that is slow: a false timeout costs more than a late one.
///
/// Only the two things that may rightly run for long have none (`Shell.run` with `timeout: nil`): the
/// `xcodebuild build-for-testing` build, and the runner, which is not run through `Shell`.
enum CommandTimeout {
    /// Questions a local tool answers by itself or through a service it may have to start: `simctl list`, `xcrun
    /// --find`, `xcodebuild -version`, `security find-identity`, `xcode-select -p`, `git rev-parse`. These take
    /// well under a second; a cold CoreSimulatorService or a first `xcrun` after switching Xcode takes seconds.
    static let query: TimeInterval = 30
    /// `devicectl`, which takes 0.2 s to 3 s while its service starts (see `AppInstallCheck`), but has to reach
    /// every paired device to list them, some of them over Wi-Fi.
    static let devicectl: TimeInterval = 60
    /// `simctl boot` returns once the simulator is starting, which the first boot of a new runtime holds up for
    /// a minute or more.
    static let simctlBoot: TimeInterval = 300
    /// `simctl bootstatus` waits for the whole boot, including the data migration of a first boot, which takes
    /// minutes on a busy machine. The waiting `relay start --background` gives all of this 30 minutes.
    static let simctlBootStatus: TimeInterval = 600
    /// `simctl shutdown` takes seconds, more with a recording or a busy simulator to stop.
    static let simctlShutdown: TimeInterval = 120
}

struct ShellError: Error, CustomStringConvertible {
    var tool = "xcrun"
    let args: [String]
    let status: Int32
    let output: String
    /// The limit it was stopped at, when it was stopped for taking too long. `status` is then how it ended
    /// (15 for SIGTERM, 9 for SIGKILL), which says nothing about the command.
    var timedOutAfter: TimeInterval?

    var description: String {
        let tail = output.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")
        let summary = timeoutSummary.map { summary in timeoutHint.map { "\(summary); \($0)" } ?? summary }
            ?? "\(tool) \(args.joined(separator: " ")) failed (\(status))"
        return "\(summary)\(tail.isEmpty ? "" : "\n\(tail)")"
    }

    /// `timed out after 30 s`, or nil if it did not time out.
    var timeoutDetail: String? {
        timedOutAfter.map { "timed out after \(String(format: "%g", $0)) s" }
    }

    /// `xcrun simctl list devices --json timed out after 30 s`, or nil if it did not time out.
    var timeoutSummary: String? {
        timeoutDetail.map { "\(tool) \(args.joined(separator: " ")) \($0)" }
    }

    /// Where to look next, for the tools that depend on a service that can get stuck.
    private var timeoutHint: String? {
        switch args.first {
        case "devicectl": "check that xcrun devicectl list devices answers; if not, killall CoreDeviceService restarts the service"
        case "simctl": "check that xcrun simctl list devices answers"
        default: nil
        }
    }
}

enum Shell {
    /// How long a process gets to end after SIGTERM before it gets SIGKILL.
    private static let killDelay: TimeInterval = 1
    /// How long to wait for a process to end after SIGKILL. It takes no time, unless the process is stuck in
    /// the kernel, where no signal reaches it: relay then returns without it.
    private static let abandonDelay: TimeInterval = 2

    /// The processes `run` is waiting for, so `terminateRunning()` can stop a build when a detached
    /// `relay start` is told to stop (see `StartCancellation`).
    private static let running = Locked<[ObjectIdentifier: Process]>([:])

    /// Sends SIGTERM to every process `run` is waiting for; `run` then throws `ShellError`.
    static func terminateRunning() {
        let processes = Array(running.value.values)
        processes.filter(\.isRunning).forEach { $0.terminate() }
    }

    /// Runs `xcrun <args>` to completion. stdout and stderr are merged and appended to `log` when given.
    @discardableResult
    static func xcrun(_ args: [String], log: FileHandle? = nil, echo: Bool = false, timeout: TimeInterval?) throws -> String {
        try run("/usr/bin/xcrun", args, log: log, echo: echo, timeout: timeout)
    }

    /// Runs `executable <args>` to completion, like `xcrun(_:log:echo:timeout:)`. After `timeout` seconds the
    /// process gets SIGTERM (SIGKILL a second later if it is still there), and this throws a `ShellError` with
    /// `timedOutAfter`. `timeout` has no default, so that every caller decides (see `CommandTimeout`); nil waits
    /// for as long as the process runs.
    @discardableResult
    static func run(_ executable: String, _ args: [String], log: FileHandle? = nil, echo: Bool = false, timeout: TimeInterval?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Not waitUntilExit(), which has no limit: SIGKILL does not reach a process stuck in the kernel.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        running.withLock { $0[ObjectIdentifier(process)] = process }
        defer {
            running.withLock { $0[ObjectIdentifier(process)] = nil }
        }
        let reader = OutputReader(pipe.fileHandleForReading, log: log, echo: echo)
        let timedOut = waitForExit(of: process, exited: exited, timeout: timeout)
        let text = reader.finish()
        let tool = URL(fileURLWithPath: executable).lastPathComponent

        if timedOut {
            throw ShellError(tool: tool, args: args, status: process.isRunning ? SIGKILL : process.terminationStatus,
                             output: text, timedOutAfter: timeout)
        }
        guard process.terminationStatus == 0 else {
            throw ShellError(tool: tool, args: args, status: process.terminationStatus, output: text)
        }
        return text
    }

    /// Whether the time ran out. A process that then ends well still counts: its output may be cut short.
    private static func waitForExit(of process: Process, exited: DispatchSemaphore, timeout: TimeInterval?) -> Bool {
        guard let timeout else {
            exited.wait()
            return false
        }
        if exited.wait(timeout: .now() + timeout) == .success {
            return false
        }
        process.terminate()
        if exited.wait(timeout: .now() + killDelay) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + abandonDelay)
        }
        return true
    }
}

/// Collects what a process writes to its pipe, on a thread of its own.
///
/// The end of the file does not come when the process ends but when the last process holding the pipe's
/// write end does, and a daemon the command started inherits it. So `finish()` waits for it only for
/// `drainDelay`, and then takes what came. This thread stays until the daemon is gone, as a blocking read
/// cannot be stopped, and throws away what the daemon writes after that: closing the pipe under it would
/// stop it with SIGPIPE at its next write.
private final class OutputReader: Sendable {
    /// What a process wrote before it ended is in the pipe already, so it is read at once; this is for a
    /// machine too busy to run this thread. It is what a command that leaves a daemon behind costs.
    private static let drainDelay: TimeInterval = 1
    private static let bufferSize = 65536

    private struct State {
        var data = Data()
        var isFinished = false
    }

    private let state = Locked(State())
    private let reachedEnd = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle, log: FileHandle?, echo: Bool) {
        Thread.detachNewThread { [state, reachedEnd] in
            var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
            while true {
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                let data = Data(buffer[..<count])
                // Under the lock, so nothing is written after `finish()`, when the caller may have closed `log`.
                state.withLock { state in
                    guard !state.isFinished else { return }
                    state.data.append(data)
                    log?.write(data)
                    if echo {
                        FileHandle.standardError.write(data)
                    }
                }
            }
            reachedEnd.signal()
        }
    }

    /// The output so far, once the pipe has ended or `drainDelay` has passed. Call it after the process ended.
    func finish() -> String {
        _ = reachedEnd.wait(timeout: .now() + Self.drainDelay)
        return state.withLock { state in
            state.isFinished = true
            return String(decoding: state.data, as: UTF8.self)
        }
    }
}
