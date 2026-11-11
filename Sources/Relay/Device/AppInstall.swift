import Foundation

/// `relay install <path>`: an `.app` or `.ipa` to put on the simulator or device of `target`.
struct AppInstallOptions: Equatable {
  var path: String
  var target = LogTargetOptions()
}

/// `relay uninstall <bundle-id>`: the app to remove from the simulator or device of `target`.
struct AppUninstallOptions: Equatable {
  var bundleID: String
  var target = LogTargetOptions()
}

/// What `devicectl` left behind: the JSON document it wrote (also when it failed, when it wrote one) and
/// the error it ended with, nil when it exited 0.
struct DevicectlRun: @unchecked Sendable {
  var json: Data?
  var error: Error?
}

/// What `relay install` and `relay uninstall` use: the host's tools of `relay logs` (the device is found the
/// same way), and a `devicectl` whose JSON is read when it fails too, as that is where it says why.
struct AppTools: Sendable {
  var base: LogTools
  var devicectl: @Sendable (_ args: [String], _ timeout: TimeInterval) -> DevicectlRun

  static var live: AppTools {
    AppTools(base: .live, devicectl: { runDevicectl($0, timeout: $1) })
  }

  static func runDevicectl(_ args: [String], timeout: TimeInterval) -> DevicectlRun {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("relay-devicectl-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: output) }
    var failure: Error?
    do {
      try Shell.xcrun(["devicectl"] + args + ["--json-output", output.path, "--quiet"], timeout: timeout)
    } catch {
      failure = error
    }
    return DevicectlRun(json: try? Data(contentsOf: output), error: failure)
  }

  /// `AppInstallCheck`'s tools, from the same commands.
  var probe: AppInstallProbe {
    let commands = base.commands
    return AppInstallProbe(
      xcrun: { try commands.xcrun($0, AppInstallCheck.simctlTimeout) },
      devicectlJSON: { try commands.devicectlJSON($0, AppInstallCheck.devicectlTimeout) }
    )
  }
}

/// What the Info.plist of an `.app` (or of the one `.app` in an `.ipa`'s `Payload/`) says.
struct AppBundleInfo: Equatable {
  var bundleID: String
  var name: String?
  var version: String?
  var build: String?
  /// `CFBundleSupportedPlatforms`: `iPhoneSimulator` or `iPhoneOS` in what Xcode builds. Empty when it is not there.
  var platforms: [String]

  /// Nil for a plist that is not a dictionary or has no `CFBundleIdentifier`.
  init?(plist data: Data) {
    guard let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
          let bundleID = object["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
    self.bundleID = bundleID
    name = (object["CFBundleDisplayName"] as? String) ?? (object["CFBundleName"] as? String)
    version = object["CFBundleShortVersionString"] as? String
    build = object["CFBundleVersion"] as? String
    platforms = (object["CFBundleSupportedPlatforms"] as? [String]) ?? []
  }

  init(bundleID: String, name: String? = nil, version: String? = nil, build: String? = nil, platforms: [String] = []) {
    self.bundleID = bundleID
    self.name = name
    self.version = version
    self.build = build
    self.platforms = platforms
  }

  /// The platform of `CFBundleSupportedPlatforms` a simulator or a device runs.
  static func platform(for kind: Device.Kind) -> String {
    kind == .simulator ? "iPhoneSimulator" : "iPhoneOS"
  }

  /// Whether the app is built for `kind`. A plist that names no platform is not checked: the tools decide.
  func runs(on kind: Device.Kind) -> Bool {
    platforms.isEmpty || platforms.contains(Self.platform(for: kind))
  }

  func json(path: String) -> [String: Any] {
    ["bundleID": bundleID, "name": nullable(name), "version": nullable(version), "build": nullable(build), "path": path]
  }
}

/// `relay install <path>` and `relay uninstall <bundle-id>`: `simctl install` / `uninstall` on a simulator,
/// `devicectl device install app` / `uninstall app` on a device, without the runner.
///
/// The app is read and checked before anything is sent. Both tools take an app built for the other kind of
/// device only to fail with a message about updating or signing it, and both report removing an app that
/// is not installed as a success.
enum AppInstall {
  /// The first `simctl install` after a boot took 50 s; later ones under a second, a device's about 1 s.
  static let installTimeout: TimeInterval = 300
  /// `simctl uninstall` took 0.2 s, `devicectl device uninstall app` 0.5 s to 1 s.
  static let uninstallTimeout: TimeInterval = 60
  /// `unzip` of an `.ipa`'s listing or Info.plist.
  static let unzipTimeout: TimeInterval = 60

