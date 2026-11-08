import Foundation

/// `relay run` (experimental): runner commands, one per line, run in order in this process.
///
/// Every step is checked before the first one runs; the run stops at the first step that fails and exits
/// with that step's status. runner.json is read once. The format may still change.
struct ScenarioOptions: Equatable {
  enum Source: Equatable {
    /// `relay run <file>`.
    case file(String)
    /// `relay run -`.
    case standardInput
    /// `relay run --step <step> [--step ...]`, one step each.
    case steps([String])
  }

  var source: Source
  /// `--runner <path>`, for every step; steps cannot name their own.
  var runnerPath: String?
  /// `--session <name>`, for every step.
  var session: String?
  /// `--quiet`: no progress line per step and no summary; a failure is still reported.
  var quiet = false
  /// `--check`: check every step and stop there, without reading runner.json or running anything.
  var check = false
}

/// One checked step and where it came from.
struct ScenarioStep: Equatable {
  enum Action: Equatable {
    /// `requireMatch`: `find --require`, as `RunnerControlOptions.requireMatch`.
    case runner(RunnerOperation, requireMatch: Bool = false)
    /// `sleep <seconds>`, a fixed wait; `find --timeout` should come first.
    case sleep(TimeInterval)
  }

  /// The line in the file or standard input, or the position of the `--step`.
  let line: Int
  /// The step as written, without surrounding spaces, for progress and failure lines; the text of a
  /// `type` step is masked (see `Scenario.displayText`).
  let text: String
  let action: Action
}

/// A step that cannot run; nothing runs when any step has one.
struct ScenarioLineError: Error, CustomStringConvertible, Equatable {
  let line: Int
  let reason: String

  var description: String { "line \(line): \(reason)" }
}

/// Every bad step of a scenario, so all of them can be fixed at once.
struct ScenarioLineErrors: Error, CustomStringConvertible, Equatable {
  let errors: [ScenarioLineError]

  /// One `line <n>: <reason>` per line; `relay: ` goes before each when printed.
  var description: String { errors.map(\.description).joined(separator: "\nrelay: ") }
}

enum Scenario {
  /// The runner commands a step may use. `shutdown` is left out: the steps after it could not run, and
  /// `relay stop` is what cleans up.
  static let stepCommands = Arguments.runnerCommandOrder.filter { $0 != "shutdown" } + ["sleep"]
  /// Upper bound of `sleep`, in seconds. Longer waits are better as `find --timeout` repeated.
  static let maxSleep: TimeInterval = 60
  /// The format this relay reads. A scenario may state the one it was written for in a
  /// `# relay-run: <version>` line before its first step; older relays skip that line as a comment.
  static let formatVersion = "1"
  static let formatKey = "relay-run:"

  /// Numbered lines of a file or standard input. A UTF-8 byte order mark at the start (some Windows
  /// editors write one) and the `\r` of CRLF are dropped.
  static func lines(of text: String) -> [(number: Int, text: String)] {
    var scalars = text.unicodeScalars[...]
    if scalars.first == "\u{FEFF}" {
      scalars = scalars.dropFirst()
    }
    return String(scalars).components(separatedBy: "\n").enumerated().map { index, line in
      (index + 1, line.hasSuffix("\r") ? String(line.dropLast()) : line)
    }
  }

  /// Checks every line and returns the steps. Blank lines and lines that start with `#` are skipped.
  /// Throws `ScenarioLineErrors` with every bad line, or `ArgumentError` when there is no step.
  static func parse(_ lines: [(number: Int, text: String)]) throws -> [ScenarioStep] {
    var steps: [ScenarioStep] = []
    var errors: [ScenarioLineError] = []
    var sawStepOrError = false
    for (number, raw) in lines {
      let text = raw.trimmingCharacters(in: .whitespaces)
      if let version = formatLine(text) {
        if sawStepOrError {
          errors.append(ScenarioLineError(line: number, reason: "# \(formatKey) goes before the first step"))
        } else if version != formatVersion {
          errors.append(ScenarioLineError(line: number, reason: version.isEmpty
              ? "# \(formatKey) requires a format version (this relay reads \(formatVersion))"
              : "unsupported scenario format \(version) (this relay reads \(formatVersion))"))
        }
        continue
      }
      if text.isEmpty || text.hasPrefix("#") { continue }
      sawStepOrError = true
      do {
        let words = try ScenarioTokenizer.split(text)
        steps.append(ScenarioStep(line: number, text: displayText(text, words: words), action: try action(words)))
      } catch let error as ArgumentError {
        errors.append(ScenarioLineError(line: number, reason: error.description))
      }
    }
    guard errors.isEmpty else { throw ScenarioLineErrors(errors: errors) }
    guard !steps.isEmpty else {
      throw ArgumentError(description: "run found no steps (blank lines and # comments are skipped)")
    }
    return steps
  }

