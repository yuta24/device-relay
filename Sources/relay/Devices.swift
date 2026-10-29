import Foundation

/// A physical device from `devicectl list devices` or a simulator from `simctl list devices`.
struct Device: Equatable {
    enum Kind: String {
        case device
        case simulator
    }

    var name: String
    var udid: String
    var kind: Kind
    var model: String?
    /// `iOS 26.7.1`.
    var os: String?
    /// Devices: devicectl's connection state (`connected`, `disconnected`, `unavailable`).
    /// Simulators: simctl's state, lowercased (`booted`, `shutdown`, ...).
    var state: String
    /// Devices: reachable from this Mac now. Simulators: the runtime is installed.
    var isAvailable: Bool
    // Devices only; nil when devicectl does not report it.
    var pairingState: String?
    var developerModeEnabled: Bool?
    var ddiServicesAvailable: Bool?

    var isBooted: Bool { kind == .simulator && state == "booted" }

    /// A connected device or a booted simulator: what `relay start` picks without `--udid`.
    var isActive: Bool { kind == .device ? isAvailable : isBooted }

    /// The major version of `os`, e.g. 26 for `iOS 26.7.1`.
    var osMajorVersion: Int? {
        os?.split(separator: " ").last?.split(separator: ".").first.flatMap { Int($0) }
    }

    /// One line for messages: `Test Phone (iPhone 14 Pro, iOS 26.7.1, device, connected) <UDID>`.
    var summary: String {
        let details = [model, os, kind.rawValue, state].compactMap { $0 }.joined(separator: ", ")
        return "\(name) (\(details)) \(udid)"
    }
}

enum DeviceList {
    /// Physical devices and iOS simulators, read with `devicectl` and `simctl`. A failing `devicectl`
    /// (older Xcode, CoreDevice not running) leaves only the simulators, with the error in `warnings`.
    static func load(_ commands: HostCommands = .live) throws -> (devices: [Device], warnings: [String]) {
        var warnings: [String] = []
        var devices: [Device] = []
        do {
            devices += try parseDevicectl(commands.devicectlJSON(["list", "devices"]))
        } catch {
            warnings.append("cannot list devices with devicectl: \(error)")
        }
        devices += try parseSimctl(Data(commands.xcrun(["simctl", "list", "devices", "--json"]).utf8))
        return (sort(devices), warnings)
    }

    /// Devices first, then simulators; active ones (connected / booted) first in each, then by name.
    static func sort(_ devices: [Device]) -> [Device] {
        devices.sorted {
            ($0.kind == .device ? 0 : 1, $0.isActive ? 0 : 1, $0.name.lowercased(), $0.os ?? "")
                < ($1.kind == .device ? 0 : 1, $1.isActive ? 0 : 1, $1.name.lowercased(), $1.os ?? "")
        }
    }

    // MARK: - Parsing