  /// The bundle IDs of a relay runner end so: `<prefix>.RelayRunnerHost` and its UI test runner. Removing
  /// the test runner stops a runner at once, and any prefix may be on the device (other sessions, an
  /// earlier `bundleIDPrefix`), so the suffix is checked, not runner.json.
  static let runnerSuffixes = [".\(RunnerBundleID.hostProduct)", ".\(RunnerBundleID.hostProduct).UITests.xctrunner"]

  /// Also `host`, the name the runner commands take for the host app.
  static func isRunnerApp(_ bundleID: String) -> Bool {
    bundleID == RunnerBundleID.hostAlias || runnerSuffixes.contains { bundleID.hasSuffix($0) }
  }

  // MARK: - Commands

  static func install(_ options: AppInstallOptions, tools: AppTools = .live) -> Int32 {
    report(command: "install", tools: tools) { try installChecked(options, tools: tools) }
  }

  static func uninstall(_ options: AppUninstallOptions, tools: AppTools = .live) -> Int32 {
    report(command: "uninstall", tools: tools) { try uninstallChecked(options, tools: tools) }
  }

  private static func report(command: String, tools: AppTools, _ body: () throws -> [String: Any]) -> Int32 {
    do {
      var object = try body()
      object["ok"] = true
      tools.base.writeLine(CLIOutput.json(object))
      return RunnerExitCode.success.rawValue
    } catch let failure as LogFailure {
      tools.base.writeLine(failure.body)
      return failure.status
    } catch let error as ArgumentError {
      return CLIOutput.usageError(error.description, command: command)
    } catch {
      tools.base.writeLine(LogFailure(code: command == "install" ? .appInstallFailed : .appUninstallFailed, message: "\(error)").body)
      return RunnerExitCode.failure.rawValue
    }
  }

  private static func installChecked(_ options: AppInstallOptions, tools: AppTools) throws -> [String: Any] {
    let url = RunnerLocator.resolve(options.path, in: tools.base.currentDirectory)
    let info = try readBundle(at: url, tools: tools.base)
    let device = try usableDevice(options.target, tools: tools.base)
    guard info.runs(on: device.kind) else {
      throw LogFailure(code: .appPlatformMismatch, message: platformMismatch(info, device: device))
    }
    switch device.kind {
    case .simulator:
      do {
        _ = try tools.base.commands.xcrun(["simctl", "install", device.udid, url.path], installTimeout)
      } catch let error as ShellError {
        throw LogFailure(code: .appInstallFailed, message: "simctl install failed: \(simctlReason(error))")
      }
    case .device:
      let run = tools.devicectl(["device", "install", "app", "--device", device.udid, url.path], installTimeout)
      if let reason = devicectlFailure(run) {
        throw LogFailure(code: .appInstallFailed, message: "devicectl device install app failed: \(reason)")
      }
    }
    return ["app": info.json(path: url.path), "device": LogTarget.json(device)]
  }

