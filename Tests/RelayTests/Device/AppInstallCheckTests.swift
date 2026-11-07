import Foundation
@testable import Relay
import Testing

struct AppInstallCheckTests {
    private static let notInstalledOutput = """
    An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):
    The operation couldn’t be completed. No such file or directory
    No such file or directory
    """

    /// The shape `devicectl device info apps --include-all-apps --bundle-id <id>` writes (jsonVersion 5).
    private static func devicectl(
        apps: [String],
        outcome: String = "success",
        defaultApps: Bool? = true,
        removableApps: Bool? = true,
        hiddenApps: Bool? = true,
        internalApps: Bool? = true
    ) -> Data {
        // nil leaves the field out.
        var result: [String: Any] = ["apps": apps.map { ["bundleIdentifier": $0, "defaultApp": true] }]
        result["defaultAppsIncluded"] = defaultApps
        result["removableAppsIncluded"] = removableApps
        result["hiddenAppsIncluded"] = hiddenApps
        result["internalAppsIncluded"] = internalApps
        let document: [String: Any] = ["info": ["outcome": outcome, "jsonVersion": 5], "result": result]
        return try! JSONSerialization.data(withJSONObject: document)
    }

    private static func probe(
        simctl: @escaping @Sendable () throws -> String,
        devicectl: @escaping @Sendable () throws -> Data = { Issue.record("devicectl was asked"); return Data() }
    ) -> AppInstallProbe {
        AppInstallProbe(xcrun: { _ in try simctl() }, devicectlJSON: { _ in try devicectl() })
    }

    private static let notSimulator = ShellError(args: [], status: 148, output: "Invalid device: x")

    // MARK: - simctl

    @Test func simctlPathMeansInstalled() {
        #expect(AppInstallCheck.interpretSimctl(status: 0, output: "/path/MobileSafari.app\n") == .state(.installed))
    }

    @Test func simctlNotInstalledNeedsItsStatusAndError() {
        #expect(AppInstallCheck.interpretSimctl(status: 2, output: Self.notInstalledOutput) == .state(.notInstalled))
        // Another failure with status 2, or that error under another status, says nothing about the app.
        #expect(AppInstallCheck.interpretSimctl(status: 2, output: "xcrun: error: unable to find utility") == .state(.unknown(reason: "simctl failed (2)")))
        #expect(AppInstallCheck.interpretSimctl(status: 1, output: Self.notInstalledOutput) == .state(.unknown(reason: "simctl failed (1)")))
    }

    @Test func simctlInvalidDeviceMeansADevice() {
        #expect(AppInstallCheck.interpretSimctl(status: 148, output: "Invalid device: x") == .notASimulator)
    }

    @Test func simctlFailuresAreUnknown() {
        let shutDown = "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to lookup in current state: Shutdown"
        #expect(AppInstallCheck.interpretSimctl(status: 149, output: shutDown) == .state(.unknown(reason: "simctl failed (149)")))
        // SIGTERM from the time limit.
        #expect(AppInstallCheck.interpretSimctl(status: 15, output: "") == .state(.unknown(reason: "simctl failed (15)")))
        #expect(AppInstallCheck.interpretSimctl(status: 0, output: " \n") == .state(.unknown(reason: "simctl printed no path")))
    }

    // MARK: - devicectl

    @Test func devicectlListsTheApp() {
        #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: ["com.example.app"]), bundleID: "com.example.app") == .installed)
    }

    @Test func devicectlEmptyListMeansNotInstalled() {
        #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: []), bundleID: "com.example.app") == .notInstalled)
        #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: ["com.example.other"]), bundleID: "com.example.app") == .notInstalled)
    }

    @Test func devicectlListThatLeftAppsOutIsUnknown() {
        let unknown = AppInstallState.unknown(reason: "devicectl did not list every app")
        // Each of the four, false or missing.
        for value in [false, nil] as [Bool?] {
            #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: [], defaultApps: value), bundleID: "a.b") == unknown)
            #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: [], removableApps: value), bundleID: "a.b") == unknown)
            #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: [], hiddenApps: value), bundleID: "a.b") == unknown)
            #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: [], internalApps: value), bundleID: "a.b") == unknown)
        }
        // What such a run does list still counts.
        #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: ["a.b"], defaultApps: false), bundleID: "a.b") == .installed)
    }

    @Test func devicectlOtherDocumentsAreUnknown() {
        let unknown = AppInstallState.unknown(reason: "unexpected devicectl output")
        #expect(AppInstallCheck.interpretDevicectl(Self.devicectl(apps: [], outcome: "failed"), bundleID: "a.b") == unknown)
        #expect(AppInstallCheck.interpretDevicectl(Data("not json".utf8), bundleID: "a.b") == unknown)
        #expect(AppInstallCheck.interpretDevicectl(Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8), bundleID: "a.b") == unknown)
    }

    /// Without `--include-all-apps`, devicectl finds no Safari, which would read as "not installed".
    @Test func devicectlIsAskedForAllApps() {
        let arguments = AppInstallCheck.devicectlArguments(bundleID: "a.b", udid: "U")
        #expect(arguments == ["device", "info", "apps", "--device", "U", "--include-all-apps", "--bundle-id", "a.b"])
    }

    // MARK: - Asking in order

