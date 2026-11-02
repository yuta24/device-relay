import Foundation

/// Arguments of the runner commands (`relay tap`, `relay screenshot`, ...), which send one request each
/// to the runner `relay start` launched.
extension Arguments {
    /// Options of each runner command; every one also takes `--runner`. `-o` is short for `--output`.
    static let runnerOptions: [String: Set<String>] = [
        "screenshot": ["--output", "--format", "--quality", "--max-size", "--scale"],
        "source": ["--format", "--max-depth", "--filter", "--bundle-id"],
        "find": selectorOptions.union(["--limit", "--timeout", "--bundle-id"]),
        "tap": selectorOptions.union(["--mode", "--timeout", "--bundle-id"]),
        "press": selectorOptions.union(["--duration", "--mode", "--timeout", "--bundle-id"]),
        "swipe": ["--duration", "--hold", "--mode"],
        "type": ["--key", "--bundle-id"],
        "key": ["--bundle-id"]
    ]
    static let selectorOptions: Set<String> = ["--id", "--label", "--type", "--value", "--index"]
    /// Options without a value.
    static let runnerFlags: [String: Set<String>] = [
        "type": ["--stdin"],
        "find": ["--require"]
    ]

    static let buttons = ["home", "volumeUp", "volumeDown"]
    static let orientations = ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"]

    /// Parses `relay <command> [arguments] [options]`. Every option but the `runnerFlags` takes a value,
    /// and options and arguments may come in any order; `--` ends the options, for text that starts with `-`.
    static func parseRunnerCommand(_ name: String, _ raw: [String], standardInput: () -> Data) throws -> Command {
        let allowed = (runnerOptions[name] ?? []).union(["--runner"])
        let flags = runnerFlags[name] ?? []
        var rest = raw
        var values: [String: [String]] = [:]
        var givenFlags: Set<String> = []
        var positionals: [String] = []
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            if argument == "--" {
                positionals += rest
                break
            }
            if argument == "-h" || argument == "--help" {
                return .commandHelp(name)
            }
            // Negative numbers are arguments, not options.
            guard argument.hasPrefix("-"), argument.count > 1, Double(argument) == nil else {
                positionals.append(argument)
                continue
            }
            let option = argument == "-o" ? "--output" : argument
            if flags.contains(option) {
                givenFlags.insert(option)
                continue
            }
            guard allowed.contains(option) else {
                throw ArgumentError(description: "unknown option for \(name): \(argument)")
            }
            // An empty value would reach the runner as "not given" (`--bundle-id ""` means the foreground app).
            guard !rest.isEmpty, !rest[0].hasPrefix("--"), !rest[0].isEmpty else {
                throw ArgumentError(description: "\(argument) requires a value")
            }
            values[option, default: []].append(rest.removeFirst())
        }

