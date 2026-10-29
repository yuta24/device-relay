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

    /// The version in `os`, e.g. [26, 7, 1] for `iOS 26.7.1`.
    var osVersion: [Int]? {
        guard let version = os?.split(separator: " ").last else { return nil }
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
    }

    /// `--os`: each component of `version` equals the OS's, so `27` matches iOS 27.0 and 27.1, and
    /// `26.5` matches 26.5 and 26.5.1 but not 26.6. Missing components count as 0 (`27.0` matches iOS 27).
    func matches(os version: String) -> Bool {
        guard let osVersion else { return false }
        let requested = version.split(separator: ".").compactMap { Int($0) }
        return requested.enumerated().allSatisfy { index, part in part == (index < osVersion.count ? osVersion[index] : 0) }
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

/// The device `DeviceSelector` picked, and how, for `relay start` and `relay doctor` to show.
struct DeviceSelection: Equatable {
    var device: Device
    /// The options that picked it and why, e.g. `--device; the newest iOS of 3 simulators named "iPhone 17 Pro"`,
    /// or why it was picked automatically, e.g. `the only booted simulator (--simulator)`.
    var reason: String
    /// Neither `--udid` nor `--device`: picked from what is connected or booted.
    var isAutomatic: Bool
}

/// Picks the device `relay start` and `relay doctor` work on.
enum DeviceSelector {
    /// `--udid`, else `--device <name>`, else the only connected device, else the only booted simulator.
    /// `simulator` (`--simulator`) leaves out devices, and `os` (`--os`) keeps those whose OS version
    /// starts with it (see `Device.matches(os:)`), before any of that.
    static func select(from devices: [Device], udid: String?, name: String?, simulator: Bool = false, os: String? = nil) throws -> DeviceSelection {
        let candidates = devices.filter { (!simulator || $0.kind == .simulator) && (os.map($0.matches(os:)) ?? true) }
        let scope = simulator ? "iOS simulator" : "device or iOS simulator"
        let filters = [simulator ? "--simulator" : nil, os.map { "--os \($0)" }].compactMap { $0 }
        let filterNote = filters.isEmpty ? "" : " (\(filters.joined(separator: " ")))"
        func selection(_ device: Device, _ option: String?, _ detail: String? = nil) -> DeviceSelection {
            guard let option else {
                return DeviceSelection(device: device, reason: (detail ?? "") + filterNote, isAutomatic: true)
            }
            let options = ([option] + filters).joined(separator: " ")
            return DeviceSelection(device: device, reason: [options, detail].compactMap { $0 }.joined(separator: "; "), isAutomatic: false)
        }

        if let udid {
            guard let device = candidates.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else {
                throw SetupError(description: "no \(scope) with UDID \(udid)\(filterNote)\(candidateList(candidates))")
            }
            return selection(device, "--udid")
        }
        if let name {
            let named = { (devices: [Device]) in devices.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            let matches = named(candidates)
            switch matches.count {
            case 0:
                // The same name outside --simulator/--os shows what to change; otherwise every candidate.
                let others = named(devices)
                throw SetupError(description: "no \(scope) named \"\(name)\"\(filterNote)\(candidateList(others.isEmpty ? candidates : others))")
            case 1:
                return selection(matches[0], "--device")
            default:
                // Simulators of different runtimes share names; the one in use is what people mean.
                let active = matches.filter(\.isActive)
                if active.count == 1 {
                    return selection(active[0], "--device", "the only connected or booted one of \(matches.count) named \"\(name)\"")
                }
                // Else the newest runtime, usually the one the selected Xcode ships with. Devices are never guessed.
                let pool = active.isEmpty ? matches : active
                if pool.allSatisfy({ $0.kind == .simulator }), let newest = newest(pool) {
                    let which = active.isEmpty ? "" : " booted"
                    return selection(newest, "--device", "the newest iOS of \(pool.count)\(which) simulators named \"\(name)\"")
                }
                let kinds = Set(matches.map(\.kind))
                let hint = kinds.count > 1 ? " (or --simulator for the simulator)" : ""
                throw SetupError(description: "\(matches.count) devices are named \"\(name)\"\(filterNote); pass --udid with one of them\(hint)"
                    + candidateList(matches))
            }
        }

        if !simulator {
            let connected = candidates.filter { $0.kind == .device && $0.isAvailable }
            if connected.count == 1 {
                return selection(connected[0], nil, "the only connected device")
            }
            if connected.count > 1 {
                throw SetupError(description: "\(connected.count) devices are connected\(filterNote); pass --udid or --device (or --simulator)"
                    + candidateList(connected))
            }
        }
        let booted = candidates.filter(\.isBooted)
        if booted.count == 1 {
            return selection(booted[0], nil, "the only booted simulator")
        }
        if booted.count > 1 {
            throw SetupError(description: "\(booted.count) simulators are booted\(filterNote); pass --udid or --device" + candidateList(booted))
        }
        // Newest runtime first, so the list starts with the simulators worth booting.
        let simulators = candidates.filter { $0.kind == .simulator && $0.isAvailable }
            .sorted {
                let order = compare($0.osVersion ?? [], $1.osVersion ?? [])
                return order != 0 ? order > 0 : $0.name.lowercased() < $1.name.lowercased()
            }
        if simulator {
            throw SetupError(description: "no booted iOS simulator\(filterNote); pass --device <name> to boot one "
                + "(it is shut down when relay exits)" + candidateList(simulators))
        }
        throw SetupError(description: "no connected device or booted simulator\(filterNote); connect a device, or pass --udid/--device "
            + "(a shut-down simulator is booted for you)" + candidateList(simulators))
    }

    /// The device with the highest OS version, or nil when two share it or one has no version.
    private static func newest(_ devices: [Device]) -> Device? {
        let versions = devices.compactMap(\.osVersion)
        guard versions.count == devices.count, let highest = versions.max(by: { compare($0, $1) < 0 }) else { return nil }
        let newest = devices.filter { compare($0.osVersion ?? [], highest) == 0 }
        return newest.count == 1 ? newest[0] : nil
    }

    /// Compares versions component by component, missing ones as 0 (`27` equals `27.0`).
    static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    /// `--os`: a version such as `27`, `27.0`, or `26.5`.
    static func isValidOSVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
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
