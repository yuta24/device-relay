import Foundation

struct DoctorOptions: Equatable {
  var udid: String?
  var device: String?
  var simulator = false
  var os: String?
  var project: String?
  /// `--json`: one JSON object on stdout instead of the lines for people (see `Doctor.json`).
  var json = false
}

/// `relay doctor`: checks the host (Xcode, the runner project, signing) and the device `relay start`
/// would use, without building or launching anything. Exits 1 when something is ✗. With `--json` it prints
/// one object (`json(sections:)`) and nothing else on stdout.
enum Doctor {
  static func run(
    _ options: DoctorOptions,
    commands: HostCommands = .live,
    configURL: URL = RelayConfig.defaultURL(),
    resolveProject: (String?) throws -> (root: URL, source: RunnerProject.Source) = { try RunnerProject.resolve(explicitPath: $0) },
    home: URL = UserHome.url,
    staleness: (URL, RunnerProject.Source) -> String? = { RunnerInstaller.staleness(root: $0, source: $1) },
    sandbox: (URL) -> [Check] = SandboxProbe.checks(home:),
    inUse: (([Device]) -> [String: StartLock.Holder])? = nil,
    output: (String) -> Void = { print($0) }
  ) -> Int32 {
    var sections: [(title: String, checks: [Check])] = []
    var checks: [Check] { sections.flatMap(\.checks) }
    // The lines for people are left out of --json: stdout holds the one object.
    func say(_ line: String) {
      if !options.json { output(line) }
    }
    func section(_ title: String, _ sectionChecks: [Check]) {
      say(title)
      sectionChecks.forEach { say($0.formatted()) }
      sections.append((title, sectionChecks))
    }

    section("Host", hostChecks(commands: commands, resolveProject: { try resolveProject(options.project) }, home: home, staleness: staleness)
      + sandbox(home))

    var deviceChecks: [Check] = []
    var target: Device?
    do {
      let (devices, warnings) = try DeviceList.load(commands, udid: options.udid, simulator: options.simulator)
      let held = inUse?(devices) ?? StartLock.holdersInUse(devices, home: home)
      let active = devices.filter(\.isActive)
      let connected = active.filter { $0.kind == .device }.count
      let simulators = "\(active.count - connected) booted simulator(s), \(devices.filter { $0.kind == .simulator && $0.isAvailable }.count) iOS simulator(s)"
      if let reason = DeviceList.devicectlSkipReason(udid: options.udid, simulator: options.simulator, simulators: devices) {
        deviceChecks.append(.ok("devices", "\(simulators) (devices not listed: \(reason))"))
      } else {
        deviceChecks.append(.ok("devices", "\(connected) connected device(s), \(simulators)"))
      }
      deviceChecks += warnings.map { .warning("devicectl", $0, fix: "check that Xcode 26 or later is selected (xcode-select -p)") }
      // Candidates another relay start holds: the automatic choice below leaves them out, as relay start does.
      let busy = devices.filter {
        held[$0.udid.uppercased()] != nil && $0.isActive && (!options.simulator || $0.kind == .simulator) && (options.os.map($0.matches(os:)) ?? true)
      }
      if !busy.isEmpty {
        deviceChecks.append(.ok("in use", busy.map { "\($0.summary) (\(held[$0.udid.uppercased()]?.summary ?? "in use"))" }.joined(separator: ", ")
            + "; relay start without --udid/--device does not pick these"))
      }
      do {
        let selection = try DeviceSelector.select(from: devices, udid: options.udid, name: options.device,
                                                  simulator: options.simulator, os: options.os, inUse: held.mapValues(\.summary))
        let device = selection.device
        target = device
        if !selection.isAutomatic, let holder = held[device.udid.uppercased()] {
          // relay start stops here with a DeviceInUseError; the checks of the device below still run.
          deviceChecks.append(.problem("target", "\(device.summary) is in use by \(holder.summary)",
                                       fix: "use another device (--udid or --device; relay status --all lists what is in use), or stop that one (\(StartLock.stopHint(holder)))"))
        } else if !selection.isAutomatic {
          deviceChecks.append(.ok("target", "\(device.summary) (\(selection.reason))"))
        } else if device.kind == .device {
          // A device needs signing and UI Automation; people trying relay out usually want a simulator.
          deviceChecks.append(.warning("target", "\(device.summary) (relay start without --udid/--device would use it: \(selection.reason))",
                                       fix: "to try a simulator first, pass --simulator (a booted one) or --device <simulator name>"))
        } else {
          deviceChecks.append(.ok("target", "\(device.summary) (relay start without --udid/--device would use it: \(selection.reason))"))
        }
      } catch {
        // The candidates follow on the next lines; the table below lists them.
        let message = String(describing: error)
        var firstLine = message.split(separator: "\n").first.map { String($0.hasSuffix(":") ? $0.dropLast() : $0) } ?? ""
        // Only the automatic choice's error lists the devices another relay start holds; here that list is
        // the "in use" line above. A named device that is not found has nothing to do with them.
        if !busy.isEmpty, options.udid == nil, options.device == nil {
          firstLine += "; \(busy.count) in use by another relay start (see the in use line)"
        }
        // Without --udid/--device nothing is wrong yet: relay start can still be told which one to use.
        deviceChecks.append(options.udid == nil && options.device == nil
          ? .warning("target", firstLine, fix: options.simulator
            ? "relay devices lists the simulators; relay doctor --device <name> checks the one relay start would boot"
            : "pass --udid or --device to relay start (relay devices lists them)")
          : .problem("target", firstLine, fix: "pick one from relay devices and pass its --udid"))
      }
      section("Devices", deviceChecks)
      // What --simulator and --os leave out is not a candidate, so not listed either.
      let listed = devices.filter {
        ($0.kind == .device || $0.isActive) && (!options.simulator || $0.kind == .simulator) && (options.os.map($0.matches(os:)) ?? true)
      }
      if !listed.isEmpty {
        say(DeviceList.table(listed).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
      }
    } catch {
      section("Devices", [.problem("devices", "\(error)", fix: "check that Xcode is installed and selected (xcode-select -p)")])
    }

    if let target {
      let locked = target.kind == .device ? DeviceChecks.lockState(udid: target.udid, commands: commands) : nil
      var targetChecks = DeviceChecks.checks(for: target, locked: locked, includeHints: true)
      targetChecks.append(signingCheck(for: target, commands: commands, configURL: configURL))
      targetChecks.append(bundleIDCheck(simulator: options.simulator || target.kind == .simulator, commands: commands, configURL: configURL))
      section("Target: \(target.name)", targetChecks)
    } else {
      section("Signing", [signingCheck(for: nil, commands: commands, configURL: configURL),
                          bundleIDCheck(simulator: options.simulator, commands: commands, configURL: configURL)])
    }

    let problems = checks.filter { $0.status == .problem }.count
    let warnings = checks.filter { $0.status == .warning }.count
    if options.json {
      output(String(decoding: json(sections: sections), as: UTF8.self))
      return problems == 0 ? RunnerExitCode.success.rawValue : RunnerExitCode.failure.rawValue
    }
    say("")
    say(problems == 0
      ? "No problems found\(warnings > 0 ? " (\(warnings) note(s) marked !)" : "")."
      : "\(problems) problem(s) found; fix the ✗ items above.")
    return problems == 0 ? RunnerExitCode.success.rawValue : RunnerExitCode.failure.rawValue
  }

  /// The `relay doctor --json` object, on one line with sorted keys:
  /// `{"checks":[{"detail":...,"fix":...,"name":...,"section":...,"status":"ok"|"warning"|"problem"}],
  /// "ok":<no problem>,"problems":<n>,"warnings":<n>}`. `fix` is null for a check that has none (every ok).
  /// The keys and the three status words are part of the CLI's output: never rename one.
  static func json(sections: [(title: String, checks: [Check])]) -> Data {
    let all = sections.flatMap { section in section.checks.map { (section.title, $0) } }
    let checks: [[String: Any]] = all.map { title, check in
      [
        "name": check.title,
        "section": title,
        "status": check.status.jsonName,
        "detail": check.detail,
        "fix": check.status == .ok ? NSNull() : (check.fix.map { $0 as Any } ?? NSNull())
      ]
    }
    let problems = all.filter { $0.1.status == .problem }.count
    let object: [String: Any] = [
      "ok": problems == 0,
      "problems": problems,
      "warnings": all.filter { $0.1.status == .warning }.count,
      "checks": checks
    ]
    return CLIOutput.json(object)
  }

  static func hostChecks(
    commands: HostCommands,
    resolveProject: () throws -> (root: URL, source: RunnerProject.Source),
    home: URL,
    staleness: (URL, RunnerProject.Source) -> String?
  ) -> [Check] {
    var checks: [Check] = [.ok("relay", RelayVersion.current)]
    let developerDirectory = (try? commands.run("/usr/bin/xcode-select", ["-p"], CommandTimeout.query))?.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let lines = try commands.xcrun(["xcodebuild", "-version"], CommandTimeout.query).split(whereSeparator: \.isNewline).map(String.init)
      let version = lines.first { $0.hasPrefix("Xcode ") } ?? lines.first ?? "?"
      let build = lines.first { $0.hasPrefix("Build version ") }.map { " (\($0.dropFirst("Build version ".count)))" } ?? ""
      checks.append(.ok("Xcode", "\(version)\(build)\(developerDirectory.map { ", \($0)" } ?? "")"))
    } catch {
      checks.append(timedOut("Xcode", error)
        ?? .problem("Xcode", "xcodebuild is not available\(developerDirectory.map { " (developer directory: \($0))" } ?? "")",
                    fix: "install Xcode and select it: sudo xcode-select -s /Applications/Xcode.app"))
    }
    do {
      checks.append(.ok("xcrun", try commands.xcrun(["--version"], CommandTimeout.query).trimmingCharacters(in: .whitespacesAndNewlines)))
    } catch {
      checks.append(timedOut("xcrun", error)
        ?? .problem("xcrun", "not working", fix: "install Xcode and select it: sudo xcode-select -s /Applications/Xcode.app"))
    }
    do {
      checks.append(.ok("devicectl", try commands.xcrun(["--find", "devicectl"], CommandTimeout.query).trimmingCharacters(in: .whitespacesAndNewlines)))
    } catch {
      checks.append(timedOut("devicectl", error)
        ?? .problem("devicectl", "not found", fix: "relay needs Xcode 26 or later; select it: sudo xcode-select -s /Applications/Xcode.app"))
    }
    let project = try? resolveProject()
    if let project {
      checks.append(.ok("runner project", "\(project.root.path) (from \(project.source.label))"))
    } else {
      checks.append(.problem("runner project", "\(RunnerProject.projectPath) not found",
                             fix: "run relay runner install from the extracted release or the checkout (or pass --project <path to device-relay>, or set \(RunnerProject.environmentKey))"))
    }
    checks.append(installCheck(project: project, home: home, staleness: staleness))
    let currentDirectory = WorkingDirectory.url
    checks += SkillInstaller.doctorChecks(home: home, currentDirectory: currentDirectory, commands: commands) {
      try? RunnerProject.resolve(explicitPath: nil, currentDirectory: currentDirectory, home: home, includeInstalled: false).root
    }
    return checks
  }

