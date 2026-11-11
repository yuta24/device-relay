import Foundation

/// The bundle IDs the runner is built with, and the `host` name the runner commands take for its host app.
///
/// An explicit App ID belongs to the team that registered it first, so a bundle ID fixed in the project
/// cannot be signed by anyone else's team. The project builds `$(RELAY_BUNDLE_ID_PREFIX).RelayRunnerHost`
/// (and `.UITests`), and the prefix defaults to one per team: `dev.devicerelay.<team id in lowercase>`, or
/// `dev.devicerelay.local` without a team (simulators, which need no App ID). The project file has the same
/// default (`dev.devicerelay.$(DEVELOPMENT_TEAM:default=local:lower)`) for builds without relay;
/// `bundleIDPrefix` in `~/.relay/config.json` replaces it.
enum RunnerBundleID {
  /// The build setting relay passes to xcodebuild.
  static let buildSetting = "RELAY_BUNDLE_ID_PREFIX"
  static let defaultBase = "dev.devicerelay"
  /// The last component of the default prefix when there is no team.
  static let noTeam = "local"
  static let hostProduct = "RelayRunnerHost"
  /// What the runner commands take in place of a bundle ID for the runner's host app.
  static let hostAlias = "host"

  enum Source: String {
    case config = "bundleIDPrefix in ~/.relay/config.json"
    case team = "the Team ID"
    case noTeam = "the default without a team"
  }

  /// The prefix to build with: the configured one, else the default for `teamID`.
  static func prefix(configured: String?, teamID: String?) -> (prefix: String, source: Source) {
    if let configured {
      return (configured, .config)
    }
    guard let teamID else {
      return ("\(defaultBase).\(noTeam)", .noTeam)
    }
    return ("\(defaultBase).\(teamID.lowercased())", .team)
  }

  static func host(prefix: String) -> String {
    "\(prefix).\(hostProduct)"
  }

  /// Reverse-DNS: two or more dot-separated components of ASCII letters, digits, and hyphens, as bundle IDs are.
  static func isValidPrefix(_ value: String) -> Bool {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    return components.count >= 2 && components.allSatisfy { component in
      !component.isEmpty && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
  }

  /// The `xcodebuild` setting for `prefix`.
  static func buildArgument(prefix: String) -> String {
    "\(buildSetting)=\(prefix)"
  }

  /// Why `relay start` rebuilds for another prefix (`RunnerBuildPlan`).
  static func rebuildNote(from built: String, to expected: String) -> String {
    "bundle ID prefix changed from \(built) to \(expected); rebuilding, and the device gets new apps "
      + "with the new IDs (the old ones stay)"
  }

  /// The bundle ID of the host app the `.xctestrun` launches, from the built app's Info.plist. The app is
  /// in `Build/Products/<configuration>-<platform>/` next to the file.
  static func builtHost(xctestrun: URL) -> String? {
    let products = xctestrun.deletingLastPathComponent()
    guard let directories = try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil) else {
      return nil
    }
    let platform = XCTestRunSelection.sdkPlatform(ofFileNamed: xctestrun.lastPathComponent)
    let candidates = directories
      .filter { platform.map($0.lastPathComponent.hasSuffix) ?? true }
      .map { $0.appendingPathComponent("\(hostProduct).app/Info.plist") }
    for plist in candidates {
      if let data = try? Data(contentsOf: plist),
         let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
         let bundleID = object["CFBundleIdentifier"] as? String {
        return bundleID
      }
    }
    return nil
  }

  /// `bundleID`, or the host app's when it is `host`. Nil stays nil (the foreground app).
  static func resolve(_ bundleID: String?, host: String?) throws -> String? {
    guard bundleID == hostAlias else { return bundleID }
    guard let host else {
      throw SetupError(description: "runner.json does not name the runner's host app (written by an older relay start); "
        + "restart the runner with relay start, or pass the bundle ID")
    }
    return host
  }
}

extension XCTestRunSelection {
  /// `-iphonesimulator` from `RelayRunner_iphonesimulator27.2-arm64.xctestrun`: the suffix of the products
  /// directory (`Debug-iphonesimulator`) the file points at. Nil for a name relay cannot read.
  static func sdkPlatform(ofFileNamed name: String) -> String? {
    ["iphonesimulator", "iphoneos"].first { sdkVersion(ofFileNamed: name, platform: $0) != nil }.map { "-\($0)" }
  }
}

extension RunnerOperation {
  /// The operation with `host` replaced by the host app's bundle ID wherever it takes a bundle ID.
  func resolvingHostAlias(_ host: String?) throws -> RunnerOperation {
    func resolve(_ bundleID: String?) throws -> String? {
      try RunnerBundleID.resolve(bundleID, host: host)
    }
    switch self {
    case .source(let format, let maxDepth, let filter, let bundleID):
      return .source(format: format, maxDepth: maxDepth, filter: filter, bundleID: try resolve(bundleID))
    case .find(let selector, let limit, let timeout, let bundleID):
      return .find(selector, limit: limit, timeout: timeout, bundleID: try resolve(bundleID))
    case .tap(var touch):
      touch.bundleID = try resolve(touch.bundleID)
      return .tap(touch)
    case .press(var touch):
      touch.bundleID = try resolve(touch.bundleID)
      return .press(touch)
    case .type(let text, let keys, let bundleID):
      return .type(text: text, keys: keys, bundleID: try resolve(bundleID))
    case .key(let key, let bundleID):
      return .key(key, bundleID: try resolve(bundleID))
    case .launch(let bundleID):
      return .launch(bundleID: try resolve(bundleID) ?? bundleID)
    case .open(let url, let bundleID):
      return .open(url: url, bundleID: try resolve(bundleID))
    case .terminate(let bundleID):
      return .terminate(bundleID: try resolve(bundleID) ?? bundleID)
    default:
      return self
    }
  }
}