  private static func uninstallChecked(_ options: AppUninstallOptions, tools: AppTools) throws -> [String: Any] {
    let bundleID = options.bundleID
    guard !isRunnerApp(bundleID) else {
      throw LogFailure(code: .appUninstallRefused, message: "\(bundleID) is a relay runner app; relay uninstall does not remove it "
        + "(relay stop stops the runner; xcrun simctl uninstall or xcrun devicectl device uninstall app removes it)")
    }
    let device = try usableDevice(options.target, tools: tools.base)
    if AppInstallCheck.ask(bundleID: bundleID, udid: device.udid, probe: tools.probe) == .notInstalled {
      throw LogFailure(code: .appNotInstalled, message: "\(bundleID) is not installed on \(device.name); nothing was removed",
                       status: RunnerExitCode.actionFailed.rawValue)
    }
    switch device.kind {
    case .simulator:
      do {
        _ = try tools.base.commands.xcrun(["simctl", "uninstall", device.udid, bundleID], uninstallTimeout)
      } catch let error as ShellError {
        throw LogFailure(code: .appUninstallFailed, message: "simctl uninstall failed: \(simctlReason(error))")
      }
    case .device:
      let run = tools.devicectl(["device", "uninstall", "app", "--device", device.udid, bundleID], uninstallTimeout)
      if let reason = devicectlFailure(run) {
        throw LogFailure(code: .appUninstallFailed, message: "devicectl device uninstall app failed: \(reason)")
      }
    }
    return ["bundleID": bundleID, "device": LogTarget.json(device)]
  }

  /// The device of `target`, booted (a simulator) or connected (a device), as `relay logs` finds it.
  static func usableDevice(_ target: LogTargetOptions, tools: LogTools) throws -> Device {
    let device = try LogTarget.resolve(target, tools: tools)!.device(tools: tools)
    switch device.kind {
    case .simulator where !device.isBooted:
      throw LogFailure(code: .deviceUnavailable, message: "the simulator \(device.name) (\(device.udid)) is \(device.state); "
        + "installing and removing apps needs it booted (relay does not boot it: xcrun simctl boot \(device.udid))")
    case .device where !device.isAvailable:
      throw LogFailure(code: .deviceUnavailable, message: "the device \(device.name) (\(device.udid)) is not connected (\(device.state))")
    default:
      return device
    }
  }

  static func platformMismatch(_ info: AppBundleInfo, device: Device) -> String {
    let built = info.platforms.joined(separator: ", ")
    let kind = device.kind == .simulator ? "a simulator" : "a device"
    return "\(info.bundleID) is built for \(built), and \(device.name) is \(kind), which runs \(AppBundleInfo.platform(for: device.kind)) apps; "
      + "build it for \(device.kind == .simulator ? "the simulator (-sdk iphonesimulator)" : "a device (-sdk iphoneos), signed")"
  }

  // MARK: - The bundle

  /// The Info.plist of the `.app` directory or `.ipa` file at `url`.
  static func readBundle(at url: URL, tools: LogTools) throws(LogFailure) -> AppBundleInfo {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw LogFailure(code: .appBundleInvalid, message: "\(url.path) does not exist")
    }
    let plist: Data
    let place: String
    switch url.pathExtension.lowercased() {
    case "app" where isDirectory.boolValue:
      place = "\(url.path)/Info.plist"
      guard let data = FileManager.default.contents(atPath: place) else {
        throw LogFailure(code: .appBundleInvalid, message: "\(url.path) has no Info.plist")
      }
      plist = data
    case "ipa" where !isDirectory.boolValue:
      (place, plist) = try ipaInfoPlist(url, tools: tools)
    default:
      throw LogFailure(code: .appBundleInvalid, message: "\(url.path) is not an .app directory or an .ipa file")
    }
    guard let info = AppBundleInfo(plist: plist) else {
      throw LogFailure(code: .appBundleInvalid, message: "\(place) is not a property list with a CFBundleIdentifier")
    }
    return info
  }

