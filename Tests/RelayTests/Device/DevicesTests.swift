import Foundation
@testable import Relay
import Testing

struct DeviceListTests {
  @Test func parsesPhysicalDevicesFromDevicectl() throws {
    let devices = try DeviceList.parseDevicectl(Data(devicectlList.utf8))
    #expect(devices.count == 2)
    #expect(devices[0] == Device(
      name: "Test Phone", udid: deviceUDID, kind: .device, model: "iPhone 14 Pro", os: "iOS 26.7.1", state: "connected",
      isAvailable: true, pairingState: "paired", developerModeEnabled: true, ddiServicesAvailable: true, transport: "wired"
    ))
    // Deprecated fields only, and not connected.
    #expect(devices[1] == Device(
      name: "Old Phone", udid: otherDeviceUDID, kind: .device, model: "iPhone13,3", os: "iOS 18.7.8", state: "unavailable",
      isAvailable: false, pairingState: "paired", developerModeEnabled: false, ddiServicesAvailable: false
    ))
    #expect(devices[0].osMajorVersion == 26)
  }

  @Test func rejectsDevicectlOutputWithoutResult() {
    #expect(throws: SetupError.self) { try DeviceList.parseDevicectl(Data(#"{"info":{"outcome":"failed"}}"#.utf8)) }
  }

  @Test func parsesIOSSimulatorsFromSimctl() throws {
    // Warnings before the JSON are skipped; the watchOS runtime is left out.
    let output = "simctl: warning\n" + simctlList([("S1", "iPhone 17 Pro", "Booted"), ("S2", "iPhone 17", "Shutdown")])
    let devices = try DeviceList.parseSimctl(Data(output.utf8)).sorted { $0.udid < $1.udid }
    #expect(devices == [
      Device(name: "iPhone 17 Pro", udid: "S1", kind: .simulator, model: "iPhone 17 Pro", os: "iOS 27.0", state: "booted", isAvailable: true),
      Device(name: "iPhone 17", udid: "S2", kind: .simulator, model: "iPhone 17 Pro", os: "iOS 27.0", state: "shutdown", isAvailable: true)
    ])
    #expect(devices[0].isBooted && devices[0].isActive)
    #expect(!devices[1].isActive)
  }

  @Test func namesRuntimesAndDeviceTypes() {
    #expect(DeviceList.osName(simulatorRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5") == "iOS 26.5")
    #expect(DeviceList.osName(simulatorRuntime: "com.apple.CoreSimulator.SimRuntime.xrOS-2-0") == "xrOS 2.0")
    #expect(DeviceList.osName(simulatorRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-26-7-1") == "iOS 26.7.1")
    #expect(DeviceList.modelName(simulatorDeviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5") == "iPad Pro 11 inch M5")
  }

  @Test func deviceTypeRuntimesEndTheVersionAtTheDeviceType() throws {
    // iPhone Duo's runtime is made for its device type, which follows the version.
    let os = DeviceList.osName(simulatorRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4")
    #expect(os == "iOS 27.2")
    let duo = Device(name: "iPhone Duo", udid: "S3", kind: .simulator, model: "iPhone Duo", os: os, state: "shutdown", isAvailable: true)
    #expect(duo.osVersion == [27, 2])
    #expect(duo.matches(os: "27.2") && duo.matches(os: "27") && !duo.matches(os: "27.0"))
    let selection = try DeviceSelector.select(from: [duo], udid: nil, name: "iPhone Duo", os: "27.2")
    #expect(selection.device.udid == "S3")
    // A runtime without a number after the platform keeps its old name.
    #expect(DeviceList.osName(simulatorRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-beta") == "iOS beta")
  }

  @Test func loadsSimulatorsEvenWhenDevicectlFails() throws {
    let host = FakeHost()
    var commands = host.commands
    commands.devicectlJSON = { _, _ in throw ShellError(args: ["devicectl"], status: 1, output: "") }
    let (devices, warnings) = try DeviceList.load(commands)
    #expect(devices.map(\.udid) == [simulatorUDID])
    #expect(warnings.count == 1)
    #expect(warnings[0].hasPrefix("cannot list physical devices with devicectl; showing simulators only\n"))
    #expect(warnings[0].contains("devicectl details: xcrun devicectl failed (1)"))
    #expect(!warnings[0].contains("sandbox"))
    let json = try #require(try JSONSerialization.jsonObject(with: DeviceList.json(devices)) as? [[String: Any]])
    #expect(json.count == 1)
    #expect(json[0]["kind"] as? String == "simulator")
  }

  @Test func aDevicectlThatTimesOutLeavesTheSimulatorsAndAWarning() throws {
    var commands = FakeHost().commands
    commands.devicectlJSON = { args, timeout in throw ShellError(args: ["devicectl"] + args, status: 15, output: "", timedOutAfter: timeout) }
    let (devices, warnings) = try DeviceList.load(commands)
    #expect(devices.map(\.udid) == [simulatorUDID])
    #expect(warnings.count == 1)
    #expect(warnings[0].hasPrefix("cannot list physical devices with devicectl; showing simulators only\n"))
    #expect(warnings[0].contains("xcrun devicectl list devices timed out after 60 s; "))
    #expect(!warnings[0].contains("sandbox"))
  }

  @Test func devicectlPermissionFailuresExplainTheSandboxBeforeTheDetails() throws {
    let outputs = [
      "Operation not permitted", "Permission denied", "Read-only file system",
      "The file couldn’t be saved because you don’t have permission.", "Access denied",
      "Error Domain=NSCocoaErrorDomain Code=513", "domain=NSPOSIXErrorDomain, code=13",
      "Operation not permitted\n" + Array(repeating: "CoreDevice is waiting", count: 25).joined(separator: "\n")
    ]
    for output in outputs {
      var commands = FakeHost().commands
      commands.devicectlJSON = { _, _ in throw ShellError(args: ["devicectl"], status: 1, output: output) }
      let (devices, warnings) = try DeviceList.load(commands)
      #expect(devices.map(\.udid) == [simulatorUDID])
      let warning = try #require(warnings.first)
      let summary = try #require(warning.components(separatedBy: .newlines).first)
      #expect(summary.contains("showing simulators only"))
      #expect(summary.contains("relay may be running inside a sandbox"))
      #expect(summary.contains("Run relay outside the sandbox"))
      #expect(summary.contains("docs/setup.md"))
      #expect(warning.contains("devicectl details:"))
    }
  }

  @Test func devicectlFilePermissionErrorsAndUnderlyingErrorsGetTheHint() {
    let errors = [
      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
      NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)),
      NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError),
      NSError(domain: "CoreDevice", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    ]
    for error in errors {
      #expect(DeviceList.devicectlWarning(error).contains("relay may be running inside a sandbox"))
    }
  }

  @Test func unrelatedDevicectlFailuresDoNotSuggestASandbox() {
    for output in ["Timed out waiting for CoreDeviceService", "failed to write the output file", "No space left on device",
                   "Error Domain=NSPOSIXErrorDomain Code=130", "Error Domain=NSCocoaErrorDomain Code=5130"] {
      #expect(!DeviceList.devicectlWarning(ShellError(args: ["devicectl"], status: 1, output: output)).contains("sandbox"))
    }
    #expect(!DeviceList.devicectlWarning(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).contains("sandbox"))
    // A timeout plus an explicit permission denial is still actionable.
    let denied = ShellError(args: ["devicectl"], status: 15, output: "Permission denied", timedOutAfter: 60)
    #expect(DeviceList.devicectlWarning(denied).contains("relay may be running inside a sandbox"))
  }

  @Test func skipsDevicectlWhenOnlySimulatorsCanBePicked() throws {
    let simulators = [simulator("iPhone 17 Pro", udid: simulatorUDID)]
    #expect(DeviceList.devicectlSkipReason(udid: nil, simulator: true, simulators: simulators) == "--simulator")
    #expect(DeviceList.devicectlSkipReason(udid: simulatorUDID.lowercased(), simulator: false, simulators: simulators) == "--udid is a simulator")
    // A device's UDID, or no --udid: devices must be listed (and --device may name a device too).
    #expect(DeviceList.devicectlSkipReason(udid: deviceUDID, simulator: false, simulators: simulators) == nil)
    #expect(DeviceList.devicectlSkipReason(udid: nil, simulator: false, simulators: simulators) == nil)

    let devicectlCalls = Locked(0)
    var commands = FakeHost().commands
    let devicectlJSON = commands.devicectlJSON
    commands.devicectlJSON = { args, timeout in
      devicectlCalls.withLock { $0 += 1 }
      return try devicectlJSON(args, timeout)
    }
    let (simulatorOnly, warnings) = try DeviceList.load(commands, udid: simulatorUDID)
    #expect(devicectlCalls.value == 0)
    #expect(simulatorOnly.map(\.udid) == [simulatorUDID])
    #expect(warnings.isEmpty)
    _ = try DeviceList.load(commands, simulator: true)
    #expect(devicectlCalls.value == 0)
    let (all, _) = try DeviceList.load(commands, udid: deviceUDID)
    #expect(devicectlCalls.value == 1)
    #expect(all.map(\.udid) == [deviceUDID, otherDeviceUDID, simulatorUDID])
  }

  @Test func sortsDevicesThenActiveSimulators() {
    let sorted = DeviceList.sort([
      simulator("b", udid: "1"), simulator("a", udid: "2"), simulator("z", udid: "3", booted: true),
      device("off", udid: "4", available: false), device("on", udid: "5")
    ])
    #expect(sorted.map(\.udid) == ["5", "4", "3", "2", "1"])
  }

  @Test func alignsTheTableByDisplayWidth() {
    let table = DeviceList.table([device("テストのiPhone", udid: "D1"), simulator("iPhone 17", udid: "S1")])
    let lines = table.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    // The UDID column starts at the same terminal column on every line.
    let columns = lines.map { line in DeviceList.displayWidth(String(line[..<line.range(of: line.contains("UDID") ? "UDID" : line.contains("D1") ? "D1" : "S1")!.lowerBound])) }
    #expect(Set(columns).count == 1)
    #expect(DeviceList.displayWidth("のiPhone") == 8)
  }

  @Test func encodesJSON() throws {
    let data = try DeviceList.json([device("Phone", udid: "D1")])
    let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(objects.first?["udid"] as? String == "D1")
    #expect(objects.first?["kind"] as? String == "device")
    #expect(objects.first?["available"] as? Bool == true)
  }

  /// Like every other `--json`: one line with sorted keys (a pretty-printed array was the odd one out).
  @Test func jsonIsOneLineLikeTheOthers() throws {
    let data = try DeviceList.json([device("Phone", udid: "D1"), simulator("Sim", udid: "S1")])
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("\n"))
    #expect(text.hasPrefix(#"[{"available":true,"#))
    #expect(data == CLIOutput.json(try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])))
    #expect(String(decoding: try DeviceList.json([]), as: UTF8.self) == "[]")
  }
}