    @Test func simulatorIsAnsweredBySimctlAlone() {
        let notInstalled = Self.probe(simctl: { throw ShellError(args: [], status: 2, output: Self.notInstalledOutput) })
        #expect(AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: notInstalled) == .notInstalled)
        // A system app the simulator has is looked up like any other.
        #expect(AppInstallCheck.ask(bundleID: "com.apple.mobilesafari", udid: "U", probe: Self.probe(simctl: { "/Safari.app" })) == .installed)
        // The simulator's answer holds for com.apple. too: no such app there.
        #expect(AppInstallCheck.ask(bundleID: "com.apple.none", udid: "U", probe: notInstalled) == .notInstalled)
    }

    @Test func deviceIsAnsweredByDevicectl() {
        let missing = Self.probe(simctl: { throw Self.notSimulator }, devicectl: { Self.devicectl(apps: []) })
        #expect(AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: missing) == .notInstalled)
        let present = Self.probe(simctl: { throw Self.notSimulator }, devicectl: { Self.devicectl(apps: ["a.b"]) })
        #expect(AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: present) == .installed)
    }

    /// SpringBoard and others may not be listed on a device: they go to the runner without asking devicectl.
    @Test func systemAppsOnADeviceAreNotLookedUp() {
        for bundleID in ["com.apple.springboard", "com.apple.mobilesafari", "com.apple.Preferences", "COM.APPLE.x"] {
            #expect(AppInstallCheck.ask(bundleID: bundleID, udid: "U", probe: Self.probe(simctl: { throw Self.notSimulator })) == .unknown(reason: nil))
        }
    }

    /// The tools failing must never read as "not installed".
    @Test func failuresToAskAreUnknown() {
        struct NotRun: Error {}
        let simctlNotRun = AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: Self.probe(simctl: { throw NotRun() }))
        guard case .unknown(reason: .some) = simctlNotRun else {
            Issue.record("\(simctlNotRun)")
            return
        }
        // No devicectl (older Xcode, xcrun: unable to find utility), no such device, or the time limit.
        let failed = Self.probe(simctl: { throw Self.notSimulator }, devicectl: { throw ShellError(args: [], status: 1, output: "ERROR") })
        #expect(AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: failed) == .unknown(reason: "devicectl failed (1)"))
        let notRun = AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: Self.probe(simctl: { throw Self.notSimulator }, devicectl: { throw NotRun() }))
        guard case .unknown(reason: .some) = notRun else {
            Issue.record("\(notRun)")
            return
        }
    }

    // MARK: - Before /launch

    @Test func hostAppIsNotAskedAbout() {
        let probe = Self.probe(simctl: { Issue.record("simctl was asked"); return "" })
        #expect(AppInstallCheck.state(of: "x.RelayRunnerHost", udid: "host-udid", hostBundleID: "x.RelayRunnerHost", probe: probe) == .installed)
    }

    @Test func onlyAnInstalledAppIsRemembered() {
        let asked = Locked(0)
        let installed = Self.probe(simctl: { asked.withLock { $0 += 1 }; return "/App.app" })
        #expect(AppInstallCheck.state(of: "a.remembered", udid: "cache-udid", hostBundleID: nil, probe: installed) == .installed)
        #expect(AppInstallCheck.state(of: "a.remembered", udid: "cache-udid", hostBundleID: nil, probe: installed) == .installed)
        #expect(asked.value == 1)

        let askedMissing = Locked(0)
        let missing = Self.probe(simctl: { askedMissing.withLock { $0 += 1 }; throw ShellError(args: [], status: 2, output: Self.notInstalledOutput) })
        #expect(AppInstallCheck.state(of: "a.missing", udid: "cache-udid", hostBundleID: nil, probe: missing) == .notInstalled)
        #expect(AppInstallCheck.state(of: "a.missing", udid: "cache-udid", hostBundleID: nil, probe: missing) == .notInstalled)
        #expect(askedMissing.value == 2)
    }

    @Test func notInstalledBodyHasTheShapeOfARunnerError() throws {
        let body = AppInstallCheck.notInstalledBody(bundleID: "a.b", device: "Phone")
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        #expect(object["code"] as? String == "app_not_installed")
        #expect(object["error"] as? String == "a.b is not installed on Phone")
        #expect(AppInstallCheck.notInstalledHint(bundleID: "a.b", device: "Phone").hasPrefix("a.b is not installed on Phone; "))
    }

    // MARK: - Time limit and time-out wording

    @Test func aToolThatTimesOutIsUnknownAndSaysSo() {
        // The output of a command stopped halfway does not count, even when it looks like an answer.
        let simctl = Self.probe(simctl: { throw ShellError(args: [], status: 15, output: Self.notInstalledOutput, timedOutAfter: 5) })
        #expect(AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: simctl) == .unknown(reason: "simctl timed out after 5 s"))
        let devicectl = Self.probe(simctl: { throw Self.notSimulator }, devicectl: { throw ShellError(args: [], status: 9, output: "", timedOutAfter: 10) })
        #expect(AppInstallCheck.ask(bundleID: "a.b", udid: "U", probe: devicectl) == .unknown(reason: "devicectl timed out after 10 s"))
    }

    @Test func launchTimeoutSaysHowToGetTheRunnerBack() {
        let reason = RunnerControl.timeoutReason(for: .launch(bundleID: "a.b"), seconds: 150)
        #expect(reason.hasPrefix("no response within 150s; "))
        #expect(reason.contains("\"busy\":false"))
        #expect(reason.contains("relay stop"))
        #expect(RunnerControl.timeoutReason(for: .ping, seconds: 30) == "no response within 30s; check it with relay ping")
    }
}
