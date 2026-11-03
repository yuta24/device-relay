import CoreGraphics
import Foundation
@testable import relay
import Testing

struct RunnerErrorCodeTests {
    /// The raw values are part of the HTTP API: a change here breaks clients that branch on them.
    @Test func codeStringsAreStable() {
        let expected: [RunnerErrorCode: String] = [
            .invalidRequest: "invalid_request",
            .pointOffscreen: "point_offscreen",
            .touchModeUnavailable: "touch_mode_unavailable",
            .httpMalformed: "http_malformed",
            .requestTooLarge: "request_too_large",
            .unauthorized: "unauthorized",
            .busy: "busy",
            .notFound: "not_found",
            .methodNotAllowed: "method_not_allowed",
            .elementNotFound: "element_not_found",
            .elementAmbiguous: "element_ambiguous",
            .elementNotHittable: "element_not_hittable",
            .noKeyboardFocus: "no_keyboard_focus",
            .displayUnknown: "display_unknown",
            .touchFailed: "touch_failed",
            .xcuiFailed: "xcui_failed",
            .internalError: "internal_error"
        ]
        #expect(RunnerErrorCode.allCases.count == expected.count)
        for code in RunnerErrorCode.allCases {
            #expect(code.rawValue == expected[code], "\(code)")
            #expect(code.rawValue.allSatisfy { $0.isLowercase || $0 == "_" }, "\(code.rawValue) is snake_case")
        }
    }

    @Test func mapsEveryRunnerErrorToItsStatusAndCode() {
        let lookup = RunnerElementLookupFailure(reason: .ambiguous, count: 2, candidates: [])
        let cases: [(RunnerError, Int, RunnerErrorCode)] = [
            (.invalidJSON, 400, .invalidRequest),
            (.missingField("x"), 400, .invalidRequest),
            (.invalidField("x"), 400, .invalidRequest),
            (.pointOffscreen("x, y: (500, 100) is outside the screen"), 400, .pointOffscreen),
            (.touchModeRejected("mode: private touch synthesis is unavailable (no class)"), 400, .touchModeUnavailable),
            (.touchUnreachable("xcui touches can't reach display 3"), 422, .touchModeUnavailable),
            (.notFound, 404, .notFound),
            (.methodNotAllowed, 405, .methodNotAllowed),
            (.internalError("failed to encode JPEG"), 500, .internalError),
            (.touchFailed("touch synthesis did not complete within 10s"), 422, .touchFailed),
            (.touchSynthesisError("touch synthesis failed: no class"), 500, .touchFailed),
            (.actionFailed("failed to snapshot com.example"), 422, .xcuiFailed),
            (.noKeyboardFocus(bundleID: "com.example"), 422, .noKeyboardFocus),
            (.displayUnknown("cannot tell which display com.example is on"), 422, .displayUnknown),
            (.elementNotResolved(lookup), 422, .elementAmbiguous)
        ]
        for (error, status, code) in cases {
            #expect(error.status == status, "\(error)")
            #expect(error.code == code, "\(error)")
            #expect(error.json["code"] as? String == code.rawValue, "\(error)")
            #expect(error.json["ok"] as? Bool == false, "\(error)")
            #expect(error.json["error"] as? String == error.description, "\(error)")
        }
    }