struct DeviceSelectorTests {
  @Test func picksByUDIDCaseInsensitively() throws {
    let devices = [device("Phone", udid: "ABC-1"), simulator("Sim", udid: "DEF-2")]
    #expect(try DeviceSelector.select(from: devices, udid: "def-2", name: nil).device.udid == "DEF-2")
    #expect(throws: SetupError.self) { try DeviceSelector.select(from: devices, udid: "missing", name: nil) }
  }

  @Test func picksByExactNameIgnoringCase() throws {
    let devices = [device("Test Phone", udid: "D1"), simulator("iPhone 17", udid: "S1"), simulator("iPhone 17 Pro", udid: "S2")]
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iphone 17").device.udid == "S1")
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "TEST PHONE").device.udid == "D1")
    // No partial matches.
    #expect(throws: SetupError.self) { try DeviceSelector.select(from: devices, udid: nil, name: "iPhone") }
  }

  @Test func sameNamesPreferTheOnlyActiveOne() throws {
    let oneBooted = [simulator("iPhone 17 Pro", udid: "S1", booted: true, os: "iOS 26.5"), simulator("iPhone 17 Pro", udid: "S2")]
    let selection = try DeviceSelector.select(from: oneBooted, udid: nil, name: "iPhone 17 Pro")
    #expect(selection.device.udid == "S1")
    #expect(selection.reason == #"--device; the only connected or booted one of 2 named "iPhone 17 Pro""#)
    // Several booted: the newest of those.
    let bothBooted = oneBooted.map { var device = $0; device.state = "booted"; return device }
    #expect(try DeviceSelector.select(from: bothBooted + [simulator("iPhone 17 Pro", udid: "S3", os: "iOS 28.0")], udid: nil,
                                      name: "iPhone 17 Pro").device.udid == "S2")
  }

  @Test func picksTheNewestRuntimeOfSimulatorsWithTheSameName() throws {
    let simulators = [simulator("iPhone 17 Pro", udid: "S1", os: "iOS 26.5"), simulator("iPhone 17 Pro", udid: "S3", os: "iOS 27.0"),
                      simulator("iPhone 17 Pro", udid: "S2", os: "iOS 26.10")]
    let selection = try DeviceSelector.select(from: simulators, udid: nil, name: "iPhone 17 Pro")
    #expect(selection.device.udid == "S3")
    #expect(selection.reason == #"--device; the newest iOS of 3 simulators named "iPhone 17 Pro""#)
    #expect(!selection.isAutomatic)
    // 26.10 is newer than 26.5: components are compared as numbers.
    #expect(try DeviceSelector.select(from: Array(simulators.prefix(1)) + simulators.suffix(1), udid: nil, name: "iPhone 17 Pro").device.udid == "S2")
    // Two on the newest runtime: nothing to tell them apart.
    let tied = simulators + [simulator("iPhone 17 Pro", udid: "S4", os: "iOS 27.0")]
    #expect {
      try DeviceSelector.select(from: tied, udid: nil, name: "iPhone 17 Pro")
    } throws: { error in
      String(describing: error).hasPrefix(#"4 devices are named "iPhone 17 Pro"; pass --udid"#)
        && String(describing: error).contains("iPhone 17 Pro (iOS 27.0, simulator, shutdown) S4")
    }
  }

  @Test func aDeviceAndASimulatorWithTheSameNameNeedAChoice() throws {
    let devices = [device("iPhone", udid: "D1", available: false), simulator("iPhone", udid: "S1"), simulator("iPhone", udid: "S2", os: "iOS 26.5")]
    #expect {
      try DeviceSelector.select(from: devices, udid: nil, name: "iPhone")
    } throws: { error in
      String(describing: error).hasPrefix(#"3 devices are named "iPhone"; pass --udid with one of them (or --simulator for the simulator):"#)
        && String(describing: error).contains("D1")
    }
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone", simulator: true).device.udid == "S1")
    // The connected device is the one in use, as before.
    var connected = devices
    connected[0] = device("iPhone", udid: "D1")
    #expect(try DeviceSelector.select(from: connected, udid: nil, name: "iPhone").device.udid == "D1")
    // Devices of the same name are never guessed by OS.
    let twoDevices = [device("iPhone", udid: "D1", available: false), device("iPhone", udid: "D2", available: false)]
    #expect(throws: SetupError.self) { try DeviceSelector.select(from: twoDevices, udid: nil, name: "iPhone") }
  }

  @Test func simulatorLeavesConnectedDevicesOut() throws {
    let devices = [device("Phone", udid: "D1"), simulator("Sim", udid: "S1", booted: true), simulator("Off", udid: "S2")]
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: nil).device.udid == "D1")
    let selection = try DeviceSelector.select(from: devices, udid: nil, name: nil, simulator: true)
    #expect(selection.device.udid == "S1")
    #expect(selection.reason == "the only booted simulator (--simulator)")
    #expect(selection.isAutomatic)
    #expect(throws: SetupError.self) { try DeviceSelector.select(from: devices, udid: "D1", name: nil, simulator: true) }

    let twoBooted = devices + [simulator("Other", udid: "S3", booted: true)]
    #expect {
      try DeviceSelector.select(from: twoBooted, udid: nil, name: nil, simulator: true)
    } throws: { error in
      String(describing: error).hasPrefix("2 simulators are booted (--simulator); pass --udid or --device:\n  Sim")
    }
  }

  @Test func simulatorWithNothingBootedListsTheNewestFirst() {
    let devices = [device("Phone", udid: "D1"), simulator("A", udid: "S1", os: "iOS 26.5"), simulator("B", udid: "S2"),
                   Device(name: "Gone", udid: "S3", kind: .simulator, os: "iOS 28.0", state: "shutdown", isAvailable: false)]
    #expect {
      try DeviceSelector.select(from: devices, udid: nil, name: nil, simulator: true)
    } throws: { error in
      let lines = String(describing: error).split(separator: "\n").map(String.init)
      return lines.first == "no booted iOS simulator (--simulator); pass --device <name> to boot one (it is shut down when relay exits):"
        && lines.dropFirst() == ["  B (iOS 27.0, simulator, shutdown) S2", "  A (iOS 26.5, simulator, shutdown) S1"]
    }
  }

  @Test func osKeepsMatchingVersionsOnly() throws {
    let devices = [device("Phone", udid: "D1"), simulator("iPhone 17 Pro", udid: "S1", os: "iOS 26.5"),
                   simulator("iPhone 17 Pro", udid: "S2"), simulator("iPhone 17 Pro", udid: "S3", booted: true, os: "iOS 26.2")]
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17 Pro", os: "26.5").device.udid == "S1")
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17 Pro", os: "27").device.udid == "S2")
    // The booted one wins without --os, and --os 26 leaves it with 26.5: still the booted one.
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17 Pro").device.udid == "S3")
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17 Pro", os: "26").device.udid == "S3")
    // Automatic: the device runs iOS 26.0, so --os 26.2 falls through to the booted simulator.
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: nil).device.udid == "D1")
    let selection = try DeviceSelector.select(from: devices, udid: nil, name: nil, os: "26.2")
    #expect(selection.device.udid == "S3")
    #expect(selection.reason == "the only booted simulator (--os 26.2)")
    #expect(try DeviceSelector.select(from: devices, udid: "s2", name: nil, simulator: true, os: "27.0").reason == "--udid --simulator --os 27.0")
    // No such version: the simulators of that name show which versions there are.
    #expect {
      try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17 Pro", os: "25")
    } throws: { error in
      String(describing: error).hasPrefix(#"no device or iOS simulator named "iPhone 17 Pro" (--os 25):"#)
        && String(describing: error).contains("iOS 26.5, simulator, shutdown) S1")
    }
  }

  @Test func matchesOSVersionsByComponent() {
    let os = { (version: String) in Device(name: "S", udid: "S", kind: .simulator, os: version, state: "shutdown", isAvailable: true) }
    #expect(os("iOS 27.0").matches(os: "27"))
    #expect(os("iOS 27.0").matches(os: "27.0"))
    #expect(os("iOS 27").matches(os: "27.0"))
    #expect(os("iOS 26.5.1").matches(os: "26.5"))
    #expect(!os("iOS 26.5").matches(os: "26.5.1"))
    #expect(!os("iOS 26.5").matches(os: "2"))
    #expect(!os("iOS 26.6").matches(os: "26.5"))
    #expect(!os("iOS 26.10").matches(os: "26.1"))
    #expect(DeviceSelector.isValidOSVersion("27") && DeviceSelector.isValidOSVersion("26.5") && DeviceSelector.isValidOSVersion("26.5.1"))
    #expect(!["", "iOS 27", "27.", ".5", "+27", "27.x", "1.2.3.4"].contains(where: DeviceSelector.isValidOSVersion))
  }

  @Test func prefersTheOnlyConnectedDevice() throws {
    let devices = [device("Phone", udid: "D1"), device("Away", udid: "D2", available: false), simulator("Sim", udid: "S1", booted: true)]
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: nil).device.udid == "D1")
  }

  @Test func refusesToGuessBetweenConnectedDevices() {
    let devices = [device("Phone", udid: "D1"), device("Pad", udid: "D2"), simulator("Sim", udid: "S1", booted: true)]
    #expect(throws: SetupError.self) { try DeviceSelector.select(from: devices, udid: nil, name: nil) }
  }

  @Test func fallsBackToTheOnlyBootedSimulator() throws {
    let devices = [device("Away", udid: "D1", available: false), simulator("Sim", udid: "S1", booted: true), simulator("Off", udid: "S2")]
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: nil).device.udid == "S1")
  }

  @Test func listsCandidatesWhenNothingOrTooMuchIsRunning() {
    let none = [simulator("Off", udid: "S2")]
    #expect {
      try DeviceSelector.select(from: none, udid: nil, name: nil)
    } throws: { error in
      String(describing: error).contains("Off (iOS 27.0, simulator, shutdown) S2")
    }
    let two = [simulator("A", udid: "S1", booted: true), simulator("B", udid: "S2", booted: true)]
    #expect {
      try DeviceSelector.select(from: two, udid: nil, name: nil)
    } throws: { error in
      String(describing: error).hasPrefix("2 simulators are booted")
    }
  }
}

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

