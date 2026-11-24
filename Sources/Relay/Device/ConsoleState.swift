import CryptoKit
import Darwin
import Foundation

struct ConsoleLaunch: Equatable {
  var path: String
  var restart: Bool
}

enum ConsoleCommand: Equatable {
  case status(String?)
  case stop(String)

  static func parse(_ words: [String]) throws -> Self {
    if words == ["status"] { return .status(nil) }
    guard words.count == 2, let id = ConsoleState.validID(words[1]) else {
      throw ArgumentError(description: "expected console status [<captureID>] or console stop <captureID> (UUID)")
    }
    switch words[0] {
    case "status": return .status(id)
    case "stop": return .stop(id)
    default: throw ArgumentError(description: "unknown console command: \(words[0])")
    }
  }
}

struct ConsoleProblem: Error {
  var code: RelayErrorCode
  var message: String

  var capture: ConsoleState?

  init(_ code: RelayErrorCode, _ message: String, capture: ConsoleState? = nil) {
    self.capture = capture
    self.code = code
    self.message = message
  }

  static func from(_ error: Error) -> Self {
    error as? Self ?? Self(.consoleUnavailable, String(describing: error))
  }
}

/// Only the owner writes the journal after handoff. The guard can finish it once the kernel
/// reparents it after an abrupt worker exit. The stop request is separate from the journal.
struct ConsoleState: Codable {
  var captureID: String
  var udid: String
  var bundleID: String
  var session: String?
  var path: String
  var runnerPID: Int32
  var runnerStart: Date
  var pid: Int32?
  var startedAt: Date?
  var appPID: Int32?
  var appStart: Date?
  var diagnostic: String?
  var state = "starting"
  var reason: String?
  var finishedAt: Date?
  var childExit: Int32?
  var childSignal: Int32?
  var limitReached = false
  var saveError: String?
  var bytesWritten: Int?

  static func validID(_ text: String) -> String? {
    guard text.utf8.count == 36, let id = UUID(uuidString: text)?.uuidString,
          text.uppercased() == id else { return nil }
    return id
  }

  static var directory: URL { UserHome.url.appendingPathComponent(".relay/consoles", isDirectory: true) }

  static func file(_ id: String, in directory: URL = directory) -> URL {
    directory.appendingPathComponent(id + ".json")
  }

  func lockURL(in directory: URL = directory) -> URL {
    let digest = SHA256.hash(data: Data("\(udid.uppercased())/\(bundleID.lowercased())".utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name + ".lock")
  }

  var stopURL: URL { Self.directory.appendingPathComponent(captureID + ".stop") }
  var workerArguments: [String] { ["__console-worker", captureID, session ?? "", udid, bundleID] }

  func owns(_ snapshot: RelayProcess.Snapshot?, executableName: String = RelayProcess.currentExecutableName) -> Bool {
    guard let snapshot, let startedAt, startedAt == snapshot.startedAt,
          URL(fileURLWithPath: snapshot.executable).lastPathComponent == executableName else { return false }
    return Array(snapshot.arguments.dropFirst().prefix(workerArguments.count)) == workerArguments
  }

  static func read(_ id: String, in directory: URL = directory) throws -> Self {
    try read(id, from: file(id, in: directory))
  }

  static func read(_ id: String, from url: URL) throws -> Self {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { throw ConsoleProblem(.consoleNotFound, "unknown console capture \(id)") }
      throw ConsoleProblem(.consoleOwnershipUnverified, "cannot open console state for \(id)")
    }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 65536,
          let data = try? FileHandle(fileDescriptor: fd).read(upToCount: 65537),
          let record = try? JSONDecoder().decode(Self.self, from: data), record.captureID == id,
          (record.state == "ended") == (record.finishedAt != nil), (record.state == "ended") == (record.reason != nil),
          record.state != "recording" || ((record.pid ?? 0) > 0 && record.startedAt != nil && (record.appPID ?? 0) > 0),
          ["starting", "recording", "ended"].contains(record.state) else {
      throw ConsoleProblem(.consoleOwnershipUnverified, "invalid console state for \(id)")
    }
    return record
  }

  func save(in directory: URL = directory) throws {
    try write(to: Self.file(captureID, in: directory))
  }

  func write(to destination: URL) throws {
    let data = try JSONEncoder().encode(self)
    let temp = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    let fd = try ConsoleSink.create(temp.path)
    defer { unlink(temp.path) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
      guard rename(temp.path, destination.path) == 0 else { throw POSIXError(.EIO) }
    } catch { throw ConsoleProblem(.consoleSaveFailed, "cannot save console state: \(error)") }
  }

