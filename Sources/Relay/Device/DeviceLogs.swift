import Darwin
import Foundation

/// A failure of `relay logs` or `relay crashes` after the command line was read: one JSON object on stdout,
/// `{"ok":false,"code":…,"error":…}`, and `status`.
struct LogFailure: Error, Equatable {
  var code: RelayErrorCode
  var message: String
  var status: Int32 = RunnerExitCode.failure.rawValue
  /// `hint`: the command that would work instead.
  var hint: String?

  var body: Data {
    CLIOutput.failureBody(code, message, extra: hint.map { ["hint": $0] } ?? [:])
  }
}

/// What `relay logs` and `relay crashes` read the host with. Tests replace them.
struct LogTools: Sendable {
  var commands: HostCommands
  /// `LogProcess.run`: a tool whose stdout relay does not read (`log collect`).
  var run: @Sendable (_ executable: String, _ args: [String], _ stdout: URL, _ timeout: TimeInterval, _ stop: LogStop?) throws -> LogToolExit
  /// `LogProcess.stream` with the line limit of `DeviceLogs.maxLineBytes`. A nil timeout is `--follow`,
  /// whose tool's stderr is passed on to relay's.
  var stream: @Sendable (_ executable: String, _ args: [String], _ timeout: TimeInterval?, _ stop: LogStop,
                         _ onLine: @escaping @Sendable (Data) -> Bool) throws -> LogToolExit
  /// Writes to stdout; false when it is closed.
  var write: @Sendable (Data) -> Bool
  var environment: [String: String]
  var home: URL
  var currentDirectory: URL
  /// Where the work directories (mode 0700) go.
  var temporaryDirectory: URL

  static var live: LogTools {
    LogTools(
      commands: .live,
      run: { try LogProcess.run($0, $1, stdout: $2, timeout: $3, stop: $4) },
      stream: { try LogProcess.stream($0, $1, timeout: $2, echoStderr: $2 == nil, maxLineBytes: DeviceLogs.maxLineBytes, stop: $3, onLine: $4) },
      write: { LogOutput.write($0, to: STDOUT_FILENO) },
      environment: ProcessInfo.processInfo.environment,
      home: UserHome.url,
      currentDirectory: WorkingDirectory.url,
      temporaryDirectory: FileManager.default.temporaryDirectory
    )
  }

  /// `data` and a line break on stdout.
  func writeLine(_ data: Data) {
    _ = write(data.last == UInt8(ascii: "\n") ? data : data + Data("\n".utf8))
  }

  /// A new directory of mode 0700 for the files of one command, which the caller removes.
  func makeWorkDirectory() throws -> URL {
    let parent = temporaryDirectory.appendingPathComponent("relay", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let url = parent.appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(url.path, 0o700) == 0 else {
      throw SetupError(description: "cannot create \(url.path): \(String(cString: strerror(errno)))")
    }
    return url
  }
}

/// The simulator or device `relay logs` and `relay crashes` read: the UDID of runner.json or `--udid`, as
/// simctl or devicectl lists it.
struct LogTarget: Equatable {
  var udid: String
  /// The runner.json it came from; nil with `--udid`.
  var info: RunnerInfo?

  /// `--bundle-id`, with `host` as the runner's host app.
  func bundleID(_ value: String) throws(LogFailure) -> String {
    guard value == "host" else { return value }
    guard let host = info?.hostBundleID else {
      throw LogFailure(code: .runnerInfoInvalid, message: info == nil
        ? "host is the runner's host app, which --udid does not name; pass its bundle ID"
        : "runner.json names no host app for host; pass its bundle ID")
    }
    return host
  }

