import Darwin
import Foundation

struct RunnerStatusOptions: Equatable {
    var json = false
    /// `--runner <path>`; nil searches as `RunnerLocator` describes.
    var runnerPath: String?
}

struct RunnerStopOptions: Equatable {
    var runnerPath: String?
}

/// The answer of `GET /ping`.
enum RunnerPing: Equatable {
    case alive(busy: Bool, busyForMs: Int?)
    /// The runner answered with something other than 200 (401 when the token is not its own).
    case status(Int)
    case unreachable(String)

    static func check(_ info: RunnerInfo, timeout: TimeInterval = 3) -> RunnerPing {
        guard let url = URL(string: info.url) else { return .unreachable("invalid url: \(info.url)") }
        var client = RunnerClient(baseURL: url, token: info.token)
        client.timeout = timeout
        do {
            return parse(try client.get("/ping"))
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func parse(_ response: RunnerResponse) -> RunnerPing {
        guard response.status == 200 else { return .status(response.status) }
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return .alive(busy: object?["busy"] as? Bool ?? false, busyForMs: (object?["busyForMs"] as? NSNumber)?.intValue)
    }

    var isAlive: Bool {
        if case .alive = self { return true }
        return false
    }

    /// 0 alive, 3 no answer, else the code the runner commands use for the status (4 for 401).
    var exitCode: RunnerExitCode {
        switch self {
        case .alive: return .success
        case .status(let status): return status == 200 ? .runnerError : RunnerExitCode(status: status)
        case .unreachable: return .unavailable
        }
    }

    var summary: String {
        switch self {
        case .alive(let busy, let busyForMs):
            return busy ? "ok (busy\(busyForMs.map { " for \($0) ms" } ?? ""))" : "ok (idle)"
        case .status(let status):
            return status == 401 ? "401 (the runner rejected the token in runner.json)" : "HTTP \(status)"
        case .unreachable(let reason):
            return "no answer (\(reason))"
        }
    }
}

/// `relay status`: what runner.json says and whether the runner answers.
enum RunnerStatus {
    struct Report {
        var infoURL: URL
        var info: RunnerInfo
        /// Whether the `relay start` in runner.json still runs (nil when runner.json has no pid).
        var processRunning: Bool?
        var ping: RunnerPing
    }

    static func run(_ options: RunnerStatusOptions) -> Int32 {
        let infoURL: URL
        let info: RunnerInfo
        do {
            infoURL = try RunnerLocator.locate(explicitPath: options.runnerPath)
            info = try RunnerInfo.read(from: infoURL)
        } catch let error as RunnerUnavailableError {
            return notRunning(error.description, json: options.json)
        } catch {
            return fail("cannot read runner info: \(error)", code: .usage)
        }
        let report = Report(
            infoURL: infoURL,
            info: info,
            processRunning: info.pid.map { _ in RelayProcess.runningRelayStart(info) != nil },
            ping: RunnerPing.check(info)
        )
        if options.json {
            FileHandle.standardOutput.write(json(report) + Data("\n".utf8))
        } else {
            print(text(report))
        }
        if !report.ping.isAlive, report.ping.exitCode == .unavailable {
            FileHandle.standardError.write(Data("relay: the runner does not answer; relay stop cleans up, relay start --background starts a new one\n".utf8))
        }
        return report.ping.exitCode.rawValue
    }

    static func text(_ report: Report, timeZone: TimeZone = .current) -> String {
        let info = report.info
        var rows: [(String, String)] = [("url", info.url)]
        rows.append(("device", info.name.map { "\($0) (\(info.udid))" } ?? info.udid))
        if let pid = info.pid {
            let state = report.processRunning == true ? "relay start running" : "relay start not running"
            rows.append(("pid", "\(pid) (\(state))"))
        }
        if let startedAt = info.startedAt {
            rows.append(("started", formatted(startedAt, timeZone: timeZone)))
        }
        rows.append(("ping", report.ping.summary))
        rows.append(("runner.json", report.infoURL.path))
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "\($0.0):\(String(repeating: " ", count: width - $0.0.count + 1))\($0.1)" }.joined(separator: "\n")
    }

    static func json(_ report: Report) -> Data {
        let info = report.info
        var object: [String: Any] = [
            "alive": report.ping.isAlive,
            "url": info.url,
            "udid": info.udid,
            "runnerInfo": report.infoURL.path,
            "name": info.name ?? NSNull(),
            "pid": info.pid.map { NSNumber(value: $0) } ?? NSNull(),
            "processRunning": report.processRunning.map { NSNumber(value: $0) } ?? NSNull(),
            "startedAt": info.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        ]
        switch report.ping {
        case .alive(let busy, let busyForMs):
            object["ping"] = ["status": 200, "busy": busy, "busyForMs": busyForMs.map { NSNumber(value: $0) } ?? NSNull()] as [String: Any]
        case .status(let status):
            object["ping"] = ["status": status]
        case .unreachable(let reason):
            object["ping"] = ["error": reason]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func formatted(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private static func notRunning(_ reason: String, json: Bool) -> Int32 {
        if json {
            let object: [String: Any] = ["alive": false, "error": reason]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } else {
            print("not running")
        }
        return fail(reason, code: .unavailable)
    }

    static func fail(_ message: String, code: RunnerExitCode) -> Int32 {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
        return code.rawValue
    }
}

/// `relay stop`: stops the `relay start` in runner.json the way Ctrl-C does, or, when that process is
/// gone, the runner itself, and removes the stale runner.json.
enum RunnerStop {
    /// `relay start` needs up to 10 seconds to stop the runner, then shuts down a simulator it booted.
    static let exitTimeout: TimeInterval = 60

    static func run(_ options: RunnerStopOptions) -> Int32 {
        let infoURL: URL
        let info: RunnerInfo
        do {
            infoURL = try RunnerLocator.locate(explicitPath: options.runnerPath)
            info = try RunnerInfo.read(from: infoURL)
        } catch is RunnerUnavailableError {
            print("not running")
            return RunnerExitCode.success.rawValue
        } catch {
            return RunnerStatus.fail("cannot read runner info: \(error)", code: .usage)
        }
        // While the simulator still runs, so the video is complete; its path goes to stderr.
        Recording.cleanUp(port: Recording.port(of: info))

        if let pid = RelayProcess.runningRelayStart(info) {
            note("stopping relay start (pid \(pid)); it shuts the runner down")
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(exitTimeout)
            while RelayProcess.runningRelayStart(info) != nil {
                guard Date() < deadline else {
                    return RunnerStatus.fail("relay start (pid \(pid)) did not exit within \(Int(exitTimeout))s; see its log in ~/.relay/logs",
                                             code: .usage)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            // relay start removes it itself unless it was killed.
            RunnerInfo.remove(at: infoURL, ifTokenIs: info.token)
            print("stopped")
            return RunnerExitCode.success.rawValue
        }

        // No relay start (killed, or runner.json from an old version): stop the runner directly.
        guard let url = URL(string: info.url) else {
            RunnerInfo.remove(at: infoURL, ifTokenIs: info.token)
            note("removed \(infoURL.path), which had an invalid url")
            print("not running")
            return RunnerExitCode.success.rawValue
        }
        var client = RunnerClient(baseURL: url, token: info.token)
        client.timeout = 5
        let status = (try? client.post("/shutdown"))?.status
        RunnerInfo.remove(at: infoURL, ifTokenIs: info.token)
        if status == 200 {
            note("relay start is not running; sent /shutdown to the runner at \(info.url) and removed \(infoURL.path)")
            print("stopped")
        } else {
            let reason = status.map { "it answered \($0)" } ?? "nothing answered at \(info.url)"
            note("removed the stale \(infoURL.path) (\(reason))")
            print("not running")
        }
        return RunnerExitCode.success.rawValue
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }
}