        var parser = RunnerArgumentValues(command: name, values: values, positionals: positionals)
        if givenFlags.contains("--stdin") {
            guard positionals.isEmpty else {
                throw ArgumentError(description: "\(name) takes either <text> or --stdin, not both")
            }
            parser.standardInputText = try text(fromStandardInput: standardInput())
        }
        let operation = try parser.operation()
        return .runner(RunnerControlOptions(operation: operation, runnerPath: try parser.string("--runner"),
                                            requireMatch: givenFlags.contains("--require")))
    }

    /// Text piped to `relay type --stdin`, without one trailing line break (`\n` or `\r\n`) such as
    /// `echo` adds. Reading it keeps secrets out of `ps` and the shell history.
    static func text(fromStandardInput data: Data) throws -> String {
        var bytes = data
        if bytes.last == UInt8(ascii: "\n") {
            bytes.removeLast()
            if bytes.last == UInt8(ascii: "\r") {
                bytes.removeLast()
            }
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ArgumentError(description: "standard input is not UTF-8 text")
        }
        return text
    }

    /// The usage of a runner command, or the whole usage for anything else.
    static func usage(for name: String?) -> String {
        if let name, let command = lifecycleUsages[name] {
            return "Usage:\n  \(command.synopsis)\n\n\(command.details)"
        }
        guard let name, let command = runnerUsages[name] else { return usage }
        return "Usage:\n  \(command.synopsis)\n\n\(command.details)\n\n\(runnerCommonUsage)"
    }

    /// What a parse error prints: the command's synopsis for a runner command, the whole usage otherwise.
    static func errorUsage(for name: String?) -> String {
        if name == "skill" { return SkillCommand.errorUsage }
        guard let name, let command = runnerUsages[name] ?? lifecycleUsages[name] else { return usage }
        return "Usage:\n  \(command.synopsis)\nRun relay \(name) --help for details."
    }

    /// Synopsis and description of each runner command, for `relay <command> --help`.
    static let runnerUsages: [String: (synopsis: String, details: String)] = [
        "ping": ("relay ping", "Checks that the runner is alive; answers at once even while a command runs (busy, busyForMs)."),
        "health": ("relay health", "Device, screen size in points, orientation, touch path, and foreground app."),
        "foreground": ("relay foreground", "The foreground app's bundle ID and pid."),
        "screenshot": (
            "relay screenshot [-o <file>|-] [--format png|jpeg] [--quality 0.05-1.0] [--max-size <px>] [--scale <px/pt>]",
            """
            Saves a screenshot and prints its absolute path. Without -o it goes to $TMPDIR/relay/screenshot-<time>.png;
            -o - writes the image to stdout instead. A .jpg/.jpeg file or --quality selects jpeg (quality 0.7 by default).
            The runner shrinks the image to --max-size pixels on the longer edge and to --scale pixels per point
            (--scale 1: one pixel per point); it never enlarges it. Shrunk, relay also prints the image size, the
            screen in points, and the pixels per point to stderr. Taps always take points: divide pixels by the scale.
            """
        ),
        "source": (
            "relay source [--format json|text|compact] [--filter interactive] [--max-depth <n>] [--bundle-id <id>]",
            """
            Prints the element tree of the foreground app (or --bundle-id). --max-depth 0 is the root only.
            --format compact prints one line per element (type, label, id, value, placeholder, frame).
            --filter interactive lists only the enabled controls on screen that a selector can name (buttons, cells,
            text fields, switches, ...; not keyboard keys), as a flat list of elements (json) or lines (compact).
            """
        ),
        "find": (
            "relay find <selector> [--limit 20] [--timeout <s>] [--require] [--bundle-id <id>]",
            """
            Lists the elements that match every given condition exactly (at most --limit, 1-100). --timeout waits
            up to 10 seconds for a match. An element's index works as --index of tap and press.
            No match is exit 0 ("count":0); with --require it is exit 6, the answer going to stderr with
            relay: no element matched (also when --index is out of range), so find --timeout <s> --require
            waits for an element and fails if it does not appear.
            """
        ),
        "tap": (
            "relay tap (<x> <y> | <selector>) [--mode private|xcui] [--timeout <s>] [--bundle-id <id>]",
            """
            Taps a point (points in the displayed orientation) or the center of the element the selector picks.
            --timeout (up to 10 seconds) and --bundle-id apply to a selector only.
            """
        ),
        "press": (
            "relay press (<x> <y> | <selector>) [--duration 1.0] [--mode private|xcui] [--timeout <s>] [--bundle-id <id>]",
            "Long-presses like tap does, for --duration seconds."
        ),
        "swipe": (
            "relay swipe <x1> <y1> <x2> <y2> [--duration 0.3] [--hold 0.05] [--mode private|xcui]",
            "Holds at the first point for --hold seconds, then drags to the second over --duration seconds."
        ),
        "type": (
            "relay type [<text> | --stdin] [--key return|delete|space]... [--bundle-id <id>]",
            """
            Types text into the element with keyboard focus (tap it first), then sends each --key in order.
            --stdin reads the text from standard input without one trailing newline, which keeps passwords out of
            ps and the shell history (printf 'secret' | relay type --stdin). Put -- before text that starts with -.
            """
        ),
        "key": ("relay key return|delete|space [--bundle-id <id>]", "Sends one special key to the element with keyboard focus."),
        "button": ("relay button home|volumeUp|volumeDown", "Presses a hardware button (the volume buttons on devices only)."),
        "orientation": ("relay orientation portrait|portraitUpsideDown|landscapeLeft|landscapeRight", "Sets the device orientation."),
        "launch": ("relay launch <bundle-id>", "Launches the app, or brings it to the foreground."),
        "terminate": ("relay terminate <bundle-id>", "Terminates the app."),
        "shutdown": ("relay shutdown", "Stops the runner; relay start then exits.")
    ]

    /// `relay status`, `relay stop`, `relay record`, and `relay run`, which manage the runner or run several commands rather
    /// than send it one.
    static let lifecycleUsages: [String: (synopsis: String, details: String)] = [
        "status": (
            "relay status [--json] [--runner <path>]",
            """
            Shows the runner in runner.json: URL, device, the relay start that owns it (pid, whether it still runs,
            start time), and the /ping result (busy included). --json prints one JSON object.
            Exit status: 0 the runner answers /ping, 3 no runner.json or no answer, 4 the token was rejected (401).
            """
        ),
        "stop": (
            "relay stop [--runner <path>]",
            """
            Sends SIGTERM to the relay start in runner.json (like Ctrl-C: it shuts the runner down, shuts down a
            simulator it booted, and removes runner.json) and waits for it to exit. Without that process, it sends
            /shutdown to the runner and removes the stale runner.json. Prints "stopped", or "not running" if nothing
            runs; both exit 0. Exits 1 if relay start does not exit within 60 seconds.
            A recording of that runner (relay record) is finished first; its path goes to stderr.
            """
        ),
        "record": (
            """
            relay record start [-o <file>] [--force] [--max-duration 600] [--runner <path>]
              relay record stop [--runner <path> | --port <n>]
              relay record status [--json] [--runner <path> | --port <n>]
            """,
            """
            Records the screen of the simulator or device the runner in runner.json runs on, to show what
            happened (a video for a pull request, for example): relay record start, then the runner commands,
            then relay record stop.
            start records detached from the terminal (log: ~/.relay/logs/record-*.log), waits until the
            recording has started, and prints the video's absolute path. A simulator is recorded with
            xcrun simctl io <udid> recordVideo --codec h264 --force <file>. A device must be connected with a USB
            cable (not only Wi-Fi) and unlocked: its screen is recorded as a capture device, as QuickTime Player
            does, into H.264 (an MP4, or a QuickTime movie if the file ends in .mov); start returns once the
            first frame is written. This needs camera access for the app relay runs in (the terminal or the
            IDE): the first start asks for it with a macOS dialog, and a denied one is allowed again in System
            Settings > Privacy & Security > Camera.
            Without -o the video goes to $TMPDIR/relay/relay-recording-<time>.mp4; a relative -o is under
            the current directory, whose directory must exist. An existing file is an error unless --force
            replaces it (relay checks before starting). The recording stops by itself after --max-duration
            seconds (600 by default); relay record stop still prints its path.
            One recording per runner: the state is ~/.relay/recording-<port>.json (mode 0600); a second start
            fails while it records, and the state of one that ended does not block the next.
            stop sends SIGINT to the recording (simctl, or relay record supervise for a device), waits up to 30
            seconds for the video to be written, checks that it is not empty, and prints its path; "not recording"
            when there is none. relay stop and the exit of relay start finish a recording of their runner too.
            A simulator shut down while recording ends the video there, and so does a device unplugged while
            recording.
            stop and status use the recording of the runner in runner.json; --port <n> uses the one of that runner
            port directly (also without runner.json; not with --runner). A --runner or $RELAY_RUNNER that does not
            exist is exit 3, as for the other commands. Without them and without runner.json, the only recording
            is used, and several are listed by port to choose one with --port.
            status shows whether it records, the video, and the elapsed time (--json: one object); it exits 0.
            Exit status: 0 ok, 1 not a booted simulator, a device not connected with USB, no camera access, a
              missing directory, an existing file without --force, already recording, the recording failing to
              start (simctl, or no frame from the device), or an empty video, 3 no runner (no runner.json or no
              answer; for stop and status, a --runner or $RELAY_RUNNER that does not exist), 4 the token was
              rejected (401).
            """
        ),
        "run": (
            "relay run (<file> | - | --step <step>...) [--check] [--runner <path>] [--quiet]",
            """
            Experimental: the format and behavior may change. Runs a scenario: runner commands, one per line,
            written as after relay (tap --label General --type button --timeout 5), read from <file>, from
            standard input (-), or from each --step. Blank lines and lines starting with # are skipped (a # later
            in a line is text). Words split like a shell: spaces, '...', "...", and \\ (no variables or globs).
            Steps: \(Scenario.stepCommands.joined(separator: " "))
            sleep <s> waits a fixed time (0 < s <= \(Int(Scenario.maxSleep))); prefer find --timeout or tap --timeout,
            which wait only as long as needed; find --require also stops the run (exit 6) when nothing matches,
            while find without it succeeds either way, as it does alone. screenshot needs --output <file>;
            type --stdin, --runner, and --help cannot be in a step.
            A line # relay-run: 1 before the first step states the format the scenario is written for; another
            version is refused, so a scenario never runs with a meaning it was not written for.
            Every step is checked first: each bad one prints relay: line <n>: <reason> and nothing runs (exit 1;
            the n of a --step is its position). --check stops there: it reads no runner.json and runs nothing,
            and prints relay: <n> steps checked; nothing was run (exit 0; --quiet: nothing).
            Otherwise runner.json is read once (--runner, else $RELAY_RUNNER, ...) and the steps run in this
            process. Each step's output goes to stdout as the command alone prints it; stderr gets
            relay: [i/n] <step> ... ok (<ms> ms) per step and a total at the end (--quiet: neither);
            these lines show the text of type steps as ***.
            The first step that fails stops the run: stderr gets its error and relay: step i/n (line n) failed:
            <step>, and relay run exits with that step's status (3 unavailable, 4 unauthorized, 5 busy, 6 action
            failed, 7 bad request, 8 runner error, 1 a screenshot not saved); 0 when every step succeeds.
            """
        )
    ]

    static let runnerCommandOrder = [
        "ping", "health", "foreground", "screenshot", "source", "find", "tap", "press", "swipe",
        "type", "key", "button", "orientation", "launch", "terminate", "shutdown"
    ]

    static let runnerCommonUsage = """
    <selector>: one or more of --id <identifier> --label <label> --type <type> --value <value>, which must all
      match exactly (the attributes relay source reports), plus --index <n> to pick one of several matches.
    Runner commands read the runner URL and token from runner.json, never from the command line:
      --runner <path>, else $RELAY_RUNNER, else .relay/runner.json in the current directory or a parent,
      else ~/.relay/runner.json (where relay start writes it).
    The runner's JSON is printed to stdout on success and to stderr on failure.
    Exit status: 0 ok, 1 usage or local error, 3 runner unavailable (no runner.json or no connection),
      4 unauthorized (401), 5 busy (409; retry), 6 action failed (422), 7 bad request (other 4xx), 8 runner error.
    """
}

