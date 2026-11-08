import Foundation

enum RelayVersion {
  /// Recorded by `relay install`; a different value in the record means the installed runner is out of date.
  static let current = "0.6.0"
}

/// What `relay install` records in `~/.relay/runner/install.json`.
struct RunnerInstallRecord: Codable, Equatable {
  static let fileName = "install.json"

  var relayVersion: String
  /// The source's git commit, when it is a checkout.
  var commit: String?
  /// Where the runner was copied from (the path of a checkout or an extracted release).
  var source: String
  var installedAt: String

  static func url(root: URL) -> URL {
    root.appendingPathComponent(fileName)
  }

  static func read(root: URL) -> RunnerInstallRecord? {
    try? JSONDecoder().decode(RunnerInstallRecord.self, from: Data(contentsOf: url(root: root)))
  }

  func write(root: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(self).write(to: Self.url(root: root), options: .atomic)
  }

  /// Why the installed runner may not match this relay, or nil. `sourceCommit` is the current commit of
  /// the checkout this relay was built from, when known; it counts only for the checkout installed from.
  func staleness(currentVersion: String = RelayVersion.current, checkout: (path: String, commit: String?)?) -> String? {
    if relayVersion != currentVersion {
      return "the runner was installed by relay \(relayVersion), but this is relay \(currentVersion)"
    }
    // A path recorded by an older relay may not be canonical.
    let installedFrom = source.hasPrefix("/") ? URL(fileURLWithPath: source).canonicalFileURL.path : source
    if let checkout, checkout.path == installedFrom, let current = checkout.commit, let commit, current != commit {
      return "the runner was installed from commit \(commit.prefix(12)), but \(source) is now at \(current.prefix(12))"
    }
    return nil
  }
}

/// Where `relay install` gets the runner project from.
protocol RunnerSource {
  /// Recorded as `source` in install.json.
  var location: String { get }
  var commit: String? { get }
  /// Puts `Runner/` and the shared sources it compiles into `directory` (which does not exist yet), in
  /// the same layout as the checkout.
  func copy(into directory: URL) throws
}

/// The runner project of a device-relay checkout or extracted release (same layout; a release has no commit).
/// Besides `Runner/`, the project compiles some of the CLI's sources (`../Sources/Relay/Shared/*.swift`), so those
/// files are copied too, and `scripts/package.sh` puts them in the release.
struct CheckoutRunnerSource: RunnerSource {
  var root: URL
  var commands: HostCommands = .live

  var location: String { root.canonicalFileURL.path }

  var commit: String? {
    Self.commit(of: root, commands: commands)
  }

  /// The commit of a git checkout; nil for an extracted release, even one inside another repository, whose
  /// commit git would answer with otherwise.
  static func commit(of root: URL, commands: HostCommands) -> String? {
    guard isGitCheckout(root), let output = try? commands.run("/usr/bin/git", ["-C", root.path, "rev-parse", "HEAD"], CommandTimeout.query) else { return nil }
    let commit = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return commit.count == 40 ? commit : nil
  }

  /// Whether `root` is a git checkout rather than an extracted release: it has `.git` (a directory, or a
  /// file in a git worktree). Not decided by `commit(of:)`, so a checkout stays one when git is missing or fails.
  static func isGitCheckout(_ root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
  }

  func copy(into directory: URL) throws {
    let manager = FileManager.default
    let runner = root.appendingPathComponent("Runner", isDirectory: true)
    let pbxproj = root.appendingPathComponent(RunnerProject.projectPath).appendingPathComponent("project.pbxproj")
    let shared = Self.referencedFiles(pbxproj: try String(contentsOf: pbxproj, encoding: .utf8))
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    try manager.copyItem(at: runner, to: directory.appendingPathComponent("Runner", isDirectory: true))
    for path in shared {
      let destination = directory.appendingPathComponent(path)
      try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try manager.copyItem(at: root.appendingPathComponent(path), to: destination)
    }
    // The agent skill, for relay skill install (a checkout from before the skill has none).
    let skill = root.appendingPathComponent(AgentSkill.path, isDirectory: true)
    if manager.fileExists(atPath: skill.path) {
      let destination = directory.appendingPathComponent(AgentSkill.path, isDirectory: true)
      try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try manager.copyItem(at: skill, to: destination)
    }
    // Per-user Xcode state does not belong in the copy.
    let userData = directory.appendingPathComponent(RunnerProject.projectPath).appendingPathComponent("xcuserdata")
    try? manager.removeItem(at: userData)
  }

