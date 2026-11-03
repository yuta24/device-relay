import Foundation
@testable import relay
import Testing

// Canned output of the external commands. UDIDs, names, and Team IDs are dummies.

private let deviceUDID = "00000000-0000000000000001"
private let otherDeviceUDID = "00000000-0000000000000002"
private let simulatorUDID = "11111111-1111-1111-1111-111111111111"

/// `devicectl list devices`: a connected device (new `properties` only), a paired device that is not
/// connected (deprecated fields only), and a simulator, which devicectl lists too.
private let devicectlList = """
{"info":{"outcome":"success"},"result":{"devices":[
 {"identifier":"AAAAAAAA-0000-0000-0000-000000000001","visibilityClass":"default","properties":{
   "connection":{"pairingState":"paired","state":"connected","transportType":"wired"},
   "hardware":{"marketingName":"iPhone 14 Pro","platform":"iOS","reality":"physical","udid":"\(deviceUDID)"},
   "software":{"osVersionNumber":{"stringValue":"26.7.1"}},
   "state":{"bootState":"booted","developerModeStatus":{"enabled":{"mode":1}},"name":"Test Phone"}},
  "deviceProperties":{"ddiServicesAvailable":true}},
 {"identifier":"AAAAAAAA-0000-0000-0000-000000000002","visibilityClass":"default",
  "connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"},
  "deviceProperties":{"ddiServicesAvailable":false,"name":"Old Phone","osVersionNumber":"18.7.8","developerModeStatus":"disabled"},
  "hardwareProperties":{"platform":"iOS","productType":"iPhone13,3","udid":"\(otherDeviceUDID)"}},
 {"identifier":"\(simulatorUDID)","visibilityClass":"simulators","properties":{
   "connection":{"pairingState":"paired","state":"disconnected","transportType":"sameMachine"},
   "hardware":{"reality":"simulated","udid":"\(simulatorUDID)"},"state":{"name":"iPhone 17 Pro"}}}
]}}
"""

private func simctlList(_ entries: [(udid: String, name: String, state: String)], runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0") -> String {
    let devices = entries.map {
        #"{"udid":"\#($0.udid)","name":"\#($0.name)","state":"\#($0.state)","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}"#
    }
    return #"{"devices":{"\#(runtime)":[\#(devices.joined(separator: ","))],"com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[{"udid":"W","name":"Watch","state":"Booted","isAvailable":true}]}}"#
}

/// The dummy certificate's SHA-1 and PEM: CN "Apple Development: Test User (ABCDE12345)", OU "TEAM000001".
private let certificateSHA1 = "3335F4D53A603E933F7178D3C26B025F393032D5"
private let certificatePEM = """
-----BEGIN CERTIFICATE-----
MIICyTCCAjKgAwIBAgIUMat+UOub1MDH0enRPmgbQvGUGp8wDQYJKoZIhvcNAQEL
BQAwgYYxGjAYBgoJkiaJk/IsZAEBDApEVU1NWVVTRVIxMTIwMAYDVQQDDClBcHBs
ZSBEZXZlbG9wbWVudDogVGVzdCBVc2VyIChBQkNERTEyMzQ1KTETMBEGA1UECwwK
VEVBTTAwMDAwMTESMBAGA1UECgwJVGVzdCBVc2VyMQswCQYDVQQGEwJVUzAeFw0y
NjEwMjkwMjI2MjdaFw0yNjEwMzAwMjI2MjdaMIGGMRowGAYKCZImiZPyLGQBAQwK
RFVNTVlVU0VSMTEyMDAGA1UEAwwpQXBwbGUgRGV2ZWxvcG1lbnQ6IFRlc3QgVXNl
ciAoQUJDREUxMjM0NSkxEzARBgNVBAsMClRFQU0wMDAwMDExEjAQBgNVBAoMCVRl
c3QgVXNlcjELMAkGA1UEBhMCVVMwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGB
AMKE/RsTtbPvPFlnaTXhIOWY+VXU+CGldR8E+cuLCrhu3FGJNSODgzqHuiE7iWpB
q5BattmxfgGQM9ODcp9qBT+9FGyxl9c5UvJ8CMlqHIhC6eDtlgxeymi/NVqTcnc7
1U0COar5PACWMOxgJ/5/6obyxDDh1gPBld1gFMX4nfHtAgMBAAGjMjAwMB0GA1Ud
DgQWBBTqjaTmc6srBoCyROiboc3SUps4vTAPBgNVHRMBAf8EBTADAQH/MA0GCSqG
SIb3DQEBCwUAA4GBAFJM0QWd0p61Jpyg2I/h136F/oIFYuSeq9IrGTrdbwOxoBg6
qVLTGs0zH3Wy8V07B297P+8i24Fss9708/AdeeuVoDhlE1tz1C4TCnb3cwOezopt
YYKaR9BBphXqqlPWKOki1w+3uWBpU7PzuQhoBzfF1MOhOciVeSkpvMNEf51c
-----END CERTIFICATE-----
"""