/// The options and arguments of one runner command, turned into a `RunnerOperation`.
private struct RunnerArgumentValues {
    let command: String
    let values: [String: [String]]
    let positionals: [String]
    /// The text of `relay type --stdin`.
    var standardInputText: String?

    func operation() throws -> RunnerOperation {
        switch command {
        case "ping": return try none(.ping)
        case "health": return try none(.health)
        case "foreground": return try none(.foreground)
        case "shutdown": return try none(.shutdown)
        case "screenshot":
            _ = try positional(0, "no arguments (save to a file with -o)")
            var screenshot = RunnerScreenshot(output: try string("--output"))
            screenshot.format = try oneOf("--format", ["png", "jpeg"])
            screenshot.quality = try number("--quality", "a number in 0.05...1.0") { RunnerRequestValues.jpegQualityRange.contains($0) }
            let minSize = RunnerRequestValues.minScreenshotMaxSize
            screenshot.maxSize = try integer("--max-size", "an integer of at least \(minSize) (pixels)") { $0 >= minSize }
            let scales = RunnerRequestValues.screenshotScaleRange
            screenshot.scale = try number("--scale", "a number in \(scales.lowerBound)...\(scales.upperBound) (pixels per point)") {
                scales.contains($0)
            }
            if screenshot.format == nil, let output = screenshot.output,
               ["jpg", "jpeg"].contains(URL(fileURLWithPath: output).pathExtension.lowercased()) {
                screenshot.format = "jpeg"
            }
            if screenshot.quality != nil {
                guard screenshot.format != "png" else {
                    throw ArgumentError(description: "--quality applies to --format jpeg only")
                }
                screenshot.format = "jpeg"
            }
            return .screenshot(screenshot)
        case "source":
            _ = try positional(0, "no arguments")
            var maxDepth: Int?
            if let text = try string("--max-depth") {
                guard let depth = RunnerElementTree.maxDepth(text) else {
                    throw ArgumentError(description: "--max-depth requires a non-negative integer")
                }
                maxDepth = depth
            }
            let format = try oneOf("--format", RunnerElementTree.formats)
            let filter = try oneOf("--filter", [RunnerElementTree.Filter.interactive.rawValue])
            if filter != nil, format == "text" {
                throw ArgumentError(description: "--filter applies to --format json and compact, not text")
            }
            return .source(format: format, maxDepth: maxDepth, filter: filter, bundleID: try string("--bundle-id"))
        case "find":
            _ = try positional(0, "an element selector, not arguments")
            guard let selector = try selector() else {
                throw ArgumentError(description: "find requires an element selector (--id, --label, --type, --value)")
            }
            let maxLimit = RunnerElementLookup.maxFindLimit
            let limit = try integer("--limit", "an integer in 1...\(maxLimit)") { (1...maxLimit).contains($0) }
            return .find(selector, limit: limit, timeout: try timeout(), bundleID: try string("--bundle-id"))
        case "tap":
            return .tap(try touch(duration: nil))
        case "press":
            return .press(try touch(duration: try number("--duration", "seconds greater than zero") { $0 > 0 }))
        case "swipe":
            let xy = try coordinates(try positional(4, "<x1> <y1> <x2> <y2>"))
            return .swipe(
                from: RunnerPoint(x: xy[0], y: xy[1]),
                to: RunnerPoint(x: xy[2], y: xy[3]),
                duration: try number("--duration", "seconds greater than zero") { $0 > 0 },
                hold: try number("--hold", "non-negative seconds") { $0 >= 0 },
                mode: try mode()
            )
        case "type":
            guard positionals.count <= 1 else {
                throw ArgumentError(description: "type takes one text argument; quote text that has spaces")
            }
            let keys = try values["--key", default: []].map(key)
            let text = (standardInputText ?? positionals.first).flatMap { $0.isEmpty ? nil : $0 }
            guard text != nil || !keys.isEmpty else {
                throw ArgumentError(description: "type requires <text>, --stdin with text, or --key")
            }
            return .type(text: text, keys: keys, bundleID: try string("--bundle-id"))
        case "key":
            return .key(try key(try positional(1, "a key name (\(RunnerKey.supportedNames))")[0]), bundleID: try string("--bundle-id"))
        case "button":
            return .button(try choice(try positional(1, "a button name")[0], "button", Arguments.buttons))
        case "orientation":
            return .orientation(try choice(try positional(1, "an orientation")[0], "orientation", Arguments.orientations))
        case "launch":
            return .launch(bundleID: try positional(1, "<bundle-id>")[0])
        case "terminate":
            return .terminate(bundleID: try positional(1, "<bundle-id>")[0])
        default:
            throw ArgumentError(description: "unknown command: \(command)")
        }
    }

