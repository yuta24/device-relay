import Foundation

enum Command: Equatable {
    case start(StartOptions)
    case bench(BenchOptions)
    case runner(RunnerControlOptions)
    case status(RunnerStatusOptions)
    case stop(RunnerStopOptions)
    case devices(json: Bool)
    case doctor(DoctorOptions)
    case config(ConfigOptions)
    case install(InstallOptions)
    case version
    case help
    /// `relay <command> --help`.
    case commandHelp(String)
}

struct StartOptions: Equatable {
    /// `--udid`; nil picks the device by `--device` or automatically (see `DeviceSelector`).
    var udid: String?
    /// `--device <name>`: a device or simulator name, case-insensitive.
    var device: String?
    /// `--project <path>`: the device-relay checkout (see `RunnerProject`).
    var project: String?
    var port: Int = 8100
    var teamID: String?
    var rebuild = false
    var verbose = false
    var readyTimeout: TimeInterval = 180
    /// Also probe the runner's Wi-Fi (and other interface) addresses, not only the CoreDevice tunnel.
    var allowWiFi = false
    /// `--background`: run `relay start` detached and return once the runner is ready (see `BackgroundStart`).
    var background = false

    /// The arguments of the same `relay start` without `--background`, for the detached process.
    var foregroundArguments: [String] {
        var arguments = ["start"]
        if let udid { arguments += ["--udid", udid] }
        if let device { arguments += ["--device", device] }
        if let project { arguments += ["--project", project] }
        arguments += ["--port", "\(port)"]
        if let teamID { arguments += ["--team-id", teamID] }
        if rebuild { arguments.append("--rebuild") }
        if verbose { arguments.append("--verbose") }
        arguments += ["--ready-timeout", "\(readyTimeout)"]
        if allowWiFi { arguments.append("--allow-wifi") }
        return arguments
    }
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

/// `relay config [get|set|unset] [<key> [<value>]]`. No action prints the whole file.
struct ConfigOptions: Equatable {
    enum Action: Equatable {
        case show
        case get(String)
        case set(String, String)
        case unset(String)
    }

