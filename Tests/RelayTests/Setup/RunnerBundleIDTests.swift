import Foundation
@testable import Relay
import Testing

struct RunnerBundleIDTests {
    @Test func prefixComesFromTheConfigElseTheTeamElseLocal() {
        #expect(RunnerBundleID.prefix(configured: "com.example.relay", teamID: "ABCDE12345") == ("com.example.relay", .config))
        // Team IDs are uppercase; the prefix uses them in lowercase, as the project file does (`:lower`).
        #expect(RunnerBundleID.prefix(configured: nil, teamID: "ABCDE12345") == ("dev.devicerelay.abcde12345", .team))
        #expect(RunnerBundleID.prefix(configured: nil, teamID: "0A1B2C3D4E") == ("dev.devicerelay.0a1b2c3d4e", .team))
        #expect(RunnerBundleID.prefix(configured: nil, teamID: nil) == ("dev.devicerelay.local", .noTeam))
        #expect(RunnerBundleID.host(prefix: "dev.devicerelay.abcde12345") == "dev.devicerelay.abcde12345.RelayRunnerHost")
    }

    @Test func validatesReverseDNSPrefixes() {
        for valid in ["dev.yuta24.devicerelay", "com.example", "com.my-company.relay2", "dev.devicerelay.0a1b2c3d4e"] {
            #expect(RunnerBundleID.isValidPrefix(valid), "\(valid)")
        }
        for invalid in ["", "devicerelay", "com..example", ".com.example", "com.example.", "com.example relay", "com.exämple", "com_example.app", "com/example"] {
            #expect(!RunnerBundleID.isValidPrefix(invalid), "\(invalid)")
        }
    }

    @Test func buildArgumentsPassThePrefixAndTheTeam() {
        let project = URL(fileURLWithPath: "/r/Runner/RelayRunner.xcodeproj")
        let derived = URL(fileURLWithPath: "/b/DerivedData-device")
        let device = RunnerLauncher.buildArguments(projectURL: project, destination: "id=X", derivedData: derived,
                                                   teamID: "ABCDE12345", sourceHash: "h", bundleIDPrefix: "dev.devicerelay.abcde12345")
        #expect(device.suffix(3) == ["-allowProvisioningUpdates", "RELAY_DEVELOPMENT_TEAM=ABCDE12345", "RELAY_BUNDLE_ID_PREFIX=dev.devicerelay.abcde12345"])
        let simulator = RunnerLauncher.buildArguments(projectURL: project, destination: "id=X", derivedData: derived,
                                                      teamID: nil, sourceHash: "h", bundleIDPrefix: "dev.devicerelay.local")
        #expect(!simulator.contains("-allowProvisioningUpdates"))
        #expect(simulator.last == "RELAY_BUNDLE_ID_PREFIX=dev.devicerelay.local")
        // Both the bundle ID prefix and the build version settings go to xcodebuild.
        #expect(simulator.contains("RELAY_RUNNER_SOURCE_HASH=h"))
    }

