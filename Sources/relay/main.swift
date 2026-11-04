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
        var (devices, warnings) = try DeviceList.load()
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
    case .help:
        print(Arguments.usage)
    case .commandHelp(let name):
        print(Arguments.usage(for: name))
    }
} catch where StartCancellation.isRequested {
    // Ctrl-C or SIGTERM stopped the boot or the build; what failed because of it is not worth showing.
    FileHandle.standardError.write(Data("relay: stopped before launching the runner\n".utf8))
    exit(1)
} catch let error as SetupError {
    FileHandle.standardError.write(Data("relay: \(error)\n".utf8))
    exit(1)
} catch let error as SessionSelectionError {
    FileHandle.standardError.write(Data("relay: \(error)\n".utf8))
    exit(1)
} catch let error as RunnerUnavailableError {
    // relay bench with a session that has no runner; the usage text is no help there.
    FileHandle.standardError.write(Data("relay: \(error)\n".utf8))
    exit(RunnerExitCode.unavailable.rawValue)
} catch let error as ShellError {
    // A failed xcodebuild or simctl: the usage text would bury its output.
    FileHandle.standardError.write(Data("relay: \(error)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("relay: \(error)\n\n\(Arguments.errorUsage(for: arguments.first))\n".utf8))
    exit(1)
}
