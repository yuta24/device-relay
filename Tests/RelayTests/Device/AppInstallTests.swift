import Foundation
@testable import Relay
import Testing

// relay install <path> / relay uninstall <bundle-id>, and relay runner install|uninstall. UDIDs, names, and
// bundle IDs are dummies (see fakeLogTools); no simulator or device is used. The tool output is as
// simctl and devicectl printed it (Xcode 27.2, devicectl 651.32).

struct InstallArgumentsTests {
  @Test func anAppIsAPathOrABundleID() throws {
    #expect(try Arguments.parse(["install", "App.app"]) == .appInstall(AppInstallOptions(path: "App.app")))
    #expect(try Arguments.parse(["install", "--udid", "SIM-ON", "a/App.ipa"])
      == .appInstall(AppInstallOptions(path: "a/App.ipa", target: LogTargetOptions(udid: "SIM-ON"))))
    #expect(try Arguments.parse(["uninstall", "com.example.app", "--session=a"])
      == .appUninstall(AppUninstallOptions(bundleID: "com.example.app", target: LogTargetOptions(session: "a"))))
    #expect(try Arguments.parse(["install", "App.app", "--runner", "/r.json"])
      == .appInstall(AppInstallOptions(path: "App.app", target: LogTargetOptions(runnerPath: "/r.json"))))
  }

  @Test func withoutAnAppTheOldFormCopiesTheRunner() throws {
    #expect(try Arguments.parse(["install"]) == .install(InstallOptions(legacy: true)))
    #expect(try Arguments.parse(["install", "--project", "/p", "--build", "--verbose"])
      == .install(InstallOptions(project: "/p", build: true, verbose: true, legacy: true)))
    #expect(try Arguments.parse(["install", "--remove"]) == .install(InstallOptions(remove: true, legacy: true)))
    #expect(try Arguments.parse(["uninstall"]) == .install(InstallOptions(remove: true, legacy: true)))
    #expect(InstallCommand.legacyNote(InstallOptions(legacy: true)).contains("now relay runner install"))
    #expect(InstallCommand.legacyNote(InstallOptions(remove: true, legacy: true)).contains("now relay runner uninstall"))
  }

  @Test func relayRunner() throws {
    #expect(try Arguments.parse(["runner", "install"]) == .install(InstallOptions()))
    #expect(try Arguments.parse(["runner", "install", "--project=/p", "--build"]) == .install(InstallOptions(project: "/p", build: true)))
    #expect(try Arguments.parse(["runner", "uninstall"]) == .install(InstallOptions(remove: true)))
    #expect(try Arguments.parse(["runner", "--help"]) == .commandHelp("runner"))
    #expect(try Arguments.parse(["runner", "install", "-h"]) == .commandHelp("runner"))
    #expect(try Arguments.parse(["runner", "help"]) == .commandHelp("runner"))
    #expect(try Arguments.parse(["help", "runner"]) == .commandHelp("runner"))
    #expect(Arguments.helpCommand(for: "runner") == "relay runner --help")
  }

  @Test func rejectsWhatIsWrong() {
    func reason(_ arguments: [String]) -> String {
      do {
        _ = try Arguments.parse(arguments)
        return "parsed"
      } catch {
        return "\(error)"
      }
    }
    #expect(reason(["install", "App.app", "--build"]).hasPrefix("install takes either an app or --build, not both"))
    #expect(reason(["install", "--remove", "App.app"]).hasSuffix("relay runner uninstall removes the runner"))
    #expect(reason(["install", "a.app", "b.app"]) == "install takes one app: the path of an .app or .ipa (got 2)")
    #expect(reason(["uninstall", "a", "b"]) == "uninstall takes one app: the bundle ID of an app (got 2)")
    #expect(reason(["install", "--udid", "SIM-ON"]) == "install --udid requires the path of an .app or .ipa")
    #expect(reason(["uninstall", "--session", "a"]) == "uninstall --session requires the bundle ID of an app")
    #expect(reason(["install", "a.app", "--udid", "X", "--session", "a"]) == "install takes one of --session, --runner, and --udid")
    #expect(reason(["install", "a.app", "--json"]) == "unknown option for install: --json")
    #expect(reason(["uninstall", "--build"]) == "unknown option for uninstall: --build")
    #expect(reason(["install", "--remove", "--build"]) == "install --remove takes no other options")
    #expect(reason(["install", "--project"]) == "--project requires a value")
    #expect(reason(["runner"]) == "runner takes install or uninstall")
    #expect(reason(["runner", "status"]) == "unknown runner action: status (install or uninstall)")
    #expect(reason(["runner", "uninstall", "--build"]) == "unknown option for runner uninstall: --build")
    #expect(reason(["runner", "install", "--project"]) == "--project requires a value")
  }
}