  /// Root-relative paths of the files the project refers to with `path = ../<path>;` (relative to the
  /// `Runner` group), e.g. `Sources/Relay/Shared/RunnerAuth.swift`.
  static func referencedFiles(pbxproj: String) -> [String] {
    var paths: [String] = []
    for line in pbxproj.split(whereSeparator: \.isNewline) {
      var rest = line[...]
      while let range = rest.range(of: "path = ") {
        rest = rest[range.upperBound...]
        let end = rest.firstIndex(of: ";") ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        rest = rest[end...]
        guard value.hasPrefix("../") else { continue }
        let path = String(value.dropFirst(3))
        if !path.isEmpty, !path.contains(".."), !paths.contains(path) {
          paths.append(path)
        }
      }
    }
    return paths
  }
}

/// `relay install`: copies the runner project to `~/.relay/runner` and records the version.
enum RunnerInstaller {
  /// Copies into a staging directory first and swaps it in, so a failure leaves the previous copy intact.
  /// Drops the previous build products, which belong to the replaced sources.
  @discardableResult
  static func install(from source: RunnerSource, home: URL = UserHome.url, now: Date = Date()) throws
    -> RunnerInstallRecord {
    let manager = FileManager.default
    let target = RunnerProject.installedRoot(home: home)
    let parent = target.deletingLastPathComponent()
    guard source.location != target.canonicalFileURL.path else {
      throw SetupError(description: "cannot install the runner from \(target.path) itself; pass --project <path to device-relay>")
    }
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent("runner.new-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: staging) }

    try source.copy(into: staging)
    guard RunnerProject.contains(staging) else {
      throw SetupError(description: "\(source.location) has no \(RunnerProject.projectPath)")
    }
    let formatter = ISO8601DateFormatter()
    let record = RunnerInstallRecord(relayVersion: RelayVersion.current, commit: source.commit, source: source.location,
                                     installedAt: formatter.string(from: now))
    try record.write(root: staging)

    if manager.fileExists(atPath: target.path) {
      let old = parent.appendingPathComponent("runner.old-\(UUID().uuidString)", isDirectory: true)
      try manager.moveItem(at: target, to: old)
      do {
        try manager.moveItem(at: staging, to: target)
      } catch {
        try? manager.moveItem(at: old, to: target)
        throw error
      }
      try? manager.removeItem(at: old)
    } else {
      try manager.moveItem(at: staging, to: target)
    }
    try? manager.removeItem(at: RunnerProject.buildDirectory(root: target, home: home))
    return record
  }

  /// Removes `~/.relay/runner` and its build products. config.json, runner.json, and logs stay.
  /// Returns false when nothing was installed.
  @discardableResult
  static func remove(home: URL = UserHome.url) throws -> Bool {
    let manager = FileManager.default
    let target = RunnerProject.installedRoot(home: home)
    try? manager.removeItem(at: RunnerProject.buildDirectory(root: target, home: home))
    guard manager.fileExists(atPath: target.path) else { return false }
    try manager.removeItem(at: target)
    return true
  }

  /// Why the runner at `root` may be out of date, for `relay start` and `relay doctor`. Only the
  /// installed copy is checked; a checkout is always current.
  static func staleness(root: URL, source: RunnerProject.Source, commands: HostCommands = .live,
                        findCheckout: () -> URL? = { try? RunnerProject.resolve(explicitPath: nil, includeInstalled: false).root }) -> String? {
    guard source == .installed else { return nil }
    guard let record = RunnerInstallRecord.read(root: root) else {
      return "\(root.path) has no \(RunnerInstallRecord.fileName)"
    }
    let checkout = findCheckout().map { ($0.canonicalFileURL.path, CheckoutRunnerSource.commit(of: $0, commands: commands)) }
    return record.staleness(checkout: checkout)
  }
}

struct InstallOptions: Equatable {
  var project: String?
  /// Also build the runner for simulators, so the first `relay start` on a simulator skips the build.
  var build = false
  /// Shows xcodebuild's output while `--build` builds, as `relay start --verbose` does.
  var verbose = false
  var remove = false
}

enum InstallCommand {
  static func run(
    _ options: InstallOptions,
    commands: HostCommands = .live,
    home: URL = UserHome.url,
    // No time limit: a build can rightly take very long, and shows progress in its log.
    build: (_ args: [String], _ log: FileHandle, _ echo: Bool) throws -> Void = { try Shell.xcrun($0, log: $1, echo: $2, timeout: nil) },
    output: (String) -> Void = { print($0) }
  ) throws -> Int32 {
    if options.remove {
      let removed = try RunnerInstaller.remove(home: home)
      output(removed ? "removed \(RunnerProject.installedRoot(home: home).path)" : "the runner is not installed")
      return RunnerExitCode.success.rawValue
    }

    let checkout = try RunnerProject.resolve(explicitPath: options.project, home: home, includeInstalled: false)
    let source = CheckoutRunnerSource(root: checkout.root, commands: commands)
    let record = try RunnerInstaller.install(from: source, home: home)
    let root = RunnerProject.installedRoot(home: home)
    output("installed the runner to \(root.path) (relay \(record.relayVersion)"
      + "\(record.commit.map { ", commit \($0.prefix(12))" } ?? ""), from \(record.source))")
    if AgentSkill.contains(AgentSkill.installedSource(home: home)) {
      output("the \(AgentSkill.name) agent skill is in \(AgentSkill.installedSource(home: home).path); relay skill install adds it to a project")
    }

    guard options.build else { return RunnerExitCode.success.rawValue }
    let derivedData = RunnerProject.buildDirectory(root: root, home: home).appendingPathComponent("DerivedData-sim", isDirectory: true)
    // Named like relay start's build logs, in the same directory.
    let logsURL = home.appendingPathComponent(".relay/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
    let buildLogURL = try RunnerLauncher.createLog("build", in: logsURL, stamp: RunnerLauncher.timestamp(), port: nil)
    output("building the runner for simulators into \(derivedData.path) (log: \(buildLogURL.path))")
    let buildLog = try FileHandle(forWritingTo: buildLogURL)
    defer { try? buildLog.close() }
    let sourceHash = try RunnerSourceHash.compute(root: root)
    // As relay start on a simulator builds it, so that reuses this build.
    let bundleIDPrefix = RunnerBundleID.prefix(
      configured: (try? RelayConfig.read(from: RelayConfig.defaultURL(home: home)))?.bundleIDPrefix, teamID: nil
    ).prefix
    let arguments = RunnerLauncher.buildArguments(
      projectURL: root.appendingPathComponent(RunnerProject.projectPath),
      destination: "generic/platform=iOS Simulator",
      derivedData: derivedData,
      teamID: nil,
      sourceHash: sourceHash,
      bundleIDPrefix: bundleIDPrefix
    )
    do {
      // Not at the same time as a relay start's build or launch from this DerivedData (see BuildLock).
      let buildLock = try BuildLock(derivedData: derivedData, relayDirectory: home.appendingPathComponent(".relay", isDirectory: true))
      defer { buildLock.release() }
      try buildLock.wait(for: .exclusive, info: output)
      try? BuildDirectoryRecord.refresh(root: root, buildDirectory: RunnerProject.buildDirectory(root: root, home: home))
      RunnerBuildStamp.remove(derivedData: derivedData)
      try build(arguments, buildLog, options.verbose)
      // relay start reuses the build only with this record (RunnerBuildPlan).
      try RunnerBuildStamp(sourceHash: sourceHash, relayVersion: RelayVersion.current, bundleIDPrefix: bundleIDPrefix)
        .write(derivedData: derivedData)
    } catch {
      // The runner is installed; only the prebuild failed, and relay start builds it again anyway.
      throw SetupError(description: "\(error)\nthe runner is installed, but building it failed; see \(buildLogURL.path)")
    }
    output("built; relay start on a simulator reuses it")
    return RunnerExitCode.success.rawValue
  }
}
