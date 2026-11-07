import Foundation
@testable import Relay
import Testing

struct RunnerKeyboardTests {
    @Test func parsesKeyNamesAndAliases() {
        #expect(RunnerKey(name: "return") == .return)
        #expect(RunnerKey(name: "Enter") == .return)
        #expect(RunnerKey(name: "delete") == .delete)
        #expect(RunnerKey(name: "BACKSPACE") == .delete)
        #expect(RunnerKey(name: "space") == .space)
        for unknown in ["", "home", "returns", " return", "\n"] {
            #expect(RunnerKey(name: unknown) == nil, "\(unknown.debugDescription)")
        }
    }

    @Test func parsesKeysArrayInOrder() throws {
        #expect(try RunnerKey.parse(["delete", "delete", "return"]) == [.delete, .delete, .return])
        #expect(try RunnerKey.parse([String]()) == [])
    }

    @Test func rejectsInvalidKeysArrays() {
        #expect(throws: RunnerKeyError.notAnArray) { try RunnerKey.parse("return") }
        #expect(throws: RunnerKeyError.notAString) { try RunnerKey.parse(["return", 1]) }
        #expect(throws: RunnerKeyError.unknownKey("f1")) { try RunnerKey.parse(["return", "f1"]) }
        #expect(RunnerKeyError.unknownKey("f1").description == "key: unsupported key 'f1' (expected return, delete, space)")
    }

    /// Tab and escape have no key on the iPhone software keyboard, so they are rejected rather than
    /// typed as a "\t" character or silently dropped.
    @Test func rejectsTabAndEscape() {
        for name in ["tab", "Tab", "escape", "esc"] {
            #expect(RunnerKey(name: name) == nil, "\(name)")
        }
        #expect(throws: RunnerKeyError.unknownKey("tab")) { try RunnerKey.parse(["return", "tab"]) }
        #expect(throws: RunnerKeyError.unknownKey("esc")) { try RunnerKey.parse(["esc"]) }
    }

    @Test func requiresNonEmptyTextWithoutKeys() throws {
        #expect(try RunnerTyping.text("hello", keyCount: 0) == "hello")
        #expect(throws: RunnerTextError.missing) { try RunnerTyping.text(nil, keyCount: 0) }
        #expect(throws: RunnerTextError.missing) { try RunnerTyping.text("", keyCount: 0) }
        #expect(throws: RunnerTextError.notAString) { try RunnerTyping.text(123, keyCount: 0) }
    }

    @Test func allowsAbsentOrEmptyTextWithKeys() throws {
        #expect(try RunnerTyping.text(nil, keyCount: 1) == "")
        #expect(try RunnerTyping.text("", keyCount: 1) == "")
        #expect(try RunnerTyping.text("abc", keyCount: 2) == "abc")
    }

    /// `{"text": 123, "keys": ["return"]}` used to drop the text silently and press only Return.
    @Test func rejectsNonStringTextWithKeys() throws {
        let body = try JSONSerialization.jsonObject(with: Data(#"{"text":123,"t":true,"n":null,"a":["x"],"o":{}}"#.utf8)) as? [String: Any]
        for name in ["text", "t", "n", "a", "o"] {
            #expect(throws: RunnerTextError.notAString, "\(name)") { try RunnerTyping.text(body?[name], keyCount: 1) }
        }
    }

    @Test func recognizesMissingKeyboardFocus() {
        let issue = "Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: ..."
        #expect(RunnerTyping.isMissingKeyboardFocus(issue))
        #expect(!RunnerTyping.isMissingKeyboardFocus("Application com.example is not running"))
        #expect(RunnerTyping.missingKeyboardFocusMessage(bundleID: "com.apple.mobilesafari") == "no element has keyboard focus in com.apple.mobilesafari")
    }
}
