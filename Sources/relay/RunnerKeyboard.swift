import Foundation

/// Special keys for `/key` and the `keys` array of `/type`.
///
/// This file is compiled into both the `relay` CLI and the RelayRunnerUITests target, so the name
/// parsing the runner relies on is covered by the SwiftPM unit tests. The runner maps each case to an
/// `XCUIKeyboardKey`.
enum RunnerKey: String, CaseIterable {
    case `return`
    case delete
    case tab
    case escape
    case space

    /// Case-insensitive, with a few common aliases (`enter`, `backspace`, `esc`).
    init?(name: String) {
        switch name.lowercased() {
        case "return", "enter": self = .return
        case "delete", "backspace": self = .delete
        case "tab": self = .tab
        case "escape", "esc": self = .escape
        case "space": self = .space
        default: return nil
        }
    }

    /// The keys of a JSON `keys` array, in order. Throws unless every entry is a known key name.
    static func parse(_ value: Any) throws -> [RunnerKey] {
        guard let names = value as? [Any] else {
            throw RunnerKeyError.notAnArray
        }
        return try names.map { item in
            guard let name = item as? String else { throw RunnerKeyError.notAString }
            guard let key = RunnerKey(name: name) else { throw RunnerKeyError.unknownKey(name) }
            return key
        }
    }

    static var supportedNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

enum RunnerKeyError: Error, Equatable, CustomStringConvertible {
    case notAnArray
    case notAString
    case unknownKey(String)

    var description: String {
        switch self {
        case .notAnArray: return "keys: expected an array of key names"
        case .notAString: return "keys: expected key names as strings"
        case .unknownKey(let name): return "key: unsupported key '\(name)' (expected \(RunnerKey.supportedNames))"
        }
    }
}

enum RunnerTyping {
    /// True when an XCUI issue says that nothing in the app has keyboard focus, as `typeText` reports
    /// with "Neither element nor any descendant has keyboard focus".
    static func isMissingKeyboardFocus(_ issue: String) -> Bool {
        issue.range(of: "has keyboard focus", options: .caseInsensitive) != nil
    }

    static func missingKeyboardFocusMessage(bundleID: String) -> String {
        "no element has keyboard focus in \(bundleID)"
    }
}