  static func ids(in directory: URL = directory) throws -> [String] {
    do {
      return try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap { name in
        guard name.hasSuffix(".json") else { return nil }
        return validID(String(name.dropLast(5)))
      }.sorted()
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
  }

  static func prune(in directory: URL = directory, now: Date = Date()) {
    let retention: TimeInterval = 7 * 86400
    for id in (try? ids(in: directory)) ?? [] {
      guard let record = try? ConsoleCapture.checked(id, in: directory, now: now),
            let end = record.finishedAt, now.timeIntervalSince(end) >= retention else { continue }
      unlink(file(id, in: directory).path)
      unlink(directory.appendingPathComponent(id + ".stop").path)
      unlink(directory.appendingPathComponent(id + ".owner").path)
    }
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
      let url = directory.appendingPathComponent(name)
      guard ["tmp", "stop", "owner"].contains(url.pathExtension), let id = validID(url.deletingPathExtension().lastPathComponent),
            let date = modified(url), now.timeIntervalSince(date) >= retention else { continue }
      if url.pathExtension == "tmp" {
        unlink(url.path)
      } else if access(file(id, in: directory).path, F_OK) != 0, errno == ENOENT,
                let lock = try? ownerLock(id, in: directory, exclusive: true) {
        if access(file(id, in: directory).path, F_OK) != 0, errno == ENOENT {
          unlink(url.path)
          unlink(directory.appendingPathComponent(id + ".owner").path)
        }
        close(lock)
      }
    }
  }

  static func modified(_ url: URL) -> Date? {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
  }

  /// Held continuously from journal creation through the guard's last waitpid and final save.
  /// An exclusive acquisition proves there is no participant left and serializes recovery.
  static func ownerLock(_ id: String, in directory: URL, exclusive: Bool) throws -> Int32? {
    let fd = open(directory.appendingPathComponent(id + ".owner").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ConsoleProblem(.consoleOwnershipUnverified, "cannot open capture owner lock") }
    if flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { return fd }
    let e = errno
    close(fd)
    if e == EWOULDBLOCK { return nil }
    throw ConsoleProblem(.consoleOwnershipUnverified, "cannot verify capture owner lock")
  }

  static func partial(_ id: String, in directory: URL) -> [String: String] {
    let fd = open(file(id, in: directory).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return [:] }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 65536,
          let data = try? FileHandle(fileDescriptor: fd).read(upToCount: 65537),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return ["path", "udid", "bundleID", "session"].reduce(into: [:]) { $0[$1] = object[$1] as? String }
  }

  func saveFinal(in directory: URL = directory) throws {
    for _ in 0 ..< 3 {
      do { try save(in: directory); return } catch { usleep(50000) }
    }
    try save(in: directory)
  }

  var json: [String: Any] {
    var result: [String: Any] = ["captureID": captureID, "backend": "simctl-pty", "stream": "combined", "path": path,
                                 "state": state, "udid": udid, "bundleID": bundleID, "session": session as Any,
                                 "limitReached": limitReached, "byteLimit": ConsoleSink.limit]
    if path.isEmpty { result["path"] = nil }
    if udid.isEmpty { result["udid"] = nil }
    if bundleID.isEmpty { result["bundleID"] = nil }
    result["pid"] = pid
    result["diagnostic"] = diagnostic
    if finishedAt != nil { result["appState"] = ConsoleCapture.appOutcome(self) }
    result["reason"] = reason
    result["childExit"] = childExit
    result["childSignal"] = childSignal
    result["saveError"] = saveError
    if saveError != nil { result["code"] = RelayErrorCode.consoleSaveFailed.rawValue }
    if finishedAt != nil { result["bytesWritten"] = bytesWritten }
    return result
  }

  func attaching(to body: Data) -> Data {
    var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    object["console"] = json
    return CLIOutput.json(object)
  }

  mutating func finish(_ why: String, status: Int32? = nil) {
    reason = why
    state = "ended"
    finishedAt = Date()
    if let status {
      let sig = status & 0x7f
      if sig == 0 { childExit = (status >> 8) & 0xff }
      else { childSignal = sig }
    }
  }
}

/// Writes PTY bytes without decoding, allocating per line, or queueing unbounded work.
struct ConsoleSink {
  static let limit = 16 * 1024 * 1024
  let fd: Int32
  var capacity = limit
  var count = 0
  var error: String?

  /// Journal updates and retention own the entries under this directory. A user capture must
  /// never become a future stop request or a prune candidate.
  static func outputPath(_ path: String, stateDirectory: URL = ConsoleState.directory) throws -> String {
    let file = URL(fileURLWithPath: path)
    let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    let reserved = stateDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    guard parent != reserved, !parent.hasPrefix(reserved + "/") else {
      throw ConsoleProblem(.consoleSaveFailed, "choose an output file outside the console state directory")
    }
    // Leave the last component unresolved for O_EXCL and O_NOFOLLOW, including dangling symlinks.
    return file.path
  }

  static func create(_ path: String) throws -> Int32 {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ConsoleProblem(.consoleSaveFailed, "cannot create \(path): \(String(cString: strerror(errno)))") }
    return fd
  }

  mutating func append(_ bytes: UnsafeRawBufferPointer, writer: (Int32, UnsafeRawPointer, Int) -> Int = Darwin.write) {
    guard var address = bytes.baseAddress, error == nil else { return }
    var remaining = min(bytes.count, capacity - count)
    while remaining > 0 {
      let n = writer(fd, address, remaining)
      if n < 0, errno == EINTR { continue }
      guard n > 0 else {
        error = String(cString: strerror(errno))
        return
      }
      count += n
      remaining -= n
      address += n
    }
  }
}