    /// `error` keeps the messages clients read before codes existed.
    @Test func keepsTheMessages() {
        #expect(RunnerError.invalidJSON.description == "request body must be a JSON object")
        #expect(RunnerError.pointOffscreen("x, y: (500, 100) is outside the screen").description
            == "invalid field: x, y: (500, 100) is outside the screen")
        #expect(RunnerError.touchModeRejected("mode: expected private").description == "invalid field: mode: expected private")
        #expect(RunnerError.noKeyboardFocus(bundleID: "com.apple.Preferences").description
            == "no element has keyboard focus in com.apple.Preferences")
        #expect(RunnerError.notFound.description == "not found")
        #expect(RunnerErrorCode.busy.body("busy") as NSDictionary == ["ok": false, "code": "busy", "error": "busy"] as NSDictionary)
    }

    @Test func givesFramingFailuresACode() {
        func failure(_ text: String) -> RunnerHTTPFraming.Failure? {
            if case .failure(let failure) = RunnerHTTPFraming.parseHead(Data(text.utf8)) { return failure }
            return nil
        }
        let filler = String(repeating: "a", count: RunnerHTTPFraming.maxHeaderSize)
        let cases: [(String, Int, RunnerErrorCode)] = [
            ("GARBAGE\r\n\r\n", 400, .httpMalformed),
            ("POST /tap HTTP/1.1\r\nContent-Length: -1\r\n\r\n", 400, .httpMalformed),
            ("POST /tap HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 501, .httpMalformed),
            ("POST /tap HTTP/1.1\r\nContent-Length: \(RunnerHTTPFraming.maxBodySize + 1)\r\n\r\n", 413, .requestTooLarge),
            ("GET / HTTP/1.1\r\nX: \(filler)\r\n\r\n", 431, .requestTooLarge)
        ]
        for (text, status, code) in cases {
            let failure = failure(text)
            #expect(failure?.status == status, "\(text.prefix(40))")
            #expect(failure?.code == code, "\(text.prefix(40))")
            #expect(failure?.json["code"] as? String == code.rawValue)
            #expect(failure?.json["error"] as? String == failure?.message)
        }
    }

    @Test func putsTheCodeInElementLookupFailures() {
        let expected: [RunnerElementLookupFailure.Reason: RunnerErrorCode] = [
            .notFound: .elementNotFound,
            .indexOutOfRange: .elementNotFound,
            .ambiguous: .elementAmbiguous,
            .emptyFrame: .elementNotHittable,
            .offscreen: .elementNotHittable,
            .disabled: .elementNotHittable
        ]
        for (reason, code) in expected {
            let failure = RunnerElementLookupFailure(reason: reason, count: 3, candidates: [])
            #expect(failure.code == code, "\(reason)")
            let json = failure.json
            #expect(json["code"] as? String == code.rawValue)
            // The fields from before codes stay.
            #expect(json["ok"] as? Bool == false)
            #expect(json["reason"] as? String == reason.rawValue)
            #expect(json["count"] as? Int == 3)
            #expect(json["candidates"] is [Any])
            #expect(json["error"] as? String == failure.message)
        }
    }

    @Test func readsTheCodeOfAnErrorBody() {
        #expect(RunnerErrorCode.parse(body: Data(#"{"ok":false,"code":"no_keyboard_focus","error":"…"}"#.utf8)) == .noKeyboardFocus)
        // A runner from before codes, a code from a newer runner, and bodies that aren't error objects.
        #expect(RunnerErrorCode.parse(body: Data(#"{"ok":false,"error":"busy"}"#.utf8)) == nil)
        #expect(RunnerErrorCode.parse(body: Data(#"{"ok":false,"code":"something_new","error":"…"}"#.utf8)) == nil)
        #expect(RunnerErrorCode.parse(body: Data(#"{"ok":false,"code":7}"#.utf8)) == nil)
        #expect(RunnerErrorCode.parse(body: Data("not json".utf8)) == nil)
        #expect(RunnerErrorCode.parse(body: Data()) == nil)
    }
}

struct RunnerControlHintTests {
    private let infoURL = URL(fileURLWithPath: "/tmp/runner.json")

    @Test func hintsByCode() {
        #expect(RunnerControl.hint(for: .actionFailed, errorCode: .noKeyboardFocus, infoURL: infoURL)?.contains("tap the text field first") == true)
        #expect(RunnerControl.hint(for: .actionFailed, errorCode: .elementNotFound, infoURL: infoURL)?.contains("--timeout") == true)
        #expect(RunnerControl.hint(for: .actionFailed, errorCode: .elementAmbiguous, infoURL: infoURL)?.contains("--index") == true)
        #expect(RunnerControl.hint(for: .actionFailed, errorCode: .touchModeUnavailable, infoURL: infoURL)?.contains("--mode") == true)
        #expect(RunnerControl.hint(for: .badRequest, errorCode: .touchModeUnavailable, infoURL: infoURL)?.contains("--mode") == true)
        #expect(RunnerControl.hint(for: .badRequest, errorCode: .notFound, infoURL: infoURL)?.contains("relay start --rebuild") == true)
        // Codes whose message already says what to do get no hint.
        for code in [RunnerErrorCode.pointOffscreen, .invalidRequest, .elementNotHittable, .displayUnknown, .xcuiFailed, .touchFailed] {
            #expect(RunnerControl.hint(for: .actionFailed, errorCode: code, infoURL: infoURL) == nil, "\(code)")
        }
    }

    /// The hints for 401 and 409 come from the status, with or without a code.
    @Test func keepsTheStatusHintsWithAndWithoutACode() {
        let unauthorized = RunnerControl.hint(for: .unauthorized, infoURL: infoURL)
        #expect(unauthorized?.contains("/tmp/runner.json") == true)
        #expect(RunnerControl.hint(for: .unauthorized, errorCode: .unauthorized, infoURL: infoURL) == unauthorized)
        let busy = RunnerControl.hint(for: .busy, infoURL: infoURL)
        #expect(busy?.contains("\"busy\":false") == true)
        #expect(RunnerControl.hint(for: .busy, errorCode: .busy, infoURL: infoURL) == busy)
        // A runner from before codes: a 422 has no hint, as before.
        #expect(RunnerControl.hint(for: .actionFailed, errorCode: RunnerErrorCode.parse(body: Data(#"{"ok":false,"error":"x"}"#.utf8)),
                                   infoURL: infoURL) == nil)
    }
}
