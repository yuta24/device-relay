import Foundation
@testable import Relay
import Testing

struct DeviceChecksTests {
    @Test func flagsWhatStopsADevice() {
        var phone = device("Phone", udid: "D1")
        #expect(DeviceChecks.checks(for: phone, locked: false, includeHints: false).allSatisfy { $0.status == .ok })

        phone.developerModeEnabled = false
        phone.pairingState = "unpaired"
        phone.os = "iOS 16.7"
        let problems = DeviceChecks.checks(for: phone, locked: false, includeHints: false).filter { $0.status == .problem }
        #expect(problems.map(\.title) == ["OS", "pairing", "Developer Mode"])
        #expect(problems.allSatisfy { $0.fix != nil })
    }

    @Test func warnsAboutWhatMayStillWork() {
        var phone = device("Phone", udid: "D1")
        phone.ddiServicesAvailable = false
        let checks = DeviceChecks.checks(for: phone, locked: true, includeHints: true)
        #expect(checks.filter { $0.status == .warning }.map(\.title) == ["disk image", "lock", "UI Automation"])
        #expect(!checks.contains { $0.status == .problem })
    }

    @Test func checksSimulatorRuntimes() {
        var sim = simulator("Sim", udid: "S1")
        #expect(DeviceChecks.checks(for: sim, locked: nil, includeHints: true).allSatisfy { $0.status == .ok })
        sim.isAvailable = false
        #expect(DeviceChecks.checks(for: sim, locked: nil, includeHints: true).contains { $0.status == .problem && $0.title == "runtime" })
    }

    @Test func parsesLockState() {
        #expect(DeviceChecks.parseLockState(Data(#"{"result":{"passcodeRequired":true}}"#.utf8)) == true)
        #expect(DeviceChecks.parseLockState(Data(#"{"result":{"passcodeRequired":false}}"#.utf8)) == false)
        #expect(DeviceChecks.parseLockState(Data("{}".utf8)) == nil)
    }

    @Test func formatsFixesUnderProblems() {
        #expect(Check.problem("pairing", "unpaired", fix: "tap Trust").formatted(titleWidth: 8) == "  ✗ pairing  unpaired\n      → tap Trust")
        #expect(Check(status: .ok, title: "OS", detail: "iOS 27.0", fix: "unused").formatted(titleWidth: 2) == "  ✓ OS iOS 27.0")
    }
}

struct StartSetupTests {
    private let project: (String?) throws -> (root: URL, source: RunnerProject.Source) = { _ in (URL(fileURLWithPath: "/relay"), .option) }

    @Test func bootsANamedSimulatorAndShutsItDownAfterwards() throws {
        let host = FakeHost()
        host.devicectl = #"{"result":{"devices":[]}}"#
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = RelayConfig.defaultURL(home: directory)

        var messages: [String] = []
        let setup = try StartSetup.prepare(StartOptions(device: "iphone 17 pro"), commands: host.commands, configURL: configURL,
                                           resolveProject: project, info: { messages.append($0) })
        #expect(setup.options.udid == simulatorUDID)
        #expect(setup.options.teamID == nil)
        #expect(setup.bootedSimulator == simulatorUDID)
        #expect(host.xcrunCalls.suffix(2) == [["simctl", "boot", simulatorUDID], ["simctl", "bootstatus", simulatorUDID]])
        #expect(messages.contains { $0.hasPrefix("using iPhone 17 Pro") && $0.hasSuffix("(--device)") })
        // Simulators need no Team ID, so nothing is looked up or saved.
        #expect(!FileManager.default.fileExists(atPath: configURL.path))

        setup.finish(commands: host.commands) { messages.append($0) }
        #expect(host.xcrunCalls.last == ["simctl", "shutdown", simulatorUDID])
    }

    @Test func leavesABootedSimulatorAlone() throws {
        let host = FakeHost()
        host.devicectl = #"{"result":{"devices":[]}}"#
        host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Booted")])
        let setup = try StartSetup.prepare(StartOptions(), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                           resolveProject: project, info: { _ in })
        #expect(setup.options.udid == simulatorUDID)
        #expect(setup.bootedSimulator == nil)
        setup.finish(commands: host.commands) { _ in }
        #expect(!host.xcrunCalls.contains { $0.contains("boot") || $0.contains("shutdown") })
    }