private let findIdentityOutput = """
  1) \(certificateSHA1) "Apple Development: Test User (ABCDE12345)"
  2) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Test User (TEAM000001)"
     2 valid identities found
"""

private let findCertificateOutput = """
SHA-256 hash: 00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF
SHA-1 hash: \(certificateSHA1)
\(certificatePEM)
"""

/// Fake external commands that record the xcrun calls.
private final class FakeHost {
    var devicectl = devicectlList
    var simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Shutdown")])
    var locked: Bool? = false
    var findIdentity = findIdentityOutput
    var xcrunCalls: [[String]] = []

    var commands: HostCommands {
        HostCommands(
            xcrun: { [self] args in
                xcrunCalls.append(args)
                switch args.first {
                case "simctl" where args.dropFirst().first == "list": return simctl
                case "xcodebuild": return "Xcode 27.0\nBuild version 27A000a\n"
                case "--version": return "xcrun version 72.\n"
                case "--find": return "/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl\n"
                default: return ""
                }
            },
            devicectlJSON: { [self] args in
                if args.starts(with: ["list", "devices"]) {
                    return Data(devicectl.utf8)
                }
                if args.starts(with: ["device", "info", "lockState"]), let locked {
                    return Data(#"{"result":{"passcodeRequired":\#(locked),"unlockedSinceBoot":true}}"#.utf8)
                }
                throw ShellError(args: args, status: 1, output: "")
            },
            run: { [self] executable, args in
                switch (executable, args.first) {
                case ("/usr/bin/security", "find-identity"): return findIdentity
                case ("/usr/bin/security", "find-certificate"):
                    guard args.last == "Apple Development:" else { throw ShellError(args: args, status: 44, output: "") }
                    return findCertificateOutput
                case ("/usr/bin/xcode-select", _): return "/Applications/Xcode.app/Contents/Developer\n"
                default: throw ShellError(args: args, status: 1, output: "")
                }
            }
        )
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func device(_ name: String, udid: String, available: Bool = true) -> Device {
    Device(name: name, udid: udid, kind: .device, os: "iOS 26.0", state: available ? "connected" : "unavailable", isAvailable: available,
           pairingState: "paired", developerModeEnabled: true, ddiServicesAvailable: true)
}

private func simulator(_ name: String, udid: String, booted: Bool = false, os: String = "iOS 27.0") -> Device {
    Device(name: name, udid: udid, kind: .simulator, os: os, state: booted ? "booted" : "shutdown", isAvailable: true)
}

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
        commands.devicectlJSON = { _ in throw ShellError(args: ["devicectl"], status: 1, output: "") }
        let (devices, warnings) = try DeviceList.load(commands)
        #expect(devices.map(\.udid) == [simulatorUDID])
        #expect(warnings.count == 1)
    }

    @Test func skipsDevicectlWhenOnlySimulatorsCanBePicked() throws {
        let simulators = [simulator("iPhone 17 Pro", udid: simulatorUDID)]
        #expect(DeviceList.devicectlSkipReason(udid: nil, simulator: true, simulators: simulators) == "--simulator")
        #expect(DeviceList.devicectlSkipReason(udid: simulatorUDID.lowercased(), simulator: false, simulators: simulators) == "--udid is a simulator")
        // A device's UDID, or no --udid: devices must be listed (and --device may name a device too).
        #expect(DeviceList.devicectlSkipReason(udid: deviceUDID, simulator: false, simulators: simulators) == nil)
        #expect(DeviceList.devicectlSkipReason(udid: nil, simulator: false, simulators: simulators) == nil)

        var devicectlCalls = 0
        var commands = FakeHost().commands
        let devicectlJSON = commands.devicectlJSON
        commands.devicectlJSON = { args in
            devicectlCalls += 1
            return try devicectlJSON(args)
        }
        let (simulatorOnly, warnings) = try DeviceList.load(commands, udid: simulatorUDID)
        #expect(devicectlCalls == 0)
        #expect(simulatorOnly.map(\.udid) == [simulatorUDID])
        #expect(warnings.isEmpty)
        _ = try DeviceList.load(commands, simulator: true)
        #expect(devicectlCalls == 0)
        let (all, _) = try DeviceList.load(commands, udid: deviceUDID)
        #expect(devicectlCalls == 1)
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

struct TeamIDTests {
    @Test func parsesFindIdentity() {
        #expect(SigningIdentities.parseFindIdentity(findIdentityOutput) == [
            SigningIdentity(sha1: certificateSHA1, name: "Apple Development: Test User (ABCDE12345)"),
            SigningIdentity(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", name: "Developer ID Application: Test User (TEAM000001)")
        ])
        #expect(SigningIdentities.parseFindIdentity("     0 valid identities found\n").isEmpty)
    }

    @Test func readsTheTeamFromTheCertificateSubject() throws {
        let certificates = SigningIdentities.parseFindCertificate(findCertificateOutput)
        let der = try #require(certificates[certificateSHA1])
        #expect(SigningIdentities.organizationalUnits(certificate: der) == ["TEAM000001"])
        #expect(SigningIdentities.organizationalUnits(certificate: Data([0x30, 0x00])).isEmpty)
    }

    @Test func loadsDevelopmentIdentitiesWithTheirTeams() throws {
        // The Developer ID identity is not for development, and the person ID in the name is not the team.
        #expect(try SigningIdentities.load(FakeHost().commands) == [
            SigningIdentity(sha1: certificateSHA1, name: "Apple Development: Test User (ABCDE12345)", teamID: "TEAM000001")
        ])
    }

