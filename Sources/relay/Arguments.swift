import Foundation

enum Command: Equatable {
    case start(StartOptions)
    case bench(BenchOptions)
    case runner(RunnerControlOptions)
    /// `relay run` (experimental).
    case run(ScenarioOptions)
    case status(RunnerStatusOptions)
    case stop(RunnerStopOptions)
    /// `relay record start|stop|status` (simulators, and devices plugged in with USB).
    case record(RecordOptions)
    case devices(json: Bool, os: String?)
    case doctor(DoctorOptions)
    case config(ConfigOptions)
    case install(InstallOptions)
    case skill(SkillOptions)
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
    /// `--simulator`: pick among simulators only.
    var simulator = false
    /// `--os <version>`: pick among devices and simulators of that OS version.
    var os: String?
    /// `--project <path>`: the device-relay checkout (see `RunnerProject`).
    var project: String?
    var port: Int = 8100
    var teamID: String?
    /// The prefix of the runner's bundle IDs (see `RunnerBundleID`). Set by `StartSetup`, not an option.
    var bundleIDPrefix: String?
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
        if simulator { arguments.append("--simulator") }
        if let os { arguments += ["--os", os] }
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
                case "--simulator": options.simulator = true
                case "--os": options.os = try osVersion(try value(for: option))
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
        case "run":
            return try parseRun(rest)
        case "record":
            return try parseRecord(rest)
        case "devices":
            var json = false
            var os: String?
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--json": json = true
                case "--os": os = try osVersion(try value(for: option))
                default: throw ArgumentError(description: "unknown option: \(option)")
                }
            }
            return .devices(json: json, os: os)
        case "doctor":
            var options = DoctorOptions()
            while !rest.isEmpty {
                let option = rest.removeFirst()
                switch option {
                case "--udid": options.udid = try value(for: option)
                case "--device": options.device = try value(for: option)
                case "--simulator": options.simulator = true
                case "--os": options.os = try osVersion(try value(for: option))
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
        case "skill":
            return .skill(try parseSkill(rest))
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

    /// `relay run (<file> | - | --step <step>...) [--check] [--runner <path>] [--quiet]`: exactly one source of steps.
    static func parseRun(_ raw: [String]) throws -> Command {
        var rest = raw
        var files: [String] = []
        var steps: [String] = []
        var runnerPath: String?
        var quiet = false
        var check = false
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            switch argument {
            case "--step", "--runner":
                // A step may start with -, so only a missing value is rejected here.
                guard !rest.isEmpty else { throw ArgumentError(description: "\(argument) requires a value") }
                let value = rest.removeFirst()
                if argument == "--step" {
                    steps.append(value)
                } else {
                    guard runnerPath == nil else { throw ArgumentError(description: "--runner is given more than once") }
                    runnerPath = value
                }
            case "--quiet", "-q": quiet = true
            case "--check": check = true
            case "-h", "--help": return .commandHelp("run")
            case "-": files.append(argument)
            default:
                guard !argument.hasPrefix("-") else { throw ArgumentError(description: "unknown option for run: \(argument)") }
                files.append(argument)
            }
        }
        let source: ScenarioOptions.Source
        switch (files.count, steps.isEmpty) {
        case (0, false): source = .steps(steps)
        case (1, true): source = files[0] == "-" ? .standardInput : .file(files[0])
        case (0, true): throw ArgumentError(description: "run requires <file>, - (standard input), or --step <step>")
        default: throw ArgumentError(description: "run takes one of <file>, -, or --step <step>...")
        }
        return .run(ScenarioOptions(source: source, runnerPath: runnerPath, quiet: quiet, check: check))
    }

    /// `relay record start [--output <path>] [--force] [--max-duration <s>] [--runner <path>]`, `relay record
    /// stop [--runner <path> | --port <n>]`, `relay record status [--json] [--runner <path> | --port <n>]`, and the internal `relay record
    /// supervise`, which `record start` runs detached (see `RecordSupervisor`).
    static func parseRecord(_ raw: [String]) throws -> Command {
        var rest = raw
        guard !rest.isEmpty else {
            throw ArgumentError(description: "record takes start, stop, or status")
        }
        let action = rest.removeFirst()
        guard ["start", "stop", "status", "supervise"].contains(action) else {
            if ["-h", "--help", "help"].contains(action) { return .commandHelp("record") }
            throw ArgumentError(description: "unknown record action: \(action) (start, stop, or status)")
        }

        func value(for option: String) throws -> String {
            guard !rest.isEmpty, !rest[0].hasPrefix("--") else {
                throw ArgumentError(description: "\(option) requires a value")
            }
            return rest.removeFirst()
        }

        var output: String?
        var maxDuration = Recording.defaultMaxDuration
        var json = false
        var runnerPath: String?
        var port: Int?
        var force = false
        var udid: String?
        var deviceName: String?
        let takesOutput = action == "start" || action == "supervise"
        while !rest.isEmpty {
            let option = rest.removeFirst()
            switch option {
            case "--output" where takesOutput, "-o" where takesOutput:
                output = try value(for: option)
            case "--max-duration" where takesOutput:
                guard let seconds = TimeInterval(try value(for: option)), seconds > 0, seconds.isFinite else {
                    throw ArgumentError(description: "--max-duration requires seconds greater than zero")
                }
                maxDuration = seconds
            case "--force" where action == "start": force = true
            case "--json" where action == "status": json = true
            case "--runner" where action != "supervise": runnerPath = try value(for: option)
            case "--port" where action == "stop" || action == "status":
                guard let value = Int(try value(for: option)), (1...65535).contains(value) else {
                    throw ArgumentError(description: "--port requires a valid TCP port")
                }
                port = value
            case "--udid" where action == "supervise": udid = try value(for: option)
            case "--device-name" where action == "supervise": deviceName = try value(for: option)
            case "-h", "--help": return .commandHelp("record")
            default: throw ArgumentError(description: "unknown option for record \(action): \(option)")
            }
        }
        guard runnerPath == nil || port == nil else {
            throw ArgumentError(description: "record \(action) takes either --runner or --port, not both")
        }
        switch action {
        case "start":
            return .record(RecordOptions(action: .start(output: output, maxDuration: maxDuration, force: force), runnerPath: runnerPath))
        case "stop":
            return .record(RecordOptions(action: .stop, runnerPath: runnerPath, port: port))
        case "status":
            return .record(RecordOptions(action: .status(json: json), runnerPath: runnerPath, port: port))
        default:
            guard let udid, let output else {
                throw ArgumentError(description: "record supervise requires --udid and --output")
            }
            return .record(RecordOptions(action: .supervise(udid: udid, output: output, maxDuration: maxDuration, deviceName: deviceName)))
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
            let name = try key(raw[1])
            return ConfigOptions(action: .set(name, name == "bundleIDPrefix" ? try bundleIDPrefix(raw[2]) : try teamID(raw[2])))
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

    private static func bundleIDPrefix(_ value: String) throws -> String {
        guard RunnerBundleID.isValidPrefix(value) else {
            throw ArgumentError(description: "invalid bundle ID prefix: \(value) (letters, digits, and hyphens, separated by dots)")
        }
        return value
    }

    private static func osVersion(_ value: String) throws -> String {
        guard DeviceSelector.isValidOSVersion(value) else {
            throw ArgumentError(description: "--os requires a version such as 27, 27.0, or 26.5")
        }
        return value
    }

    /// The synopses at the top of the usage of the commands other than the runner commands, in order, each
    /// with the command names it shows. The usage is built from it, and so is `commandNames`, so a command
    /// added here is known everywhere.
    static let commandSynopses: [(names: [String], synopsis: String)] = [
        (["start"], """
        relay start [--udid <UDID> | --device <NAME>] [--simulator] [--os <VERSION>] [--team-id <TEAM_ID>] [--project <PATH>] [--port 8100] [--rebuild] [--verbose]
                    [--ready-timeout 180] [--allow-wifi] [--background]
        """),
        (["status"], "relay status [--json] [--runner <PATH>]"),
        (["stop"], "relay stop [--runner <PATH>]"),
        (["record"], "relay record start [-o <file>] [--force] [--max-duration 600] [--runner <PATH>] | relay record stop | relay record status [--json]"),
        (["install", "uninstall"], "relay install [--project <PATH>] [--build [--verbose]] | relay install --remove | relay uninstall"),
        (["skill"], "relay skill install [--global | --dir <skills dir>] [--link] [--force] | relay skill uninstall | relay skill status"),
        (["devices"], "relay devices [--json] [--os <VERSION>]"),
        (["doctor"], "relay doctor [--udid <UDID> | --device <NAME>] [--simulator] [--os <VERSION>] [--project <PATH>]"),
        (["config"], "relay config [get <key> | set <key> <value> | unset <key>]"),
        (["bench"], "relay bench --url <RUNNER_URL> [--count 10] [--tap x,y] [--mode private|xcui] [--token <TOKEN>]"),
        (["run"], "relay run (<file> | - | --step <step>...) [--check] [--runner <PATH>] [--quiet]   (experimental)")
    ]

    /// Every command name of relay: the commands of `commandSynopses`, the runner commands, and the
    /// lifecycle commands (status, stop, run).
    static var commandNames: Set<String> {
        Set(commandSynopses.flatMap(\.names)).union(runnerUsages.keys).union(lifecycleUsages.keys)
    }

    static let usage = """
    Usage:
    \(commandSynopses.map { $0.synopsis.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") }.joined(separator: "\n"))

    start    Builds the RelayRunner XCTest runner if needed (no build yet, its sources changed, or another
             Xcode SDK), launches it on the device or simulator, and prints the runner URL once it answers /health. The URL and a per-launch access token
             are saved to ~/.relay/runner.json (mode 0600) and removed on exit. Ctrl-C shuts the runner down.
             Without --udid or --device it uses the only connected device, else the only booted simulator;
             --simulator leaves devices out (to try a simulator with a device connected), and --os 27 or
             --os 26.5 keeps those whose OS version starts with it. --device picks, of several with that name,
             the only connected or booted one, else the simulator with the newest iOS, and prints which.
             A shut-down simulator named with --udid/--device is booted, and shut down again on exit.
             For devices, the Team ID defaults to teamID in ~/.relay/config.json, else the team of the
             Apple Development certificates in the keychain; the one used is saved there. The runner's host
             app is <prefix>.RelayRunnerHost (prefix: bundleIDPrefix in config.json, else dev.devicerelay.<team
             id in lowercase>, else dev.devicerelay.local); the runner commands take host for its bundle ID.
             The runner project is --project, else $RELAY_HOME, else a device-relay checkout around the
             current directory, else the copy relay install made in ~/.relay/runner, else the checkout of
             the relay executable. Builds and logs go to ~/.relay/build and ~/.relay/logs.
             Devices are reached over the CoreDevice tunnel only; --allow-wifi also tries the device's
             Wi-Fi addresses, where the token travels as plain HTTP.
             --background runs it detached from the terminal (log: ~/.relay/logs/start-*.log) and exits once
             the runner is ready, printing ready: <url>; relay stop stops it. Agents and CI should use
             relay start --background, then the runner commands, then relay stop.
    status   Shows the runner in runner.json (URL, device, relay start pid, start time), whether /ping
             answers, and the build it reports (relay version and runner source hash). Exits 0 if it does, 3 if there is no runner or it does not answer, 4 if it answers 401
             (the token in runner.json is not that runner's).
    stop     Stops relay start (SIGTERM, like Ctrl-C), which shuts the runner down, shuts down a simulator
             it booted, and removes runner.json. Prints "not running" (exit 0) if nothing runs.
             A recording (relay record) of that runner is finished first.
    record   Records the screen of the runner's simulator, or of its device connected with USB, to an MP4
             (detached from the terminal) until relay record stop, which prints the video's path, or until
             --max-duration seconds. A device needs camera access for the terminal. relay record --help for details.
    install  Copies the runner project and the agent skill from the device-relay checkout (--project,
             $RELAY_HOME, or the one the relay executable was built in) to ~/.relay/runner, replacing a
             previous copy, and records the relay version. --build also builds it for simulators (log: ~/.relay/logs/build-*.log;
             --verbose also shows xcodebuild's output). --remove (or relay uninstall) deletes
             ~/.relay/runner and its builds; config.json and runner.json stay.
    skill    Installs the device-relay agent skill into .claude/skills of the current git repository
             (--global: ~/.claude/skills; relay skill --help for details).
    devices  Lists devices (devicectl) and iOS simulators (simctl): name, UDID, kind, OS, and state.
             --os lists those of that OS version only.
    doctor   Checks Xcode, the runner project, the agent skill, signing, and the device relay start would
             use (with the same --udid, --device, --simulator, and --os), marking each ✓ / ✗ / ! with a fix.
             Exits 1 if anything is ✗.
    config   Shows or changes ~/.relay/config.json (keys: teamID, bundleIDPrefix). bundleIDPrefix replaces the
             runner's default bundle ID prefix, dev.devicerelay.<team id in lowercase>.
    bench    Measures round-trip latency of /health, /screenshot, and optionally /tap.
             --mode forces the runner's touch path (private event synthesis or public XCUI).
             --token defaults to the token in the runner.json the runner commands use.
    run      Experimental; the format may change. Runs runner commands, one per line (without relay), in order
             in one process, after checking them all; stops at the first that fails and exits with its status.
             relay run --help for details.

    Runner commands (operate the runner relay start launched; relay <command> --help for details):
    \(runnerCommandOrder.map { "  " + runnerUsages[$0]!.synopsis }.joined(separator: "\n"))

    \(runnerCommonUsage)
    """
}