struct AppBundleInfoTests {
  private func plist(_ object: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
  }

  @Test func readsTheInfoPlist() throws {
    let info = try #require(AppBundleInfo(plist: plist([
      "CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleName": "ExampleApp",
      "CFBundleShortVersionString": "1.0", "CFBundleVersion": "7", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]
    ], format: .binary)))
    #expect(info == AppBundleInfo(bundleID: "com.example.app", name: "Example", version: "1.0", build: "7", platforms: ["iPhoneSimulator"]))
    #expect(info.runs(on: .simulator))
    #expect(!info.runs(on: .device))
    let json = info.json(path: "/a/Example.app")
    #expect(json["bundleID"] as? String == "com.example.app")
    #expect(json["path"] as? String == "/a/Example.app")

    let bare = try #require(AppBundleInfo(plist: plist(["CFBundleIdentifier": "com.example.bare", "CFBundleName": "Bare"])))
    #expect(bare.name == "Bare")
    // No platforms: not checked, the tools decide.
    #expect(bare.runs(on: .device) && bare.runs(on: .simulator))
    #expect(bare.json(path: "/b")["version"] is NSNull)

    #expect(AppBundleInfo(plist: try plist(["CFBundleName": "NoID"])) == nil)
    #expect(AppBundleInfo(plist: try plist(["CFBundleIdentifier": ""])) == nil)
    #expect(AppBundleInfo(plist: Data("not a plist".utf8)) == nil)
  }

  @Test func findsTheOneAppOfAnIPA() {
    let listing = """
    Payload/
    Payload/Example.app/
    Payload/Example.app/Info.plist
    Payload/Example.app/PlugIns/Widget.appex/Info.plist
    Payload/Example.app/Watch/Watch.app/Info.plist
    Payload/.app/Info.plist
    Symbols/Info.plist
    """
    #expect(AppInstall.infoPlistEntries(listing) == ["Payload/Example.app/Info.plist"])
    #expect(AppInstall.unzipPattern("Payload/A[1]*?.app/Info.plist") == "Payload/A[[]1][*][?].app/Info.plist")
  }

  @Test func readsAnAppAndAnIPAOnDisk() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var tools = fakeLogTools(home: root)
    tools.commands.run = { try Shell.run($0, $1, timeout: $2) }

    let app = root.appendingPathComponent("Payload/Example.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app", "CFBundleVersion": "3"],
                                       format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    #expect(try AppInstall.readBundle(at: app, tools: tools).bundleID == "com.example.app")

    let ipa = root.appendingPathComponent("Example.ipa")
    _ = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.appendingPathComponent("Payload").path, ipa.path], timeout: 30)
    let info = try AppInstall.readBundle(at: ipa, tools: tools)
    #expect(info.bundleID == "com.example.app")
    #expect(info.build == "3")

    func failure(_ url: URL) -> String {
      do {
        _ = try AppInstall.readBundle(at: url, tools: tools)
        return "read"
      } catch {
        #expect(error.code == .appBundleInvalid)
        return error.message
      }
    }
    #expect(failure(root.appendingPathComponent("Missing.app")).hasSuffix("Missing.app does not exist"))
    #expect(failure(root).hasSuffix("is not an .app directory or an .ipa file"))
    let empty = root.appendingPathComponent("Empty.app", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(failure(empty).hasSuffix("Empty.app has no Info.plist"))
    try Data("x".utf8).write(to: empty.appendingPathComponent("Info.plist"))
    #expect(failure(empty).hasSuffix("Empty.app/Info.plist is not a property list with a CFBundleIdentifier"))
    let notZip = root.appendingPathComponent("NotZip.ipa")
    try Data("x".utf8).write(to: notZip)
    #expect(failure(notZip).contains("cannot read \(notZip.path) as a zip file"))
    let noApp = root.appendingPathComponent("NoApp.ipa")
    _ = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", empty.path, noApp.path], timeout: 30)
    #expect(failure(noApp).hasSuffix("has 0 apps in Payload/; an .ipa has one"))
  }
}