  /// One step's words, checked as `relay <command>` would check them, minus what a step cannot do.
  static func action(_ words: [String]) throws -> ScenarioStep.Action {
    guard let name = words.first else { throw ArgumentError(description: "empty step") }
    let rest = try Arguments.splittingEquals(Array(words.dropFirst()))
    if name == "relay" {
      throw ArgumentError(description: "write steps without the leading relay (tap ..., not relay tap ...)")
    }
    if name == "sleep" {
      guard rest.count == 1, let seconds = TimeInterval(rest[0]), seconds.isFinite, seconds > 0, seconds <= maxSleep else {
        throw ArgumentError(description: "sleep takes one number of seconds in (0, \(Int(maxSleep))]")
      }
      return .sleep(seconds)
    }
    guard stepCommands.contains(name) else {
      throw ArgumentError(description: (Arguments.commandNames.contains(name) ? "\(name) cannot be a step" : "unknown step: \(name)")
        + " (steps: \(stepCommands.joined(separator: ", ")))")
    }
    let options = optionWords(name, rest)
    for option in ["--runner", "--session"] where options.contains(option) {
      throw ArgumentError(description: "\(option) goes to relay run, not to a step")
    }
    if options.contains("-h") || options.contains("--help") {
      throw ArgumentError(description: "--help cannot be a step")
    }
    if name == "type", options.contains("--stdin") {
      throw ArgumentError(description: "type --stdin cannot be a step (standard input is not the step's)")
    }
    guard case .runner(let options) = try Arguments.parseRunnerCommand(name, rest, standardInput: { Data() }) else {
      throw ArgumentError(description: "\(name) cannot be a step")
    }
    if case .screenshot(let screenshot) = options.operation, screenshot.output == nil || screenshot.output == "-" {
      throw ArgumentError(description: "screenshot needs --output <file> in a step (stdout carries the other steps' output)")
    }
    return .runner(options.operation, requireMatch: options.requireMatch)
  }

  /// The version of a `# relay-run: <version>` line, empty when none is given; nil for any other line.
  static func formatLine(_ text: String) -> String? {
    guard text.hasPrefix("#") else { return nil }
    let comment = text.dropFirst().trimmingCharacters(in: .whitespaces)
    guard comment.hasPrefix(formatKey) else { return nil }
    return comment.dropFirst(formatKey.count).trimmingCharacters(in: .whitespaces)
  }

  /// The words of a step in option position, as `Arguments.parseRunnerCommand` reads them: not the value
  /// of an option (`--label -h` is a label), and nothing after `--` (text to type).
  static func optionWords(_ name: String, _ words: [String]) -> [String] {
    let takesValue = (Arguments.runnerOptions[name] ?? []).union(["--runner", "--session", "-o"])
    var options: [String] = []
    var rest = words[...]
    while let word = rest.popFirst() {
      if word == "--" { break }
      guard isOption(word) else { continue }
      options.append(word)
      if takesValue.contains(word), let value = rest.first, !value.hasPrefix("--"), !value.isEmpty {
        rest.removeFirst()
      }
    }
    return options
  }

  /// The step for progress and failure lines (stderr, often kept in logs). The text of `type` becomes `***`:
  /// a scenario has no `--stdin`, so a password could only be written in it. Other steps are shown as written.
  static func displayText(_ text: String, words: [String]) -> String {
    guard words.first == "type" else { return text }
    let takesValue = Arguments.runnerOptions["type"] ?? []
    var shown = ["type"]
    var rest = words.dropFirst()
    var onlyText = false
    while let word = rest.popFirst() {
      if !onlyText, word == "--" {
        onlyText = true
        shown.append(word)
      } else if !onlyText, isOption(word) {
        shown.append(word)
        if takesValue.contains(word), let value = rest.popFirst() {
          shown.append(value)
        }
      } else {
        shown.append("***")
      }
    }
    return shown.joined(separator: " ")
  }

  /// An option rather than an argument, as the runner commands tell them apart (negative numbers are arguments).
  private static func isOption(_ word: String) -> Bool {
    word.hasPrefix("-") && word.count > 1 && Double(word) == nil
  }

  /// Runs the steps in order and stops at the first that fails. `perform` runs one runner operation (with
  /// `requireMatch` of `find --require`) and returns its exit status, printing its output as the command does.
  static func execute(
    _ steps: [ScenarioStep],
    quiet: Bool = false,
    perform: (RunnerOperation, _ requireMatch: Bool) -> Int32,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    log: (String) -> Void = { FileHandle.standardError.write(Data("relay: \($0)\n".utf8)) }
  ) -> Int32 {
    let startedAt = now()
    func milliseconds(since start: UInt64) -> Int { Int((now() - start) / 1_000_000) }

    for (index, step) in steps.enumerated() {
      let position = "\(index + 1)/\(steps.count)"
      let stepStartedAt = now()
      let status: Int32
      switch step.action {
      case .runner(let operation, let requireMatch):
        status = perform(operation, requireMatch)
      case .sleep(let seconds):
        sleep(seconds)
        status = RunnerExitCode.success.rawValue
      }
      guard status == RunnerExitCode.success.rawValue else {
        log("step \(position) (line \(step.line)) failed: \(step.text)")
        if !quiet {
          log("\(index) of \(steps.count) steps succeeded in \(milliseconds(since: startedAt)) ms; exit status \(status)")
        }
        return status
      }
      if !quiet {
        log("[\(position)] \(step.text) ... ok (\(milliseconds(since: stepStartedAt)) ms)")
      }
    }
    if !quiet {
      log("\(steps.count) of \(steps.count) steps succeeded in \(milliseconds(since: startedAt)) ms")
    }
    return RunnerExitCode.success.rawValue
  }
}