    @Test func prefersOptionThenConfigThenKeychain() throws {
        let identities = [SigningIdentity(sha1: "A", name: "Apple Development: A", teamID: "TEAM000001")]
        let fromOption = try TeamIDResolver.resolve(explicit: "TEAM000003", config: RelayConfig(teamID: "TEAM000002")) { identities }
        #expect(fromOption.teamID == "TEAM000003" && fromOption.source == .option)
        let fromConfig = try TeamIDResolver.resolve(explicit: nil, config: RelayConfig(teamID: "TEAM000002")) { identities }
        #expect(fromConfig.teamID == "TEAM000002" && fromConfig.source == .config)
        let fromKeychain = try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }
        #expect(fromKeychain.teamID == "TEAM000001" && fromKeychain.source == .keychain)
    }

    @Test func certificatesOfOneTeamAreNotAmbiguous() throws {
        let identities = [
            SigningIdentity(sha1: "A", name: "Apple Development: A", teamID: "TEAM000001"),
            SigningIdentity(sha1: "B", name: "Apple Development: B", teamID: "TEAM000001")
        ]
        #expect(try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }.teamID == "TEAM000001")
    }

    @Test func refusesToGuessBetweenTeams() {
        let identities = [
            SigningIdentity(sha1: "A", name: "Apple Development: A", teamID: "TEAM000001"),
            SigningIdentity(sha1: "B", name: "Apple Development: B", teamID: "TEAM000002")
        ]
        #expect {
            try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }
        } throws: { error in
            String(describing: error).contains("TEAM000001  Apple Development: A") && String(describing: error).contains("TEAM000002")
        }
        #expect(throws: SetupError.self) { try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { [] } }
    }

    @Test func validatesTeamIDs() {
        #expect(RelayConfig.isValidTeamID("ABCDE12345"))
        #expect(!RelayConfig.isValidTeamID("ABCDE1234"))
        #expect(!RelayConfig.isValidTeamID("abcde12345"))
    }

    @Test func configCommandSetsGetsAndUnsets() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = RelayConfig.defaultURL(home: directory)
        #expect(try RelayConfig.read(from: url) == RelayConfig())

        var lines: [String] = []
        #expect(ConfigCommand.run(ConfigOptions(action: .get("teamID")), url: url) { lines.append($0) } == 1)
        #expect(ConfigCommand.run(ConfigOptions(action: .set("teamID", "ABCDE12345")), url: url) == 0)
        #expect(try RelayConfig.read(from: url).teamID == "ABCDE12345")
        #expect(ConfigCommand.run(ConfigOptions(action: .get("teamID")), url: url) { lines.append($0) } == 0)
        #expect(lines == ["ABCDE12345"])
        #expect(ConfigCommand.run(ConfigOptions(action: .unset("teamID")), url: url) == 0)
        #expect(try RelayConfig.read(from: url).teamID == nil)
    }
}

struct CanonicalPathTests {
    @Test func resolvesSymlinksAlsoInPathsThatDoNotExistYet() throws {
        let missing = UUID().uuidString
        #expect(URL(fileURLWithPath: "/private/tmp").canonicalFileURL.path == "/tmp")
        #expect(URL(fileURLWithPath: "/private/tmp/\(missing)/a").canonicalFileURL.path == "/tmp/\(missing)/a")
        #expect(URL(fileURLWithPath: "/tmp/\(missing)/../b").canonicalFileURL.path == "/tmp/b")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(link.appendingPathComponent("x/y").canonicalFileURL.path == real.path + "/x/y")
        #expect(URL(fileURLWithPath: "/private" + root.path).canonicalFileURL.path == root.path)
        #expect(RunnerLocator.resolve("link/x", in: URL(fileURLWithPath: "/private" + root.path)).path == real.path + "/x")
    }
}

struct RunnerProjectTests {
    /// <root>/relay (a checkout with the project), <root>/relay/bin/relay -> <root>/relay/.build/relay,
    /// <root>/links/relay -> the same, and <root>/app/sub (the current directory).
    private struct Tree {
        let root: URL
        var checkout: URL { root.appendingPathComponent("relay") }
        var current: URL { root.appendingPathComponent("app/sub") }
        var executable: URL { checkout.appendingPathComponent(".build/release/relay") }
        var link: URL { root.appendingPathComponent("links/relay") }

