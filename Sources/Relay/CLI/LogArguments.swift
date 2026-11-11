import Foundation

/// Where a log or crash window starts: `--since 5m` (that long before the command started) or an RFC 3339
/// time with a time zone (`2026-11-11T00:20:00Z`). It is resolved once, when the command starts.
enum LogSince: Equatable {
  case ago(TimeInterval)
  case at(Date)

  func resolve(now: Date) -> Date {
    switch self {
    case .ago(let seconds): now.addingTimeInterval(-seconds)
    case .at(let date): date
    }
  }

  /// `30s`, `5m`, `2h`, `1d` (a positive integer and a unit), or an RFC 3339 time with a time zone.
  static func parse(_ value: String, option: String = "--since") throws -> LogSince {
    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    if let unit = value.last, let seconds = units[unit], let count = Int(value.dropLast()), count > 0,
       value.dropLast().allSatisfy(\.isASCII) {
      return .ago(TimeInterval(count) * seconds)
    }
    if let date = LogTime.rfc3339(value) {
      return .at(date)
    }
    throw ArgumentError(description: "\(option) requires a duration such as 30s, 5m, 2h, or 1d, "
      + "or a time with a time zone such as 2026-11-11T00:20:00Z (got \(value))")
  }
}

/// The device `relay logs` and `relay crashes` look at: the runner's (`--runner`, `--session`, or what
/// `RunnerLocator` finds), or `--udid`, which reads no runner.json, so it works after `relay stop` too.
struct LogTargetOptions: Equatable {
  var runnerPath: String?
  var session: String?
  var udid: String?
}

/// `relay logs`: the unified log of an app or of the whole device (see `DeviceLogs`).
struct LogsOptions: Equatable {
  /// `--bundle-id <id>` (`host` for the runner's host app): the log of its main executable only.
  var bundleID: String?
  /// `--since`; nil is the last 5 minutes, or the whole archive with `--archive`.
  var since: LogSince?
  /// `--follow`: new lines as NDJSON until SIGINT or SIGTERM (simulators only).
  var follow = false
  /// `--archive <path>`: a `.logarchive` collected elsewhere (`sudo log collect`).
  var archive: String?
  /// `-o <file>`: the JSON (NDJSON with `--follow`) goes there, and a summary to stdout.
  var output: String?
  var target = LogTargetOptions()
}

/// `relay crashes`: the crash reports of a simulator (the Mac's DiagnosticReports) or a device (devicectl).
struct CrashesOptions: Equatable {
  /// `--bundle-id <id>`: simulators only; a device's list has no bundle IDs.
  var bundleID: String?
  /// `--since`; nil is the last 24 hours.
  var since: LogSince?
  /// `--name <relativePath>`: the one report to list or save, as the list names it.
  var name: String?
  /// `-o <dir>`: save the reports listed into that directory.
  var output: String?
  var target = LogTargetOptions()
}

extension Arguments {
  /// `relay logs [--bundle-id <id>] [--since <time>] [--follow] [--archive <path>] [-o <file>]
  /// [--session <name> | --runner <path> | --udid <udid>]`.
  static func parseLogs(_ raw: [String]) throws -> Command {
    var options = LogsOptions()
    var rest = raw[...]
    while let option = rest.popFirst() {
      switch option {
      case "--bundle-id": options.bundleID = try logValue(for: option, from: &rest)
      case "--since": options.since = try LogSince.parse(try logValue(for: option, from: &rest))
      case "--follow": options.follow = true
      case "--archive": options.archive = try logValue(for: option, from: &rest)
      case "-o", "--output": options.output = try logValue(for: option, from: &rest)
      case "--session", "--runner", "--udid": try readTarget(option, from: &rest, into: &options.target)
      case "-h", "--help": return .commandHelp("logs")
      default: throw ArgumentError(description: "unknown option for logs: \(option)")
      }
    }
    try checkTarget(options.target, command: "logs")
    if options.follow, options.since != nil {
      throw ArgumentError(description: "--follow shows new lines only; it takes no --since (run relay logs --since without --follow for the past)")
    }
    if options.follow, options.archive != nil {
      throw ArgumentError(description: "--follow cannot read an --archive; pass one of them")
    }
    return .logs(options)
  }

  /// `relay crashes [--bundle-id <id>] [--since <time>] [--name <relativePath>] [-o <dir>]
  /// [--session <name> | --runner <path> | --udid <udid>]`.
  static func parseCrashes(_ raw: [String]) throws -> Command {
    var options = CrashesOptions()
    var rest = raw[...]
    while let option = rest.popFirst() {
      switch option {
      case "--bundle-id": options.bundleID = try logValue(for: option, from: &rest)
      case "--since": options.since = try LogSince.parse(try logValue(for: option, from: &rest))
      case "--name": options.name = try crashName(try logValue(for: option, from: &rest))
      case "-o", "--output": options.output = try logValue(for: option, from: &rest)
      case "--session", "--runner", "--udid": try readTarget(option, from: &rest, into: &options.target)
      case "-h", "--help": return .commandHelp("crashes")
      default: throw ArgumentError(description: "unknown option for crashes: \(option)")
      }
    }
    try checkTarget(options.target, command: "crashes")
    return .crashes(options)
  }

