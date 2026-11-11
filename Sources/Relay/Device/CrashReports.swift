import Darwin
import Foundation

/// A crash report as `relay crashes` lists it.
struct CrashReport: Equatable {
  var name: String
  /// Where it is in the folder it was listed from: the name for a simulator's, devicectl's path for a device's.
  var relativePath: String
  /// The process that crashed (`procName`); nil for a device's, whose reports are not opened.
  var process: String?
  /// A device's: the process the file name suggests (`App-2026-11-11-092059.ips` → `App`), not checked.
  var processHint: String?
  var bundleID: String?
  /// `bundleID` comes from the report; false for a device's.
  var bundleIDVerified: Bool
  /// When it crashed (`captureTime`); nil for a device's.
  var occurredAt: Date?
  /// When the file was written.
  var modifiedAt: Date?
  var size: Int?
  /// The report on the Mac (a simulator's); nil for a device's.
  var sourcePath: String?

  /// What `--since` compares: `captured` (occurredAt) for a simulator's, `modified` for a device's.
  var timeBasis: String { occurredAt == nil ? "modified" : "captured" }
  var time: Date? { occurredAt ?? modifiedAt }

  func json(path: String? = nil, error: String? = nil) -> [String: Any] {
    var object: [String: Any] = [
      "name": name,
      "relativePath": relativePath,
      "process": process ?? NSNull(),
      "processHint": processHint ?? NSNull(),
      "bundleID": bundleID ?? NSNull(),
      "bundleIDVerified": bundleIDVerified,
      "occurredAt": occurredAt.map { LogTime.string($0) } ?? NSNull(),
      "modifiedAt": modifiedAt.map { LogTime.string($0) } ?? NSNull(),
      "timeBasis": timeBasis,
      "size": size ?? NSNull()
    ]
    object["sourcePath"] = sourcePath
    object["path"] = path
    object["error"] = error
    return object
  }
}

/// `relay crashes`: the crash reports of a simulator (in the Mac's DiagnosticReports, kept by the UDID in
/// `procPath`) or of a device (devicectl's `systemCrashLogs`, listed without being opened).
enum CrashReports {
  static let defaultSince: TimeInterval = 86400
  /// A larger report is counted as unreadable rather than read.
  static let maxReportBytes = 16 * 1024 * 1024
  static let domain = "systemCrashLogs"
  static let simulatorLimitations = [
    "only .ips reports whose process ran in this simulator; Jetsam, hang, and other report kinds were not tried"
  ]
  static let deviceLimitations = [
    "candidates only: the reports are not opened, so process and bundleID are unknown and processHint comes from the name",
    "modifiedAt is when the file was written on the device, not when it crashed"
  ]

  // MARK: - Pure helpers

  static func diagnosticReports(home: URL) -> URL {
    home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
  }

  /// What a `.ips` file on the Mac is to a simulator.
  enum SimulatorMatch: Equatable {
    case report(CrashReport)
    /// The process ran elsewhere (another simulator, the Mac).
    case elsewhere
    case unreadable
  }