  /// The check for a command that did not answer in time, or nil for another failure. It says nothing about
  /// what is installed, so the fix for a missing tool would mislead.
  private static func timedOut(_ title: String, _ error: Error) -> Check? {
    (error as? ShellError)?.timeoutSummary.map { .problem(title, $0, fix: "run it in a terminal to see what it is waiting for") }
  }

  /// The copy in `~/.relay/runner`: its record, and whether it matches this relay. With the runner next to
  /// the relay executable (a release, or `make install`), the copy is neither needed nor used, so its absence
  /// or age is no reason to warn: only a relay binary moved away from there would use it.
  static func installCheck(project: (root: URL, source: RunnerProject.Source)?, home: URL, staleness: (URL, RunnerProject.Source) -> String?) -> Check {
    let installed = RunnerProject.installedRoot(home: home)
    let besideExecutable = project?.source == .executable
    guard RunnerProject.contains(installed) else {
      if besideExecutable {
        return .ok("runner install", "not needed; using the runner project of the relay executable")
      }
      return .warning("runner install", "not installed\(project.map { "; using \($0.root.path)" } ?? "")",
                      fix: "run relay runner install so relay start works without the extracted release or checkout")
    }
    let record = RunnerInstallRecord.read(root: installed)
    let detail = record.map { record in
      "relay \(record.relayVersion)\(record.commit.map { ", commit \($0.prefix(12))" } ?? ""), from \(record.source), \(record.installedAt)"
    } ?? "\(installed.path) (no \(RunnerInstallRecord.fileName))"
    if !besideExecutable, let reason = staleness(installed, .installed) {
      return .warning("runner install", reason, fix: "run relay runner install again to update \(installed.path)")
    }
    if let project, project.source != .installed {
      return .ok("runner install", "\(detail) (not used: \(project.source.label) wins)")
    }
    return .ok("runner install", detail)
  }

