import Foundation

/// One line of `relay doctor` and of the checks `relay start` runs before building.
struct Check: Equatable {
    enum Status: String {
        case ok = "✓"
        case problem = "✗"
        case warning = "!"
    }

    var status: Status
    var title: String
    var detail: String
    /// How to fix it, in one line. Shown for ✗ and !.
    var fix: String?

    static func ok(_ title: String, _ detail: String) -> Check {
        Check(status: .ok, title: title, detail: detail)
    }

    static func problem(_ title: String, _ detail: String, fix: String) -> Check {
        Check(status: .problem, title: title, detail: detail, fix: fix)
    }

    static func warning(_ title: String, _ detail: String, fix: String? = nil) -> Check {
        Check(status: .warning, title: title, detail: detail, fix: fix)
    }

    func formatted(titleWidth: Int = 16) -> String {
        var line = "  \(status.rawValue) \(title.padding(toLength: max(titleWidth, title.count), withPad: " ", startingAt: 0)) \(detail)"
        if let fix, status != .ok {
            line += "\n      → \(fix)"
        }
        return line
    }
}

enum DeviceChecks {
    static let minimumOSMajorVersion = 17

    /// What can be read about the device or simulator from the Mac. `locked` is the device's lock state
    /// (nil when unknown). `includeHints` adds reminders for what cannot be read, such as UI Automation.
    static func checks(for device: Device, locked: Bool?, includeHints: Bool) -> [Check] {
        var checks: [Check] = []
        if let major = device.osMajorVersion {
            checks.append(major >= minimumOSMajorVersion
                ? .ok("OS", device.os ?? "")
                : .problem("OS", device.os ?? "", fix: "relay needs iOS \(minimumOSMajorVersion) or later (it reaches devices over the CoreDevice tunnel)"))
        }

        guard device.kind == .device else {
            checks.append(device.isAvailable
                ? .ok("runtime", "installed")
                : .problem("runtime", "unavailable", fix: "install the \(device.os ?? "iOS") runtime in Xcode > Settings > Components, or pick another simulator (relay devices)"))
            checks.append(.ok("state", device.isBooted ? "booted" : "\(device.state); relay start boots it and shuts it down when it exits"))
            return checks
        }

        checks.append(device.isAvailable
            ? .ok("connection", device.state)
            : .problem("connection", device.state, fix: "connect the device with USB (or to the same network), unlock it, and check xcrun devicectl list devices"))
        switch device.pairingState {
        case "paired":
            checks.append(.ok("pairing", "paired"))
        case let state?:
            checks.append(.problem("pairing", state, fix: "connect the device with USB, unlock it, and tap Trust on the device"))
        case nil:
            checks.append(.warning("pairing", "unknown", fix: "connect the device with USB, unlock it, and tap Trust on the device"))
        }
        switch device.developerModeEnabled {
        case true?:
            checks.append(.ok("Developer Mode", "enabled"))
        case false?:
            checks.append(.problem("Developer Mode", "disabled", fix: "on the device, turn on Settings > Privacy & Security > Developer Mode (it restarts)"))
        case nil:
            checks.append(.warning("Developer Mode", "unknown", fix: "on the device, check Settings > Privacy & Security > Developer Mode"))
        }
        // xcodebuild usually mounts the disk image itself, so a missing one is not fatal.
        switch device.ddiServicesAvailable {
        case true?:
            checks.append(.ok("disk image", "developer disk image mounted"))
        default:
            checks.append(.warning("disk image", "developer disk image not mounted",
                                   fix: "open Xcode > Window > Devices and Simulators with the device connected and wait until it is ready"))
        }
        switch locked {
        case false?:
            checks.append(.ok("lock", "unlocked"))
        case true?:
            checks.append(.warning("lock", "locked", fix: "unlock the device and keep it unlocked until the runner is ready"))
        case nil:
            checks.append(.warning("lock", "unknown", fix: "unlock the device and keep it unlocked until the runner is ready"))
        }
        if includeHints {
            checks.append(.warning("UI Automation", "cannot be read from the Mac",
                                   fix: "on the device, turn on Settings > Developer > Enable UI Automation"))
        }
        return checks
    }

    /// Whether the device is locked, from `devicectl device info lockState` (`passcodeRequired`).
    static func lockState(udid: String, commands: HostCommands) -> Bool? {
        guard let data = try? commands.devicectlJSON(["device", "info", "lockState", "--device", udid]) else { return nil }
        return parseLockState(data)
    }

    static func parseLockState(_ data: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            return nil
        }
        return result["passcodeRequired"] as? Bool
    }
}

/// What `relay start` does before building: finds the checkout, picks the device, checks it, finds
/// the Team ID, and boots a shut-down simulator.
struct StartSetup {
    var options: StartOptions
    var root: URL
    var device: Device
    /// The simulator relay booted, which `finish()` shuts down again.
    var bootedSimulator: String?
    /// The config with a Team ID that is not saved yet. `saveTeam()` saves it once the runner is ready,
    /// so a mistyped `--team-id` that cannot sign is not remembered.
    var teamConfig: (config: RelayConfig, url: URL)?