/// Splits a step into words like a shell, minimally: spaces and tabs separate words; '...' keeps everything
/// as is; "..." keeps everything but \" and \\; outside quotes \ keeps the next character. No variables,
/// globs, or comments: `#` in the middle of a line is text.
enum ScenarioTokenizer {
  static func split(_ line: String) throws -> [String] {
    var words: [String] = []
    var word = ""
    // A word exists once anything is written, so '' is an empty word rather than nothing.
    var inWord = false
    var characters = line.makeIterator()
    while let character = characters.next() {
      switch character {
      case " ", "\t":
        if inWord {
          words.append(word)
          word = ""
          inWord = false
        }
      case "'":
        inWord = true
        while true {
          guard let next = characters.next() else { throw ArgumentError(description: "unterminated ' quote") }
          if next == "'" { break }
          word.append(next)
        }
      case "\"":
        inWord = true
        while true {
          guard let next = characters.next() else { throw ArgumentError(description: "unterminated \" quote") }
          if next == "\"" { break }
          if next == "\\" {
            guard let escaped = characters.next() else { throw ArgumentError(description: "unterminated \" quote") }
            if escaped != "\"" && escaped != "\\" {
              word.append(next)
            }
            word.append(escaped)
          } else {
            word.append(next)
          }
        }
      case "\\":
        guard let escaped = characters.next() else { throw ArgumentError(description: "\\ at the end of the line") }
        inWord = true
        word.append(escaped)
      default:
        inWord = true
        word.append(character)
      }
    }
    if inWord {
      words.append(word)
    }
    return words
  }
}

/// `relay run`: reads the steps, checks them all, reads runner.json once, and runs them.
enum ScenarioCommand {
  static func run(
    _ options: ScenarioOptions,
    readFile: (String) throws -> String = { path in
      try String(contentsOf: RunnerLocator.resolve(path, in: WorkingDirectory.url), encoding: .utf8)
    },
    standardInput: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
  ) -> Int32 {
    let steps: [ScenarioStep]
    do {
      steps = try Scenario.parse(try lines(options.source, readFile: readFile, standardInput: standardInput))
    } catch let error as SetupError {
      // The file or standard input could not be read: not a mistake in the steps.
      CLIOutput.note(error.description)
      return RunnerExitCode.failure.rawValue
    } catch {
      // Steps that are wrong are exit 2, as a wrong command line is; nothing has run.
      return CLIOutput.usageError("\(error)", command: "run")
    }
    if options.check {
      if !options.quiet {
        FileHandle.standardError.write(Data("relay: \(checkedSummary(steps.count))\n".utf8))
      }
      return RunnerExitCode.success.rawValue
    }
    let connection: RunnerConnection
    switch RunnerControl.connect(runnerPath: options.runnerPath, session: options.session, command: "run") {
    case .success(let found): connection = found
    case .failure(let failure): return failure.code
    }
    return Scenario.execute(steps, quiet: options.quiet) { operation, requireMatch in
      RunnerControl.perform(operation, on: connection, requireMatch: requireMatch)
    }
  }

  /// What `--check` prints when every step is fine.
  static func checkedSummary(_ count: Int) -> String {
    "\(count) step\(count == 1 ? "" : "s") checked; nothing was run"
  }

  static func lines(
    _ source: ScenarioOptions.Source,
    readFile: (String) throws -> String,
    standardInput: () -> Data
  ) throws -> [(number: Int, text: String)] {
    switch source {
    case .file(let path):
      do {
        return Scenario.lines(of: try readFile(path))
      } catch {
        throw SetupError(description: "cannot read \(path): \(error.localizedDescription)")
      }
    case .standardInput:
      guard let text = String(data: standardInput(), encoding: .utf8) else {
        throw SetupError(description: "standard input is not UTF-8 text")
      }
      return Scenario.lines(of: text)
    case .steps(let steps):
      let broken = steps.indices.filter { steps[$0].contains("\n") }
      guard broken.isEmpty else {
        throw ScenarioLineErrors(errors: broken.map {
          ScenarioLineError(line: $0 + 1, reason: "a --step holds one step, without line breaks")
        })
      }
      return steps.enumerated().map { ($0.offset + 1, $0.element) }
    }
  }
}