    @Test func aSimulatorWhoseBootIsStoppedIsShutDown() throws {
        for cancelled in [true, false] {
            let host = FakeHost()
            host.devicectl = #"{"result":{"devices":[]}}"#
            var commands = host.commands
            let xcrun = commands.xcrun
            commands.xcrun = { args, timeout in
                let output = try xcrun(args, timeout)
                // simctl boot stopped by Ctrl-C (or failing on its own).
                if args.prefix(2) == ["simctl", "boot"] { throw ShellError(args: args, status: 15, output: "") }
                return output
            }
            #expect(throws: ShellError.self) {
                try StartSetup.prepare(StartOptions(udid: simulatorUDID), commands: commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                       resolveProject: project, isCancelled: { cancelled }, info: { _ in })
            }
            // Only a stopped boot is undone: a boot that failed on its own may be someone else's simulator.
            #expect(host.xcrunCalls.last == (cancelled ? ["simctl", "shutdown", simulatorUDID] : ["simctl", "boot", simulatorUDID]))
        }
    }

    @Test func aSimulatorWhoseBootTimesOutIsShutDown() throws {
        let host = FakeHost()
        host.devicectl = #"{"result":{"devices":[]}}"#
        var commands = host.commands
        let xcrun = commands.xcrun
        commands.xcrun = { args, timeout in
            let output = try xcrun(args, timeout)
            if args.prefix(2) == ["simctl", "boot"] { throw ShellError(args: args, status: 15, output: "", timedOutAfter: timeout) }
            return output
        }
        #expect {
            try StartSetup.prepare(StartOptions(udid: simulatorUDID), commands: commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                   resolveProject: project, isCancelled: { false }, info: { _ in })
        } throws: { "\($0)".contains("simctl boot \(simulatorUDID) timed out after 300 s") }
        // The boot simctl asked for goes on without simctl.
        #expect(host.xcrunCalls.last == ["simctl", "shutdown", simulatorUDID])
    }

    @Test func startGivesEachCommandItsTimeLimit() throws {
        let host = FakeHost()
        host.devicectl = #"{"result":{"devices":[]}}"#
        let limits = Locked<[String: TimeInterval]>([:])
        var commands = host.commands
        let xcrun = commands.xcrun
        commands.xcrun = { args, timeout in
            limits.withLock { $0[args.prefix(2).joined(separator: " ")] = timeout }
            return try xcrun(args, timeout)
        }
        let devicectlJSON = commands.devicectlJSON
        commands.devicectlJSON = { args, timeout in
            limits.withLock { $0["devicectl " + args.prefix(2).joined(separator: " ")] = timeout }
            return try devicectlJSON(args, timeout)
        }
        let setup = try StartSetup.prepare(StartOptions(device: "iphone 17 pro"), commands: commands,
                                           configURL: URL(fileURLWithPath: "/nonexistent/config.json"), resolveProject: project, info: { _ in })
        setup.finish(commands: commands) { _ in }
        #expect(limits.value == [
            "simctl list": CommandTimeout.query,
            "devicectl list devices": CommandTimeout.devicectl,
            "simctl boot": CommandTimeout.simctlBoot,
            "simctl bootstatus": CommandTimeout.simctlBootStatus,
            "simctl shutdown": CommandTimeout.simctlShutdown
        ])
    }

    @Test func doctorGivesEachCommandItsTimeLimit() {
        let host = FakeHost()
        let limits = Locked<[String: TimeInterval]>([:])
        var commands = host.commands
        let xcrun = commands.xcrun
        commands.xcrun = { args, timeout in
            limits.withLock { $0[args.first ?? ""] = timeout }
            return try xcrun(args, timeout)
        }
        let devicectlJSON = commands.devicectlJSON
        commands.devicectlJSON = { args, timeout in
            limits.withLock { $0[args.prefix(3).joined(separator: " ")] = timeout }
            return try devicectlJSON(args, timeout)
        }
        let run = commands.run
        commands.run = { executable, args, timeout in
            limits.withLock { $0[executable] = timeout }
            return try run(executable, args, timeout)
        }
        _ = Doctor.run(DoctorOptions(udid: deviceUDID), commands: commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                       resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), sandbox: { _ in [] }, output: { _ in })
        for command in ["xcodebuild", "--version", "--find", "simctl", "/usr/bin/xcode-select", "/usr/bin/security"] {
            #expect(limits.value[command] == CommandTimeout.query, "\(command)")
        }
        #expect(limits.value["list devices"] == CommandTimeout.devicectl)
        #expect(limits.value["device info lockState"] == CommandTimeout.devicectl)
    }

    /// Everything that does not answer: doctor says so where it would say the tool is missing, and goes on.
    @Test func doctorReportsCommandsThatTimeOutAndGoesOn() {
        var commands = FakeHost().commands
        commands.xcrun = { args, timeout in throw ShellError(args: args, status: 15, output: "", timedOutAfter: timeout) }
        commands.devicectlJSON = { args, timeout in throw ShellError(args: ["devicectl"] + args, status: 15, output: "", timedOutAfter: timeout) }
        commands.run = { executable, args, timeout in
            throw ShellError(tool: URL(fileURLWithPath: executable).lastPathComponent, args: args, status: 9, output: "", timedOutAfter: timeout)
        }
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(), commands: commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), sandbox: { _ in [] }, output: { lines.append($0) })
        #expect(status == RunnerExitCode.failure.rawValue)
        #expect(lines.contains { $0.hasPrefix("  ✗ Xcode            xcrun xcodebuild -version timed out after 30 s\n") })
        #expect(lines.contains { $0.hasPrefix("  ✗ xcrun            xcrun --version timed out after 30 s\n") })
        #expect(lines.contains { $0.hasPrefix("  ✗ devicectl        xcrun --find devicectl timed out after 30 s\n") })
        #expect(lines.contains { $0.hasPrefix("  ✗ devices") && $0.contains("xcrun simctl list devices --json timed out after 30 s") })
        #expect(lines.contains { $0.contains("signing") && $0.contains("security find-identity -v -p codesigning timed out after 30 s") })
        // The fix for a missing Xcode would mislead: nothing says it is missing.
        #expect(!lines.contains { $0.contains("install Xcode") })
    }

    @Test func picksTheConnectedDeviceAndRemembersTheKeychainTeam() throws {
        let host = FakeHost()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = RelayConfig.defaultURL(home: directory)

        var messages: [String] = []
        let setup = try StartSetup.prepare(StartOptions(), commands: host.commands, configURL: configURL, resolveProject: project, info: { messages.append($0) })
        #expect(setup.options.udid == deviceUDID)
        #expect(setup.options.teamID == "TEAM000001")
        #expect(messages.contains { $0.contains("selected automatically") })
        #expect(messages.contains("signing team: TEAM000001 (from keychain)"))
        // Saved only once the runner is ready.
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        setup.saveTeam(info: { messages.append($0) })
        #expect(try RelayConfig.read(from: configURL).teamID == "TEAM000001")

        // The saved team wins over the keychain from now on.
        host.findIdentity = ""
        let again = try StartSetup.prepare(StartOptions(), commands: host.commands, configURL: configURL, resolveProject: project, info: { _ in })
        #expect(again.options.teamID == "TEAM000001")
        #expect(again.teamConfig == nil)
        // An explicit --team-id replaces it, once the runner it signed is ready.
        let explicit = try StartSetup.prepare(StartOptions(teamID: "ABCDE12345"), commands: host.commands, configURL: configURL, resolveProject: project, info: { _ in })
        #expect(try RelayConfig.read(from: configURL).teamID == "TEAM000001")
        explicit.saveTeam(info: { _ in })
        #expect(try RelayConfig.read(from: configURL).teamID == "ABCDE12345")
    }

    @Test func stopsBeforeBuildingForADeviceThatIsNotReady() throws {
        let host = FakeHost()
        host.devicectl = host.devicectl.replacingOccurrences(of: #"{"enabled":{"mode":1}}"#, with: #"{"disabled":{}}"#)
        #expect {
            try StartSetup.prepare(StartOptions(), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                   resolveProject: project, info: { _ in })
        } throws: { error in
            error is SetupError && String(describing: error).contains("Developer Mode")
        }
        // Not even the keychain is read.
        #expect(!host.xcrunCalls.contains { $0.first == "xcodebuild" })
    }

    @Test func refusesAnUnavailableDeviceNamedExplicitly() {
        let host = FakeHost()
        #expect(throws: SetupError.self) {
            try StartSetup.prepare(StartOptions(udid: otherDeviceUDID), commands: host.commands,
                                   configURL: URL(fileURLWithPath: "/nonexistent/config.json"), resolveProject: project, info: { _ in })
        }
    }
}