  /// The prefix of the runner's bundle IDs `relay start` would build with, and where it comes from.
  static func bundleIDCheck(simulator: Bool, commands: HostCommands, configURL: URL) -> Check {
    let config: RelayConfig
    do {
      config = try RelayConfig.read(from: configURL)
    } catch {
      return .problem("bundle ID", "\(error)", fix: "fix or remove \(configURL.path)")
    }
    // The team relay start would use on a device; nil when it cannot tell (it then asks for --team-id).
    let teamID = config.bundleIDPrefix == nil
      ? (try? TeamIDResolver.resolve(explicit: nil, config: config) { try SigningIdentities.load(commands) })?.teamID
      : nil
    return bundleIDCheck(config: config, teamID: teamID, simulator: simulator)
  }

  /// Shown, not judged: the default works for anyone's team. Only an invalid prefix in config.json is ✗.
  static func bundleIDCheck(config: RelayConfig, teamID: String?, simulator: Bool) -> Check {
    let title = "bundle ID"
    func shown(_ prefix: String, _ source: String) -> Check {
      .ok(title, "prefix \(prefix) (\(source)); host app \(RunnerBundleID.host(prefix: prefix))")
    }
    if let configured = config.bundleIDPrefix {
      guard RunnerBundleID.isValidPrefix(configured) else {
        return .problem(title, "invalid bundleIDPrefix in config.json: \(configured)",
                        fix: "relay config set bundleIDPrefix <prefix> (e.g. com.example.devicerelay), or relay config unset bundleIDPrefix")
      }
      return shown(configured, "from \(RunnerBundleID.Source.config.rawValue)")
    }
    if simulator {
      return shown(RunnerBundleID.prefix(configured: nil, teamID: nil).prefix, "default; simulators need no signing")
    }
    guard let teamID else {
      return .ok(title, "prefix dev.devicerelay.<team id in lowercase> (default; the Team ID is not known yet)")
    }
    return shown(RunnerBundleID.prefix(configured: nil, teamID: teamID).prefix, "default, from \(RunnerBundleID.Source.team.rawValue) \(teamID)")
  }