    @Test func rebuildsWhenThePrefixOfTheLastBuildDiffers() {
        let xctestrun = URL(fileURLWithPath: "/d/Build/Products/RelayRunner_iphonesimulator27.2-arm64.xctestrun")
        func decide(_ stamp: RunnerBuildStamp, prefix: String = "dev.devicerelay.abcde12345") -> RunnerBuildPlan {
            RunnerBuildPlan.decide(rebuild: false, selection: .reuse(xctestrun), platform: "iphonesimulator", sdkVersion: "27.2",
                                   stamp: stamp, sourceHash: "a", bundleIDPrefix: prefix, relayVersion: "0.2.0")
        }
        #expect(decide(RunnerBuildStamp(sourceHash: "a", relayVersion: "0.2.0", bundleIDPrefix: "dev.devicerelay.abcde12345")) == .reuse(xctestrun))
        #expect(decide(RunnerBuildStamp(sourceHash: "a", relayVersion: "0.2.0", bundleIDPrefix: "dev.yuta24.devicerelay"))
            == .build(reason: RunnerBundleID.rebuildNote(from: "dev.yuta24.devicerelay", to: "dev.devicerelay.abcde12345")))
        // Checked before the sources and the relay version, so the note about new apps is not hidden.
        #expect(decide(RunnerBuildStamp(sourceHash: "b", relayVersion: "0.1.0", bundleIDPrefix: "dev.yuta24.devicerelay"))
            == .build(reason: RunnerBundleID.rebuildNote(from: "dev.yuta24.devicerelay", to: "dev.devicerelay.abcde12345")))
        // A stamp from a relay before prefixes.
        guard case .build(let reason?) = decide(RunnerBuildStamp(sourceHash: "a", relayVersion: "0.2.0")) else {
            Issue.record("expected a build with a reason")
            return
        }
        #expect(reason.contains("no record of its bundle ID prefix"))
        // The SDK check still comes first.
        #expect(RunnerBuildPlan.decide(rebuild: false, selection: .otherSDK(xctestrun), platform: "iphonesimulator", sdkVersion: "27.2",
                                       stamp: RunnerBuildStamp(sourceHash: "a", relayVersion: "0.2.0", bundleIDPrefix: "x.y"),
                                       sourceHash: "a", bundleIDPrefix: "dev.devicerelay.abcde12345", relayVersion: "0.2.0")
            != .reuse(xctestrun))
    }

    @Test func stampsFromBeforePrefixesStillRead() throws {
        let derivedData = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: derivedData) }
        let url = RunnerBuildStamp.url(derivedData: derivedData)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"relayVersion":"0.2.0","sourceHash":"a"}"#.utf8).write(to: url)
        #expect(RunnerBuildStamp.read(derivedData: derivedData) == RunnerBuildStamp(sourceHash: "a", relayVersion: "0.2.0"))
        try RunnerBuildStamp(sourceHash: "a", relayVersion: "0.2.0", bundleIDPrefix: "dev.devicerelay.local").write(derivedData: derivedData)
        #expect(RunnerBuildStamp.read(derivedData: derivedData)?.bundleIDPrefix == "dev.devicerelay.local")
    }

    @Test func theProjectFileUsesThePrefix() throws {
        let pbxproj = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/RelayRunner.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: pbxproj, encoding: .utf8)
        #expect(contents.contains(#"PRODUCT_BUNDLE_IDENTIFIER = "$(RELAY_BUNDLE_ID_PREFIX).RelayRunnerHost";"#))
        // The default for builds without relay matches RunnerBundleID.prefix.
        #expect(contents.contains(#"RELAY_BUNDLE_ID_PREFIX = "dev.devicerelay.$(DEVELOPMENT_TEAM:default=local:lower)";"#))
        #expect(!contents.contains("dev.yuta24"))
    }

    @Test func readsTheBuiltHostAppNextToTheXCTestRun() throws {
        let products = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Build/Products")
        defer { try? FileManager.default.removeItem(at: products.deletingLastPathComponent().deletingLastPathComponent()) }
        func app(_ directory: String, _ bundleID: String) throws {
            let url = products.appendingPathComponent("\(directory)/RelayRunnerHost.app")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .binary, options: 0)
            try plist.write(to: url.appendingPathComponent("Info.plist"))
        }
        try app("Debug-iphoneos", "dev.devicerelay.abcde12345.RelayRunnerHost")
        try app("Debug-iphonesimulator", "dev.devicerelay.local.RelayRunnerHost")
        let simulator = products.appendingPathComponent("RelayRunner_iphonesimulator27.0-arm64.xctestrun")
        let device = products.appendingPathComponent("RelayRunner_iphoneos27.0-arm64.xctestrun")
        #expect(RunnerBundleID.builtHost(xctestrun: simulator) == "dev.devicerelay.local.RelayRunnerHost")
        #expect(RunnerBundleID.builtHost(xctestrun: device) == "dev.devicerelay.abcde12345.RelayRunnerHost")
        #expect(RunnerBundleID.builtHost(xctestrun: products.appendingPathComponent("missing/x.xctestrun")) == nil)
    }

    @Test func hostNamesTheRunnersHostApp() throws {
        let host = "dev.devicerelay.abcde12345.RelayRunnerHost"
        #expect(try RunnerBundleID.resolve("host", host: host) == host)
        #expect(try RunnerBundleID.resolve("com.example.app", host: host) == "com.example.app")
        #expect(try RunnerBundleID.resolve(nil, host: host) == nil)
        #expect(try RunnerBundleID.resolve("com.example.app", host: nil) == "com.example.app")
        // runner.json from an older relay start has no host app.
        #expect(throws: SetupError.self) { try RunnerBundleID.resolve("host", host: nil) }

        #expect(try RunnerOperation.launch(bundleID: "host").resolvingHostAlias(host) == .launch(bundleID: host))
        #expect(try RunnerOperation.terminate(bundleID: "host").resolvingHostAlias(host) == .terminate(bundleID: host))
        #expect(try RunnerOperation.launch(bundleID: "com.apple.Preferences").resolvingHostAlias(nil) == .launch(bundleID: "com.apple.Preferences"))
        #expect(try RunnerOperation.key("return", bundleID: "host").resolvingHostAlias(host) == .key("return", bundleID: host))
        #expect(try RunnerOperation.type(text: "a", keys: [], bundleID: "host").resolvingHostAlias(host) == .type(text: "a", keys: [], bundleID: host))
        let selector = RunnerElementSelector(identifier: "relay.input")
        let touch = RunnerTouch(target: .element(selector), bundleID: "host")
        #expect(try RunnerOperation.tap(touch).resolvingHostAlias(host).request.body?["bundleId"] as? String == host)
        #expect(try RunnerOperation.find(selector, limit: nil, timeout: nil, bundleID: "host").resolvingHostAlias(host)
            == .find(selector, limit: nil, timeout: nil, bundleID: host))
        #expect(try RunnerOperation.source(format: nil, maxDepth: nil, filter: nil, bundleID: "host").resolvingHostAlias(host)
            == .source(format: nil, maxDepth: nil, filter: nil, bundleID: host))
        #expect(try RunnerOperation.ping.resolvingHostAlias(nil) == .ping)
    }

    @Test func runnerInfoKeepsTheHostApp() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runner.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        info.hostBundleID = "dev.devicerelay.local.RelayRunnerHost"
        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url).hostBundleID == "dev.devicerelay.local.RelayRunnerHost")
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""hostBundleID" : "dev.devicerelay.local.RelayRunnerHost""#))
    }

    @Test func configSetValidatesThePrefix() throws {
        #expect(try Arguments.parse(["config", "set", "bundleIDPrefix", "dev.yuta24.devicerelay"])
            == .config(ConfigOptions(action: .set("bundleIDPrefix", "dev.yuta24.devicerelay"))))
        #expect(try Arguments.parse(["config", "get", "bundleIDPrefix"]) == .config(ConfigOptions(action: .get("bundleIDPrefix"))))
        #expect(try Arguments.parse(["config", "unset", "bundleIDPrefix"]) == .config(ConfigOptions(action: .unset("bundleIDPrefix"))))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "set", "bundleIDPrefix", "devicerelay"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "set", "bundleIDPrefix", "com.example..relay"]) }
        // Each key keeps its own validation.
        #expect(throws: ArgumentError.self) { try Arguments.parse(["config", "set", "teamID", "com.example"]) }
    }

    @Test func configCommandKeepsBothKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ConfigCommand.run(ConfigOptions(action: .set("teamID", "ABCDE12345")), url: url) == 0)
        #expect(ConfigCommand.run(ConfigOptions(action: .set("bundleIDPrefix", "dev.yuta24.devicerelay")), url: url) == 0)
        #expect(try RelayConfig.read(from: url) == RelayConfig(teamID: "ABCDE12345", bundleIDPrefix: "dev.yuta24.devicerelay"))
        var lines: [String] = []
        #expect(ConfigCommand.run(ConfigOptions(action: .get("bundleIDPrefix")), url: url) { lines.append($0) } == 0)
        #expect(lines == ["dev.yuta24.devicerelay"])
        lines = []
        #expect(ConfigCommand.run(ConfigOptions(action: .show), url: url) { lines.append($0) } == 0)
        #expect(lines.dropFirst() == ["teamID: ABCDE12345", "bundleIDPrefix: dev.yuta24.devicerelay"])
        #expect(ConfigCommand.run(ConfigOptions(action: .unset("bundleIDPrefix")), url: url) == 0)
        #expect(try RelayConfig.read(from: url) == RelayConfig(teamID: "ABCDE12345"))
        // A config.json from before the key still reads.
        try Data(#"{"teamID":"ABCDE12345"}"#.utf8).write(to: url)
        #expect(try RelayConfig.read(from: url).bundleIDPrefix == nil)
    }

    @Test func doctorShowsThePrefixAndWhereItComesFrom() {
        let configured = Doctor.bundleIDCheck(config: RelayConfig(bundleIDPrefix: "dev.yuta24.devicerelay"), teamID: "ABCDE12345", simulator: false)
        #expect(configured == .ok("bundle ID", "prefix dev.yuta24.devicerelay (from bundleIDPrefix in ~/.relay/config.json); host app dev.yuta24.devicerelay.RelayRunnerHost"))
        // The configured prefix is used for simulators too.
        #expect(Doctor.bundleIDCheck(config: RelayConfig(bundleIDPrefix: "dev.yuta24.devicerelay"), teamID: nil, simulator: true) == configured)

        // The default is shown, not warned about: it works for anyone's team.
        #expect(Doctor.bundleIDCheck(config: RelayConfig(), teamID: "ABCDE12345", simulator: false)
            == .ok("bundle ID", "prefix dev.devicerelay.abcde12345 (default, from the Team ID ABCDE12345); host app dev.devicerelay.abcde12345.RelayRunnerHost"))
        #expect(Doctor.bundleIDCheck(config: RelayConfig(), teamID: nil, simulator: false)
            == .ok("bundle ID", "prefix dev.devicerelay.<team id in lowercase> (default; the Team ID is not known yet)"))
        #expect(Doctor.bundleIDCheck(config: RelayConfig(), teamID: "ABCDE12345", simulator: true)
            == .ok("bundle ID", "prefix dev.devicerelay.local (default; simulators need no signing); host app dev.devicerelay.local.RelayRunnerHost"))

        // Only an invalid prefix fails.
        let invalid = Doctor.bundleIDCheck(config: RelayConfig(bundleIDPrefix: "not valid"), teamID: "ABCDE12345", simulator: true)
        #expect(invalid.status == .problem)
        #expect(invalid.fix?.hasPrefix("relay config set bundleIDPrefix <prefix>") == true)
    }

    @Test func rebuildNoteNamesBothPrefixes() {
        #expect(RunnerBundleID.rebuildNote(from: "dev.yuta24.devicerelay", to: "dev.devicerelay.abcde12345")
            == "bundle ID prefix changed from dev.yuta24.devicerelay to dev.devicerelay.abcde12345; rebuilding, and the device gets new apps "
            + "with the new IDs (the old ones stay)")
    }
}
