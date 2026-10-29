import Darwin
import Foundation

/// One `relay start` per port at a time. Two on the same port would build into the same DerivedData and
/// launch runners that cannot both listen, and the runner.json and `/ping` check of `relay start
/// --background` does not see a start that is still booting or building.
///
/// The lock is `flock` on `~/.relay/locks/start-<port>.lock`, held by `relay start` (foreground or detached)
/// from before it picks the device until it exits, after its runner stopped: the port is taken for that
/// whole time. The kernel drops the lock when the process exits, however it exits, so a file left behind
/// never blocks the next start; the file only says which pid holds the lock. `relay start --background`
/// takes it before its check and passes the descriptor to the detached `relay start`, which keeps holding
/// the same lock after the waiting process exits.
struct StartLock {
    /// The descriptor number the detached `relay start` inherits the lock as.
    static let inheritedEnvironmentKey = "RELAY_START_LOCK_FD"

    let fileDescriptor: Int32

    static func url(port: Int, home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay/locks", isDirectory: true).appendingPathComponent("start-\(port).lock")
    }

    /// Takes the lock without waiting. Throws `SetupError` when another `relay start` holds it.
    static func acquire(port: Int, home: URL = UserHome.url) throws -> StartLock {
        let url = url(port: port, home: home)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw SetupError(description: "cannot create \(url.deletingLastPathComponent().path): \(error)")
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw SetupError(description: "cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            let owner = Self.owner(fd)
            close(fd)
            guard error == EWOULDBLOCK else {
                throw SetupError(description: "cannot lock \(url.path): \(String(cString: strerror(error)))")
            }
            throw SetupError(description: heldMessage(port: port, owner: owner))
        }
        let lock = StartLock(fileDescriptor: fd)
        lock.recordOwner()
        return lock
    }

    /// The lock `relay start --background` passed down to this process, if it is the lock for `port`.
    static func inherited(port: Int, home: URL = UserHome.url,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> StartLock? {
        guard let value = environment[inheritedEnvironmentKey], let fd = Int32(value), fd > 2 else { return nil }
        var held = stat()
        var file = stat()
        // flock succeeds again on the descriptor that already holds the lock, and fails on any other.
        guard fstat(fd, &held) == 0, stat(url(port: port, home: home).path, &file) == 0,
              held.st_dev == file.st_dev, held.st_ino == file.st_ino, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return nil
        }
        // Keep it from xcodebuild and the other processes this one starts.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let lock = StartLock(fileDescriptor: fd)
        lock.recordOwner()
        return lock
    }

    /// The lock for this `relay start`: the inherited one, else a new one. Held until the process exits.
    static func acquireForStart(port: Int, home: URL = UserHome.url) throws -> StartLock {
        defer { unsetenv(inheritedEnvironmentKey) }
        if let lock = inherited(port: port, home: home) {
            return lock
        }
        return try acquire(port: port, home: home)
    }

    static func heldMessage(port: Int, owner: pid_t?) -> String {
        let process = owner.map { " (pid \($0))" } ?? ""
        return "another relay start\(process) is starting or running a runner on port \(port), the port relay start would use; "
            + "use it once it is ready (relay status), stop it (relay stop, or Ctrl-C where it runs), or start another on another port with --port"
    }

    func release() {
        close(fileDescriptor)
    }

    private func recordOwner() {
        let text = "\(getpid())\n"
        ftruncate(fileDescriptor, 0)
        _ = text.withCString { pwrite(fileDescriptor, $0, strlen($0), 0) }
    }

    /// The pid written in the lock file, if that process still exists.
    private static func owner(_ fd: Int32) -> pid_t? {
        var buffer = [CChar](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count - 1, 0)
        guard count > 0, let pid = pid_t(String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 || errno == EPERM else {
            return nil
        }
        return pid
    }
}