  /// Reads a `.ips`: a JSON line of metadata (`bundleID`, `timestamp`), then the JSON report
  /// (`procName`, `procPath`, `bundleInfo`, `captureTime`). Its process ran in the simulator `udid` when
  /// `procPath` is under `/CoreSimulator/Devices/<udid>/` (the home part of the path may be anonymized).
  static func simulatorReport(name: String, data: Data, modified: Date?, udid: String) -> SimulatorMatch {
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
          let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex ..< newline])) as? [String: Any],
          let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any] else {
      return .unreadable
    }
    guard let path = body["procPath"] as? String else { return .unreadable }
    guard path.range(of: "/CoreSimulator/Devices/\(udid)/", options: .caseInsensitive) != nil else { return .elsewhere }
    let bundleInfo = body["bundleInfo"] as? [String: Any]
    let bundleID = (bundleInfo?["CFBundleIdentifier"] as? String) ?? (header["bundleID"] as? String)
    let occurred = (body["captureTime"] as? String).flatMap(LogTime.parse) ?? (header["timestamp"] as? String).flatMap(LogTime.parse)
    return .report(CrashReport(
      name: name, relativePath: name, process: body["procName"] as? String ?? header["name"] as? String, processHint: nil,
      bundleID: bundleID, bundleIDVerified: bundleID != nil, occurredAt: occurred, modifiedAt: modified, size: data.count,
      sourcePath: nil
    ))
  }

  /// The process a device's report name suggests: what comes before `-YYYY-MM-DD-HHMMSS`.
  static func processHint(name: String) -> String? {
    guard let range = name.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression), range.lowerBound > name.startIndex else {
      return nil
    }
    return String(name[..<range.lowerBound])
  }

  /// The `.ips` files of `devicectl device info files --domain-type systemCrashLogs --json-output`.
  static func deviceReports(json data: Data) throws -> [CrashReport] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = object["result"] as? [String: Any], let files = result["files"] as? [[String: Any]] else {
      throw SetupError(description: "devicectl printed no file list")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return files.compactMap { file in
      let resources = file["resources"] as? [String: Any] ?? [:]
      guard let name = file["name"] as? String, let relativePath = file["relativePath"] as? String, name.hasSuffix(".ips"),
            resources["isDirectory"] as? Bool != true, resources["isSymbolicLink"] as? Bool != true else { return nil }
      let metadata = file["metadata"] as? [String: Any] ?? [:]
      let modified = (metadata["lastModDate"] as? String).flatMap { formatter.date(from: $0) ?? LogTime.rfc3339($0) }
      return CrashReport(name: name, relativePath: relativePath, process: nil, processHint: processHint(name: name), bundleID: nil,
                         bundleIDVerified: false, occurredAt: nil, modifiedAt: modified, size: metadata["size"] as? Int, sourcePath: nil)
    }
  }

  /// The reports to list: the one `name` chooses (whatever its time), else those since `since` (when the
  /// time is unknown too), oldest first.
  static func select(_ reports: [CrashReport], since: Date, name: String?) -> [CrashReport] {
    if let name {
      return reports.filter { $0.relativePath == name }
    }
    return reports.filter { ($0.time ?? since) >= since }.sorted { ($0.time ?? .distantPast, $0.name) < ($1.time ?? .distantPast, $1.name) }
  }

  /// Copies `data` to a new file `name` in `directory` (mode 0600, never replacing one).
  static func saveNew(_ data: Data, name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw SetupError(description: errno == EEXIST ? "\(url.path) already exists" : "cannot create \(url.path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      unlink(url.path)
      throw error
    }
    return url
  }

  /// Moves `file` to a new file `name` in `directory` without replacing one: link(2) fails on an existing name.
  static func moveNew(_ file: URL, name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    guard link(file.path, url.path) == 0 else {
      throw SetupError(description: errno == EEXIST ? "\(url.path) already exists" : "cannot create \(url.path): \(String(cString: strerror(errno)))")
    }
    unlink(file.path)
    chmod(url.path, 0o600)
    return url
  }

  /// The one regular file at `url`: `url` itself, or the only file in it when devicectl made it a directory.
  static func copiedFile(at url: URL) -> URL? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
    guard isDirectory.boolValue else { return url }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    guard names.count == 1 else { return nil }
    let inner = url.appendingPathComponent(names[0])
    guard FileManager.default.fileExists(atPath: inner.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
    return inner
  }

  // MARK: - Command

  static func run(_ options: CrashesOptions, tools: LogTools = .live, now: Date = Date()) -> Int32 {
    do {
      return try runChecked(options, tools: tools, now: now)
    } catch let failure as LogFailure {
      tools.writeLine(failure.body)
      return failure.status
    } catch let error as ArgumentError {
      return CLIOutput.usageError(error.description, command: "crashes")
    } catch {
      tools.writeLine(LogFailure(code: .crashesUnavailable, message: "\(error)").body)
      return RunnerExitCode.failure.rawValue
    }
  }

  private static func runChecked(_ options: CrashesOptions, tools: LogTools, now: Date) throws -> Int32 {
    let since = options.since.map { $0.resolve(now: now) } ?? now.addingTimeInterval(-defaultSince)
    if since > now {
      throw ArgumentError(description: "--since \(LogTime.string(since, fraction: false)) is in the future")
    }
    let output = options.output.map { RunnerLocator.resolve($0, in: tools.currentDirectory) }
    let target = try LogTarget.resolve(options.target, tools: tools)!
    let device = try target.device(tools: tools)
    var isDirectory: ObjCBool = false
    if let output, !(FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
      throw LogFailure(code: .crashesSaveFailed, message: "-o \(output.path) is not an existing directory; create it first")
    }

    let reports: [CrashReport]
    var extra: [String: Any] = [:]
    let limitations: [String]
    let backend: String
    switch device.kind {
    case .simulator:
      let bundleID = try options.bundleID.map { value throws(LogFailure) in try target.bundleID(value) }
      let (found, unreadable) = simulatorReports(udid: device.udid, since: since, name: options.name, home: tools.home)
      reports = select(found.filter { bundleID == nil || $0.bundleID == bundleID }, since: since, name: options.name)
      extra["unreadable"] = unreadable
      extra["filter"] = bundleID.map { ["bundleID": $0] } ?? NSNull()
      limitations = simulatorLimitations
      backend = "DiagnosticReports"
    case .device:
      guard device.isAvailable else {
        throw LogFailure(code: .deviceUnavailable, message: "the device \(device.name) (\(device.udid)) is not connected (\(device.state))")
      }
      if options.bundleID != nil {
        throw LogFailure(code: .crashFilterUnsupported, message: "--bundle-id works on simulators only: a device's list has no bundle IDs, "
          + "and relay does not open its reports; use processHint, then --name")
      }
      if output != nil, options.name == nil {
        throw ArgumentError(description: "on a device, -o saves one report: pass --name <relativePath> from the list")
      }
      let data: Data
      do {
        data = try tools.commands.devicectlJSON(["device", "info", "files", "--device", device.udid, "--domain-type", domain], CommandTimeout.devicectl)
        reports = select(try deviceReports(json: data), since: since, name: options.name)
      } catch {
        throw LogFailure(code: .crashesUnavailable, message: "cannot list the crash reports of \(device.name): \(error)")
      }
      extra["filter"] = NSNull()
      limitations = deviceLimitations
      backend = "devicectl"
    }
    if let name = options.name, reports.isEmpty {
      throw LogFailure(code: .crashesUnavailable, message: "no crash report named \(name) (relay crashes lists them)")
    }

    var items = reports.map { ($0, $0.json()) }
    var failed = 0
    if let output {
      for index in items.indices {
        let report = items[index].0
        do {
          let saved = try save(report, device: device, to: output, tools: tools)
          items[index].1 = report.json(path: saved.path)
        } catch {
          failed += 1
          items[index].1 = report.json(error: "\(error)")
        }
      }
    }
    var object = extra
    object["ok"] = failed == 0
    object["backend"] = backend
    object["device"] = LogTarget.json(device)
    object["range"] = ["requestedSince": LogTime.string(since), "until": LogTime.string(now)]
    object["count"] = items.count
    object["reports"] = items.map(\.1)
    object["limitations"] = limitations
    if failed > 0 {
      object["code"] = RelayErrorCode.crashesSaveFailed.rawValue
      object["error"] = "\(failed) of \(items.count) reports could not be saved to \(output!.path)"
      tools.writeLine(CLIOutput.json(object))
      return RunnerExitCode.failure.rawValue
    }
    tools.writeLine(CLIOutput.json(object))
    return RunnerExitCode.success.rawValue
  }

  /// The `.ips` files of DiagnosticReports written since `since` (or named `name`) whose process ran in the
  /// simulator `udid`, with `sourcePath`, and how many could not be read. A report is written after the
  /// crash, so one older than `since` is not opened.
  static func simulatorReports(udid: String, since: Date, name: String?, home: URL) -> (reports: [CrashReport], unreadable: Int) {
    let directory = diagnosticReports(home: home)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".ips") }
    var reports: [CrashReport] = []
    var unreadable = 0
    for file in names.sorted() where name == nil || file == name {
      let url = directory.appendingPathComponent(file)
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular else { continue }
      let modified = attributes[.modificationDate] as? Date
      if name == nil, let modified, modified < since { continue }
      guard (attributes[.size] as? Int ?? 0) <= maxReportBytes, let data = FileManager.default.contents(atPath: url.path) else {
        unreadable += 1
        continue
      }
      switch simulatorReport(name: file, data: data, modified: modified, udid: udid) {
      case .report(var report):
        report.sourcePath = url.path
        reports.append(report)
      case .elsewhere:
        continue
      case .unreadable:
        unreadable += 1
      }
    }
    return (reports, unreadable)
  }

  /// Saves one report into `directory` under its name.
  private static func save(_ report: CrashReport, device: Device, to directory: URL, tools: LogTools) throws -> URL {
    let name = URL(fileURLWithPath: report.relativePath).lastPathComponent
    if let source = report.sourcePath {
      guard let data = FileManager.default.contents(atPath: source) else {
        throw SetupError(description: "cannot read \(source)")
      }
      return try saveNew(data, name: name, in: directory)
    }
    // A directory of mode 0700 beside the result, so the move is a rename on the same volume.
    let staging = directory.appendingPathComponent(".relay-crash-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(staging.path, 0o700) == 0 else {
      throw SetupError(description: "cannot create \(staging.path): \(String(cString: strerror(errno)))")
    }
    defer { try? FileManager.default.removeItem(at: staging) }
    let destination = staging.appendingPathComponent(name)
    _ = try tools.commands.devicectlJSON(["device", "copy", "from", "--device", device.udid, "--domain-type", domain,
                                          "--source", report.relativePath, "--destination", destination.path], CommandTimeout.devicectl)
    guard let copied = copiedFile(at: destination) else {
      throw SetupError(description: "devicectl copied no file for \(report.relativePath)")
    }
    return try moveNew(copied, name: name, in: directory)
  }
}