        init() throws {
            root = try temporaryDirectory()
            let manager = FileManager.default
            try manager.createDirectory(at: checkout.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
            try manager.createDirectory(at: current, withIntermediateDirectories: true)
            try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: executable.path, contents: Data())
            try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: executable)
        }

        var home: URL { root.appendingPathComponent("home") }

        func resolve(_ explicitPath: String? = nil, environment: [String: String] = [:], current: URL? = nil, executable: URL? = nil,
                     includeInstalled: Bool = true) throws -> (root: URL, source: RunnerProject.Source) {
            try RunnerProject.resolve(explicitPath: explicitPath, environment: environment, currentDirectory: current ?? self.current,
                                      executableURL: executable, home: home, includeInstalled: includeInstalled)
        }
    }

    @Test func prefersOptionThenEnvironmentThenCurrentDirectoryThenExecutable() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let environment = [RunnerProject.environmentKey: tree.checkout.path]

        // Relative to the current directory; the .xcodeproj path works too.
        #expect(try tree.resolve("../../relay", environment: ["RELAY_HOME": "/nonexistent"]) == (tree.checkout, .option))
        #expect(try tree.resolve(tree.checkout.appendingPathComponent(RunnerProject.projectPath).path).root == tree.checkout)
        #expect(try tree.resolve(tree.checkout.appendingPathComponent("Runner").path).root == tree.checkout)
        #expect(try tree.resolve(environment: environment) == (tree.checkout, .environment))
        #expect(try tree.resolve(current: tree.checkout.appendingPathComponent("Runner")) == (tree.checkout, .currentDirectory))
        // The link from make install resolves to the build product inside the checkout.
        #expect(try tree.resolve(executable: tree.link) == (tree.checkout, .executable))
        #expect(try tree.resolve(environment: [RunnerProject.environmentKey: ""], executable: tree.link).source == .executable)
    }

    @Test func theInstalledCopyComesAfterTheCurrentCheckoutAndBeforeTheExecutable() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let installed = RunnerProject.installedRoot(home: tree.home)
        try FileManager.default.createDirectory(at: installed.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)

        // From the app's repository (no checkout around the current directory): the installed copy.
        #expect(try tree.resolve(executable: tree.link) == (installed, .installed))
        // Inside the checkout (xcrun swift run relay start): its sources, not an older installed copy.
        #expect(try tree.resolve(current: tree.checkout, executable: tree.link) == (tree.checkout, .currentDirectory))
        #expect(try tree.resolve(current: tree.checkout.appendingPathComponent("Runner")) == (tree.checkout, .currentDirectory))
        #expect(try tree.resolve(environment: [RunnerProject.environmentKey: tree.checkout.path]) == (tree.checkout, .environment))
        // Inside the installed copy itself it is the installed copy, not a checkout.
        #expect(try tree.resolve(current: installed, executable: tree.link) == (installed, .installed))
        // relay install looks for a checkout only, even from inside the installed copy.
        #expect(try tree.resolve(current: installed, executable: tree.link, includeInstalled: false) == (tree.checkout, .executable))
    }

    @Test func buildsGoUnderTheHomeDirectoryPerSource() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(RunnerProject.buildDirectory(root: RunnerProject.installedRoot(home: home), home: home).path == "/Users/me/.relay/build/installed")
        let a = RunnerProject.buildDirectory(root: URL(fileURLWithPath: "/src/device-relay"), home: home)
        let b = RunnerProject.buildDirectory(root: URL(fileURLWithPath: "/work/device-relay"), home: home)
        #expect(a.path.hasPrefix("/Users/me/.relay/build/device-relay-"))
        #expect(a != b)
    }

    @Test func givenPathsMustHoldTheProject() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        // No fallback to the checkout found from the executable.
        #expect(throws: SetupError.self) { try tree.resolve(tree.root.path, executable: tree.link) }
        #expect(throws: SetupError.self) { try tree.resolve(environment: [RunnerProject.environmentKey: tree.current.path], executable: tree.link) }
        #expect {
            try tree.resolve(executable: tree.root.appendingPathComponent("elsewhere/relay"))
        } throws: { error in
            String(describing: error).contains("--project") && String(describing: error).contains(RunnerProject.environmentKey)
        }
    }
}

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
            commands.xcrun = { args in
                let output = try xcrun(args)
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

struct DoctorTests {
    private let project: (String?) throws -> (root: URL, source: RunnerProject.Source) = { _ in (URL(fileURLWithPath: "/relay"), .environment) }

    @Test func passesWithWarningsOnly() {
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(), commands: FakeHost().commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(status == RunnerExitCode.success.rawValue)
        let output = lines.joined(separator: "\n")
        // The only connected device, picked automatically: a note with how to try a simulator instead.
        #expect(output.contains("! target           Test Phone"))
        #expect(output.contains("relay start without --udid/--device would use it: the only connected device"))
        #expect(output.contains("→ to try a simulator first, pass --simulator (a booted one) or --device <simulator name>"))
        #expect(output.contains("✓ signing          team TEAM000001 (from keychain)"))
        #expect(output.contains("! UI Automation"))
    }

    @Test func failsWhenSomethingIsWrong() {
        let host = FakeHost()
        host.findIdentity = ""
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(udid: deviceUDID), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: { _ in throw SetupError(description: "not found") }, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(status == RunnerExitCode.usage.rawValue)
        let output = lines.joined(separator: "\n")
        #expect(output.contains("✗ runner project"))
        #expect(output.contains("✗ signing"))
        #expect(output.hasSuffix("2 problem(s) found; fix the ✗ items above."))
    }

    @Test func checksTheSimulatorRelayStartWouldPickWithSimulator() {
        let host = FakeHost()
        host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Booted")])
        var lines: [String] = []
        _ = Doctor.run(DoctorOptions(simulator: true), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                       resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(lines.contains { $0.hasPrefix("  ✓ target           iPhone 17 Pro") && $0.hasSuffix("(relay start without --udid/--device would use it: the only booted simulator (--simulator))") })
        #expect(lines.contains("Target: iPhone 17 Pro"))
        // The connected device is not a candidate, so not listed.
        #expect(!lines.contains { $0.contains("Test Phone") })

        host.simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Shutdown")])
        lines = []
        _ = Doctor.run(DoctorOptions(simulator: true), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                       resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(lines.contains { $0.hasPrefix("  ! target           no booted iOS simulator (--simulator)")
            && $0.hasSuffix("→ relay devices lists the simulators; relay doctor --device <name> checks the one relay start would boot") })
    }

    @Test func aSimulatorUDIDIsCheckedWithoutDevicectl() {
        let host = FakeHost()
        var commands = host.commands
        commands.devicectlJSON = { args in
            Issue.record("devicectl \(args)")
            throw ShellError(args: args, status: 1, output: "")
        }
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(udid: simulatorUDID), commands: commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), sandbox: { _ in [] }, output: { lines.append($0) })
        #expect(status == RunnerExitCode.success.rawValue)
        #expect(lines.contains("  ✓ devices          0 booted simulator(s), 1 iOS simulator(s) (devices not listed: --udid is a simulator)"))
        #expect(!lines.contains { $0.contains("devicectl") && $0.contains("cannot list") })
    }

    @Test func reportsASandboxThatBlocksLocalhost() {
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(udid: simulatorUDID), commands: FakeHost().commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"),
                                sandbox: { _ in [SandboxProbe.localhostCheck(connectError: EPERM)] }, output: { lines.append($0) })
        #expect(status == RunnerExitCode.usage.rawValue)
        #expect(lines.contains { $0.hasPrefix("  ✗ localhost        the OS refused a connection to 127.0.0.1 (Operation not permitted)") })
        #expect(lines.contains { $0.contains("→ run relay outside the sandbox (in Claude Code: sandbox.excludedCommands)") })
    }

    @Test func sandboxChecksReadTheErrno() throws {
        #expect(SandboxProbe.localhostCheck(connectError: ECONNREFUSED).status == .ok)
        #expect(SandboxProbe.localhostCheck(connectError: 0).status == .ok)
        #expect(SandboxProbe.localhostCheck(connectError: EPERM).status == .problem)
        #expect(SandboxProbe.stateWriteCheck(writeError: 0, path: "/h/.relay") == .ok("~/.relay", "writable"))
        #expect(SandboxProbe.stateWriteCheck(writeError: EPERM, path: "/h/.relay").detail.contains("sandbox"))
        #expect(!SandboxProbe.stateWriteCheck(writeError: EACCES, path: "/h/.relay").detail.contains("sandbox"))
        // The live probes, outside any sandbox here: the directory is writable and leaves nothing behind.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SandboxProbe.writeError(in: directory) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(SandboxProbe.writeError(in: directory.appendingPathComponent("missing")) == ENOENT)
    }

    @Test func aMissingTeamIsOnlyANoteForSimulators() {
        let host = FakeHost()
        host.findIdentity = ""
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(udid: simulatorUDID), commands: host.commands, configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                                resolveProject: project, home: URL(fileURLWithPath: "/nonexistent"), output: { lines.append($0) })
        #expect(status == RunnerExitCode.success.rawValue)
        #expect(lines.contains { $0.hasPrefix("  ! signing") })
    }

    @Test func showsWhichRunnerProjectIsUsed() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = RunnerProject.installedRoot(home: home)
        try FileManager.default.createDirectory(at: installed.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
        try RunnerInstallRecord(relayVersion: RelayVersion.current, commit: nil, source: "/src/relay", installedAt: "1970-01-01T00:00:00Z")
            .write(root: installed)
        let checkout = URL(fileURLWithPath: "/src/relay")

        // Inside a checkout: the checkout is built, and the installed copy is shown as not used.
        let inCheckout = Doctor.installCheck(project: (checkout, .currentDirectory), home: home) { _, _ in nil }
        #expect(inCheckout.status == .ok)
        #expect(inCheckout.detail.hasSuffix("(not used: current directory wins)"))
        // From an app's repository: the installed copy.
        let fromApp = Doctor.installCheck(project: (installed, .installed), home: home) { _, _ in nil }
        #expect(fromApp == .ok("runner install", "relay \(RelayVersion.current), from /src/relay, 1970-01-01T00:00:00Z"))
        // An outdated copy is a note even while a checkout wins, so it is updated before it is used again.
        let outdated = Doctor.installCheck(project: (checkout, .currentDirectory), home: home) { _, _ in "the runner was installed by relay 0.1.0" }
        #expect(outdated.status == .warning)
    }

    @Test func aSavedTeamIsEnoughWithoutTheKeychain() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-doctor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = RelayConfig.defaultURL(home: home)
        try RelayConfig(teamID: "ABCDE12345").write(to: configURL)
        var commands = FakeHost().commands
        commands.run = { executable, args in
            if executable == "/usr/bin/security" { throw ShellError(tool: "security", args: args, status: 1, output: "") }
            return try FakeHost().commands.run(executable, args)
        }
        var lines: [String] = []
        let status = Doctor.run(DoctorOptions(udid: deviceUDID), commands: commands, configURL: configURL,
                                resolveProject: project, home: home, output: { lines.append($0) })
        #expect(status == RunnerExitCode.success.rawValue)
        #expect(lines.contains("  ✓ signing          team ABCDE12345 (from ~/.relay/config.json)"))
    }
}

