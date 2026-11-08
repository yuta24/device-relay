import Darwin
import Foundation

/// Reads other processes on this Mac: whether the pid in runner.json is still the `relay start` that wrote
/// it, and which processes a detached `relay start` started.
///
/// A pid alone is not enough to send SIGTERM to: once `relay start` exits, the system may give its pid to
/// an unrelated process. runner.json also records the start time, and the process must still be a relay
/// executable running `start`.
enum RelayProcess {
  /// A process as `ps` would show it.
  struct Snapshot: Equatable {
    var startedAt: Date
    /// The path of the executable (`proc_pidpath`).
    var executable: String
    /// argv, from `KERN_PROCARGS2`.
    var arguments: [String]
  }

  /// The process with `pid`, or nil when there is none (or it belongs to another user).
  static func snapshot(pid: Int32) -> Snapshot? {
    guard pid > 0, let startedAt = startTime(pid: pid) else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &path, UInt32(path.count))
    let executable = length > 0 ? String(nullTerminated: path) : ""
    return Snapshot(startedAt: startedAt, executable: executable, arguments: arguments(pid: pid) ?? [])
  }

  /// Whether `snapshot` is the `relay start` that recorded `pid` and `startedAt` in runner.json.
  /// The start time must match to the second (runner.json keeps whole seconds), the executable must be
  /// named like this one (`relay`), and its first argument must be `start`.
  static func isRelayStart(_ snapshot: Snapshot, startedAt: Date, executableName: String = currentExecutableName) -> Bool {
    abs(snapshot.startedAt.timeIntervalSince1970.rounded(.down) - startedAt.timeIntervalSince1970.rounded(.down)) < 1
      && URL(fileURLWithPath: snapshot.executable).lastPathComponent == executableName
      && snapshot.arguments.dropFirst().first == "start"
  }

  /// The `relay start` recorded in runner.json, if it is still running.
  static func runningRelayStart(_ info: RunnerInfo) -> Int32? {
    guard let pid = info.pid, let startedAt = info.startedAt, let snapshot = snapshot(pid: pid),
          isRelayStart(snapshot, startedAt: startedAt) else {
      return nil
    }
    return pid
  }

  /// When the process started, from `kinfo_proc.kp_proc.p_starttime`.
  static func startTime(pid: Int32) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
  }

  /// argv of `pid`. `KERN_PROCARGS2` is argc, the executable path, padding, then argv and the environment.
  static func arguments(pid: Int32) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcessArguments(Array(buffer.prefix(size)))
  }

  static func parseProcessArguments(_ buffer: [UInt8]) -> [String]? {
    guard buffer.count > MemoryLayout<Int32>.size else { return nil }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    // Skip the executable path and the NUL padding after it.
    while index < buffer.count, buffer[index] != 0 { index += 1 }
    while index < buffer.count, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while arguments.count < Int(argc), index < buffer.count {
      let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
      arguments.append(String(decoding: buffer[index ..< end], as: UTF8.self))
      index = end + 1
    }
    return arguments.count == Int(argc) ? arguments : nil
  }

  /// The children of `pid` and theirs, deepest first, so killing them in order never orphans one.
  static func descendants(of pid: Int32) -> [Int32] {
    var result: [Int32] = []
    for child in children(of: pid) {
      result += descendants(of: child)
      result.append(child)
    }
    return result
  }

  private static func children(of pid: Int32) -> [Int32] {
    let count = proc_listchildpids(pid, nil, 0)
    guard count > 0 else { return [] }
    // Room for children started between the two calls.
    var pids = [Int32](repeating: 0, count: Int(count) + 16)
    let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<Int32>.stride))
    guard filled > 0 else { return [] }
    return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
  }

  /// Whether a process with `pid` exists (it may belong to another user).
  static func exists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  /// The path of this executable, which `relay start --background` runs again.
  static var currentExecutable: String {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    if proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 {
      return String(nullTerminated: path)
    }
    return Bundle.main.executablePath ?? CommandLine.arguments[0]
  }

  static var currentExecutableName: String {
    URL(fileURLWithPath: currentExecutable).lastPathComponent
  }

  /// This process's start time in whole seconds, as runner.json records it.
  static func currentStartTime() -> Date {
    let start = startTime(pid: getpid()) ?? Date()
    return Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
  }
}

extension String {
  /// The text before the first NUL of a buffer a C function filled; invalid UTF-8 is repaired.
  init(nullTerminated buffer: [CChar]) {
    self.init(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }
}
