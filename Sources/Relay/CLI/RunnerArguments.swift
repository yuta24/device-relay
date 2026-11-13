import Foundation

/// Arguments of the runner commands (`relay tap`, `relay screenshot`, ...), which send one request each
/// to the runner `relay start` launched.
extension Arguments {
  /// Options of each runner command; every one also takes `--runner` and `--session`. `-o` is short for `--output`.
  static let runnerOptions: [String: Set<String>] = [
    "screenshot": ["--output", "--format", "--quality", "--max-size", "--scale"],
    "source": ["--format", "--max-depth", "--filter", "--bundle-id"],
    "find": selectorOptions.union(["--limit", "--timeout", "--bundle-id"]),
    "tap": selectorOptions.union(["--count", "--mode", "--timeout", "--bundle-id"]),
    "press": selectorOptions.union(["--duration", "--mode", "--timeout", "--bundle-id"]),
    "swipe": ["--duration", "--hold", "--mode"],
    "adjust": selectorOptions.union(["--position", "--picker-value", "--timeout", "--bundle-id"]),
    "type": ["--key", "--bundle-id"],
    "key": ["--bundle-id"],
    "open": ["--bundle-id"]
  ]
  static let selectorOptions: Set<String> = ["--id", "--label", "--type", "--value", "--index"]
  /// Options without a value.
  static let runnerFlags: [String: Set<String>] = [
    "type": ["--stdin", "--clear"],
    "find": ["--require", "--gone"]
  ]

  static let buttons = ["home", "volumeUp", "volumeDown"]
  static let orientations = ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"]
  /// Other names `relay orientation` takes, and the orientation each sends. Resolved here, so the runner
  /// (an older one included) only ever sees the four names above.
  static let orientationAliases = ["landscape": "landscapeLeft"]

