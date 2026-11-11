import Foundation

// Line-buffer stdout so `ready: <url>` reaches pipes and files immediately, not only TTYs.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
do {
  switch try Arguments.parse(arguments) {
  case .start(var options):
    options.session = try RelaySession.resolve(flag: options.session)
    if options.background {
      exit(BackgroundStart.run(options))
    }
    // Held until this process exits, after the runner stopped (see StartLock).
    _ = try StartLocks.acquire(for: &options)
    if let conflict = BackgroundStart.sessionConflict(options) {
      throw SetupError(description: conflict)
    }
    // Here, not in --background's waiting process: every start comes through here, and holds its port now.
    RelayPrune.atStart(port: options.port, project: options.project)
    StartCancellation.install()
    let setup = try StartSetup.prepare(
      options,
      inUse: { StartLock.devicesInUse($0) },
      claimDevice: { [session = options.session] in _ = try StartLock.acquire(device: $0, session: session) }
    )
    if StartCancellation.isRequested {
      setup.finish()
      exit(1)
    }
    let launcher = RunnerLauncher(options: setup.options, udid: setup.device.udid, isSimulator: setup.device.kind == .simulator,
                                  rootURL: setup.root, buildURL: RunnerProject.buildDirectory(root: setup.root),
                                  deviceName: setup.device.name)
    launcher.onReady = { setup.saveTeam() }
    let status: Int32
    do {
      status = try launcher.run()
    } catch {
      Recording.cleanUp(port: setup.options.port)
      setup.finish()
      throw error
    }
    // Before a simulator relay start booted is shut down, so the video is complete.
    Recording.cleanUp(port: setup.options.port)
    setup.finish()
    exit(status)
  case .devices(let json, let os):
    var devices: [Device]
    var warnings: [String]
    do {
      (devices, warnings) = try DeviceList.load()
    } catch {
      guard json else { throw error }
      // --json: the failure is the one object on stdout, as the list is on success.
      CLIOutput.writeLine(CLIOutput.failureBody(.devicesUnavailable, "\(error)"))
      exit(RunnerExitCode.failure.rawValue)
    }
    if let os {
      devices = devices.filter { $0.matches(os: os) }
    }
    warnings.forEach { FileHandle.standardError.write(Data("relay: \($0)\n".utf8)) }
    if json {
      FileHandle.standardOutput.write(try DeviceList.json(devices) + Data("\n".utf8))
    } else {
      print(devices.isEmpty ? "no devices or iOS simulators found\(os.map { " with --os \($0)" } ?? "")" : DeviceList.table(devices))
    }
  case .doctor(let options):
    exit(Doctor.run(options))
  case .config(let options):
    exit(ConfigCommand.run(options))
  case .install(let options):
    exit(try InstallCommand.run(options))
  case .skill(let options):
    exit(try SkillCommand.run(options))
  case .version:
    print("relay \(RelayVersion.current)")
  case .bench(let options):
    try Bench.run(options)
  case .runner(let options):
    exit(RunnerControl.run(options))
  case .run(let options):
    exit(ScenarioCommand.run(options))
  case .status(let options):
    exit(RunnerStatus.run(options))
  case .stop(let options):
    exit(RunnerStop.run(options))
  case .record(let options):
    exit(Recording.run(options))
  case .logs(let options):
    exit(DeviceLogs.run(options))
  case .crashes(let options):
    exit(CrashReports.run(options))
  case .help:
    print(Arguments.usage)
  case .commandHelp(let name):
    print(Arguments.usage(for: name))
  }
} catch where StartCancellation.isRequested {
  // Ctrl-C or SIGTERM stopped the boot or the build; what failed because of it is not worth showing.
  CLIOutput.note("stopped before launching the runner")
  exit(RunnerExitCode.failure.rawValue)
} catch let error as ArgumentError {
  // A command line that is wrong: the problem and where the help is, not the whole usage text.
  exit(CLIOutput.usageError(error.description, command: arguments.first))
} catch let error as SessionSelectionError {
  exit(CLIOutput.usageError(error.description, command: arguments.first))
} catch let error as RunnerUnavailableError {
  // relay bench with a session that has no runner.
  CLIOutput.note(error.description)
  exit(RunnerExitCode.unavailable.rawValue)
} catch {
  // SetupError, a failed xcodebuild or simctl, ...: a local failure, whose message is all there is to say.
  CLIOutput.note("\(error)")
  exit(RunnerExitCode.failure.rawValue)
}
