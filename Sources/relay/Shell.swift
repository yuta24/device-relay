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
    /// Runs `xcrun <args>` to completion. stdout and stderr are merged and appended to `log` when given.
    @discardableResult
    static func xcrun(_ args: [String], log: FileHandle? = nil, echo: Bool = false) throws -> String {
        try run("/usr/bin/xcrun", args, log: log, echo: echo)
    }

    /// Runs `executable <args>` to completion, like `xcrun(_:log:echo:)`.
    @discardableResult
    static func run(_ executable: String, _ args: [String], log: FileHandle? = nil, echo: Bool = false) throws -> String {
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
        process.waitUntilExit()
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
