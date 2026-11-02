import Darwin
import Foundation

/// `relay doctor`'s checks for a sandbox around relay itself, such as the one a coding agent runs its shell
/// commands in. There is no general way to ask whether a process is sandboxed, so these try what relay needs
/// and read the errno: macOS Seatbelt answers a blocked `connect()` or file write with EPERM, where nothing
/// listening is ECONNREFUSED. Something else that filters connections with EPERM (a network filter
/// extension) looks the same, so the result says "seems". A Linux-style sandbox with its own loopback gives
/// ECONNREFUSED and is not noticed; relay runs on macOS only.
enum SandboxProbe {
    static let fix = "run relay outside the sandbox (in Claude Code: sandbox.excludedCommands); see the sandbox section of docs/setup.md"

    static func checks(home: URL) -> [Check] {
        var checks = [localhostCheck(connectError: localhostConnectError())]
        let stateURL = home.appendingPathComponent(".relay", isDirectory: true)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            checks.append(stateWriteCheck(writeError: writeError(in: stateURL), path: stateURL.path))
        }
        return checks
    }

    /// From the errno of a `connect()` to 127.0.0.1 (0 when it connected). Only EPERM is the OS refusing it.
    static func localhostCheck(connectError: Int32) -> Check {
        guard connectError == EPERM else {
            return .ok("localhost", "connections to 127.0.0.1 are allowed")
        }
        return .problem("localhost", "the OS refused a connection to 127.0.0.1 (Operation not permitted); relay seems to run inside a sandbox "
                        + "(an AI agent's, for example) that blocks localhost, so the runner commands cannot reach a simulator's runner",
                        fix: fix)
    }

    /// From the errno of creating a file in `~/.relay` (0 when it worked), where `relay start` keeps its lock,
    /// logs, and builds. EPERM (and EROFS) is a sandbox; other errors are reported as they are.
    static func stateWriteCheck(writeError: Int32, path: String) -> Check {
        switch writeError {
        case 0:
            return .ok("~/.relay", "writable")
        case EPERM, EROFS:
            return .problem("~/.relay", "cannot write \(path) (\(String(cString: strerror(writeError)))); relay seems to run inside a sandbox "
                            + "(an AI agent's, for example), where relay start cannot run", fix: fix)
        default:
            return .problem("~/.relay", "cannot write \(path) (\(String(cString: strerror(writeError))))",
                            fix: "check the permissions of \(path)")
        }
    }

    /// Connects to 127.0.0.1 on `port`, where usually nothing listens (ECONNREFUSED, at once on loopback).
    /// Returns the errno, or 0 when something answered.
    static func localhostConnectError(port: UInt16 = 9) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 ? 0 : errno
    }

    /// Creates and removes an empty file in `directory`; returns the errno, or 0.
    static func writeError(in directory: URL) -> Int32 {
        let url = directory.appendingPathComponent(".doctor-\(getpid())-\(UUID().uuidString)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return errno }
        close(fd)
        unlink(url.path)
        return 0
    }
}