    var action: Action
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
            var options = StartOptions()
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--udid": options.udid = try value(for: option)
                case "--device": options.device = try value(for: option)
                case "--project": options.project = try value(for: option)
                case "--port":
                    guard let port = Int(try value(for: option)), (1...65535).contains(port) else {
                        throw ArgumentError(description: "--port requires a valid TCP port")
                    }
                    options.port = port
                case "--team-id": options.teamID = try teamID(try value(for: option))
                case "--ready-timeout":
                    guard let timeout = TimeInterval(try value(for: option)), timeout > 0 else {
                        throw ArgumentError(description: "--ready-timeout requires seconds greater than zero")
                    }
                    options.readyTimeout = timeout
                case "--rebuild": options.rebuild = true
                case "--verbose": options.verbose = true
                case "--allow-wifi": options.allowWiFi = true
                case "--background": options.background = true
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            guard options.udid == nil || options.device == nil else {
                throw ArgumentError(description: "start takes either --udid or --device, not both")
            }
            return .start(options)
        case "status", "stop":
            var json = false
            var runnerPath: String?
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--json" where subcommand == "status": json = true
                case "--runner": runnerPath = try value(for: option)
                case "-h", "--help": return .commandHelp(subcommand)
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            return subcommand == "status" ? .status(RunnerStatusOptions(json: json, runnerPath: runnerPath)) : .stop(RunnerStopOptions(runnerPath: runnerPath))
        case "devices":
            var json = false
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--json": json = true
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            return .devices(json: json)
        case "doctor":
            var options = DoctorOptions()
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--udid": options.udid = try value(for: option)
                case "--device": options.device = try value(for: option)
                case "--project": options.project = try value(for: option)
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            guard options.udid == nil || options.device == nil else {
                throw ArgumentError(description: "doctor takes either --udid or --device, not both")
            }
            return .doctor(options)
        case "config":
            return .config(try parseConfig(rest))
        case "install", "uninstall":
            var options = InstallOptions(remove: subcommand == "uninstall")
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--project" where subcommand == "install": options.project = try value(for: option)
                case "--build" where subcommand == "install": options.build = true
                case "--verbose" where subcommand == "install": options.verbose = true
                case "--remove" where subcommand == "install": options.remove = true
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            guard !(options.remove && (options.build || options.verbose || options.project != nil)) else {
                throw ArgumentError(description: "install --remove takes no other options")
            }
            return .install(options)
        case "--version", "version":
            return .version
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
            if let name = rest.first, runnerUsages[name] != nil || lifecycleUsages[name] != nil {
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

    /// `relay config` arguments: `get <key>`, `set <key> <value>`, `unset <key>`, or nothing.
    static func parseConfig(_ raw: [String]) throws -> ConfigOptions {
        func key(_ value: String) throws -> String {
            guard RelayConfig.keys.contains(value) else {
                throw ArgumentError(description: "unknown config key: \(value) (known: \(RelayConfig.keys.joined(separator: ", ")))")
            }
            return value
        }
        switch raw.first {
        case nil:
            return ConfigOptions(action: .show)
        case "get" where raw.count == 2:
            return ConfigOptions(action: .get(try key(raw[1])))
        case "set" where raw.count == 3:
            return ConfigOptions(action: .set(try key(raw[1]), try teamID(raw[2])))
        case "unset" where raw.count == 2:
            return ConfigOptions(action: .unset(try key(raw[1])))
        default:
            throw ArgumentError(description: "config takes get <key>, set <key> <value>, or unset <key>")
        }
    }

    private static func teamID(_ value: String) throws -> String {
        guard RelayConfig.isValidTeamID(value) else {
            throw ArgumentError(description: "invalid Team ID: \(value) (10 uppercase letters and digits)")
        }
        return value
    }

    static let usage = """
    Usage:
      relay start [--udid <UDID> | --device <NAME>] [--team-id <TEAM_ID>] [--project <PATH>] [--port 8100] [--rebuild] [--verbose]
                  [--ready-timeout 180] [--allow-wifi] [--background]
      relay status [--json] [--runner <PATH>]
      relay stop [--runner <PATH>]
      relay install [--project <PATH>] [--build [--verbose]] | relay install --remove | relay uninstall
      relay devices [--json]
      relay doctor [--udid <UDID> | --device <NAME>] [--project <PATH>]
      relay config [get <key> | set <key> <value> | unset <key>]
      relay bench --url <RUNNER_URL> [--count 10] [--tap x,y] [--mode private|xcui] [--token <TOKEN>]

    start    Builds the RelayRunner XCTest runner if needed, launches it on the device or simulator,
             and prints the runner URL once it answers /health. The URL and a per-launch access token
             are saved to ~/.relay/runner.json (mode 0600) and removed on exit. Ctrl-C shuts the runner down.
             Without --udid or --device it uses the only connected device, else the only booted simulator.
             A shut-down simulator named with --udid/--device is booted, and shut down again on exit.
             For devices, the Team ID defaults to teamID in ~/.relay/config.json, else the team of the
             Apple Development certificates in the keychain; the one used is saved there.
             The runner project is --project, else $RELAY_HOME, else a device-relay checkout around the
             current directory, else the copy relay install made in ~/.relay/runner, else the checkout of
             the relay executable. Builds and logs go to ~/.relay/build and ~/.relay/logs.
             Devices are reached over the CoreDevice tunnel only; --allow-wifi also tries the device's
             Wi-Fi addresses, where the token travels as plain HTTP.
             --background runs it detached from the terminal (log: ~/.relay/logs/start-*.log) and exits once
             the runner is ready, printing ready: <url>; relay stop stops it. Agents and CI should use
             relay start --background, then the runner commands, then relay stop.
    status   Shows the runner in runner.json (URL, device, relay start pid, start time) and whether /ping
             answers. Exits 0 if it does, 3 if there is no runner or it does not answer.
    stop     Stops relay start (SIGTERM, like Ctrl-C), which shuts the runner down, shuts down a simulator
             it booted, and removes runner.json. Prints "not running" (exit 0) if nothing runs.
    install  Copies the runner project from the device-relay checkout (--project, $RELAY_HOME, or the one the
             relay executable was built in) to ~/.relay/runner, replacing a previous copy, and records the
             relay version. --build also builds it for simulators (log: ~/.relay/logs/build-*.log;
             --verbose also shows xcodebuild's output). --remove (or relay uninstall) deletes
             ~/.relay/runner and its builds; config.json and runner.json stay.
    devices  Lists devices (devicectl) and iOS simulators (simctl): name, UDID, kind, OS, and state.
    doctor   Checks Xcode, the runner project, signing, and the device relay start would use, marking each
             ✓ / ✗ / ! with a fix. Exits 1 if anything is ✗.
    config   Shows or changes ~/.relay/config.json (key: teamID).
    bench    Measures round-trip latency of /health, /screenshot, and optionally /tap.
             --mode forces the runner's touch path (private event synthesis or public XCUI).
             --token defaults to the token in the runner.json the runner commands use.

    Runner commands (operate the runner relay start launched; relay <command> --help for details):
    \(runnerCommandOrder.map { "  " + runnerUsages[$0]!.synopsis }.joined(separator: "\n"))

    \(runnerCommonUsage)
    """
}
