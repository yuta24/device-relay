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

  @Test func allowsAbsentOrEmptyTextWhenClearing() throws {
    #expect(try RunnerTyping.text(nil, keyCount: 0, clear: true) == "")
    #expect(try RunnerTyping.text("", keyCount: 0, clear: true) == "")
    #expect(try RunnerTyping.text("new", keyCount: 0, clear: true) == "new")
    #expect(throws: RunnerTextError.notAString) { try RunnerTyping.text(1, keyCount: 0, clear: true) }
  }

  /// `{"text": 123, "keys": ["return"]}` used to drop the text silently and press only Return.
  @Test func rejectsNonStringTextWithKeys() throws {
    let body = try JSONSerialization.jsonObject(with: Data(#"{"text":123,"t":true,"n":null,"a":["x"],"o":{}}"#.utf8)) as? [String: Any]
    for name in ["text", "t", "n", "a", "o"] {
      #expect(throws: RunnerTextError.notAString, "\(name)") { try RunnerTyping.text(body?[name], keyCount: 1) }
    }
  }

  /// A failed focus query must not count as focus: the text would be typed into whatever has it.
  @Test func failedFocusQueryTypesNothing() {
    #expect(RunnerTyping.focusCheck(matchCount: 1, queryFailed: false) == .focused)
    #expect(RunnerTyping.focusCheck(matchCount: 0, queryFailed: false) == .notFocused)
    #expect(RunnerTyping.focusCheck(matchCount: 0, queryFailed: true) == .queryFailed)
    #expect(RunnerTyping.focusCheck(matchCount: 1, queryFailed: true) == .queryFailed)
  }

  @Test func recognizesMissingKeyboardFocus() {
    let issue = "Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: ..."
    #expect(RunnerTyping.isMissingKeyboardFocus(issue))
    #expect(!RunnerTyping.isMissingKeyboardFocus("Application com.example is not running"))
    #expect(RunnerTyping.missingKeyboardFocusMessage(bundleID: "com.apple.mobilesafari") == "no element has keyboard focus in com.apple.mobilesafari")
  }
}

struct RunnerClearingTests {
  /// A field that changes as the steps say: select all empties it unless `selectAll` is false, deletes take
  /// characters off the end. `lagReads` reads after a step still see the old text, as an app that updates late.
  private final class FakeField {
    var text: String
    var placeholder: String?
    var selectAll = true
    var refills = false
    /// Reads after each step that still see the text from before it.
    var lagAfterStep = 0
    private var lagReads = 0
    var shown: String
    var performed: [RunnerClearing.Step] = []
    var waited: [TimeInterval] = []
    var reads = 0

    init(_ text: String, placeholder: String? = nil) {
      self.text = text
      self.placeholder = placeholder
      shown = text
    }

    func read() -> RunnerClearing.Field {
      reads += 1
      if lagReads > 0 {
        lagReads -= 1
      } else {
        shown = text
      }
      let value = shown.isEmpty ? placeholder : shown
      return RunnerClearing.Field(value: value, placeholder: placeholder)
    }

    func perform(_ step: RunnerClearing.Step) {
      performed.append(step)
      let before = text
      switch step {
      case .selectAllAndDelete:
        text = selectAll ? "" : String(text.dropLast())
      case .moveToEndAndDelete(let count):
        text = String(text.dropLast(count))
      }
      if refills { text = before }
      lagReads = lagAfterStep
    }

    func clear() throws -> RunnerClearing.Outcome {
      try RunnerClearing.clear(read: read, perform: perform, wait: { self.waited.append($0) })
    }
  }

  @Test func sendsNothingToAnEmptyField() throws {
    let field = FakeField("")
    #expect(try field.clear() == .alreadyEmpty)
    #expect(field.performed.isEmpty)
    #expect(field.reads == 1)
  }

  @Test func selectAllIsTheFirstStepWhereverTheCursorIs() throws {
    let field = FakeField("a👨‍👩‍👧🇯🇵e\u{301}日本語")
    #expect(try field.clear() == .cleared(steps: [.selectAllAndDelete]))
    #expect(field.text.isEmpty)
    #expect(field.waited.isEmpty)
  }

  /// A delete takes one character as Swift counts them, so the count is of characters, not scalars or UTF-16.
  @Test func deletesFromTheEndWhenSelectAllDoesNotWork() throws {
    let field = FakeField("a👨‍👩‍👧🇯🇵e\u{301}日本語")
    field.selectAll = false
    // One delete went with command-A: 6 characters were left.
    #expect(try field.clear() == .cleared(steps: [.selectAllAndDelete, .moveToEndAndDelete(count: 6)]))
    #expect(field.text.isEmpty)
    // The read after select all looked again for the settle time before deleting.
    #expect(field.waited == Array(repeating: RunnerClearing.settleInterval, count: 5))
  }

  @Test func readsAgainWhileTheAppCatchesUp() throws {
    let field = FakeField("hello")
    field.lagAfterStep = 2
    #expect(try field.clear() == .cleared(steps: [.selectAllAndDelete]))
    #expect(field.waited == [RunnerClearing.settleInterval, RunnerClearing.settleInterval])
  }

  @Test func failsWithWhatIsLeftWhenTheFieldKeepsItsText() {
    let field = FakeField("keep me")
    field.refills = true
    #expect(throws: RunnerClearing.NotCleared(remaining: 7, steps: [.selectAllAndDelete, .moveToEndAndDelete(count: 7)])) {
      try field.clear()
    }
  }

  @Test func deletesAtMostTheLimit() {
    let field = FakeField(String(repeating: "x", count: 250))
    field.selectAll = false
    let steps: [RunnerClearing.Step] = [.selectAllAndDelete, .moveToEndAndDelete(count: RunnerClearing.maxDeletes)]
    #expect(throws: RunnerClearing.NotCleared(remaining: 49, steps: steps)) { try field.clear() }
  }

  /// A field that shows its placeholder as the value may also hold that very text, so it is cleared anyway, and
  /// is empty once only the placeholder is left.
  @Test func clearsTextThatLooksLikeThePlaceholder() throws {
    let field = FakeField("Type here", placeholder: "Type here")
    #expect(try field.clear() == .cleared(steps: [.selectAllAndDelete]))
    #expect(field.text.isEmpty)
    #expect(RunnerClearing.Field(value: "Type here", placeholder: "Type here").hasNoValue == false)
    #expect(RunnerClearing.Field(value: "Type here", placeholder: "Type here").isClear)
    #expect(RunnerClearing.Field(value: nil).isClear)
    #expect(RunnerClearing.Field(value: "").hasNoValue)
    #expect(RunnerClearing.Field(value: "•••").characterCount == 3)
  }

  @Test func aFailedReadOrStepStopsAtOnce() {
    struct ReadFailed: Error {}
    #expect(throws: ReadFailed.self) {
      try RunnerClearing.clear(read: { throw ReadFailed() }, perform: { _ in Issue.record("sent a key") }, wait: { _ in })
    }
  }

  /// relay waits this much longer for `type --clear`; the runner gives up on the clearing within it (plus the grace).
  @Test func theWaitCoversEveryKeyAndTheMostDeletes() {
    #expect(RunnerTyping.clearWait == 3 * RunnerTyping.waitPerKey + Double(RunnerClearing.maxDeletes) * RunnerTyping.waitPerCharacter)
    #expect(RunnerTyping.clearWait + RunnerTyping.synthesisGrace < 60)
  }
}