  /// `Payload/<name>.app/Info.plist` of the one `.app` an `.ipa` (a zip) has: listed with `unzip -Z1`, then
  /// extracted into a work directory, as it may be a binary plist. Foundation reads no zip files.
  static func ipaInfoPlist(_ url: URL, tools: LogTools) throws(LogFailure) -> (String, Data) {
    let listing: String
    do {
      listing = try tools.commands.run("/usr/bin/unzip", ["-Z1", url.path], unzipTimeout)
    } catch {
      throw LogFailure(code: .appBundleInvalid, message: "cannot read \(url.path) as a zip file: \(error)")
    }
    let entries = infoPlistEntries(listing)
    guard entries.count == 1, let entry = entries.first else {
      throw LogFailure(code: .appBundleInvalid, message: "\(url.path) has \(entries.count) apps in Payload/; an .ipa has one")
    }
    let work: URL
    do {
      work = try tools.makeWorkDirectory()
    } catch {
      throw LogFailure(code: .appBundleInvalid, message: "\(error)")
    }
    defer { try? FileManager.default.removeItem(at: work) }
    do {
      _ = try tools.commands.run("/usr/bin/unzip", ["-q", "-o", url.path, unzipPattern(entry), "-d", work.path], unzipTimeout)
    } catch {
      throw LogFailure(code: .appBundleInvalid, message: "cannot extract \(entry) from \(url.path): \(error)")
    }
    guard let data = FileManager.default.contents(atPath: work.appendingPathComponent(entry).path) else {
      throw LogFailure(code: .appBundleInvalid, message: "cannot extract \(entry) from \(url.path)")
    }
    return ("\(url.path):\(entry)", data)
  }

  /// The entries of an `unzip -Z1` listing that are the Info.plist of an app right inside `Payload/`.
  static func infoPlistEntries(_ listing: String) -> [String] {
    listing.split(whereSeparator: \.isNewline).map(String.init).filter { entry in
      let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
      return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[1].count > 4 && parts[2] == "Info.plist"
    }
  }

  /// `entry` as an `unzip` pattern that matches only itself: its wildcards in brackets.
  static func unzipPattern(_ entry: String) -> String {
    entry.map { "*?[".contains($0) ? "[\($0)]" : String($0) }.joined()
  }

  // MARK: - What the tools say

  /// What `simctl` says after its first line (`An error was encountered processing the command (domain=…, code=…):`):
  /// `Unable to lookup in current state: Shutdown`, `App installation failed: … Needs to Be Updated`.
  static func simctlReason(_ error: ShellError) -> String {
    if let timeout = error.timeoutDetail {
      return timeout
    }
    let lines = error.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let reason = lines.first { !$0.hasPrefix("An error was encountered") && !$0.hasPrefix("Underlying error") }
    return reason.map { "\($0) (exit \(error.status))" } ?? "exit \(error.status)"
  }

  /// Why `devicectl` failed, or nil when it did not. The error of its JSON nests the reason: the outermost
  /// says only `Failed to install the app on the device.`, the innermost with a text what was wrong
  /// (`… 0xe8008015 (A valid provisioning profile for this executable was not found.)`).
  static func devicectlFailure(_ run: DevicectlRun) -> String? {
    let root = run.json.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    let outcome = (root?["info"] as? [String: Any])?["outcome"] as? String
    guard run.error != nil || (outcome != nil && outcome != "success") else { return nil }
    if let error = root?["error"] as? [String: Any], let reason = devicectlReason(error) {
      return reason
    }
    if let error = run.error as? ShellError {
      return error.timeoutDetail ?? (error.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(error.status)")
    }
    return run.error.map { "\($0)" } ?? "devicectl reported \(outcome ?? "no outcome")"
  }

  static func devicectlReason(_ error: [String: Any]) -> String? {
    func text(_ info: [String: Any], _ key: String) -> String? {
      ((info[key] as? [String: Any])?["string"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    var top: String?
    var deepest: String?
    var level: [String: Any]? = error
    while let current = level {
      let info = current["userInfo"] as? [String: Any] ?? [:]
      if top == nil { top = text(info, "NSLocalizedDescription") }
      if let reason = text(info, "NSLocalizedRecoverySuggestion") ?? text(info, "NSLocalizedFailureReason") ?? text(info, "NSLocalizedDescription") {
        deepest = reason
      }
      level = (info["NSUnderlyingError"] as? [String: Any])?["error"] as? [String: Any]
    }
    guard let deepest else { return top }
    guard let top, top != deepest else { return deepest }
    return "\(top) \(deepest)"
  }
}
