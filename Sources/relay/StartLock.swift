import Darwin
import Foundation

/// One `relay start` per port at a time. Two on the same port would launch runners that cannot both listen,
/// and the runner.json and `/ping` check of `relay start --background` does not see a start that is still
/// booting or building. The same kind of lock keeps one `relay start` per session (`acquire(session:)`) and
/// per device (`acquire(device:)`): two runners on one device stop each other's XCTest session.
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
    /// The same for the session's lock.
    static let inheritedSessionEnvironmentKey = "RELAY_SESSION_LOCK_FD"

    let fileDescriptor: Int32

    /// Who holds a lock, as far as its file says.
    struct Holder: Equatable {
        var pid: pid_t?
        var session: String?

        /// `session a, relay start pid 123`.
        var summary: String {
            let parts = [session.map { "session \($0)" }, pid.map { "relay start pid \($0)" }].compactMap { $0 }
            return parts.isEmpty ? "another relay start" : parts.joined(separator: ", ")
        }
    }

    static func url(port: Int, home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay/locks", isDirectory: true).appendingPathComponent("start-\(port).lock")
    }

    static func deviceURL(udid: String, home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay/locks", isDirectory: true).appendingPathComponent("device-\(udid.uppercased()).lock")
    }

    /// Takes the lock without waiting. Throws `SetupError` when another `relay start` holds it.
    static func acquire(port: Int, home: URL = UserHome.url) throws -> StartLock {
        let url = url(port: port, home: home)
        guard let lock = try take(url) else {
            throw SetupError(description: heldMessage(port: port, owner: holder(of: url)?.pid))
        }
        return lock
    }

    /// The lock of `port`, or nil when another `relay start` holds it (`PortPicker` then tries the next port).
    static func tryAcquire(port: Int, home: URL = UserHome.url) throws -> StartLock? {
        try take(url(port: port, home: home))
    }

    /// Takes the session's lock without waiting: two starts of one session would overwrite each other's runner.json.
    static func acquire(session: String, home: URL = UserHome.url) throws -> StartLock {
        let url = RelaySession.lockURL(name: session, home: home)
        guard let lock = try take(url) else {
            throw SetupError(description: sessionHeldMessage(session, owner: holder(of: url)?.pid))
        }
        return lock
    }

    /// Takes the device's lock without waiting. `session` goes into the file, for the message another
    /// `relay start` shows and for `devicesInUse`. Throws `DeviceInUseError` when another process holds it
    /// (the automatic choice in `StartSetup.prepare` selects again), `SetupError` when the lock file fails.
    static func acquire(device: Device, session: String?, home: URL = UserHome.url) throws -> StartLock {
        let url = deviceURL(udid: device.udid, home: home)
        guard let lock = try take(url, session: session) else {
            throw DeviceInUseError(device: device, holder: holder(of: url))
        }
        return lock
    }

    /// The devices among `devices` a `relay start` holds, by uppercase UDID, with who holds each. A device
    /// with no lock file was never used, so this opens only a few files.
    static func devicesInUse(_ devices: [Device], home: URL = UserHome.url) -> [String: String] {
        holdersInUse(devices, home: home).mapValues(\.summary)
    }

    /// `devicesInUse` with the holder itself, for what needs more than the summary (see `stopHint`).
    static func holdersInUse(_ devices: [Device], home: URL = UserHome.url) -> [String: Holder] {
        var inUse: [String: Holder] = [:]
        for device in devices {
            if let holder = holder(of: deviceURL(udid: device.udid, home: home)) {
                inUse[device.udid.uppercased()] = holder
            }
        }
        return inUse
    }

    /// Who holds the lock at `url`, or nil when nobody does (or there is no file).
    static func holder(of url: URL) -> Holder? {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) != 0 else { return nil }
        return readHolder(fd)
    }

    /// The lock `relay start --background` passed down to this process, if it is the lock for `port`.
    static func inherited(port: Int, home: URL = UserHome.url,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> StartLock? {
        inherited(url: url(port: port, home: home), key: inheritedEnvironmentKey, environment: environment)
    }

    /// The lock in `environment[key]`, if it is a descriptor that holds the lock at `url`.
    static func inherited(url: URL, key: String, environment: [String: String]) -> StartLock? {
        guard let value = environment[key], let fd = Int32(value), fd > 2 else { return nil }
        var held = stat()
        var file = stat()
        // flock succeeds again on the descriptor that already holds the lock, and fails on any other.
        guard fstat(fd, &held) == 0, stat(url.path, &file) == 0,
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

    static func sessionHeldMessage(_ session: String, owner: pid_t?) -> String {
        let process = owner.map { " (pid \($0))" } ?? ""
        return "another relay start\(process) is starting or running session \(session); use it once it is ready "
            + "(relay status --session \(session)), stop it (relay stop --session \(session)), or pick another session name"
    }

    /// How to stop the `relay start` that holds a lock: its session's `relay stop`, else any `relay stop` or Ctrl-C.
    static func stopHint(_ holder: Holder?) -> String {
        holder?.session.map { "relay stop --session \($0)" } ?? "relay stop, or Ctrl-C where it runs"
    }

    static func deviceHeldMessage(_ device: Device, holder: Holder?) -> String {
        return "\(device.name) (\(device.udid)) is in use by \(holder?.summary ?? "another relay start"): a device takes one runner at a time. "
            + "Use another device (--udid or --device; relay status --all lists what is in use), or stop that one (\(stopHint(holder)))"
    }

    func release() {
        close(fileDescriptor)
    }

    /// Opens and locks `url` without waiting; nil when another process holds it. A second try covers the
    /// moment `holder(of:)` in another process holds the lock to see whether it is free.
    private static func take(_ url: URL, session: String? = nil) throws -> StartLock? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw SetupError(description: "cannot create \(url.deletingLastPathComponent().path): \(error)")
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw SetupError(description: "cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
        var attempts = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            attempts += 1
            if error == EWOULDBLOCK, attempts < 3 {
                usleep(20_000)
                continue
            }
            close(fd)
            guard error == EWOULDBLOCK else {
                throw SetupError(description: "cannot lock \(url.path): \(String(cString: strerror(error)))")
            }
            return nil
        }
        let lock = StartLock(fileDescriptor: fd)
        lock.recordOwner(session: session)
        return lock
    }

    private func recordOwner(session: String? = nil) {
        let text = "\(getpid())\n" + (session.map { "\($0)\n" } ?? "")
        ftruncate(fileDescriptor, 0)
        _ = text.withCString { pwrite(fileDescriptor, $0, strlen($0), 0) }
    }

    /// The pid in the lock file, if that process still exists, and the session after it.
    private static func readHolder(_ fd: Int32) -> Holder {
        var buffer = [CChar](repeating: 0, count: 128)
        let count = pread(fd, &buffer, buffer.count - 1, 0)
        guard count > 0 else { return Holder() }
        let lines = String(cString: buffer).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var holder = Holder()
        if let pid = lines.first.flatMap({ pid_t($0) }), pid > 0, kill(pid, 0) == 0 || errno == EPERM {
            holder.pid = pid
        }
        if lines.count > 1, RelaySession.isValidName(lines[1]) {
            holder.session = lines[1]
        }
        return holder
    }
}

