import Foundation

extension Arguments {
  /// `relay install <path> [--session <name> | --runner <path> | --udid <udid>]` and `relay uninstall
  /// <bundle-id> [...]`: an app. The form without an app (`relay install [--project <path>] [--build]`,
  /// `--remove`, `relay uninstall`), which copied or removed the runner until 0.8.0, is a usage error that
  /// names `relay runner install|uninstall`.
  static func parseInstall(_ subcommand: String, _ raw: [String]) throws -> Command {
    let install = subcommand == "install"
    let moved = install ? "relay runner install" : "relay runner uninstall"
    var target = LogTargetOptions()
    var targetOption: String?
    var arguments: [String] = []
    var rest = raw[...]
    while let option = rest.popFirst() {
      switch option {
      case "--project" where install, "--build" where install, "--verbose" where install:
        throw ArgumentError(description: "install \(option) is now relay runner install \(option); install takes an app")
      case "--remove" where install:
        throw ArgumentError(description: "install --remove is now relay runner uninstall; install takes an app")
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
    guard let argument = arguments.first else {
      throw ArgumentError(description: targetOption.map { "\(subcommand) \($0) requires \(what)" }
        ?? "\(subcommand) requires \(what); \(moved) is for the runner")
    }
    try checkTarget(target, command: subcommand)
    return install
      ? .appInstall(AppInstallOptions(path: argument, target: target))
      : .appUninstall(AppUninstallOptions(bundleID: argument, target: target))
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