  /// Parses `relay <command> [arguments] [options]`. Every option but the `runnerFlags` takes a value,
  /// and options and arguments may come in any order; `--` ends the options, for text that starts with `-`.
  static func parseRunnerCommand(_ name: String, _ raw: [String], standardInput: () -> Data) throws -> Command {
    let allowed = (runnerOptions[name] ?? []).union(["--runner", "--session"])
    // --json does nothing: the output is always JSON. Accepted so a command line written for another tool works.
    let flags = (runnerFlags[name] ?? []).union(["--json"])
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
    parser.gone = givenFlags.contains("--gone")
    parser.clear = givenFlags.contains("--clear")
    let operation = try parser.operation()
    let runnerPath = try parser.string("--runner")
    let session = try parser.string("--session")
    guard runnerPath == nil || session == nil else {
      throw ArgumentError(description: "\(name) takes either --runner or --session, not both")
    }
    return .runner(RunnerControlOptions(operation: operation, runnerPath: runnerPath, session: try session.map(sessionName),
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
      throw SetupError(description: "standard input is not UTF-8 text")
    }
    return text
  }

  /// The usage of a runner command, or the whole usage for anything else.
  static func usage(for name: String?) -> String {
    if name == "runner" {
      return InstallCommand.usage
    }
    if let name, let command = lifecycleUsages[name] {
      return "Usage:\n  \(command.synopsis)\n\n\(command.details)"
    }
    if let name, let help = commandHelp(for: name) { return help }
    guard let name, let command = runnerUsages[name] else { return usage }
    return "Usage:\n  \(command.synopsis)\n\n\(command.details)\n\n\(runnerCommonUsage)"
  }

  /// The help of a command that has no text of its own: its synopsis from `commandSynopses` and its entry
  /// of the overall usage (the lines indented under its name), with that indent removed. Nil for other names.
  static func commandHelp(for name: String) -> String? {
    guard let entry = commandSynopses.first(where: { $0.names.contains(name) }), !["skill", "runner"].contains(name) else { return nil }
    let lines = usage.components(separatedBy: "\n")
    let described = entry.names.first { first in lines.contains { $0.hasPrefix(first + " ") } } ?? name
    guard let start = lines.firstIndex(where: { $0.hasPrefix(described + " ") }) else { return nil }
    let indent = 9
    var description = [String(lines[start].dropFirst(indent))]
    for line in lines[(start + 1)...] {
      guard line.hasPrefix(String(repeating: " ", count: indent)) else { break }
      description.append(String(line.dropFirst(indent)))
    }
    let synopsis = entry.synopsis.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
    let more = commandHelpDetails[name].map { "\n\($0)" } ?? ""
    return "Usage:\n\(synopsis)\n\n\(description.joined(separator: "\n"))\(more)"
  }

  /// What `relay <command> --help` adds to the command's entry of the overall usage: details the overall
  /// usage leaves out to stay short.
  static let commandHelpDetails: [String: String] = [
    "start": """
    Options: --port is the runner's port on the device (8100; a session without it takes a free one in
    8101-8199). --rebuild builds the runner even when the build is current. --verbose shows the build's
    and the runner's output on stderr. --ready-timeout is how many seconds the runner gets from its
    launch to answer /health (180). Build and boot time are not counted: a build has no time limit.
    Output: relay start prints ready: <url> and token: <runner.json path> once the runner answers
    (the token itself is only in runner.json, mode 0600), then runs until Ctrl-C or relay stop.
    --background prints, once ready, the lines ready: <url>, session: <name> (with a session),
    device: <name> (<udid>), pid: <relay start's pid>, log: <its log>, and token: <runner.json path>.
    Exit status: 0 ready (--background), 1 a local failure (no device, a device in use, a failed build,
      the runner failing to start, a port or session already in use), 2 usage, 3 not ready in time
      (--background: not launched within \(Int(BackgroundStart.launchTimeout / 60)) minutes, or no answer within
      --ready-timeout seconds of the launch). Without --background, the exit status after the runner
      ends is that of xcodebuild, or 1.
    """,
    "doctor": """
    ✗ is a problem to fix, and doctor exits 1. ! is a warning (unknown, or worth a look): it does not
    stop relay start, which prints a device's warnings as relay: lines and goes on, and doctor exits 0
    when there is no ✗.
    """
  ]

  /// Synopsis and description of each runner command, for `relay <command> --help`.
  static let runnerUsages: [String: (synopsis: String, details: String)] = [
    "ping": (
      "relay ping",
      """
      Asks whether the runner is alive and whether it is busy with a command (busy, busyForMs), and which
      build it is. It answers at once even while a command runs, and does not touch the device.
      relay health is for what a command needs first (the screen size); relay status also looks at
      runner.json and the relay start behind it.
      """
    ),
    "health": (
      "relay health",
      """
      What to know before operating the device: its model and OS (device), the screen size in points
      (screen; a tap must be inside it), the orientation, the touch and typing paths (touchSynthesis,
      typeSynthesis: private or xcui), and the foreground app. It is a command like the others: while
      another runs it fails with exit 5 (busy); relay ping answers even then.
      displays lists the device's displays ({"id","width","height" in portrait points,"scale","main"}):
      one on most devices, two on iPhone Duo. display is the id of the one the foreground app is on, and
      screen is that display's size; display is null when that cannot be told, and touches and
      screenshots then fail (exit 6).
      """
    ),
    "foreground": ("relay foreground", "The foreground app's bundle ID and pid."),
    "screenshot": (
      "relay screenshot [-o <file>|-] [--format png|jpeg] [--quality 0.05-1.0] [--max-size <px>]\n      [--scale <px/pt>]",
      """
      Saves a screenshot and prints its absolute path (not JSON). Without -o it goes to
      $TMPDIR/relay/screenshot-<time>.png; -o - writes the image to stdout instead, and then a failure's
      JSON goes to stderr, not stdout. A .jpg/.jpeg file or --quality selects jpeg (quality 0.7 by
      default).
      The runner shrinks the image to --max-size pixels on the longer edge and to --scale pixels per point
      (--scale 1: one pixel per point); it never enlarges it. Shrunk, relay also prints the image size,
      the screen in points, and the pixels per point to stderr. Taps always take points: divide pixels by
      the scale.
      """
    ),
    "source": (
      "relay source [--format json|text|compact] [--filter interactive] [--max-depth <n>]\n      [--bundle-id <id>]",
      """
      Prints the element tree of the foreground app (or --bundle-id). --max-depth 0 is the root only.
      --format compact prints one line per element: the type, then label="..", id="..", value="..", and
      placeholder=".." when not empty, frame=x,y,width,height (points), and the flags that apply:
      selected, focused (keyboard focus), disabled, truncated (children cut off by --max-depth).
      --filter interactive lists only the enabled controls on screen that a selector can name (buttons,
      cells, text fields, switches, ...; not keyboard keys), as a flat list of elements (json) or lines
      (compact).
      \(HelpText.wrapped("Types (the names --type takes; a newer type is type<n>): "
          + RunnerElementTree.typeNames.joined(separator: " "), hanging: 2))
      """
    ),
    "find": (
      "relay find <selector> [--limit 20] [--timeout <s>] [--gone] [--require] [--bundle-id <id>]",
      """
      Lists the elements that match every given condition exactly (at most --limit, 1-100). --timeout
      waits up to 10 seconds for a match. Prints {"ok":true,"bundleId":..,"count":n,"elements":[{"index",
      "type","identifier","label","value","frame":{"x","y","width","height"},"enabled"}],
      "truncated":bool}:
      count is every match, elements the first --limit, truncated whether more were left out. index
      counts from 0 in screen order (the tree's order), and works as --index of find, tap, press,
      and adjust.
      No match is exit 0 ("count":0); with --require it is exit 6, the answer (count, elements) coming
      back as {"ok":false,"code":"element_not_found",...} on stdout (also when --index is out of range),
      so find --timeout <s> --require waits for an element and fails if it does not appear.
      --gone waits the other way, up to --timeout, for no element to match (an element counts while it
      is in the tree, off the screen too) and adds "gone":true|false to the answer; --gone --require is
      exit 6 when one is still there ({"ok":false,"code":"element_still_present",...}). --gone cannot
      take --index. The app is the one in front when find starts, as with --timeout.
      """
    ),
    "tap": (
      "relay tap (<x> <y> | <selector>) [--count 2] [--mode private|xcui] [--timeout <s>]\n      [--bundle-id <id>]",
      """
      Taps a point (points in the displayed orientation) or the center of the element the selector picks.
      --count 2 double-taps (zooms a map or a photo, selects a word): both taps go as one gesture, which
      two relay tap commands are not, and the answer has "taps":2.
      --timeout (up to 10 seconds) and --bundle-id apply to a selector only. A point outside the screen (0
      <= x < width, 0 <= y < height as relay health reports it) is rejected with exit 7; nothing is sent.
      --mode xcui (public XCUI, which waits for the app to be idle before and after) is slower than the
      default private path: about 1-2 seconds a tap when measured. relay health shows the default path.
      """
    ),
    "press": (
      "relay press (<x> <y> | <selector>) [--duration 1.0] [--mode private|xcui] [--timeout <s>]\n      [--bundle-id <id>]",
      "Long-presses like tap does, for --duration seconds."
    ),
    "adjust": (
      "relay adjust <selector> (--position <0-1> | --picker-value <value>) [--timeout <s>]\n      [--bundle-id <id>]",
      """
      Sets the slider the selector picks to --position (0 is the left end, 1 the right) or the picker
      wheel to --picker-value (the text it shows: June, 15, 2026 for a date picker's wheels) with XCUI's
      adjust, reads the element again, and prints {"ok":true,"bundleId":..,"element":{..},"value":..}
      (a slider adds "position"; element is as it was found). XCUI leaves a slider up to 0.09 off, so
      the runner then drags it by what is missing until it is within \(RunnerRequestValues.decimal(CGFloat(RunnerAdjusting.positionTolerance))) of --position.
      Pick one wheel of a picker with --type pickerWheel and --value (what it shows now) or --index.
      --timeout (up to 10 seconds) waits for the element, as for tap.
      Another type of element is exit 6 (code element_not_adjustable), and nothing is adjusted. A value
      the wheel does not have, or a slider or wheel that ends elsewhere (a slider of steps, June 31), is
      exit 6 (code adjust_failed) with what it shows now in value (and position): it may have moved.
      A slider takes about 2-4 seconds, a wheel under 1; no correction starts \(Int(RunnerAdjusting.correctionStop)) seconds after
      the adjust did. XCUI waits for the app to be idle before and after (about 60 s each when it never
      is), so relay waits \(Int(RunnerAdjusting.longestAnswer)) s more than other commands for the answer.
      """
    ),
    "swipe": (
      "relay swipe <x1> <y1> <x2> <y2> [--duration 0.3] [--hold 0.05] [--mode private|xcui]",
      """
      Holds at the first point for --hold seconds, then drags to the second over --duration seconds.
      Both points must be on the screen, as for tap (exit 7 otherwise).
      """
    ),
    "type": (
      "relay type [--clear] [<text> | --stdin] [--key return|delete|space]... [--bundle-id <id>]",
      """
      Types text into the element with keyboard focus (tap it first), then sends each --key in order.
      --clear empties that field first (select all and delete, else deletes from the end; wherever the
      cursor is), reads it again, and fails with exit 6 (code clear_failed) without typing when it is
      not empty; alone, it only empties the field. relay waits \(Int(RunnerTyping.clearGiveUp)) seconds more for it.
      --stdin reads the text from standard input without one trailing newline, which keeps passwords out
      of ps and the shell history (printf 'secret' | relay type --stdin). Put -- before text that starts
      with -.
      """
    ),
    "key": ("relay key return|delete|space [--bundle-id <id>]", "Sends one special key to the element with keyboard focus."),
    "button": ("relay button home|volumeUp|volumeDown", "Presses a hardware button (the volume buttons on devices only)."),
    "orientation": (
      "relay orientation portrait|portraitUpsideDown|landscapeLeft|landscapeRight|landscape",
      "Sets the device orientation. landscape is short for landscapeLeft."
    ),
    "launch": (
      "relay launch <bundle-id>",
      """
      Launches the app, or brings it to the foreground. relay first checks with simctl or devicectl that
      the app is installed: if not, it fails at once with app_not_installed (exit 6) and sends nothing
      (relay install <app> installs one). When the check cannot tell (relay: cannot tell whether <id> is
      installed ...), the app is sent anyway; a missing app then keeps the runner busy for minutes.
      com.apple.* apps are not checked on a device. Waits up to 150 seconds for the answer.
      """
    ),
    "open": (
      "relay open <url> [--bundle-id <id>]",
      """
      Opens a URL as tapping a link does: https:// in Safari, a custom scheme (myapp://item/42) in the
      app that registered it, launching it if needed. --bundle-id sends the URL to that app whatever its
      scheme (an https:// link to the app itself, say). Waits up to \(Int(RunnerOpen.foregroundWait)) seconds for the app to
      come to the front, then prints the foreground app ({"ok":true,"foreground":{"bundleId":...}}).
      When the app already in front opens the URL, the whole wait passes unless --bundle-id names it.
      Quote the URL for the shell and percent-encode it: a space or no scheme is a usage error (exit 2).
      A scheme no installed app handles fails with exit 6 (code open_failed). With --bundle-id, relay
      checks the app is installed first, as relay launch does: app_not_installed (exit 6) sends nothing
      (relay install <app> installs one), and when it cannot tell, it prints relay: cannot tell whether
      <id> is installed ... and sends the URL anyway.
      """
    ),
    "terminate": ("relay terminate <bundle-id>", "Terminates the app."),
    "shutdown": (
      "relay shutdown",
      """
      Normally use relay stop. This only sends /shutdown to the runner and returns at once ({"ok":true}).
      The relay start behind it sees the runner end, then removes runner.json and shuts down a simulator
      it booted, a few seconds later and without telling you when it is done; relay stop waits for that
      and prints stopped. If relay start is no longer running, shutdown leaves its runner.json behind,
      which relay stop removes.
      """
    )
  ]

  /// `relay status`, `relay stop`, `relay record`, and `relay run`, which manage the runner or run several commands rather
  /// than send it one.
  static let lifecycleUsages: [String: (synopsis: String, details: String)] = [
    "status": (
      "relay status [--json] [--runner <path> | --session <name> | --all]",
      """
      Shows the runner in runner.json: URL, device, the relay start that owns it (pid, whether it still
      runs, start time), and the /ping result (busy included). --json prints one JSON object. Unlike relay
      ping, it reads runner.json and looks at the relay start behind it, which is why it is the check
      after relay start.
      Exit status: 0 the runner answers /ping, 3 no runner.json or no answer, 4 the token was rejected
      (401).
      --json keys: alive, url, udid, name, runnerInfo (the runner.json path), pid, processRunning,
      startedAt, hostBundleID, session, runner and expectedRunner ({"version","sourceHash"}: what the
      runner reports and what relay start expects), and ping ({"status":200,"busy","busyForMs"}, or
      {"status"} for another answer, or {"error"} when nothing answers).
      With --json, a failure is one JSON object on stdout too
      ({"alive":false,"ok":false,"code":...,"error":...}).
      --all lists every session and the runner of ~/.relay/runner.json instead, one line each: session
      ((default) for that runner), state (starting, running, busy, no answer, rejected, unknown), device,
      URL, and the relay start's pid; --json prints one array of {"session","state","alive","url","udid",
      "name","pid","processRunning","runnerInfo"}. It exits 0 whatever the states are.
      """
    ),
    "stop": (
      "relay stop [--runner <path> | --session <name> | --all]",
      """
      Sends SIGTERM to the relay start in runner.json (like Ctrl-C: it shuts the runner down, shuts down a
      simulator it booted, and removes runner.json) and waits for it to exit. Without that process, it
      sends /shutdown to the runner and removes the stale runner.json. Prints "stopped", or "not running"
      if nothing runs; both exit 0. Exits 1 if relay start does not exit within \(Int(RunnerStop.exitTimeout)) seconds.
      A recording of that runner (relay record) is finished first; its path goes to stderr.
      A session still booting or building (no runner.json yet) is stopped too. --all stops every session
      and the runner of ~/.relay/runner.json, one after the other, printing <session>: stopped for each;
      it also stops other agents' runners, so an agent normally stops only its own session.
      """
    ),
    "record": (
      """
      relay record start [-o <file>] [--force] [--max-duration 600] [--runner <path> | --session <name>]
        relay record stop [--runner <path> | --session <name> | --port <n>]
        relay record status [--json] [--runner <path> | --session <name> | --port <n>]
      """,
      """
      Records the screen of the simulator or device the runner in runner.json runs on, to show what
      happened (a video for a pull request, for example): relay record start, then the runner commands,
      then relay record stop.
      start records detached from the terminal (log: ~/.relay/logs/record-*.log), waits until the
      recording has started, and prints the video's absolute path. A simulator is recorded with xcrun
      simctl io <udid> recordVideo --codec h264 --force <file>. A device must be connected with a USB
      cable (not only Wi-Fi) and unlocked: its screen is recorded as a capture device, as QuickTime Player
      does, into H.264 (an MP4, or a QuickTime movie if the file ends in .mov); start returns once the
      first frame is written. This needs camera access for the app relay runs in (the terminal or the
      IDE): the first start asks for it with a macOS dialog, and a denied one is allowed again in System
      Settings > Privacy & Security > Camera.
      Without -o the video goes to $TMPDIR/relay/relay-recording-<time>.mp4; a relative -o is under the
      current directory, whose directory must exist. An existing file is an error unless --force replaces
      it (relay checks before starting). The recording stops by itself after --max-duration seconds (600
      by default); relay record stop still prints its path.
      One recording per runner: the state is ~/.relay/recording-<port>.json (mode 0600); a second start
      fails while it records, and the state of one that ended does not block the next.
      stop sends SIGINT to the recording (simctl, or relay record supervise for a device), waits up to 30
      seconds for the video to be written, checks that it is not empty, and prints its path; "not
      recording" when there is none. For a device it takes about 4 seconds: the capture must be stopped
      for a few seconds before the next one sees the screen (start tries a new process once when it does
      not).
      relay stop and the exit of relay start finish a recording of their runner too.
      A simulator shut down while recording ends the video there, and so does a device unplugged while
      recording. A device that sends no frame for 5 seconds (locked, for example) keeps recording: the log
      and status note it (the video holds the last frame), and the log notes when frames come again.
      stop and status use the recording of the runner in runner.json; --port <n> uses the one of that
      runner port directly (also without runner.json; not with --runner or --session). A --runner,
      $RELAY_RUNNER, or session that does not exist is exit 3, as for the other commands. Without them and
      without runner.json, the only recording is used, and several are listed by port to choose one with
      --port.
      status shows whether it records, the video, the elapsed time, and a device's frames having stopped
      (--json: one object); it exits 0.
      A device is found among the capture devices by its name: two connected devices with the same name
      cannot be told apart, and start fails (rename one in Settings > General > About, or unplug it).
      Exit status: 0 ok, 1 not a booted simulator, a device not connected with USB, no camera access, a
        missing directory, an existing file without --force, already recording, the recording failing to
        start (simctl, no frame from the device, or two devices of that name), or an empty video, 3 no
        runner (no runner.json or no answer; for stop and status, a --runner or $RELAY_RUNNER that does
        not exist), 4 the token was rejected (401).
      """
    ),
    "logs": (
      """
      relay logs [--bundle-id <id>] [--since 5m] [-o <file>] [<target>]
        relay logs --follow [--bundle-id <id>] [-o <file>] [<target>]
        relay logs --archive <path> [--since <time>] [-o <file>] [<target>]
        <target>: --session <name> | --runner <path> | --udid <udid>
      """,
      """
      Reads the unified log (Logger, os_log, NSLog) of the simulator or device the runner in runner.json
      runs on, on the Mac and without the runner: it works while the runner is busy, and --udid needs no
      runner at all (after relay stop, for example). An app's stdout and stderr (print) are not in it.
      --since 5m (s, m, h, d) or --since 2026-11-11T00:20:00Z (RFC 3339 with a time zone) is where it
      starts; 5 minutes by default. Note the time before a test, and pass it after a failure.
      --bundle-id <id> (host: the runner's host app) keeps the lines of the app's main executable as
      installed now (its UUID): not its extensions, nor lines of an earlier build.
      Prints one JSON object: {"ok":true,"backend":..,"count":n,"device":{..},"entries":[{"category":..,
      "level":..,"message":..,"process":..,"processID":..,"subsystem":..,"timestamp":..}],"filter":..,
      "limitations":[..],"range":{..}}. -o <file> writes it to a new file (mode 0600) and prints a
      summary with its path instead. Debug lines are not kept in the past log; --follow shows them.
      --follow (simulators) prints new lines as NDJSON until SIGINT or SIGTERM: {"type":"start"}, one
      {"type":"log",..} per line, then {"type":"end"} (exit 130 or 143). An error after the start is
      {"type":"error","ok":false,"code":..,"partial":true} (exit 1). With -o the lines go to the file.
      A device's log needs an administrator to collect (log collect --device-udid): relay does not run
      sudo and fails with logs_permission_denied, whose hint is the command to run. --archive <path>
      reads the .logarchive it writes (the whole archive unless --since).
      --bundle-id works on simulators only: on a device or with --archive it is logs_filter_unsupported.
      Exit status: 0 ok (0 lines included), 1 not a booted simulator or a connected device
        (device_unavailable), no administrator (logs_permission_denied), --follow on a device
        (logs_follow_unsupported), --bundle-id where it does not work (logs_filter_unsupported), an
        app that is not installed (log_app_unavailable), log failing or printing more than 64 MiB
        (logs_unavailable), -o not written (logs_save_failed), 2 usage, 3 no runner.json.
      """
    ),
    "crashes": (
      """
      relay crashes [--bundle-id <id>] [--since 24h] [--name <name>] [-o <dir>]
          [--session <name> | --runner <path> | --udid <udid>]
      """,
      """
      Lists the crash reports (.ips) of the simulator or device the runner in runner.json runs on, or of
      --udid, as one JSON object: {"ok":true,"count":n,"reports":[{"name":..,"relativePath":..,..}],..}.
      --since 24h (s, m, h, d) or an RFC 3339 time is where the list starts; 24 hours by default.
      A simulator's are in ~/Library/Logs/DiagnosticReports of the Mac: relay keeps those whose process
      ran in that simulator, with the process, bundleID, and the time it crashed (occurredAt).
      --bundle-id keeps one app's. Reports it cannot read are counted in unreadable.
      A device's come from devicectl (systemCrashLogs) without being opened: the name, the time the file
      was written (modifiedAt), and a processHint from the name; bundleID is null, so --bundle-id is
      crash_filter_unsupported. They are candidates: not all are crashes of an app.
      --name <name> keeps the one with that relativePath, whatever --since and --bundle-id say.
      -o <dir> copies the reports listed into that existing directory (mode 0600) and adds each one's
      path; an existing file is not replaced. On a device, -o copies only the one --name chooses.
      Exit status: 0 ok (0 reports included), 1 not a simulator or a connected device
        (device_unavailable), --bundle-id on a device (crash_filter_unsupported), the list failing
        (crashes_unavailable), a report not saved (crashes_save_failed), 2 usage (-o without --name on
        a device included), 3 no runner.json.
      """
    ),
    "install": (
      "relay install <APP.app | APP.ipa> [--session <name> | --runner <path> | --udid <udid>]",
      """
      Installs an .app or .ipa on the simulator or device of the runner in runner.json (--session,
      --runner, as for relay logs) or of --udid, with simctl install or devicectl device install app; the
      runner is not used, and need not run with --udid. A simulator must be booted (relay does not boot
      it) and a device connected. An app of the same bundle ID is replaced, and a running copy quits.
      Info.plist is read first: an app built for the other kind of device (CFBundleSupportedPlatforms) is
      refused before anything is sent. Waits up to \(Int(AppInstall.installTimeout)) seconds for the tool.
      Prints {"ok":true,"app":{"bundleID","name","version","build","path"},"device":{..}} (device as for
      relay logs). Then relay launch <bundle ID> starts it.
      A failure is {"ok":false,"code":...,"error":...} on stdout.
      Exit status: 0 ok, 1 no such file, not an .app or .ipa, or no readable Info.plist
        (app_bundle_invalid), built for the other kind of device (app_platform_mismatch), the tool
        failing or not done in time (app_install_failed), a simulator not booted, a device not connected,
        or no such UDID (device_unavailable), 2 usage, 3 no runner.json.
      Without an app, relay install still does what relay runner install does, with a note on stderr,
      until the next release.
      """
    ),
    "uninstall": (
      "relay uninstall <BUNDLE_ID> [--session <name> | --runner <path> | --udid <udid>]",
      """
      Removes an app from the simulator or device of the runner in runner.json (--session, --runner, as
      for relay logs) or of --udid, with simctl uninstall or devicectl device uninstall app; the runner is
      not used. A simulator must be booted and a device connected.
      relay checks first that the app is installed, as relay launch does: if not, it fails with
      app_not_installed (exit 6) and removes nothing (a script that only needs it gone can take 6 as
      done). When that cannot be told, the tool is run anyway. relay's own runner apps (host,
      *.RelayRunnerHost, *.RelayRunnerHost.UITests.xctrunner) are refused (app_uninstall_refused).
      Waits up to \(Int(AppInstall.uninstallTimeout)) seconds for the tool.
      Prints {"ok":true,"bundleID":..,"device":{..}}; a failure is {"ok":false,"code":...,"error":...}.
      Exit status: 0 ok, 1 a runner app (app_uninstall_refused), the tool failing or not done in time
        (app_uninstall_failed), a simulator not booted, a device not connected, or no such UDID
        (device_unavailable), 2 usage, 3 no runner.json, 6 not installed (app_not_installed).
      Without a bundle ID, relay uninstall still does what relay runner uninstall does, with a note on
      stderr, until the next release.
      """
    ),
    "run": (
      "relay run (<file> | - | --step <step>...) [--check] [--runner <path> | --session <name>] [--quiet]",
      """
      Experimental: the format and behavior may change. Runs a scenario: runner commands, one per line,
      written as after relay (tap --label General --type button --timeout 5), read from <file>, from
      standard input (-), or from each --step. Blank lines and lines starting with # are skipped (a #
      later in a line is text). Words split like a shell: spaces, '...', "...", and \\ (no variables or
      globs).
      \(HelpText.wrapped("Steps: " + Scenario.stepCommands.joined(separator: " "), hanging: 2))
      sleep <s> waits a fixed time (0 < s <= \(Int(Scenario.maxSleep))); prefer find --timeout or tap --timeout,
      which wait only as long as needed, and find --gone --timeout for an element to go; find --require
      also stops the run (exit 6) when nothing matches (with --gone: when one is left), while find
      without it succeeds either way, as it does alone. screenshot needs --output <file>; type
      --stdin, --runner, --session, and --help cannot be in a step.
      A line # relay-run: 1 before the first step states the format the scenario is written for; another
      version is refused, so a scenario never runs with a meaning it was not written for.
      Every step is checked first: each bad one prints relay: line <n>: <reason> on stderr and nothing
      runs (exit 2, a usage error; the n of a --step is its position). A step takes the options it takes
      alone, --json and --opt=value included. --check stops there: it reads no runner.json and runs
      nothing, and prints relay: <n> steps checked; nothing was run (exit 0; --quiet: nothing).
      Otherwise runner.json is read once (--runner or --session, else $RELAY_RUNNER or $RELAY_SESSION,
      else ~/.relay/runner.json) and the steps run in this process. Each step's output goes to stdout as
      the command alone prints it, one after the other; stderr gets relay: [i/n] <step> ... ok (<ms> ms)
      per step and a total at the end (--quiet: neither); these lines show the text of type steps as ***.
      The first step that fails stops the run: its error is the last JSON on stdout
      ({"ok":false,"code":...}, as the command alone prints it), stderr gets relay: step i/n (line n)
      failed: <step>, and relay run exits with that step's status (3 unavailable, 4 unauthorized, 5 busy,
      6 action failed, 7 bad request, 8 runner error, 1 a screenshot not saved); 0 when every step
      succeeds. A runner.json that cannot be found or reached fails the same way before the first step.
      """
    )
  ]

  static let runnerCommandOrder = [
    "ping", "health", "foreground", "screenshot", "source", "find", "tap", "press", "swipe", "adjust",
    "type", "key", "button", "orientation", "launch", "open", "terminate", "shutdown"
  ]

  /// The runner commands the overall usage lists: all of them. `relay shutdown` comes last, with a note
  /// that `relay stop`, which does more, is what normally stops a runner.
  static let listedRunnerCommands = runnerCommandOrder

  static let runnerCommonUsage = """
  <selector>: one or more of --id <identifier> --label <label> --type <type> --value <value>, which
    must all match exactly (the attributes relay source reports), plus --index <n> to pick one of
    several matches (from 0, in the order relay find lists them). --type takes an element type name
    such as button, cell, staticText, textField, or switch (relay source --help lists them all).
  Runner commands read the runner URL and token from runner.json, never from the command line:
    --runner <path> or --session <name>, else $RELAY_RUNNER or $RELAY_SESSION (both set is an error),
    else ~/.relay/runner.json (where relay start without a session writes it). A session is
    ~/.relay/sessions/<name>/runner.json, with no fallback. A .relay/runner.json in the current
    directory is not read: pass it with --runner. A session name is up to 64 letters, digits, '.',
    '_', and '-', starting with a letter or digit.
  relay waits 30 seconds for the answer, plus what the command itself may wait: --timeout (find, tap,
    press, adjust), --duration and --hold (press, swipe), \(Int(RunnerAdjusting.longestAnswer)) s (adjust), 120 s (launch, open,
    terminate: 150 s in all), 0.1 s a character and 1 s a key (type, key), \(Int(RunnerTyping.clearGiveUp)) s more for type
    --clear. Past that it fails with runner_timeout (exit 3), but the runner keeps at the command and
    stays busy (exit 5 for others) until it ends: wait until relay ping shows "busy":false.
  Output is always JSON (a screenshot prints the saved file's path); --json is accepted, not needed.
  A failure is JSON on stdout too: the runner's {"ok":false,"code":...,"error":...}, or relay's own in
    that shape when it fails before the runner answers (code runner_unavailable, runner_timeout,
    runner_info_invalid, app_not_installed, ...). relay: lines on stderr are hints for people.
    Exception: screenshot -o - writes the image to stdout, so a failure's JSON goes to stderr.
  Options may be written --opt value or --opt=value; text after -- is never split.
  Exit status: 0 ok, 1 local failure (runner.json unreadable, screenshot not saved; for relay install
    and uninstall, the app or device), 2 usage error (the command line is wrong: two relay: lines on
    stderr, no JSON), 3 runner unavailable (no runner.json, no connection, or no answer in time), 4
    unauthorized (401), 5 busy (409; retry), 6 action failed (422, or app_not_installed from launch,
    open --bundle-id, and uninstall), 7 bad request (other 4xx), 8 runner error.
  """
}

/// The options and arguments of one runner command, turned into a `RunnerOperation`.
private struct RunnerArgumentValues {
  let command: String
  let values: [String: [String]]
  let positionals: [String]
  /// The text of `relay type --stdin`.
  var standardInputText: String?
  /// `relay find --gone`.
  var gone = false
  /// `relay type --clear`.
  var clear = false

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
      let limit = try integer("--limit", "an integer in 1...\(maxLimit)") { (1 ... maxLimit).contains($0) }
      if gone, selector.index != nil {
        throw ArgumentError(description: "--gone cannot be combined with --index (it waits for every match to go)")
      }
      return .find(selector, limit: limit, timeout: try timeout(), bundleID: try string("--bundle-id"), gone: gone)
    case "tap":
      var touch = try touch(duration: nil)
      let maxTaps = RunnerRequestValues.maxTaps
      touch.taps = try integer("--count", "1 or \(maxTaps) (\(maxTaps) is a double tap)") { (1 ... maxTaps).contains($0) }
      return .tap(touch)
    case "press":
      return .press(try touch(duration: try number("--duration", "seconds greater than zero") { $0 > 0 }))
    case "adjust":
      _ = try positional(0, "an element selector, not arguments")
      guard let selector = try selector() else {
        throw ArgumentError(description: "adjust requires an element selector (--id, --label, --type, --value)")
      }
      let target: RunnerAdjusting.Target
      switch (try number("--position", "a number in 0...1 (0 is the left end)") { (0 ... 1).contains($0) },
              try string("--picker-value")) {
      case (let position?, nil): target = .position(position)
      case (nil, let value?): target = .pickerValue(value)
      case (nil, nil): throw ArgumentError(description: "adjust requires --position <0-1> (a slider) or --picker-value <value> (a picker wheel)")
      case (_?, _?): throw ArgumentError(description: "adjust takes either --position or --picker-value, not both")
      }
      return .adjust(selector, target, timeout: try timeout(), bundleID: try string("--bundle-id"))
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
      guard text != nil || !keys.isEmpty || clear else {
        throw ArgumentError(description: "type requires <text>, --stdin with text, --key, or --clear")
      }
      return .type(text: text, keys: keys, bundleID: try string("--bundle-id"), clear: clear)
    case "key":
      return .key(try key(try positional(1, "a key name (\(RunnerKey.supportedNames))")[0]), bundleID: try string("--bundle-id"))
    case "button":
      return .button(try choice(try positional(1, "a button name")[0], "button", Arguments.buttons))
    case "orientation":
      let name = try positional(1, "an orientation")[0]
      let orientations = Arguments.orientations + Arguments.orientationAliases.keys.sorted()
      if let alias = Arguments.orientationAliases[name] {
        return .orientation(alias)
      }
      return .orientation(try choice(name, "orientation", orientations))
    case "launch":
      return .launch(bundleID: try positional(1, "<bundle-id>")[0])
    case "open":
      let text = try positional(1, "<url> (quote it for the shell)")[0]
      switch RunnerOpen.url(text) {
      case .success: return .open(url: text, bundleID: try string("--bundle-id"))
      case .failure(let error): throw ArgumentError(description: error.description)
      }
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
    return try number("--timeout", "seconds in 0...\(Int(maxTimeout))") { (0 ... maxTimeout).contains($0) }
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
