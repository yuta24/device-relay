import Foundation

struct ShellError: Error, CustomStringConvertible {
    var tool = "xcrun"
    let args: [String]
    let status: Int32
    let output: String

    var description: String {
        let tail = output.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")
        return "\(tool) \(args.joined(separator: " ")) failed (\(status))\(tail.isEmpty ? "" : "\n\(tail)")"
    }
}

enum Shell {
    /// The processes `run` is waiting for, so `terminateRunning()` can stop a build when a detached
    /// `relay start` is told to stop (see `StartCancellation`).
    private static var running: [ObjectIdentifier: Process] = [:]
    private static let runningLock = NSLock()

    /// Sends SIGTERM to every process `run` is waiting for; `run` then throws `ShellError`.
    static func terminateRunning() {
        runningLock.lock()
        let processes = Array(running.values)
        runningLock.unlock()
        processes.filter(\.isRunning).forEach { $0.terminate() }
    }

    /// Runs `xcrun <args>` to completion. stdout and stderr are merged and appended to `log` when given.
    @discardableResult
    static func xcrun(_ args: [String], log: FileHandle? = nil, echo: Bool = false, timeout: TimeInterval? = nil) throws -> String {
        try run("/usr/bin/xcrun", args, log: log, echo: echo, timeout: timeout)
    }

    /// Runs `executable <args>` to completion, like `xcrun(_:log:echo:)`. After `timeout` seconds the process
    /// gets SIGTERM (SIGKILL a second later if it is still there), and this throws `ShellError` as for any
    /// other nonzero status.
    @discardableResult
    static func run(_ executable: String, _ args: [String], log: FileHandle? = nil, echo: Bool = false, timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var output = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            output.append(data)
            lock.unlock()
            log?.write(data)
            if echo {
                FileHandle.standardError.write(data)
            }
        }

        try process.run()
        runningLock.lock()
        running[ObjectIdentifier(process)] = process
        runningLock.unlock()
        defer {
            runningLock.lock()
            running[ObjectIdentifier(process)] = nil
            runningLock.unlock()
        }
        let stop = DispatchWorkItem {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        }
        process.waitUntilExit()
        stop.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        output.append(remaining)
        let text = String(decoding: output, as: UTF8.self)
        lock.unlock()
        log?.write(remaining)

        guard process.terminationStatus == 0 else {
            throw ShellError(tool: URL(fileURLWithPath: executable).lastPathComponent, args: args, status: process.terminationStatus, output: text)
        }
        return text
    }
}