    static func prepare(
        _ options: StartOptions,
        commands: HostCommands = .live,
        configURL: URL = RelayConfig.defaultURL(),
        resolveProject: (String?) throws -> (root: URL, source: RunnerProject.Source) = { try RunnerProject.resolve(explicitPath: $0) },
        staleness: (URL, RunnerProject.Source) -> String? = { RunnerInstaller.staleness(root: $0, source: $1) },
        isCancelled: () -> Bool = { StartCancellation.isRequested },
        info: (String) -> Void = StartSetup.info,
        inUse: ([Device]) -> [String: String] = { _ in [:] },
        claimDevice: (Device) throws -> Void = { _ in }
    ) throws -> StartSetup {
        let project = try resolveProject(options.project)
        info("runner project: \(project.root.path) (from \(project.source.label))")
        if let reason = staleness(project.root, project.source) {
            // Not fatal: the old runner may still work, and the person may want to finish something first.
            info("\(reason); run relay install again to update the runner")
        }

        let (devices, warnings) = try DeviceList.load(commands, udid: options.udid, simulator: options.simulator)
        warnings.forEach(info)
        let selection = try DeviceSelector.select(from: devices, udid: options.udid, name: options.device,
                                                  simulator: options.simulator, os: options.os, inUse: inUse(devices))
        let device = selection.device
        info("using \(device.summary) (\(selection.isAutomatic ? "selected automatically; " : "")\(selection.reason))")
        // Before booting it or building: two runners on one device stop each other's XCTest session.
        try claimDevice(device)

        let locked = device.kind == .device ? DeviceChecks.lockState(udid: device.udid, commands: commands) : nil
        let checks = DeviceChecks.checks(for: device, locked: locked, includeHints: false)
        let problems = checks.filter { $0.status == .problem }
        guard problems.isEmpty else {
            throw SetupError(description: "\(device.name) is not ready:\n" + problems.map { $0.formatted() }.joined(separator: "\n")
                + "\nrelay doctor checks the whole setup")
        }
        for check in checks where check.status == .warning {
            info("\(check.title): \(check.detail)\(check.fix.map { "; \($0)" } ?? "")")
        }

        var resolved = options
        resolved.udid = device.udid
        var teamConfig: (config: RelayConfig, url: URL)?
        let config = try RelayConfig.read(from: configURL)
        if device.kind == .device || options.teamID != nil {
            let team = try TeamIDResolver.resolve(explicit: options.teamID, config: config) {
                try SigningIdentities.load(commands)
            }
            resolved.teamID = team.teamID
            info("signing team: \(team.teamID) (from \(team.source.rawValue))")
            if team.source != .config, config.teamID != team.teamID {
                var updated = config
                updated.teamID = team.teamID
                teamConfig = (updated, configURL)
            }
        }
        if let configured = config.bundleIDPrefix, !RunnerBundleID.isValidPrefix(configured) {
            throw SetupError(description: "invalid bundleIDPrefix in \(configURL.path): \(configured); "
                + "relay config set bundleIDPrefix <prefix> replaces it")
        }
        let bundleID = RunnerBundleID.prefix(configured: config.bundleIDPrefix, teamID: resolved.teamID)
        resolved.bundleIDPrefix = bundleID.prefix
        info("runner host app: \(RunnerBundleID.host(prefix: bundleID.prefix)) (prefix from \(bundleID.source.rawValue))")

        var setup = StartSetup(options: resolved, root: project.root, device: device, teamConfig: teamConfig)
        if device.kind == .simulator, !device.isBooted {
            info("booting simulator \(device.name) (\(device.udid)); it is shut down when relay exits")
            do {
                _ = try commands.xcrun(["simctl", "boot", device.udid])
            } catch {
                // Stopping simctl does not stop the boot it asked for.
                if isCancelled() {
                    setup.bootedSimulator = device.udid
                    setup.finish(commands: commands, info: info)
                }
                throw error
            }
            setup.bootedSimulator = device.udid
            do {
                // Blocks until the simulator has finished booting.
                _ = try commands.xcrun(["simctl", "bootstatus", device.udid])
            } catch {
                setup.finish(commands: commands, info: info)
                throw error
            }
        }
        return setup
    }

    /// Saves the Team ID `prepare` found or was given, if it is new. Called when the runner is ready.
    func saveTeam(info: (String) -> Void = StartSetup.info) {
        guard let teamConfig else { return }
        do {
            try teamConfig.config.write(to: teamConfig.url)
            info("saved the team to \(teamConfig.url.path); relay config unset teamID forgets it")
        } catch {
            info("cannot save \(teamConfig.url.path): \(error)")
        }
    }

    /// Shuts down the simulator `prepare` booted, if any.
    func finish(commands: HostCommands = .live, info: (String) -> Void = StartSetup.info) {
        guard let udid = bootedSimulator else { return }
        info("shutting down simulator \(device.name) (\(udid)), which relay booted")
        do {
            _ = try commands.xcrun(["simctl", "shutdown", udid])
        } catch {
            info("cannot shut down \(udid): \(error)")
        }
    }

    static func info(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }
}