struct BundleIDSetupTests {
    private let project: (String?) throws -> (root: URL, source: RunnerProject.Source) = { _ in (URL(fileURLWithPath: "/relay"), .environment) }

    @Test func startUsesTheTeamPrefixUnlessTheConfigSetsOne() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = RelayConfig.defaultURL(home: directory)

        var messages: [String] = []
        var setup = try StartSetup.prepare(StartOptions(), commands: FakeHost().commands, configURL: configURL, resolveProject: project,
                                           info: { messages.append($0) })
        #expect(setup.options.bundleIDPrefix == "dev.devicerelay.team000001")
        #expect(messages.contains("runner host app: dev.devicerelay.team000001.RelayRunnerHost (prefix from the Team ID)"))

        try RelayConfig(bundleIDPrefix: "dev.yuta24.devicerelay").write(to: configURL)
        setup = try StartSetup.prepare(StartOptions(), commands: FakeHost().commands, configURL: configURL, resolveProject: project, info: { _ in })
        #expect(setup.options.bundleIDPrefix == "dev.yuta24.devicerelay")

        // A simulator without a team.
        let host = FakeHost()
        host.devicectl = #"{"result":{"devices":[]}}"#
        host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Booted")])
        try RelayConfig().write(to: configURL)
        setup = try StartSetup.prepare(StartOptions(), commands: host.commands, configURL: configURL, resolveProject: project, info: { _ in })
        #expect(setup.options.bundleIDPrefix == "dev.devicerelay.local")