  /// A `--name` as the list gives it: a relative path inside the crash log folder, without `.` or `..`.
  static func crashName(_ value: String) throws -> String {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !value.isEmpty, !value.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
      throw ArgumentError(description: "--name requires a name from the list of relay crashes, such as App-2026-11-11-092059.ips (got \(value))")
    }
    return value
  }

  /// A `--udid`: letters, digits, and `-`, as simctl and devicectl print them.
  static func udid(_ value: String) throws -> String {
    guard !value.isEmpty, value.count <= 64, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
      throw ArgumentError(description: "--udid requires a UDID as relay devices shows it (got \(value))")
    }
    return value
  }

  private static func logValue(for option: String, from rest: inout ArraySlice<String>) throws -> String {
    guard let value = rest.first, !value.hasPrefix("--") else {
      throw ArgumentError(description: "\(option) requires a value")
    }
    rest.removeFirst()
    return value
  }

  private static func readTarget(_ option: String, from rest: inout ArraySlice<String>, into target: inout LogTargetOptions) throws {
    let value = try logValue(for: option, from: &rest)
    switch option {
    case "--session": target.session = try sessionName(value)
    case "--runner": target.runnerPath = value
    default: target.udid = try udid(value)
    }
  }

  private static func checkTarget(_ target: LogTargetOptions, command: String) throws {
    guard [target.runnerPath, target.session, target.udid].compactMap({ $0 }).count <= 1 else {
      throw ArgumentError(description: "\(command) takes one of --session, --runner, and --udid")
    }
  }
}

/// The time formats of `log`, crash reports, and `--since`.
enum LogTime {
  /// `2026-11-11T00:20:00Z`, `2026-11-11T09:20:00.5+09:00`: RFC 3339 with a time zone.
  static func rfc3339(_ text: String) -> Date? {
    let normalized = text.replacingOccurrences(of: " ", with: "T", options: [], range: text.range(of: " "))
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: normalized) {
        return date
      }
    }
    return nil
  }

  /// The times of `log --style ndjson` (`2026-11-11 09:20:47.739833+0900`) and of crash reports
  /// (`2026-11-11 09:20:54.6059 +0900`, `2026-11-11 09:20:59.00 +0900`): any number of fraction digits,
  /// with or without a space before the offset.
  static func parse(_ text: String) -> Date? {
    let scalars = Array(text.utf8)
    var index = 0
    func number(_ digits: Int) -> Int? {
      guard index + digits <= scalars.count else { return nil }
      var value = 0
      for scalar in scalars[index ..< index + digits] {
        guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(scalar) else { return nil }
        value = value * 10 + Int(scalar - UInt8(ascii: "0"))
      }
      index += digits
      return value
    }
    func expect(_ character: Character) -> Bool {
      guard index < scalars.count, scalars[index] == character.asciiValue else { return false }
      index += 1
      return true
    }
    guard let year = number(4), expect("-"), let month = number(2), expect("-"), let day = number(2),
          expect(" ") || expect("T"), let hour = number(2), expect(":"), let minute = number(2), expect(":"),
          let second = number(2) else { return nil }
    var fraction = 0.0
    if expect(".") {
      var scale = 0.1
      let start = index
      while index < scalars.count, let digit = number(1) {
        fraction += Double(digit) * scale
        scale /= 10
      }
      guard index > start else { return nil }
    }
    _ = expect(" ")
    var offset = 0
    if expect("Z") {
      offset = 0
    } else {
      let sign: Int
      if expect("+") { sign = 1 } else if expect("-") { sign = -1 } else { return nil }
      guard let hours = number(2) else { return nil }
      _ = expect(":")
      guard let minutes = number(2) else { return nil }
      offset = sign * (hours * 3600 + minutes * 60)
    }
    guard index == scalars.count else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    guard let zone = TimeZone(secondsFromGMT: offset), (1 ... 12).contains(month), (1 ... 31).contains(day),
          hour < 24, minute < 60, second < 61 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: components).map { $0.addingTimeInterval(fraction) }
  }

  /// `2026-11-11T00:20:47.739833Z`: UTC, with microseconds when there is a fraction of a second.
  static func string(_ date: Date, fraction: Bool = true) -> String {
    let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    let seconds = Int64((Double(micros) / 1_000_000).rounded(.down))
    let rest = micros - seconds * 1_000_000
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
    return fraction && rest != 0 ? base + String(format: ".%06lld", rest) + "Z" : base + "Z"
  }
}
