import Foundation

enum Command: Equatable {
    case start(StartOptions)
    case bench(BenchOptions)
    case runner(RunnerControlOptions)
    case help
    /// `relay <command> --help`.
    case commandHelp(String)
}

struct StartOptions: Equatable {
    var udid: String
    var port: Int = 8100
    var teamID: String?
    var rebuild = false
    var verbose = false
    var readyTimeout: TimeInterval = 180
    /// Also probe the runner's Wi-Fi (and other interface) addresses, not only the CoreDevice tunnel.
    var allowWiFi = false
}

struct BenchOptions: Equatable {
    var url: String
    var count = 10
    var tap: (x: Double, y: Double)?
    /// Touch path for `/tap`: `private` or `xcui`. Nil lets the runner choose.
    var mode: String?
    /// Bearer token for the runner. Nil reads it from `.relay/runner.json`.
    var token: String?

    static func == (lhs: BenchOptions, rhs: BenchOptions) -> Bool {
        lhs.url == rhs.url && lhs.count == rhs.count && lhs.tap?.x == rhs.tap?.x && lhs.tap?.y == rhs.tap?.y
            && lhs.mode == rhs.mode && lhs.token == rhs.token
    }
}

struct ArgumentError: Error, CustomStringConvertible {
    let description: String
}

enum Arguments {
    /// `standardInput` is read only by `relay type --stdin`; tests pass their own.
    static func parse(_ raw: [String], standardInput: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) throws -> Command {
        guard let subcommand = raw.first else { return .help }
        var rest = Array(raw.dropFirst())

        func value(for option: String) throws -> String {
            guard !rest.isEmpty, !rest[0].hasPrefix("--") else {
                throw ArgumentError(description: "\(option) requires a value")
            }
            return rest.removeFirst()
        }

        switch subcommand {
        case "start":
            var options = StartOptions(udid: "")
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--udid": options.udid = try value(for: option)
                case "--port":
                    guard let port = Int(try value(for: option)), (1...65535).contains(port) else {
                        throw ArgumentError(description: "--port requires a valid TCP port")
                    }
                    options.port = port
                case "--team-id": options.teamID = try value(for: option)
                case "--ready-timeout":
                    guard let timeout = TimeInterval(try value(for: option)), timeout > 0 else {
                        throw ArgumentError(description: "--ready-timeout requires seconds greater than zero")
                    }
                    options.readyTimeout = timeout
                case "--rebuild": options.rebuild = true
                case "--verbose": options.verbose = true
                case "--allow-wifi": options.allowWiFi = true
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            guard !options.udid.isEmpty else {
                throw ArgumentError(description: "start requires --udid <DEVICE_OR_SIMULATOR_UDID>")
            }
            return .start(options)
        case "bench":
            var options = BenchOptions(url: "")
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--url": options.url = try value(for: option)
                case "--count":
                    guard let count = Int(try value(for: option)), count > 0 else {
                        throw ArgumentError(description: "--count requires a positive integer")
                    }
                    options.count = count
                case "--tap":
                    let parts = try value(for: option).split(separator: ",").compactMap { Double($0) }
                    guard parts.count == 2 else {
                        throw ArgumentError(description: "--tap requires x,y")
                    }
                    options.tap = (parts[0], parts[1])
                case "--mode":
                    let mode = try value(for: option)
                    guard ["private", "xcui"].contains(mode) else {
                        throw ArgumentError(description: "--mode requires private or xcui")
                    }
                    options.mode = mode
                case "--token": options.token = try value(for: option)
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            guard !options.url.isEmpty else {
                throw ArgumentError(description: "bench requires --url <RUNNER_URL>")
            }
            return .bench(options)
        case "-h", "--help", "help":
            if let name = rest.first, runnerUsages[name] != nil {
                return .commandHelp(name)
            }
            return .help
        default:
            if runnerUsages[subcommand] != nil {
                return try parseRunnerCommand(subcommand, rest, standardInput: standardInput)
            }
            throw ArgumentError(description: "unknown command: \(subcommand)")
        }
    }

    static let usage = """
    Usage:
      relay start --udid <UDID> [--port 8100] [--team-id <TEAM_ID>] [--rebuild] [--verbose] [--ready-timeout 180] [--allow-wifi]
      relay bench --url <RUNNER_URL> [--count 10] [--tap x,y] [--mode private|xcui] [--token <TOKEN>]

    start  Builds the RelayRunner XCTest runner if needed, launches it on the device or simulator,
           and prints the runner URL once it answers /health. The URL and a per-launch access token
           are saved to .relay/runner.json (mode 0600) and removed on exit. Ctrl-C shuts the runner down.
           Devices are reached over the CoreDevice tunnel only; --allow-wifi also tries the device's
           Wi-Fi addresses, where the token travels as plain HTTP.
    bench  Measures round-trip latency of /health, /screenshot, and optionally /tap.
           --mode forces the runner's touch path (private event synthesis or public XCUI).
           --token defaults to the token in .relay/runner.json.

    Runner commands (operate the runner relay start launched; relay <command> --help for details):
    \(runnerCommandOrder.map { "  " + runnerUsages[$0]!.synopsis }.joined(separator: "\n"))

    \(runnerCommonUsage)
    """
}
