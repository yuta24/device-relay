import Foundation
@testable import Relay

// Canned output of the external commands. UDIDs, names, and Team IDs are dummies.

let deviceUDID = "00000000-0000000000000001"
let otherDeviceUDID = "00000000-0000000000000002"
let simulatorUDID = "11111111-1111-1111-1111-111111111111"

/// `devicectl list devices`: a connected device (new `properties` only), a paired device that is not
/// connected (deprecated fields only), and a simulator, which devicectl lists too.
let devicectlList = """
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

func simctlList(_ entries: [(udid: String, name: String, state: String)], runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0") -> String {
    let devices = entries.map {
        #"{"udid":"\#($0.udid)","name":"\#($0.name)","state":"\#($0.state)","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}"#
    }
    return #"{"devices":{"\#(runtime)":[\#(devices.joined(separator: ","))],"com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[{"udid":"W","name":"Watch","state":"Booted","isAvailable":true}]}}"#
}

/// The dummy certificate's SHA-1 and PEM: CN "Apple Development: Test User (ABCDE12345)", OU "TEAM000001".
let certificateSHA1 = "3335F4D53A603E933F7178D3C26B025F393032D5"
let certificatePEM = """
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

let findIdentityOutput = """
  1) \(certificateSHA1) "Apple Development: Test User (ABCDE12345)"
  2) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Test User (TEAM000001)"
     2 valid identities found
"""

let findCertificateOutput = """
SHA-256 hash: 00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF
SHA-1 hash: \(certificateSHA1)
\(certificatePEM)
"""

/// Fake external commands that record the xcrun calls.
final class FakeHost: Sendable {
    private struct State {
        var devicectl = devicectlList
        var simctl = simctlList([(simulatorUDID, "iPhone 17 Pro", "Shutdown")])
        var locked: Bool? = false
        var findIdentity = findIdentityOutput
        var xcrunCalls: [[String]] = []
    }

    private let state = Locked(State())

    var devicectl: String {
        get { state.value.devicectl }
        set { state.withLock { $0.devicectl = newValue } }
    }
    var simctl: String {
        get { state.value.simctl }
        set { state.withLock { $0.simctl = newValue } }
    }
    var locked: Bool? {
        get { state.value.locked }
        set { state.withLock { $0.locked = newValue } }
    }
    var findIdentity: String {
        get { state.value.findIdentity }
        set { state.withLock { $0.findIdentity = newValue } }
    }
    var xcrunCalls: [[String]] {
        get { state.value.xcrunCalls }
        set { state.withLock { $0.xcrunCalls = newValue } }
    }

    var commands: HostCommands {
        HostCommands(
            xcrun: { [self] args, _ in
                state.withLock { $0.xcrunCalls.append(args) }
                switch args.first {
                case "simctl" where args.dropFirst().first == "list": return simctl
                case "xcodebuild": return "Xcode 27.0\nBuild version 27A000a\n"
                case "--version": return "xcrun version 72.\n"
                case "--find": return "/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl\n"
                default: return ""
                }
            },
            devicectlJSON: { [self] args, _ in
                if args.starts(with: ["list", "devices"]) {
                    return Data(devicectl.utf8)
                }
                if args.starts(with: ["device", "info", "lockState"]), let locked {
                    return Data(#"{"result":{"passcodeRequired":\#(locked),"unlockedSinceBoot":true}}"#.utf8)
                }
                throw ShellError(args: args, status: 1, output: "")
            },
            run: { [self] executable, args, _ in
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

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func device(_ name: String, udid: String, available: Bool = true) -> Device {
    Device(name: name, udid: udid, kind: .device, os: "iOS 26.0", state: available ? "connected" : "unavailable", isAvailable: available,
           pairingState: "paired", developerModeEnabled: true, ddiServicesAvailable: true)
}

func simulator(_ name: String, udid: String, booted: Bool = false, os: String = "iOS 27.0") -> Device {
    Device(name: name, udid: udid, kind: .simulator, os: os, state: booted ? "booted" : "shutdown", isAvailable: true)
}