/// Another `relay start` holds the lock of `device`. Shows as `relay: <message>` and exits 1 like a `SetupError`.
struct DeviceInUseError: Error, CustomStringConvertible {
    let device: Device
    /// Who holds the lock, if the file says.
    let holder: StartLock.Holder?

    var description: String {
        StartLock.deviceHeldMessage(device, holder: holder)
    }
}

/// The locks a `relay start` holds before it picks a device: its session's, if it has one, and its port's.
struct StartLocks {
    var port: StartLock
    var session: StartLock?

    /// The locks and the variables that name them for the detached `relay start`.
    var inheritable: [(key: String, lock: StartLock)] {
        [(StartLock.inheritedEnvironmentKey, port)] + (session.map { [(StartLock.inheritedSessionEnvironmentKey, $0)] } ?? [])
    }

    /// The locks for `options`, inherited or new, held until the process exits. A session without `--port`
    /// gets a free port (`PortPicker`), which goes into `options`.
    static func acquire(for options: inout StartOptions, home: URL = UserHome.url) throws -> StartLocks {
        defer { unsetenv(StartLock.inheritedSessionEnvironmentKey) }
        var session: StartLock?
        if let name = options.session {
            session = StartLock.inherited(url: RelaySession.lockURL(name: name, home: home), key: StartLock.inheritedSessionEnvironmentKey,
                                          environment: ProcessInfo.processInfo.environment)
            if session == nil {
                session = try StartLock.acquire(session: name, home: home)
            }
        }
        if options.session != nil, !options.portGiven {
            let picked = try PortPicker.pick { try StartLock.tryAcquire(port: $0, home: home) }
            options.port = picked.port
            options.portGiven = true
            return StartLocks(port: picked.lock, session: session)
        }
        return StartLocks(port: try StartLock.acquireForStart(port: options.port, home: home), session: session)
    }
}