struct RunnerInstallTests {
    private static let pbxproj = """
    A /* RunnerAuth.swift */ = {isa = PBXFileReference; path = ../Sources/relay/RunnerAuth.swift; sourceTree = "<group>"; };
    B /* Shared.swift */ = {isa = PBXFileReference; path = "../Sources/relay/Shared.swift"; sourceTree = "<group>"; };
    C /* RelayRunnerUITests.swift */ = {isa = PBXFileReference; path = RelayRunnerUITests.swift; sourceTree = "<group>"; };
    D = {isa = PBXFileReference; path = ../Sources/relay/RunnerAuth.swift; sourceTree = "<group>"; };
    """

    /// <root>/checkout with Runner/ and the shared sources, and <root>/home.
    private struct Tree {
        let root: URL
        var checkout: URL { root.appendingPathComponent("checkout") }
        var home: URL { root.appendingPathComponent("home") }
        var installed: URL { RunnerProject.installedRoot(home: home) }

        init() throws {
            root = try temporaryDirectory()
            let project = checkout.appendingPathComponent(RunnerProject.projectPath)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("xcuserdata"), withIntermediateDirectories: true)
            try RunnerInstallTests.pbxproj.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
            try write("test", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")
            try write("auth", to: "Sources/relay/RunnerAuth.swift")
            try write("shared", to: "Sources/relay/Shared.swift")
            try write("cli", to: "Sources/relay/main.swift")
        }