        // A hand-edited invalid prefix stops relay start before it builds.
        try Data(#"{"bundleIDPrefix":"not valid"}"#.utf8).write(to: configURL)
        #expect(throws: SetupError.self) {
            try StartSetup.prepare(StartOptions(), commands: host.commands, configURL: configURL, resolveProject: project, info: { _ in })
        }
    }

    @Test func doctorShowsTheDefaultPrefixForADevice() {
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(), commands: FakeHost().commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(status == RunnerExitCode.success.rawValue)
        #expect(lines.contains("  ✓ bundle ID        prefix dev.devicerelay.team000001 (default, from the Team ID TEAM000001); "
            + "host app dev.devicerelay.team000001.RelayRunnerHost"))
    }

    @Test func doctorOnlyShowsThePrefixWithSimulator() {
        let host = FakeHost()
        host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Booted")])
        var lines: [String] = []
        _ = Doctor.run(DoctorOptions(simulator: true), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                       resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(lines.contains { $0.hasPrefix("  ✓ bundle ID        prefix dev.devicerelay.local (default; simulators need no signing)") })
    }

    @Test func doctorFailsForAnInvalidPrefix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = RelayConfig.defaultURL(home: directory)
        try RelayConfig(bundleIDPrefix: "devicerelay").write(to: configURL)
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(), commands: FakeHost().commands, configURL: configURL,
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(status == RunnerExitCode.failure.rawValue)
        #expect(lines.contains { $0.hasPrefix("  ✗ bundle ID        invalid bundleIDPrefix in config.json: devicerelay") })
    }
}
