import Foundation
@testable import Relay
import Testing

// relay logs and relay crashes: the command line, and the times of log and crash reports. UDIDs are dummies.

struct LogArgumentsTests {
  @Test func logsDefaults() throws {
    #expect(try Arguments.parse(["logs"]) == .logs(LogsOptions()))
    #expect(try Arguments.parse(["crashes"]) == .crashes(CrashesOptions()))
  }

  @Test func logsOptions() throws {
    var options = LogsOptions()
    options.bundleID = "com.example.app"
    options.since = .ago(300)
    options.output = "app.json"
    options.target.session = "agent-1"
    #expect(try Arguments.parse(["logs", "--bundle-id", "com.example.app", "--since", "5m", "-o", "app.json", "--session", "agent-1"])
      == .logs(options))
    #expect(try Arguments.parse(["logs", "--bundle-id=com.example.app", "--since=5m", "--output", "app.json", "--session=agent-1"])
      == .logs(options))

    var follow = LogsOptions()
    follow.follow = true
    follow.target.udid = "SIM-0001"
    #expect(try Arguments.parse(["logs", "--follow", "--udid", "SIM-0001"]) == .logs(follow))

    var archive = LogsOptions()
    archive.archive = "device.logarchive"
    archive.since = .at(Date(timeIntervalSince1970: 1_794_356_400))
    archive.target.runnerPath = "r.json"
    #expect(try Arguments.parse(["logs", "--archive", "device.logarchive", "--since", "2026-11-11T00:20:00Z", "--runner", "r.json"])
      == .logs(archive))
  }

  @Test func crashesOptions() throws {
    var options = CrashesOptions()
    options.bundleID = "host"
    options.since = .ago(86400)
    options.name = "Retired/App-2026-11-11-092059.ips"
    options.output = "crashes"
    options.target.udid = "DEVICE-1"
    #expect(try Arguments.parse(["crashes", "--bundle-id", "host", "--since", "1d", "--name", "Retired/App-2026-11-11-092059.ips",
                                 "-o", "crashes", "--udid", "DEVICE-1"]) == .crashes(options))
  }

  @Test func rejectsBadArguments() {
    for arguments in [
      ["logs", "--bogus"], ["logs", "--since"], ["logs", "--since", "5"], ["logs", "--since", "0m"], ["logs", "--since", "5w"],
      ["logs", "--since", "-5m"], ["logs", "--since", "2026-11-11T00:20:00"], ["logs", "--since", "yesterday"],
      ["logs", "--follow", "--since", "5m"], ["logs", "--follow", "--archive", "a.logarchive"], ["logs", "--follow=1"],
      ["logs", "--udid", "A", "--session", "b"], ["logs", "--runner", "r.json", "--session", "b"], ["logs", "--udid", "A/B"],
      ["logs", "--udid", ""], ["logs", "--session", "bad/name"], ["logs", "-o"], ["logs", "--bundle-id", "--follow"],
      ["crashes", "--follow"], ["crashes", "--archive", "a"], ["crashes", "--name", "/abs.ips"], ["crashes", "--name", "../x.ips"],
      ["crashes", "--name", "a//b.ips"], ["crashes", "--name", "./a.ips"], ["crashes", "--name", ""],
      ["crashes", "--udid", "A", "--runner", "r.json"], ["crashes", "--since", "soon"]
    ] {
      #expect(throws: ArgumentError.self, "\(arguments)") { try Arguments.parse(arguments) }
    }
  }

  @Test func helpForBoth() throws {
    for name in ["logs", "crashes"] {
      #expect(try Arguments.parse([name, "--help"]) == .commandHelp(name))
      #expect(try Arguments.parse([name, "--since", "5m", "-h"]) == .commandHelp(name))
      #expect(Arguments.usage(for: name).hasPrefix("Usage:\n  relay \(name)"))
    }
    #expect(flattened(Arguments.usage(for: "logs")).contains("relay does not run sudo"))
    #expect(flattened(Arguments.usage(for: "logs")).contains("logs_filter_unsupported"))
    #expect(flattened(Arguments.usage(for: "crashes")).contains("crash_filter_unsupported"))
    #expect(flattened(Arguments.usage).contains("logs Prints the unified log"))
  }
}

struct LogSinceTests {
  @Test func durations() throws {
    #expect(try LogSince.parse("30s") == .ago(30))
    #expect(try LogSince.parse("5m") == .ago(300))
    #expect(try LogSince.parse("2h") == .ago(7200))
    #expect(try LogSince.parse("1d") == .ago(86400))
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(LogSince.ago(300).resolve(now: now) == Date(timeIntervalSince1970: 999_700))
    #expect(LogSince.at(now).resolve(now: Date()) == now)
  }

  @Test func timesNeedAZone() throws {
    #expect(try LogSince.parse("2026-11-11T00:20:00Z") == .at(Date(timeIntervalSince1970: 1_794_356_400)))
    #expect(try LogSince.parse("2026-11-11T09:20:00+09:00") == .at(Date(timeIntervalSince1970: 1_794_356_400)))
    #expect(try LogSince.parse("2026-11-11T00:20:00.5Z") == .at(Date(timeIntervalSince1970: 1_794_356_400.5)))
    let error = #expect(throws: ArgumentError.self) { try LogSince.parse("2026-11-11 00:20") }
    #expect(error?.description.contains("--since requires") == true)
  }
}

struct LogTimeTests {
  @Test func readsTheFormatsOfLogAndCrashReports() {
    let base = 1_794_356_400.0 // 2026-11-11T00:20:00Z
    func near(_ text: String, _ expected: Double) -> Bool {
      LogTime.parse(text).map { abs($0.timeIntervalSince1970 - expected) < 0.000001 } ?? false
    }
    #expect(near("2026-11-11 09:20:00.739833+0900", base + 0.739833))
    #expect(near("2026-11-11 09:20:00.6059 +0900", base + 0.6059))
    #expect(near("2026-11-11 09:20:00.00 +0900", base))
    #expect(near("2026-11-11T00:20:00Z", base))
    #expect(near("2026-11-10 23:20:00-0100", base))
    #expect(near("2026-11-11 05:50:00+05:30", base))
    for bad in ["", "2026-11-11", "2026-11-11 09:20:00", "2026-11-11 09:20:00.+0900", "2026-13-11 09:20:00+0900",
                "2026-11-11 09:20:00+0900 extra", "2026-11-11 09:20:00*0900", "2026-11-11 09:20:00+09", "x026-11-11 09:20:00Z"] {
      #expect(LogTime.parse(bad) == nil, "\(bad)")
    }
  }

  @Test func writesUTCWithMicroseconds() {
    #expect(LogTime.string(Date(timeIntervalSince1970: 1_794_356_400.739833)) == "2026-11-11T00:20:00.739833Z")
    #expect(LogTime.string(Date(timeIntervalSince1970: 1_794_356_400)) == "2026-11-11T00:20:00Z")
    #expect(LogTime.string(Date(timeIntervalSince1970: 1_794_356_400.5), fraction: false) == "2026-11-11T00:20:00Z")
    #expect(LogTime.rfc3339("2026-11-11 00:20:00Z")?.timeIntervalSince1970 == 1_794_356_400)
    #expect(LogTime.rfc3339("2026-11-11") == nil)
  }
}