  /// The runner of `options` (runner.json as `RunnerLocator` finds it), or `--udid`. With `optional`, no
  /// runner.json found without an option or a variable is nil rather than a failure (`--archive`).
  static func resolve(_ options: LogTargetOptions, tools: LogTools, optional: Bool = false) throws -> LogTarget? {
    if let udid = options.udid {
      return LogTarget(udid: udid)
    }
    let selection: RunnerLocator.Selection
    do {
      selection = try RunnerLocator.selection(explicitPath: options.runnerPath, session: options.session, environment: tools.environment)
    } catch let error as SessionSelectionError {
      throw ArgumentError(description: error.description)
    }
    if optional, selection == .defaultRunner, !FileManager.default.fileExists(atPath: RunnerLocator.userURL(home: tools.home).path) {
      return nil
    }
    let url: URL
    do {
      url = try RunnerLocator.locate(explicitPath: options.runnerPath, session: options.session, environment: tools.environment,
                                     currentDirectory: tools.currentDirectory, home: tools.home)
    } catch let error as RunnerUnavailableError {
      throw LogFailure(code: .runnerUnavailable, message: error.description + "; or pass --udid <udid> (relay devices lists them)",
                       status: RunnerExitCode.unavailable.rawValue)
    }
    do {
      let info = try RunnerInfo.read(from: url)
      return LogTarget(udid: info.udid, info: info)
    } catch {
      throw LogFailure(code: .runnerInfoInvalid, message: "cannot read \(url.path): \(error)")
    }
  }

  /// The simulator simctl lists with this UDID, else the device devicectl lists with it.
  func device(tools: LogTools) throws(LogFailure) -> Device {
    let simulators: [Device]
    do {
      simulators = try DeviceList.parseSimctl(Data(tools.commands.xcrun(["simctl", "list", "devices", "--json"], CommandTimeout.query).utf8))
    } catch {
      throw LogFailure(code: .deviceUnavailable, message: "cannot list the simulators: \(error)")
    }
    if case .simulator(let simulator) = Recording.target(udid: udid, devices: simulators) {
      return simulator
    }
    let devices: [Device]
    do {
      devices = try DeviceList.parseDevicectl(tools.commands.devicectlJSON(["list", "devices"], CommandTimeout.devicectl))
    } catch {
      throw LogFailure(code: .deviceUnavailable, message: "\(udid) is not a simulator, and devicectl cannot list the devices: \(error)")
    }
    guard case .device(let device) = Recording.target(udid: udid, devices: devices) else {
      throw LogFailure(code: .deviceUnavailable, message: "no simulator or device has the UDID \(udid) (relay devices lists them)")
    }
    return device
  }

  static func json(_ device: Device) -> [String: Any] {
    ["udid": device.udid, "name": device.name, "kind": device.kind.rawValue, "os": nullable(device.os)]
  }
}

/// `value`, or JSON's null.
func nullable(_ value: Any?) -> Any {
  value ?? NSNull()
}

/// A line of the unified log, as `relay logs` prints it.
struct LogEntry: Equatable {
  var date: Date
  var level: String?
  var processID: Int?
  var process: String?
  var subsystem: String?
  var category: String?
  var message: String?
  /// The UUID of the executable (`processImageUUID`), which `LogFilter` compares; not printed.
  var imageUUID: String?

  var json: [String: Any] {
    [
      "timestamp": LogTime.string(date),
      "level": nullable(level),
      "processID": nullable(processID),
      "process": nullable(process),
      "subsystem": nullable(subsystem),
      "category": nullable(category),
      "message": nullable(message)
    ]
  }
}

/// `--bundle-id` of a simulator: the app's main executable as installed now. `log` gets `process ==
/// "<executable name>"`, and relay keeps the lines whose `processImageUUID` is that executable's. The
/// past log names the path an executable with that UUID first ran from, which is not the current one
/// after a reinstall, so the path cannot be compared.
struct LogFilter: Equatable {
  var bundleID: String
  /// The executable in the app's container on the Mac.
  var executablePath: String
  /// The LC_UUIDs of its architectures, uppercased.
  var imageUUIDs: [String]

  var executableName: String { URL(fileURLWithPath: executablePath).lastPathComponent }
  var predicate: String { DeviceLogs.predicate(process: executableName) }

  func keeps(_ entry: LogEntry) -> Bool {
    entry.imageUUID.map { imageUUIDs.contains($0.uppercased()) } ?? false
  }

  var json: [String: Any] {
    ["bundleID": bundleID, "executablePath": executablePath, "imageUUIDs": imageUUIDs]
  }
}

/// The LC_UUID of each architecture of a Mach-O file, thin or fat.
enum MachO {
  /// How much of a slice is read for its load commands, which come right after its header.
  static let headerWindow = 1 << 20

