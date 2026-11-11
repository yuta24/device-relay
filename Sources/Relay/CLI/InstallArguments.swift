import Foundation

extension Arguments {
  /// `relay install <path> [--session <name> | --runner <path> | --udid <udid>]` and `relay uninstall
  /// <bundle-id> [...]`: an app. Without one, the old `relay install [--project <path>] [--build [--verbose]]`,
  /// `relay install --remove`, and `relay uninstall`, which are `relay runner install|uninstall` now and stay
  /// for one release (`InstallOptions.legacy`). An app with an option of the old form is an error.
  static func parseInstall(_ subcommand: String, _ raw: [String]) throws -> Command {
    let install = subcommand == "install"
    var runner = InstallOptions(remove: !install, legacy: true)
    var runnerOption: String?
    var target = LogTargetOptions()
    var targetOption: String?
    var arguments: [String] = []
    var rest = raw[...]
    while let option = rest.popFirst() {
      switch option {
      case "--project" where install:
        guard let value = rest.first, !value.hasPrefix("--") else {
          throw ArgumentError(description: "--project requires a value")
        }
        runner.project = rest.removeFirst()
        runnerOption = runnerOption ?? option
      case "--build" where install: runner.build = true; runnerOption = runnerOption ?? option
      case "--verbose" where install: runner.verbose = true; runnerOption = runnerOption ?? option
      case "--remove" where install: runner.remove = true; runnerOption = runnerOption ?? option
      case "--session", "--runner", "--udid":
        try readTarget(option, from: &rest, into: &target)
        targetOption = targetOption ?? option
      default:
        guard !option.hasPrefix("-") else {
          throw ArgumentError(description: "unknown option for \(subcommand): \(option)")
        }
        arguments.append(option)
      }
    }
    let what = install ? "the path of an .app or .ipa" : "the bundle ID of an app"
    guard arguments.count <= 1 else {
      throw ArgumentError(description: "\(subcommand) takes one app: \(what) (got \(arguments.count))")
    }
    if let argument = arguments.first {
      if let runnerOption {
        throw ArgumentError(description: "install takes either an app or \(runnerOption), not both; "
          + (runnerOption == "--remove" ? "relay runner uninstall removes the runner" : "relay runner install takes \(runnerOption) for the runner"))
      }
      try checkTarget(target, command: subcommand)
      return install
        ? .appInstall(AppInstallOptions(path: argument, target: target))
        : .appUninstall(AppUninstallOptions(bundleID: argument, target: target))
    }
    if let targetOption {
      throw ArgumentError(description: "\(subcommand) \(targetOption) requires \(what)")
    }
    try checkRunnerOptions(runner)
    return .install(runner)
  }

  /// `relay runner install [--project <path>] [--build [--verbose]]` and `relay runner uninstall`.
  static func parseRunnerSetup(_ raw: [String]) throws -> Command {
    var rest = raw[...]
    guard let action = rest.popFirst(), ["install", "uninstall"].contains(action) else {
      if raw.first == "help" { return .commandHelp("runner") }
      throw ArgumentError(description: raw.first.map { "unknown runner action: \($0) (install or uninstall)" }
        ?? "runner takes install or uninstall")
    }
    var options = InstallOptions(remove: action == "uninstall")
    while let option = rest.popFirst() {
      switch option {
      case "--project" where action == "install":
        guard let value = rest.first, !value.hasPrefix("--") else {
          throw ArgumentError(description: "--project requires a value")
        }
        options.project = rest.removeFirst()
      case "--build" where action == "install": options.build = true
      case "--verbose" where action == "install": options.verbose = true
      default: throw ArgumentError(description: "unknown option for runner \(action): \(option)")
      }
    }
    try checkRunnerOptions(options)
    return .install(options)
  }

  private static func checkRunnerOptions(_ options: InstallOptions) throws {
    guard !(options.remove && (options.build || options.verbose || options.project != nil)) else {
      throw ArgumentError(description: "install --remove takes no other options")
    }
  }
}