struct AutomaticDeviceTests {
  private let devices = [sessionSimulator("iPhone 17", "SIM-A"), sessionSimulator("iPhone 17 Pro", "SIM-B"), sessionSimulator("iPhone Air", "SIM-C", booted: false)]

  @Test func leavesOutDevicesInUse() throws {
    let selection = try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-A": "session a"])
    #expect(selection.device.udid == "SIM-B")
    #expect(selection.isAutomatic)
  }

  @Test func caseOfTheUDIDDoesNotMatter() throws {
    let lower = [sessionSimulator("iPhone 17", "sim-a"), sessionSimulator("iPhone 17 Pro", "sim-b")]
    #expect(try DeviceSelector.select(from: lower, udid: nil, name: nil, inUse: ["SIM-A": "session a"]).device.udid == "sim-b")
  }

  @Test func nothingFreeSaysWhoHoldsIt() {
    #expect {
      try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-A": "session a", "SIM-B": "session b"])
    } throws: { error in
      let message = "\(error)"
      return message.contains("in use by another relay start") && message.contains("session a") && message.contains("session b")
        && message.contains("SIM-C")
    }
  }

  @Test func severalFreeStillNeedAName() {
    #expect(throws: SetupError.self) {
      try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-X": "session x"])
    }
  }

  /// A named device is not replaced by another one: the device lock then says it is in use.
  @Test func aNamedDeviceIsStillPicked() throws {
    #expect(try DeviceSelector.select(from: devices, udid: "SIM-A", name: nil, inUse: ["SIM-A": "session a"]).device.udid == "SIM-A")
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: "iPhone 17", inUse: ["SIM-A": "session a"]).device.udid == "SIM-A")
  }

  @Test func withoutAnyInUseItIsAsBefore() throws {
    #expect(try DeviceSelector.select(from: [sessionSimulator("iPhone 17", "SIM-A")], udid: nil, name: nil).device.udid == "SIM-A")
  }

  @Test func prepareClaimsTheDeviceBeforeBooting() throws {
    let commands = HostCommands(
      xcrun: { arguments, _ in
        if arguments.prefix(3) == ["simctl", "list", "devices"] {
          return #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"SIM-C","name":"iPhone Air","state":"Shutdown","isAvailable":true}]}}"#
        }
        Issue.record("should not run: \(arguments)")
        return ""
      },
      devicectlJSON: { _, _ in Data() },
      run: { _, _, _ in "" }
    )
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect {
      _ = try StartSetup.prepare(
        StartOptions(udid: "SIM-C"), commands: commands, configURL: home.appendingPathComponent("config.json"),
        resolveProject: { _ in (home, .option) }, staleness: { _, _ in nil }, info: { _ in },
        claimDevice: { throw SetupError(description: "in use: \($0.udid)") }
      )
    } throws: { "\($0)".contains("in use: SIM-C") }
  }
}