        func write(_ text: String, to path: String) throws {
            let url = checkout.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func installedText(_ path: String) -> String? {
            try? String(contentsOf: installed.appendingPathComponent(path), encoding: .utf8)
        }
    }

    private func source(_ tree: Tree, commit: String = String(repeating: "a", count: 40)) -> CheckoutRunnerSource {
        var commands = FakeHost().commands
        commands.run = { executable, args in
            guard executable == "/usr/bin/git", args.suffix(2) == ["rev-parse", "HEAD"] else { throw ShellError(args: args, status: 1, output: "") }
            return commit + "\n"
        }
        return CheckoutRunnerSource(root: tree.checkout, commands: commands)
    }

    @Test func findsTheSharedSourcesTheProjectCompiles() {
        #expect(CheckoutRunnerSource.referencedFiles(pbxproj: Self.pbxproj)
            == ["Sources/relay/RunnerAuth.swift", "Sources/relay/Shared.swift"])
    }

    @Test func copiesTheRunnerAndRecordsTheVersion() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let build = RunnerProject.buildDirectory(root: tree.installed, home: tree.home)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

        let record = try RunnerInstaller.install(from: source(tree), home: tree.home, now: Date(timeIntervalSince1970: 0))
        #expect(record == RunnerInstallRecord(relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40),
                                              source: tree.checkout.path, installedAt: "1970-01-01T00:00:00Z"))
        #expect(RunnerInstallRecord.read(root: tree.installed) == record)
        #expect(RunnerProject.contains(tree.installed))
        #expect(tree.installedText("Runner/RelayRunnerUITests/RelayRunnerUITests.swift") == "test")
        #expect(tree.installedText("Sources/relay/Shared.swift") == "shared")
        // Only what the project compiles, and no per-user Xcode state.
        #expect(tree.installedText("Sources/relay/main.swift") == nil)
        #expect(!FileManager.default.fileExists(atPath: tree.installed.appendingPathComponent(RunnerProject.projectPath + "/xcuserdata").path))
        // Builds of the replaced sources are dropped.
        #expect(!FileManager.default.fileExists(atPath: build.path))
        // No staging directories are left behind.
        let entries = try FileManager.default.contentsOfDirectory(atPath: tree.installed.deletingLastPathComponent().path)
        #expect(entries.sorted() == ["build", "runner"])
    }

    @Test func reinstallingReplacesThePreviousCopy() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try RunnerInstaller.install(from: source(tree), home: tree.home)
        try "stale".write(to: tree.installed.appendingPathComponent("Runner/leftover.txt"), atomically: true, encoding: .utf8)
        try tree.write("test v2", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")

        let record = try RunnerInstaller.install(from: source(tree, commit: String(repeating: "b", count: 40)), home: tree.home)
        #expect(record.commit == String(repeating: "b", count: 40))
        #expect(tree.installedText("Runner/RelayRunnerUITests/RelayRunnerUITests.swift") == "test v2")
        #expect(tree.installedText("Runner/leftover.txt") == nil)
    }

    @Test func aFailedInstallKeepsThePreviousCopy() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try RunnerInstaller.install(from: source(tree), home: tree.home)
        try FileManager.default.removeItem(at: tree.checkout.appendingPathComponent("Sources/relay/Shared.swift"))

        #expect(throws: (any Error).self) { try RunnerInstaller.install(from: source(tree), home: tree.home) }
        #expect(tree.installedText("Sources/relay/Shared.swift") == "shared")
        let entries = try FileManager.default.contentsOfDirectory(atPath: tree.installed.deletingLastPathComponent().path)
        #expect(entries == ["runner"])
    }

    @Test func refusesToInstallFromTheInstalledCopy() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try RunnerInstaller.install(from: source(tree), home: tree.home)
        #expect(throws: SetupError.self) {
            try RunnerInstaller.install(from: CheckoutRunnerSource(root: tree.installed, commands: FakeHost().commands), home: tree.home)
        }
    }

    @Test func removingKeepsTheConfigAndRunnerInfo() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        #expect(try RunnerInstaller.remove(home: tree.home) == false)
        try RunnerInstaller.install(from: source(tree), home: tree.home)
        try RelayConfig(teamID: "ABCDE12345").write(to: RelayConfig.defaultURL(home: tree.home))
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "S").write(to: RunnerLocator.userURL(home: tree.home))

        var lines: [String] = []
        #expect(try InstallCommand.run(InstallOptions(remove: true), home: tree.home, output: { lines.append($0) }) == 0)
        #expect(lines == ["removed \(tree.installed.path)"])
        #expect(!FileManager.default.fileExists(atPath: tree.installed.path))
        #expect(try RelayConfig.read(from: RelayConfig.defaultURL(home: tree.home)).teamID == "ABCDE12345")
        #expect(FileManager.default.fileExists(atPath: RunnerLocator.userURL(home: tree.home).path))
    }

    @Test func installCommandCopiesFromTheGivenCheckout() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        var lines: [String] = []
        #expect(try InstallCommand.run(InstallOptions(project: tree.checkout.path), commands: FakeHost().commands, home: tree.home, output: { lines.append($0) }) == 0)
        #expect(lines.first?.hasPrefix("installed the runner to \(tree.installed.path)") == true)
        // The fake has no git, so no commit is recorded.
        #expect(RunnerInstallRecord.read(root: tree.installed)?.commit == nil)
    }

    @Test func installBuildWritesTheBuildLog() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let logs = tree.home.appendingPathComponent(".relay/logs")
        var builds: [(args: [String], echo: Bool)] = []
        var lines: [String] = []
        let status = try InstallCommand.run(InstallOptions(project: tree.checkout.path, build: true, verbose: true), commands: FakeHost().commands,
                                            home: tree.home, build: { args, log, echo in
                                                log.write(Data("** TEST BUILD SUCCEEDED **\n".utf8))
                                                builds.append((args, echo))
                                            }, output: { lines.append($0) })
        #expect(status == 0)
        #expect(builds.count == 1)
        #expect(builds.first?.echo == true)
        #expect(builds.first?.args.contains("generic/platform=iOS Simulator") == true)
        // Built from the installed copy's sources, and recorded so relay start reuses it.
        let sourceHash = try RunnerSourceHash.compute(root: tree.installed)
        #expect(builds.first?.args.contains("RELAY_RUNNER_SOURCE_HASH=\(sourceHash)") == true)
        let derivedData = RunnerProject.buildDirectory(root: tree.installed, home: tree.home).appendingPathComponent("DerivedData-sim")
        #expect(RunnerBuildStamp.read(derivedData: derivedData) == RunnerBuildStamp(sourceHash: sourceHash, relayVersion: RelayVersion.current))
        let files = try FileManager.default.contentsOfDirectory(atPath: logs.path)
        #expect(files.count == 1)
        #expect(files.first?.hasPrefix("build-") == true && files.first?.hasSuffix(".log") == true)
        let log = logs.appendingPathComponent(files[0])
        #expect(try String(contentsOf: log, encoding: .utf8) == "** TEST BUILD SUCCEEDED **\n")
        #expect(lines.contains { $0.contains("(log: \(log.path))") })
    }

    @Test func aFailedInstallBuildPointsToTheLog() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        #expect {
            try InstallCommand.run(InstallOptions(project: tree.checkout.path, build: true), commands: FakeHost().commands, home: tree.home,
                                   build: { args, _, _ in throw ShellError(args: args, status: 65, output: "error: boom") }, output: { _ in })
        } throws: { error in
            let description = String(describing: error)
            return error is SetupError && description.contains("error: boom") && description.contains("see \(tree.home.path)/.relay/logs/build-")
        }
        // The copy stays installed, and nothing records a build relay start could reuse.
        #expect(RunnerProject.contains(tree.installed))
        let derivedData = RunnerProject.buildDirectory(root: tree.installed, home: tree.home).appendingPathComponent("DerivedData-sim")
        #expect(RunnerBuildStamp.read(derivedData: derivedData) == nil)
    }

    /// The installed copy holds the files the checkout's runner is built from, so a build of either is the
    /// same sources; Xcode's per-user state in the checkout (dropped from the copy) does not count.
    @Test func theInstalledCopyHashesLikeItsCheckout() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try tree.write("state", to: "\(RunnerProject.projectPath)/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate")
        try RunnerInstaller.install(from: source(tree), home: tree.home)
        #expect(try RunnerSourceHash.compute(root: tree.installed) == RunnerSourceHash.compute(root: tree.checkout))
        try tree.write("test changed", to: "Runner/RelayRunnerUITests/RelayRunnerUITests.swift")
        #expect(try RunnerSourceHash.compute(root: tree.installed) != RunnerSourceHash.compute(root: tree.checkout))
    }

    @Test func detectsAnOutdatedInstall() {
        let record = RunnerInstallRecord(relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40), source: "/src/relay",
                                         installedAt: "")
        #expect(record.staleness(checkout: nil) == nil)
        #expect(record.staleness(checkout: ("/src/relay", String(repeating: "a", count: 40))) == nil)
        #expect(record.staleness(checkout: ("/src/relay", String(repeating: "b", count: 40)))?.contains("aaaaaaaaaaaa") == true)
        // Another checkout's commit says nothing about this install.
        #expect(record.staleness(checkout: ("/other/relay", String(repeating: "b", count: 40))) == nil)
        #expect(record.staleness(currentVersion: "9.9.9", checkout: nil)?.contains("relay \(RelayVersion.current), but this is relay 9.9.9") == true)
    }

    @Test func comparesTheRecordedSourceCanonically() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let alias = tree.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tree.checkout)
        // Recorded through a symbolic link (or as /private/tmp/...) by an older relay.
        let record = RunnerInstallRecord(relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40), source: alias.path,
                                         installedAt: "")
        #expect(record.staleness(checkout: (tree.checkout.path, String(repeating: "b", count: 40)))?.contains("aaaaaaaaaaaa") == true)
        #expect(CheckoutRunnerSource(root: alias).location == tree.checkout.path)
    }

    @Test func checksOnlyTheInstalledCopy() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        #expect(RunnerInstaller.staleness(root: tree.checkout, source: .currentDirectory) { nil } == nil)
        try FileManager.default.createDirectory(at: tree.installed, withIntermediateDirectories: true)
        #expect(RunnerInstaller.staleness(root: tree.installed, source: .installed) { nil }?.contains("install.json") == true)
        try RunnerInstaller.install(from: source(tree), home: tree.home)
        #expect(RunnerInstaller.staleness(root: tree.installed, source: .installed, commands: FakeHost().commands) { tree.checkout } == nil)
    }

    @Test func parsesInstallCommands() throws {
        #expect(try Arguments.parse(["install"]) == .install(InstallOptions()))
        #expect(try Arguments.parse(["install", "--project", "..", "--build"]) == .install(InstallOptions(project: "..", build: true)))
        #expect(try Arguments.parse(["install", "--build", "--verbose"]) == .install(InstallOptions(build: true, verbose: true)))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["install", "--remove", "--verbose"]) }
        #expect(try Arguments.parse(["install", "--remove"]) == .install(InstallOptions(remove: true)))
        #expect(try Arguments.parse(["uninstall"]) == .install(InstallOptions(remove: true)))
        #expect(throws: ArgumentError.self) { try Arguments.parse(["install", "--remove", "--build"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["uninstall", "--build"]) }
        #expect(try Arguments.parse(["--version"]) == .version)
    }
}