struct AppInstallToolOutputTests {
  @Test func simctlSaysWhyAfterItsFirstLine() {
    let shutdown = ShellError(args: [], status: 149, output: """
    An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):
    Unable to lookup in current state: Shutdown
    """)
    #expect(AppInstall.simctlReason(shutdown) == "Unable to lookup in current state: Shutdown (exit 149)")
    let wrongPlatform = ShellError(args: [], status: 4, output: """
    An error was encountered processing the command (domain=IXUserPresentableErrorDomain, code=4):
    App installation failed: “Example” Needs to Be Updated
    This app needs to be updated by the developer to work on this version of iOS.
    Underlying error (domain=IXUserPresentableErrorDomain, code=4):
    """)
    #expect(AppInstall.simctlReason(wrongPlatform) == "App installation failed: “Example” Needs to Be Updated (exit 4)")
    #expect(AppInstall.simctlReason(ShellError(args: [], status: 1, output: "")) == "exit 1")
    #expect(AppInstall.simctlReason(ShellError(args: [], status: 15, output: "", timedOutAfter: 300)) == "timed out after 300 s")
  }

  /// The error of `devicectl device install app --json-output` for an app whose entitlements no profile allows.
  static let provisioningFailure = #"""
  {"info":{"outcome":"failed"},"error":{"code":3002,"domain":"com.apple.dt.CoreDeviceError","userInfo":{
   "NSLocalizedDescription":{"string":"Failed to install the app on the device."},
   "NSUnderlyingError":{"error":{"code":14,"domain":"IXUserPresentableErrorDomain","userInfo":{
    "NSLocalizedDescription":{"string":"Unable to Install “Example”"},
    "NSLocalizedFailureReason":{"string":"This app cannot be installed because its integrity could not be verified."},
    "NSUnderlyingError":{"error":{"code":13,"domain":"MIInstallerErrorDomain","userInfo":{
     "NSLocalizedDescription":{"string":"Failed to verify code signature of /var/x/Example.app : 0xe8008015 (A valid provisioning profile for this executable was not found.)"}}}}}}}}}}
  """#

  @Test func devicectlSaysWhyInItsInnermostError() {
    #expect(AppInstall.devicectlFailure(DevicectlRun(json: Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8))) == nil)
    let failed = DevicectlRun(json: Data(Self.provisioningFailure.utf8), error: ShellError(args: [], status: 1, output: "ERROR: …"))
    #expect(AppInstall.devicectlFailure(failed) == "Failed to install the app on the device. Failed to verify code signature of "
      + "/var/x/Example.app : 0xe8008015 (A valid provisioning profile for this executable was not found.)")
    // No JSON: the first line of what it printed, or the time limit.
    #expect(AppInstall.devicectlFailure(DevicectlRun(error: ShellError(args: [], status: 1, output: "ERROR: no device\nmore"))) == "ERROR: no device")
    #expect(AppInstall.devicectlFailure(DevicectlRun(error: ShellError(args: [], status: 15, output: "", timedOutAfter: 300))) == "timed out after 300 s")
    #expect(AppInstall.devicectlFailure(DevicectlRun(json: Data(#"{"info":{"outcome":"failed"}}"#.utf8))) == "devicectl reported failed")
    #expect(AppInstall.devicectlReason(["userInfo": ["NSLocalizedDescription": ["string": "Only this"]]]) == "Only this")
    #expect(AppInstall.devicectlReason([:]) == nil)
  }
}

struct AppInstallCommandTests {
  /// A booted simulator SIM-ON and a connected device DEV-ON (fakeLogTools), apps written to `root`.
  private struct Setup {
    let root: URL
    let output = CapturedOutput()
    let xcrunCalls = Locked<[[String]]>([])
    let devicectlCalls = Locked<[[String]]>([])

    init() throws {
      root = try temporaryDirectory()
    }

    func app(_ name: String = "Example", platform: String) throws -> URL {
      let app = root.appendingPathComponent("\(name).app", isDirectory: true)
      try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": "com.example.app", "CFBundleName": name, "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "7", "CFBundleSupportedPlatforms": [platform]
      ], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
      return app
    }

    /// `xcrun` answers with `simctl` (nil: exit 0), `devicectl info apps` with `apps`, other devicectl runs with `run`.
    func tools(simctl: @escaping @Sendable ([String]) throws -> String = { _ in "" },
               apps: [[String: Any]]? = [],
               run: DevicectlRun = DevicectlRun(json: Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8))) -> AppTools {
      let xcrunCalls = xcrunCalls
      let devicectlCalls = devicectlCalls
      let appsJSON = apps.map { apps in
        CLIOutput.json(["info": ["outcome": "success"], "result": [
          "apps": apps, "defaultAppsIncluded": true, "removableAppsIncluded": true, "hiddenAppsIncluded": true, "internalAppsIncluded": true
        ]])
      }
      let base = fakeLogTools(home: root, output: output, xcrun: { args in
        xcrunCalls.withLock { $0.append(args) }
        return try simctl(args)
      }, devicectl: { args in
        guard let appsJSON else { throw ShellError(args: args, status: 1, output: "ERROR") }
        return appsJSON
      })
      return AppTools(base: base, devicectl: { args, _ in
        devicectlCalls.withLock { $0.append(args) }
        return run
      })
    }
  }

  @Test func installsOnASimulatorWithSimctl() throws {
    let setup = try Setup()
    let app = try setup.app(platform: "iPhoneSimulator")
    let status = AppInstall.install(AppInstallOptions(path: "Example.app", target: LogTargetOptions(udid: "SIM-ON")), tools: setup.tools())
    #expect(status == 0)
    #expect(setup.xcrunCalls.value.last == ["simctl", "install", "SIM-ON", app.path])
    let object = setup.output.object
    #expect(object["ok"] as? Bool == true)
    let json = try #require(object["app"] as? [String: Any])
    #expect(json["bundleID"] as? String == "com.example.app")
    #expect(json["name"] as? String == "Example")
    #expect(json["version"] as? String == "1.0")
    #expect(json["build"] as? String == "7")
    #expect(json["path"] as? String == app.path)
    #expect((object["device"] as? [String: Any])?["kind"] as? String == "simulator")
    #expect(setup.output.lines.count == 1)
  }

  @Test func installsOnADeviceWithDevicectl() throws {
    let setup = try Setup()
    let app = try setup.app(platform: "iPhoneOS")
    #expect(AppInstall.install(AppInstallOptions(path: app.path, target: LogTargetOptions(udid: "DEV-ON")), tools: setup.tools()) == 0)
    #expect(setup.devicectlCalls.value == [["device", "install", "app", "--device", "DEV-ON", app.path]])
    #expect((setup.output.object["device"] as? [String: Any])?["name"] as? String == "Test Phone")
  }

  @Test func refusesBeforeSendingAndReportsTheToolsFailures() throws {
    let setup = try Setup()
    _ = try setup.app("Sim", platform: "iPhoneSimulator")
    _ = try setup.app("Dev", platform: "iPhoneOS")
    func install(_ path: String, _ udid: String, _ tools: AppTools) -> (Int32, [String: Any]) {
      let output = CapturedOutput()
      var tools = tools
      tools.base.write = { output.write($0) }
      return (AppInstall.install(AppInstallOptions(path: path, target: LogTargetOptions(udid: udid)), tools: tools), output.object)
    }
    var (status, object) = install("Dev.app", "SIM-ON", setup.tools())
    #expect(status == 1)
    #expect(object["code"] as? String == "app_platform_mismatch")
    #expect((object["error"] as? String)?.contains("build it for the simulator (-sdk iphonesimulator)") == true)
    (status, object) = install("Sim.app", "DEV-ON", setup.tools())
    #expect(object["code"] as? String == "app_platform_mismatch")
    #expect((object["error"] as? String)?.contains("is a device, which runs iPhoneOS apps") == true)
    #expect(setup.devicectlCalls.value.isEmpty)
    #expect(!setup.xcrunCalls.value.contains { $0.prefix(2) == ["simctl", "install"] })

    (status, object) = install("Sim.app", "SIM-OFF", setup.tools())
    #expect(object["code"] as? String == "device_unavailable")
    #expect((object["error"] as? String)?.contains("xcrun simctl boot SIM-OFF") == true)
    (status, object) = install("Dev.app", "DEV-OFF", setup.tools())
    #expect(object["code"] as? String == "device_unavailable")
    (status, object) = install("Sim.app", "NOPE", setup.tools())
    #expect(object["code"] as? String == "device_unavailable")

    let simctlFails = setup.tools(simctl: { args in
      guard args.prefix(2) == ["simctl", "install"] else { return "" }
      throw ShellError(args: args, status: 4, output: "An error was encountered (domain=x, code=4):\nApp installation failed: no")
    })
    (status, object) = install("Sim.app", "SIM-ON", simctlFails)
    #expect(status == 1)
    #expect(object["code"] as? String == "app_install_failed")
    #expect(object["error"] as? String == "simctl install failed: App installation failed: no (exit 4)")

    let devicectlFails = setup.tools(run: DevicectlRun(json: Data(AppInstallToolOutputTests.provisioningFailure.utf8),
                                                       error: ShellError(args: [], status: 1, output: "")))
    (status, object) = install("Dev.app", "DEV-ON", devicectlFails)
    #expect(object["code"] as? String == "app_install_failed")
    #expect((object["error"] as? String)?.hasSuffix("(A valid provisioning profile for this executable was not found.)") == true)

    (status, object) = install("Missing.app", "SIM-ON", setup.tools())
    #expect(object["code"] as? String == "app_bundle_invalid")
  }

  @Test func theRunnerOfASessionNamesTheDevice() throws {
    let setup = try Setup()
    _ = try setup.app(platform: "iPhoneSimulator")
    var tools = setup.tools()
    tools.base.environment = ["RELAY_SESSION": "nobody"]
    #expect(AppInstall.install(AppInstallOptions(path: "Example.app"), tools: tools) == 3)
    #expect(setup.output.object["code"] as? String == "runner_unavailable")
  }

  @Test func uninstallsWhatIsInstalled() throws {
    let setup = try Setup()
    // A simulator: simctl get_app_container finds it.
    #expect(AppInstall.uninstall(AppUninstallOptions(bundleID: "com.example.app", target: LogTargetOptions(udid: "SIM-ON")),
                                 tools: setup.tools(simctl: { _ in "/path/Example.app" })) == 0)
    #expect(setup.xcrunCalls.value.last == ["simctl", "uninstall", "SIM-ON", "com.example.app"])
    #expect(setup.output.object["bundleID"] as? String == "com.example.app")

    // A device: devicectl lists it.
    let device = setup.tools(simctl: { args in
      if args.prefix(2) == ["simctl", "get_app_container"] { throw ShellError(args: args, status: 148, output: "Invalid device: DEV-ON") }
      return ""
    }, apps: [["bundleIdentifier": "com.example.app"]])
    #expect(AppInstall.uninstall(AppUninstallOptions(bundleID: "com.example.app", target: LogTargetOptions(udid: "DEV-ON")), tools: device) == 0)
    #expect(setup.devicectlCalls.value == [["device", "uninstall", "app", "--device", "DEV-ON", "com.example.app"]])
  }

  @Test func uninstallSaysWhatItDidNotRemove() throws {
    let setup = try Setup()
    func uninstall(_ bundleID: String, _ udid: String, _ tools: AppTools) -> (Int32, [String: Any]) {
      let output = CapturedOutput()
      var tools = tools
      tools.base.write = { output.write($0) }
      return (AppInstall.uninstall(AppUninstallOptions(bundleID: bundleID, target: LogTargetOptions(udid: udid)), tools: tools), output.object)
    }
    let notInstalled = setup.tools(simctl: { args in
      if args.prefix(2) == ["simctl", "get_app_container"] {
        throw ShellError(args: args, status: 2, output: "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):")
      }
      return ""
    })
    var (status, object) = uninstall("com.example.gone", "SIM-ON", notInstalled)
    #expect(status == 6)
    #expect(object["code"] as? String == "app_not_installed")
    #expect(object["error"] as? String == "com.example.gone is not installed on Test Sim; nothing was removed")
    #expect(!setup.xcrunCalls.value.contains { $0.prefix(2) == ["simctl", "uninstall"] })

    let calls = setup.xcrunCalls.value.count
    for bundleID in ["host", "dev.devicerelay.local.RelayRunnerHost", "dev.example.RelayRunnerHost.UITests.xctrunner"] {
      (status, object) = uninstall(bundleID, "SIM-ON", setup.tools())
      #expect(status == 1)
      #expect(object["code"] as? String == "app_uninstall_refused", "\(bundleID)")
    }
    #expect(!AppInstall.isRunnerApp("com.example.RelayRunnerHostile"))
    #expect(setup.xcrunCalls.value.count == calls)

    // Not known to be missing (devicectl fails): sent, and the tool's failure is reported.
    let unknown = setup.tools(simctl: { args in
      if args.prefix(2) == ["simctl", "get_app_container"] { throw ShellError(args: args, status: 148, output: "Invalid device") }
      return ""
    }, apps: nil, run: DevicectlRun(error: ShellError(args: [], status: 1, output: "ERROR: the device went away")))
    (status, object) = uninstall("com.example.app", "DEV-ON", unknown)
    #expect(status == 1)
    #expect(object["code"] as? String == "app_uninstall_failed")
    #expect(object["error"] as? String == "devicectl device uninstall app failed: ERROR: the device went away")

    let simctlFails = setup.tools(simctl: { args in
      if args.prefix(2) == ["simctl", "uninstall"] { throw ShellError(args: args, status: 1, output: "x\nUnable to remove") }
      return "/path"
    })
    (status, object) = uninstall("com.example.app", "SIM-ON", simctlFails)
    #expect(object["code"] as? String == "app_uninstall_failed")
    #expect(object["error"] as? String == "simctl uninstall failed: x (exit 1)")
  }
}