    func string(_ option: String) throws -> String? {
        guard let given = values[option] else { return nil }
        guard given.count == 1 else { throw ArgumentError(description: "\(option) is given more than once") }
        return given[0]
    }

    private func number(_ option: String, _ requirement: String, where isValid: (Double) -> Bool) throws -> Double? {
        guard let text = try string(option) else { return nil }
        guard let value = Double(text), value.isFinite, isValid(value) else {
            throw ArgumentError(description: "\(option) requires \(requirement)")
        }
        return value
    }

    private func integer(_ option: String, _ requirement: String, where isValid: (Int) -> Bool) throws -> Int? {
        guard let text = try string(option) else { return nil }
        guard let value = Int(text), isValid(value) else {
            throw ArgumentError(description: "\(option) requires \(requirement)")
        }
        return value
    }

    private func oneOf(_ option: String, _ choices: [String]) throws -> String? {
        guard let value = try string(option) else { return nil }
        guard choices.contains(value) else {
            throw ArgumentError(description: "\(option) requires \(choices.joined(separator: " or "))")
        }
        return value
    }

    private func choice(_ value: String, _ name: String, _ choices: [String]) throws -> String {
        guard choices.contains(value) else {
            throw ArgumentError(description: "unknown \(name) '\(value)' (expected \(choices.joined(separator: ", ")))")
        }
        return value
    }