  static func uuids(_ data: Data) -> [String] {
    let header = window(data, at: 0)
    guard header.count >= 8 else { return [] }
    let magic = header[0 ..< 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
      // Each slice is read at its offset, which may be far into the file.
      return fatOffsets(header, wide: magic == 0xCAFE_BABF).compactMap { uuid(window(data, at: $0)) }
    }
    return uuid(header).map { [$0] } ?? []
  }

  private static func window(_ data: Data, at offset: Int) -> [UInt8] {
    guard offset >= 0, offset < data.count else { return [] }
    let start = data.startIndex + offset
    return [UInt8](data[start ..< min(start + headerWindow, data.endIndex)])
  }

  /// The offsets of the slices of a fat file, from its header.
  private static func fatOffsets(_ bytes: [UInt8], wide: Bool) -> [Int] {
    func u32(_ offset: Int) -> UInt32? {
      guard offset >= 0, offset + 4 <= bytes.count else { return nil }
      return bytes[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    guard let count = u32(4), count < 64 else { return [] }
    return (0 ..< Int(count)).compactMap { index -> Int? in
      let entry = 8 + index * (wide ? 32 : 20)
      if wide {
        guard let high = u32(entry + 8), let low = u32(entry + 12) else { return nil }
        // A broken header can hold an offset past Int.max: skip that slice.
        return Int(exactly: UInt64(high) << 32 | UInt64(low))
      }
      return u32(entry + 8).map(Int.init)
    }
  }

  /// The LC_UUID of a thin Mach-O that starts at the first byte of `bytes`.
  private static func uuid(_ bytes: [UInt8]) -> String? {
    // Little-endian, as on every Apple architecture.
    func u32(_ offset: Int) -> UInt32? {
      guard offset >= 0, offset + 4 <= bytes.count else { return nil }
      return bytes[offset ..< offset + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    guard let magic = u32(0), magic == 0xFEED_FACF || magic == 0xFEED_FACE, let count = u32(16) else { return nil }
    var offset = magic == 0xFEED_FACF ? 32 : 28
    for _ in 0 ..< min(count, 4096) {
      guard let command = u32(offset), let size = u32(offset + 4), size >= 8 else { return nil }
      if command == 0x1B, offset + 24 <= bytes.count {
        let hex = bytes[offset + 8 ..< offset + 24].map { String(format: "%02X", $0) }.joined()
        let parts = [0 ..< 8, 8 ..< 12, 12 ..< 16, 16 ..< 20, 20 ..< 32].map { range in
          String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound) ..< hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
      }
      offset += Int(size)
    }
    return nil
  }
}

/// The lines of one `log show` that `relay logs` keeps, read one at a time so neither `log`'s output nor
/// the lines left out are kept.
struct LogCollector {
  var since: Date?
  var until: Date?
  var filter: LogFilter?
  /// The most JSON relay prints (about: each line's message and a fixed size for the rest).
  var maxBytes = DeviceLogs.maxOutputBytes

  private(set) var entries: [LogEntry] = []
  /// Events that are not log lines (`activityCreateEvent`, ...).
  private(set) var skipped = 0
  private(set) var failure: LogFailure?
  private var bytes = 0
  private var lineNumber = 0

  init(since: Date?, until: Date?, filter: LogFilter?, maxBytes: Int = DeviceLogs.maxOutputBytes) {
    self.since = since
    self.until = until
    self.filter = filter
    self.maxBytes = maxBytes
  }

  /// False once it has to stop: a line it cannot read, or too much to print (`failure`).
  mutating func add(_ raw: Data) -> Bool {
    lineNumber += 1
    switch DeviceLogs.parse(line: raw) {
    case .entry(let entry):
      if let since, entry.date < since { return true }
      if let until, entry.date > until { return true }
      if let filter, !filter.keeps(entry) { return true }
      bytes += 200 + (entry.message?.utf8.count ?? 0)
      guard bytes <= maxBytes else {
        failure = LogFailure(code: .logsUnavailable, message: "the log is larger than \(maxBytes / 1024 / 1024) MiB; "
          + "give a later --since, or --bundle-id")
        return false
      }
      entries.append(entry)
    case .otherEvent:
      skipped += 1
    case .summary, .notice:
      break
    case .invalid(let reason):
      failure = LogFailure(code: .logsUnavailable, message: "log printed \(reason) (line \(lineNumber)); relay does not skip what it cannot read")
      return false
    }
    return true
  }
}

/// `relay logs`: the unified log of a simulator (`simctl spawn <udid> log show|stream`), of a device
/// (`log collect --device-udid`, which needs an administrator), or of a `.logarchive`.
enum DeviceLogs {
  /// Without `--since`.
  static let defaultSince: TimeInterval = 300
  /// The most JSON `relay logs` prints: a larger log is an error that asks for a later `--since`.
  static let maxOutputBytes = 64 * 1024 * 1024
  /// A line longer than this is not a log line relay reads.
  static let maxLineBytes = 1024 * 1024
  static let showTimeout: TimeInterval = 60
  /// Not measured: collecting needs an administrator, which was not tried.
  static let collectTimeout: TimeInterval = 120
  static let simulatorLimitations = [
    "debug lines are not kept in the past log: relay logs --follow shows them",
    "print() and other writes to stdout or stderr of an app are not in the unified log"
  ]
  static let bundleLimitation = "only the main executable of the app as installed now: not its extensions, other processes, "
    + "or an earlier build"

  // MARK: - Pure helpers

  /// `@<seconds>`, rounded down so the window `log` returns includes `date`.
  static func epoch(_ date: Date) -> String {
    "@\(Int64(date.timeIntervalSince1970.rounded(.down)))"
  }

  /// `process == "<name>"`, with `\` and `"` escaped.
  static func predicate(process: String) -> String {
    let escaped = process.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "process == \"\(escaped)\""
  }

  static func showArguments(udid: String, since: Date, predicate: String?) -> [String] {
    ["simctl", "spawn", udid, "log", "show", "--style", "ndjson", "--info", "--debug", "--start", epoch(since)]
      + (predicate.map { ["--predicate", $0] } ?? [])
  }

  static func streamArguments(udid: String, predicate: String?) -> [String] {
    ["simctl", "spawn", udid, "log", "stream", "--style", "ndjson", "--level", "debug"] + (predicate.map { ["--predicate", $0] } ?? [])
  }

  static func collectArguments(udid: String, since: Date, output: String) -> [String] {
    ["collect", "--device-udid", udid, "--start", epoch(since), "--output", output]
  }

  static func archiveArguments(path: String, since: Date?) -> [String] {
    ["show", "--archive", path, "--style", "ndjson", "--info", "--debug"] + (since.map { ["--start", epoch($0)] } ?? [])
  }

  /// What a line of `log --style ndjson` is.
  enum Line: Equatable {
    case entry(LogEntry)
    /// A JSON event that is not a log line (`activityCreateEvent`, `signpostEvent`, ...).
    case otherEvent
    /// The last line of `log show`: `{"count":540,"finished":1}`.
    case summary
    /// What `log stream` prints first (`Filtering the log data using …`, an empty line).
    case notice(String)
    /// Anything else, which is an error rather than something to skip.
    case invalid(String)
  }

  static func parse(line raw: Data) -> Line {
    let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.isEmpty || line.hasPrefix("Filtering the log data") {
      return .notice(line)
    }
    guard line.hasPrefix("{"), let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
      return .invalid("a line that is not JSON")
    }
    if object["finished"] != nil, object["eventType"] == nil {
      return .summary
    }
    guard let type = object["eventType"] as? String else {
      return .invalid("a JSON line without eventType")
    }
    guard type == "logEvent" else { return .otherEvent }
    guard let time = object["timestamp"] as? String, let date = LogTime.parse(time) else {
      return .invalid("a log line without a readable timestamp")
    }
    func text(_ key: String) -> String? {
      (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    return .entry(LogEntry(
      date: date,
      level: text("messageType")?.lowercased(),
      processID: object["processID"] as? Int,
      process: text("processImagePath").map { URL(fileURLWithPath: $0).lastPathComponent },
      subsystem: text("subsystem"),
      category: text("category"),
      message: object["eventMessage"] as? String,
      imageUUID: text("processImageUUID")
    ))
  }

  /// The first line of what a tool wrote to stderr that says why it failed, without the warning `log` prints
  /// on success too (`getpwuid_r did not find a match for uid …`), cut at 200 characters.
  static func reason(_ exit: LogToolExit, tool: String, timeout: TimeInterval) -> String {
    if exit.timedOut {
      return "\(tool) timed out after \(Int(timeout)) s"
    }
    let line = exit.stderr.split(whereSeparator: \.isNewline).map(String.init)
      .first { !$0.hasPrefix("getpwuid_r") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let detail = line.map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
    return "\(tool) failed (\(exit.status))" + (detail.map { ": \($0)" } ?? "")
  }

  static func isPermissionDenied(_ exit: LogToolExit) -> Bool {
    exit.status == 77 || exit.stderr.contains("Must be admin")
  }

  /// The commands to run instead when `log collect` needs an administrator.
  static func collectHint(udid: String, since: Date) -> String {
    "sudo log collect --device-udid \(udid) --start \(epoch(since)) --output <dir>/device.logarchive, "
      + "then relay logs --archive <dir>/device.logarchive --udid \(udid)"
  }

  /// The JSON of `relay logs` without `--follow`.
  static func result(
    backend: String, device: Any, filter: Any, since: Date?, until: Date?, collector: LogCollector, limitations: [String],
    extra: [String: Any] = [:]
  ) -> [String: Any] {
    var object = extra
    object["ok"] = true
    object["backend"] = backend
    object["device"] = device
    object["filter"] = filter
    object["range"] = [
      "requestedSince": nullable(since.map { LogTime.string($0) }),
      "until": nullable(until.map { LogTime.string($0) }),
      "firstEntryAt": nullable(collector.entries.first.map { LogTime.string($0.date) }),
      "lastEntryAt": nullable(collector.entries.last.map { LogTime.string($0.date) })
    ]
    object["count"] = collector.entries.count
    object["entries"] = collector.entries.map(\.json)
    object["skippedEvents"] = collector.skipped
    object["limitations"] = limitations
    return object
  }

  /// The JSON of `relay logs -o`: `result` without `entries`, with the file.
  static func summary(of result: [String: Any], path: String) -> [String: Any] {
    var summary = result
    summary["entries"] = nil
    summary["path"] = path
    return summary
  }

  /// Creates `url` (mode 0600, never replacing a file) and returns its descriptor.
  static func createNewFile(_ url: URL) throws(LogFailure) -> Int32 {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      let reason = errno == EEXIST ? "it already exists; give another -o" : String(cString: strerror(errno))
      throw LogFailure(code: .logsSaveFailed, message: "cannot create \(url.path): \(reason)")
    }
    return fd
  }

  /// Creates `url` (mode 0600, never replacing a file) with `data`.
  static func writeNewFile(_ data: Data, to url: URL) throws(LogFailure) {
    let fd = try createNewFile(url)
    defer { close(fd) }
    guard LogOutput.write(data, to: fd) else {
      unlink(url.path)
      throw LogFailure(code: .logsSaveFailed, message: "cannot write \(url.path): \(String(cString: strerror(errno)))")
    }
  }

  /// The main executable of `bundleID` installed on the simulator: its `.app` from `simctl get_app_container`,
  /// `CFBundleExecutable` from the app's Info.plist, and the executable's UUIDs; all on the Mac.
  static func filter(bundleID: String, udid: String, tools: LogTools) throws(LogFailure) -> LogFilter {
    let app: String
    do {
      app = try tools.commands.xcrun(["simctl", "get_app_container", udid, bundleID, "app"], CommandTimeout.query)
        .split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    } catch {
      throw LogFailure(code: .logAppUnavailable, message: "\(bundleID) is not installed on the simulator \(udid) "
        + "(simctl get_app_container failed); check the bundle ID, which is case-sensitive")
    }
    let appURL = URL(fileURLWithPath: app)
    let plist = appURL.appendingPathComponent("Info.plist")
    guard app.hasPrefix("/"),
          let data = FileManager.default.contents(atPath: plist.path),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/") else {
      throw LogFailure(code: .logAppUnavailable, message: "cannot read CFBundleExecutable of \(bundleID) from \(plist.path)")
    }
    let executableURL = appURL.appendingPathComponent(executable)
    let uuids = (try? Data(contentsOf: executableURL, options: .mappedIfSafe)).map(MachO.uuids) ?? []
    guard !uuids.isEmpty else {
      throw LogFailure(code: .logAppUnavailable, message: "cannot read the UUID of \(executableURL.path), which tells the app's lines apart")
    }
    return LogFilter(bundleID: bundleID, executablePath: executableURL.path, imageUUIDs: uuids)
  }

  // MARK: - Command

  static func run(_ options: LogsOptions, tools: LogTools = .live, now: Date = Date()) -> Int32 {
    do {
      return try runChecked(options, tools: tools, now: now)
    } catch let failure as LogFailure {
      tools.writeLine(failure.body)
      return failure.status
    } catch let error as ArgumentError {
      return CLIOutput.usageError(error.description, command: "logs")
    } catch {
      tools.writeLine(LogFailure(code: .logsUnavailable, message: "\(error)").body)
      return RunnerExitCode.failure.rawValue
    }
  }

  private static func runChecked(_ options: LogsOptions, tools: LogTools, now: Date) throws -> Int32 {
    let since = options.since.map { $0.resolve(now: now) } ?? (options.archive == nil ? now.addingTimeInterval(-defaultSince) : nil)
    if let since, since > now {
      throw ArgumentError(description: "--since \(LogTime.string(since, fraction: false)) is in the future")
    }
    let output = options.output.map { RunnerLocator.resolve($0, in: tools.currentDirectory) }

    if let archive = options.archive {
      let target = try LogTarget.resolve(options.target, tools: tools, optional: true)
      if options.bundleID != nil {
        throw LogFailure(code: .logsFilterUnsupported, message: "--bundle-id cannot be used with --archive yet: "
          + "relay cannot tell which lines of an archive are the app's; pass --since only")
      }
      let url = RunnerLocator.resolve(archive, in: tools.currentDirectory)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw LogFailure(code: .logsUnavailable, message: "no .logarchive at \(url.path)")
      }
      let device: Any = target.map { ["udid": $0.udid, "name": nullable($0.info?.name), "kind": NSNull(), "os": NSNull()] } ?? NSNull()
      return try show(archive: url, backend: "archive", device: device, since: since, until: nil, tools: tools, output: output,
                      limitations: ["the archive is not checked against the device: deviceVerified is false"],
                      extra: ["deviceVerified": false])
    }

    let target = try LogTarget.resolve(options.target, tools: tools)!
    let device = try target.device(tools: tools)
    switch device.kind {
    case .simulator:
      guard device.isBooted else {
        throw LogFailure(code: .deviceUnavailable, message: "the simulator \(device.name) (\(device.udid)) is \(device.state); "
          + "its log needs it booted (relay does not boot it)")
      }
      let filter = try options.bundleID.map { value throws(LogFailure) in
        try Self.filter(bundleID: try target.bundleID(value), udid: device.udid, tools: tools)
      }
      let limitations = simulatorLimitations + (filter == nil ? [] : [bundleLimitation])
      if options.follow {
        return try follow(device: device, filter: filter, limitations: limitations, output: output, tools: tools)
      }
      var collector = LogCollector(since: since, until: now, filter: filter)
      try collect(into: &collector, "/usr/bin/xcrun", showArguments(udid: device.udid, since: since!, predicate: filter?.predicate), tools: tools)
      let object = result(backend: "simctl", device: LogTarget.json(device), filter: nullable(filter?.json), since: since, until: now,
                          collector: collector, limitations: limitations)
      return try finish(object, output: output, tools: tools)
    case .device:
      guard device.isAvailable else {
        throw LogFailure(code: .deviceUnavailable, message: "the device \(device.name) (\(device.udid)) is not connected (\(device.state))")
      }
      if options.follow {
        throw LogFailure(code: .logsFollowUnsupported, message: "--follow works on simulators only: macOS has no way to stream "
          + "a device's log that relay can use; relay logs --since reads the past")
      }
      if options.bundleID != nil {
        throw LogFailure(code: .logsFilterUnsupported, message: "--bundle-id works on simulators only: relay cannot tell which lines of "
          + "a device's log are the app's; leave it out (collecting the log needs an administrator, too)")
      }
      let work = try tools.makeWorkDirectory()
      defer { try? FileManager.default.removeItem(at: work) }
      let archive = work.appendingPathComponent("device.logarchive")
      let stop = LogStop()
      let signals = LogSignals.install(stop)
      defer { LogSignals.uninstall(signals) }
      let exit = try tools.run("/usr/bin/log", collectArguments(udid: device.udid, since: since!, output: archive.path),
                               work.appendingPathComponent("collect.out"), collectTimeout, stop)
      if isPermissionDenied(exit) {
        throw LogFailure(code: .logsPermissionDenied, message: "log collect needs an administrator to collect the log of \(device.name); "
          + "relay does not run sudo: run the hint yourself", hint: collectHint(udid: device.udid, since: since!))
      }
      try check(exit, tool: "log collect", timeout: collectTimeout)
      return try show(archive: archive, backend: "log collect", device: LogTarget.json(device), since: since, until: now, tools: tools,
                      output: output, limitations: [])
    }
  }

  /// `log show --archive`: the JSON of `relay logs` for an archive.
  private static func show(
    archive: URL, backend: String, device: Any, since: Date?, until: Date?, tools: LogTools, output: URL?, limitations: [String],
    extra: [String: Any] = [:]
  ) throws -> Int32 {
    var collector = LogCollector(since: since, until: until, filter: nil)
    try collect(into: &collector, "/usr/bin/log", archiveArguments(path: archive.path, since: since), tools: tools)
    let object = result(backend: backend, device: device, filter: NSNull(), since: since, until: until, collector: collector,
                        limitations: limitations, extra: extra)
    return try finish(object, output: output, tools: tools)
  }

  /// Runs a `log show` and hands each line to `collector`. Throws for a tool that was stopped, timed out,
  /// failed, or printed what the collector cannot read.
  private static func collect(into collector: inout LogCollector, _ executable: String, _ args: [String], tools: LogTools) throws {
    let stop = LogStop()
    let signals = LogSignals.install(stop)
    defer { LogSignals.uninstall(signals) }
    let shared = Locked(collector)
    let exit = try tools.stream(executable, args, showTimeout, stop) { line in
      shared.withLock { $0.add(line) }
    }
    collector = shared.value
    if let failure = collector.failure {
      throw failure
    }
    try check(exit, tool: "log show", timeout: showTimeout)
  }

  /// Throws for a tool that was stopped, timed out, or failed.
  private static func check(_ exit: LogToolExit, tool: String, timeout: TimeInterval) throws(LogFailure) {
    if case .signal(let number) = exit.stopped {
      throw LogFailure(code: .logsUnavailable, message: "stopped by \(signalName(number)) before \(tool) ended",
                       status: LogStop.exitStatus(for: number))
    }
    if exit.stopped == .overlongLine {
      throw LogFailure(code: .logsUnavailable, message: "\(tool) printed a line longer than \(maxLineBytes / 1024 / 1024) MiB")
    }
    guard exit.status == 0, !exit.timedOut else {
      throw LogFailure(code: .logsUnavailable, message: reason(exit, tool: tool, timeout: timeout))
    }
  }

  /// Prints `object`, or writes it to `output` and prints the summary.
  private static func finish(_ object: [String: Any], output: URL?, tools: LogTools) throws(LogFailure) -> Int32 {
    if let output {
      try writeNewFile(CLIOutput.json(object) + Data("\n".utf8), to: output)
      tools.writeLine(CLIOutput.json(summary(of: object, path: output.path)))
    } else {
      tools.writeLine(CLIOutput.json(object))
    }
    return RunnerExitCode.success.rawValue
  }

  // MARK: - Follow

  /// What `--follow` has written, shared with the thread that reads the lines.
  private struct FollowState {
    var count = 0
    var failure: LogFailure?
    var outputClosed = false
  }

  /// `--follow`: `log stream` of a simulator as NDJSON, until a signal (exit 128 + the signal) or an error.
  private static func follow(device: Device, filter: LogFilter?, limitations: [String], output: URL?, tools: LogTools) throws -> Int32 {
    let fd = try output.map { url throws(LogFailure) in try createNewFile(url) } ?? -1
    var keepOpen = false
    defer { if fd >= 0, !keepOpen { close(fd) } }
    let emit: @Sendable (Data) -> Bool = { data in
      let line = data + Data("\n".utf8)
      return fd >= 0 ? LogOutput.write(line, to: fd) : tools.write(line)
    }

    let stop = LogStop()
    let signals = LogSignals.install(stop)
    defer { LogSignals.uninstall(signals) }
    let start: [String: Any] = ["type": "start", "ok": true, "backend": "simctl", "device": LogTarget.json(device),
                                "filter": nullable(filter?.json), "startedAt": LogTime.string(Date()), "limitations": limitations]
    guard emit(CLIOutput.json(start)) else {
      throw LogFailure(code: .logsSaveFailed, message: "cannot write the log")
    }
    let state = Locked(FollowState())
    let exit = try tools.stream("/usr/bin/xcrun", streamArguments(udid: device.udid, predicate: filter?.predicate), nil, stop) { raw in
      switch parse(line: raw) {
      case .entry(let entry):
        if let filter, !filter.keeps(entry) { return true }
        var object = entry.json
        object["type"] = "log"
        guard emit(CLIOutput.json(object)) else {
          state.withLock { $0.outputClosed = true }
          return false
        }
        state.withLock { $0.count += 1 }
        return true
      case .notice(let text):
        if !text.isEmpty { CLIOutput.note("log stream: \(text)") }
        return true
      case .otherEvent, .summary:
        return true
      case .invalid(let reason):
        state.withLock { $0.failure = LogFailure(code: .logsUnavailable, message: "log stream printed \(reason); stopped") }
        return false
      }
    }
    let final = state.value
    if exit.deliveryAbandoned {
      // A line is still being written (to a stdout nobody reads, say): another write would wait the same
      // way, and the fd stays open so that write never reaches a file opened later. relay ends now.
      keepOpen = true
      CLIOutput.note("cannot finish writing \(output?.path ?? "to stdout"); stopped")
      let number = exit.stopped.flatMap { reason -> Int32? in if case .signal(let n) = reason { n } else { nil } }
      return number.map(LogStop.exitStatus) ?? RunnerExitCode.failure.rawValue
    }
    if final.outputClosed {
      // Nothing more can go where the lines went.
      CLIOutput.note("cannot write \(output?.path ?? "to stdout"); stopped")
      return RunnerExitCode.failure.rawValue
    }
    let failure = followFailure(state: final.failure, exit: exit)
    let status: Int32
    if let failure {
      _ = emit(CLIOutput.json(["type": "error", "ok": false, "code": failure.code.rawValue, "error": failure.message,
                               "partial": true, "count": final.count]))
      status = failure.status
    } else {
      let number = exit.stopped.flatMap { reason -> Int32? in if case .signal(let n) = reason { n } else { nil } } ?? SIGINT
      _ = emit(CLIOutput.json(["type": "end", "ok": true, "count": final.count, "reason": signalName(number)]))
      status = LogStop.exitStatus(for: number)
    }
    if let output {
      var summary: [String: Any] = ["ok": failure == nil, "path": output.path, "count": final.count]
      if let failure {
        summary["code"] = failure.code.rawValue
        summary["error"] = failure.message
        summary["partial"] = true
      }
      tools.writeLine(CLIOutput.json(summary))
    }
    return status
  }

  /// Why `--follow` ended, unless a signal ended it.
  static func followFailure(state: LogFailure?, exit: LogToolExit) -> LogFailure? {
    if let state {
      return state
    }
    switch exit.stopped {
    case .signal:
      return nil
    case .overlongLine:
      return LogFailure(code: .logsUnavailable, message: "log stream printed a line longer than \(maxLineBytes / 1024 / 1024) MiB; stopped")
    case .consumer, nil:
      return LogFailure(code: .logsUnavailable, message: reason(exit, tool: "log stream", timeout: 0)
        + "; it ended by itself (was the simulator shut down?)")
    }
  }

  static func signalName(_ number: Int32) -> String {
    switch number {
    case SIGINT: "SIGINT"
    case SIGTERM: "SIGTERM"
    case SIGHUP: "SIGHUP"
    default: "signal \(number)"
    }
  }
}