  /// The Team ID `relay start` would sign with. Needed for devices only, so a missing one is ✗ only then.
  static func signingCheck(for target: Device?, commands: HostCommands, configURL: URL) -> Check {
    let needed = target?.kind == .device
    // A Team ID in config.json is enough for relay start, even when the keychain cannot be read.
    if let teamID = (try? RelayConfig.read(from: configURL))?.teamID {
      return .ok("signing", "team \(teamID) (from \(TeamIDResolver.Source.config.rawValue))")
    }
    let identities: [SigningIdentity]
    do {
      identities = try SigningIdentities.load(commands)
    } catch {
      return needed
        ? .problem("signing", "cannot read the keychain: \(error)", fix: "pass --team-id <TEAM_ID> to relay start")
        : .warning("signing", "cannot read the keychain: \(error)", fix: "needed for devices only; pass --team-id <TEAM_ID> to relay start")
    }
    let certificates = "\(identities.count) Apple Development certificate(s)"
    do {
      let team = try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }
      return .ok("signing", "team \(team.teamID) (from \(team.source.rawValue)); \(certificates)")
    } catch {
      let teams = TeamIDResolver.teamIDs(in: identities)
      let detail = teams.count > 1 ? "\(certificates) of \(teams.count) teams (\(teams.joined(separator: ", ")))" : certificates
      let fix = teams.count > 1
        ? "pass --team-id <TEAM_ID> to relay start once, or relay config set teamID <TEAM_ID>"
        : "sign in to your Apple Account in Xcode > Settings > Accounts and create an Apple Development certificate"
      return needed
        ? .problem("signing", detail, fix: fix)
        : .warning("signing", "no Team ID: \(detail)", fix: "needed for devices only; \(fix)")
    }
  }
}