    /// Key names go to the runner as given (it accepts the same aliases); this only checks them early.
    private func key(_ name: String) throws -> String {
        guard RunnerKey(name: name) != nil else {
            throw ArgumentError(description: "unsupported key '\(name)' (expected \(RunnerKey.supportedNames))")
        }
        return name
    }

    private func none(_ operation: RunnerOperation) throws -> RunnerOperation {
        _ = try positional(0, "no arguments")
        return operation
    }

    private func positional(_ count: Int, _ description: String) throws -> [String] {
        guard positionals.count == count else {
            throw ArgumentError(description: "\(command) takes \(description)")
        }
        return positionals
    }

    private func coordinates(_ texts: [String]) throws -> [Double] {
        try texts.map { text in
            guard let value = Double(text), value.isFinite else {
                throw ArgumentError(description: "invalid coordinate: \(text)")
            }
            return value
        }
    }

    private func timeout() throws -> TimeInterval? {
        let maxTimeout = RunnerElementLookup.maxTimeout
        return try number("--timeout", "seconds in 0...\(Int(maxTimeout))") { (0...maxTimeout).contains($0) }
    }

    private func mode() throws -> String? {
        try oneOf("--mode", ["private", "xcui"])
    }

    /// The `element` built from --id, --label, --type, --value, and --index; nil when none is given.
    /// It is checked with the runner's own parser, so a bad type name fails before anything is sent.
    private func selector() throws -> RunnerElementSelector? {
        var object: [String: Any] = [:]
        for (option, key) in [("--id", "identifier"), ("--label", "label"), ("--type", "type"), ("--value", "value")] {
            object[key] = try string(option)
        }
        object["index"] = try integer("--index", "a non-negative integer") { $0 >= 0 }
        guard !object.isEmpty else { return nil }
        do {
            return try RunnerElementSelector(json: object)
        } catch let error as RunnerElementSelectorError {
            throw ArgumentError(description: error.description)
        }
    }

    private func touch(duration: TimeInterval?) throws -> RunnerTouch {
        let target: RunnerTouch.Target
        switch (positionals.count, try selector()) {
        case (0, let selector?):
            target = .element(selector)
        case (2, nil):
            guard values["--timeout"] == nil, values["--bundle-id"] == nil else {
                throw ArgumentError(description: "--timeout and --bundle-id need an element selector, not <x> <y>")
            }
            let xy = try coordinates(positionals)
            target = .point(RunnerPoint(x: xy[0], y: xy[1]))
        case (_, nil):
            throw ArgumentError(description: "\(command) requires <x> <y> or an element selector (--id, --label, --type, --value)")
        default:
            throw ArgumentError(description: "\(command) takes <x> <y> or an element selector, not both")
        }
        return RunnerTouch(target: target, duration: duration, mode: try mode(), timeout: try timeout(), bundleID: try string("--bundle-id"))
    }
}