    /// Physical devices in `devicectl list devices --json-output` (also `device info details`, whose
    /// `result` is one device). devicectl lists simulators too; they come from simctl instead.
    /// Reads the `properties` dictionary and falls back to the deprecated `*Properties` fields.
    static func parseDevicectl(_ data: Data) throws -> [Device] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            throw SetupError(description: "unexpected devicectl output: no result")
        }
        let entries = result["devices"] as? [[String: Any]] ?? [result]
        return entries.compactMap(device(fromDevicectl:))
    }

    private static func device(fromDevicectl entry: [String: Any]) -> Device? {
        let properties = entry["properties"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any] ?? [:]
        let software = properties["software"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let oldConnection = entry["connectionProperties"] as? [String: Any] ?? [:]
        let oldDevice = entry["deviceProperties"] as? [String: Any] ?? [:]
        let oldHardware = entry["hardwareProperties"] as? [String: Any] ?? [:]

        let reality = hardware["reality"] as? String ?? oldHardware["reality"] as? String
        let isSimulator = reality == "simulated" || entry["visibilityClass"] as? String == "simulators"
            || oldDevice["provider"] as? String == "com.apple.CoreSimulator.SimulatorCoreDevicePlugin"
        guard !isSimulator else { return nil }
        guard let udid = hardware["udid"] as? String ?? oldHardware["udid"] as? String ?? entry["identifier"] as? String else {
            return nil
        }

        let platform = hardware["platform"] as? String ?? oldHardware["platform"] as? String
        let version = (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String
            ?? oldDevice["osVersionNumber"] as? String
        let transport = connection["transportType"] as? String ?? oldConnection["transportType"] as? String
        let connectionState = connection["state"] as? String ?? oldConnection["tunnelState"] as? String ?? "unknown"
        return Device(
            name: state["name"] as? String ?? oldDevice["name"] as? String ?? udid,
            udid: udid,
            kind: .device,
            model: hardware["marketingName"] as? String ?? oldHardware["marketingName"] as? String
                ?? hardware["productType"] as? String ?? oldHardware["productType"] as? String,
            os: version.map { [platform, $0].compactMap { $0 }.joined(separator: " ") },
            state: connectionState,
            // A device that is not plugged in or on the network has no transport and is `unavailable`.
            isAvailable: connectionState == "connected" || (transport != nil && connectionState != "unavailable"),
            pairingState: connection["pairingState"] as? String ?? oldConnection["pairingState"] as? String,
            developerModeEnabled: developerMode(state["developerModeStatus"] ?? oldDevice["developerModeStatus"]),
            ddiServicesAvailable: oldDevice["ddiServicesAvailable"] as? Bool
        )
    }

    /// `"enabled"` / `"disabled"` (deprecated field), or `{"enabled": {...}}` / `{"disabled": {...}}`.
    private static func developerMode(_ value: Any?) -> Bool? {
        let key = (value as? String) ?? (value as? [String: Any])?.keys.first
        switch key {
        case "enabled": return true
        case "disabled": return false
        default: return nil
        }
    }

    /// iOS simulators in `simctl list devices --json`. Other platforms (watchOS, tvOS, ...) are left
    /// out: the runner is an iOS test bundle.
    static func parseSimctl(_ data: Data) throws -> [Device] {
        // simctl may print warnings before the JSON on the merged output.
        let json = data.firstIndex(of: UInt8(ascii: "{")).map { data[$0...] } ?? data
        guard let root = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
              let runtimes = root["devices"] as? [String: Any] else {
            throw SetupError(description: "unexpected simctl output: no devices")
        }
        var devices: [Device] = []
        for (runtime, entries) in runtimes {
            guard let os = osName(simulatorRuntime: runtime), os.hasPrefix("iOS ") else { continue }
            for entry in entries as? [[String: Any]] ?? [] {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                devices.append(Device(
                    name: name,
                    udid: udid,
                    kind: .simulator,
                    model: (entry["deviceTypeIdentifier"] as? String).flatMap(modelName(simulatorDeviceType:)),
                    os: os,
                    state: (entry["state"] as? String ?? "unknown").lowercased(),
                    isAvailable: entry["isAvailable"] as? Bool ?? false
                ))
            }
        }
        return devices
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`.
    static func osName(simulatorRuntime runtime: String) -> String? {
        guard let last = runtime.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }

    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro` → `iPhone 17 Pro`.
    static func modelName(simulatorDeviceType identifier: String) -> String? {
        identifier.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") }
    }

    // MARK: - Output

    /// The `relay devices` table: name, UDID, kind, OS, state.
    static func table(_ devices: [Device]) -> String {
        let header = ["NAME", "UDID", "KIND", "OS", "STATE"]
        let rows = devices.map { device in
            [device.name, device.udid, device.kind.rawValue, device.os ?? "-",
             device.isAvailable || device.state == "unavailable" ? device.state : "\(device.state) (unavailable)"]
        }
        let widths = header.indices.map { column in ([header] + rows).map { displayWidth($0[column]) }.max() ?? 0 }
        return ([header] + rows).map { row in
            row.enumerated().map { column, value in
                column == row.count - 1 ? value : value + String(repeating: " ", count: widths[column] - displayWidth(value))
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// Terminal columns of `text`: East Asian wide characters (device names such as 「…のiPhone」) take two.
    static func displayWidth(_ text: String) -> Int {
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
            0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
            0x1F900...0x1F9FF, 0x20000...0x3FFFD
        ]
        return text.reduce(0) { width, character in
            let value = character.unicodeScalars.first?.value ?? 0
            return width + (wide.contains { $0.contains(value) } ? 2 : 1)
        }
    }

    /// The `relay devices --json` array.
    static func json(_ devices: [Device]) throws -> Data {
        let objects: [[String: Any]] = devices.map { device in
            var object: [String: Any] = [
                "name": device.name, "udid": device.udid, "kind": device.kind.rawValue,
                "state": device.state, "available": device.isAvailable
            ]
            object["model"] = device.model
            object["os"] = device.os
            object["pairingState"] = device.pairingState
            object["developerMode"] = device.developerModeEnabled
            return object
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// Picks the device `relay start` and `relay doctor` work on.
enum DeviceSelector {
    /// `--udid`, else `--device <name>`, else the only connected device, else the only booted simulator.
    static func select(from devices: [Device], udid: String?, name: String?) throws -> Device {
        if let udid {
            guard let device = devices.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else {
                throw SetupError(description: "no device or iOS simulator with UDID \(udid)\(candidateList(devices))")
            }
            return device
        }
        if let name {
            let matches = devices.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            switch matches.count {
            case 0:
                throw SetupError(description: "no device or iOS simulator named \"\(name)\"\(candidateList(devices))")
            case 1:
                return matches[0]
            default:
                // Simulators of different runtimes share names; the one in use is what people mean.
                let active = matches.filter(\.isActive)
                if active.count == 1 {
                    return active[0]
                }
                throw SetupError(description: "\(matches.count) devices are named \"\(name)\"; pass --udid with one of them"
                    + candidateList(matches))
            }
        }

        let connected = devices.filter { $0.kind == .device && $0.isAvailable }
        if connected.count == 1 {
            return connected[0]
        }
        if connected.count > 1 {
            throw SetupError(description: "\(connected.count) devices are connected; pass --udid or --device" + candidateList(connected))
        }
        let booted = devices.filter(\.isBooted)
        if booted.count == 1 {
            return booted[0]
        }
        if booted.count > 1 {
            throw SetupError(description: "\(booted.count) simulators are booted; pass --udid or --device" + candidateList(booted))
        }
        let simulators = devices.filter { $0.kind == .simulator && $0.isAvailable }
        throw SetupError(description: "no connected device or booted simulator; connect a device, or pass --udid/--device "
            + "(a shut-down simulator is booted for you)" + candidateList(simulators))
    }

    private static func candidateList(_ devices: [Device]) -> String {
        guard !devices.isEmpty else { return "" }
        let limit = 20
        var lines = devices.prefix(limit).map { "  \($0.summary)" }
        if devices.count > limit {
            lines.append("  ... \(devices.count - limit) more (relay devices lists all)")
        }
        return ":\n" + lines.joined(separator: "\n")
    }
}