/// Keeps `xcodebuild build-for-testing` of one DerivedData to one process, and away from a `relay start`
/// launching a runner from those products, while starts that reuse a build run side by side.
///
/// Reading the products takes the lock shared (from deciding to reuse them until the runner answers, when
/// the build is no longer read); building takes it exclusive. Waiting polls, so Ctrl-C and `relay stop` still
/// work: a thread blocked in `flock` would not notice them. The kernel drops the lock when the process exits.
final class BuildLock {
    enum Mode {
        case shared
        case exclusive

        var flag: Int32 { self == .shared ? LOCK_SH : LOCK_EX }
    }

    static let pollInterval: TimeInterval = 0.2

    private let fileDescriptor: Int32
    private var isReleased = false

    /// `~/.relay/locks/build-<hash of the DerivedData path>.lock`.
    static func url(derivedData: URL, relayDirectory: URL) -> URL {
        let key = RunnerAuth.tokenHash(derivedData.standardizedFileURL.path).prefix(12)
        return relayDirectory.appendingPathComponent("locks", isDirectory: true).appendingPathComponent("build-\(key).lock")
    }

    init(derivedData: URL, relayDirectory: URL) throws {
        let url = Self.url(derivedData: derivedData, relayDirectory: relayDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw SetupError(description: "cannot create \(url.deletingLastPathComponent().path): \(error)")
        }
        fileDescriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fileDescriptor >= 0 else {
            throw SetupError(description: "cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Holds the lock in `mode`, waiting as long as it takes, and returns whether it had to wait.
    ///
    /// Going to exclusive gives up what this descriptor holds first, explicitly, so another process may get
    /// the lock before this one and the products may have changed by the time this returns. On Darwin a
    /// `LOCK_EX | LOCK_NB` that fails keeps the shared lock: two starts polling for it while both still hold
    /// it shared would each block the other for ever. Going from exclusive to shared has nothing to wait for,
    /// since nobody else can hold the lock, and lets no build in between.
    @discardableResult
    func wait(for mode: Mode, isCancelled: () -> Bool = { StartCancellation.isRequested }, info: (String) -> Void) throws -> Bool {
        if mode == .exclusive {
            flock(fileDescriptor, LOCK_UN)
        }
        var waited = false
        while flock(fileDescriptor, mode.flag | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                throw SetupError(description: "cannot lock the runner build: \(String(cString: strerror(errno)))")
            }
            if isCancelled() {
                throw SetupError(description: "stopped while waiting for another relay start's build")
            }
            if !waited {
                waited = true
                info("waiting for another relay start's build (or its launch from the same build)")
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return waited
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        close(fileDescriptor)
    }
}
