import Foundation

/// The stable, machine-readable `code` of every error the on-device runner answers with:
/// `{"ok":false,"code":"<code>","error":"<message for people>"}`.
///
/// The raw values are part of the HTTP API: never rename one. A code stands for what a client should do
/// next, not for every message, so several messages (and sometimes several statuses) share one. The
/// message in `error` stays as it was before codes existed. Like `RunnerAuth.swift`, this file is compiled
/// into both the `relay` CLI and the runner target so the SwiftPM unit tests cover it.
enum RunnerErrorCode: String, CaseIterable {
    /// 400: a body that is not a JSON object, a missing field, or a value of the wrong type or out of range.
    case invalidRequest = "invalid_request"
    /// 400: a point of `/tap`, `/press`, or `/swipe` is outside the screen in the displayed orientation.
    case pointOffscreen = "point_offscreen"
    /// 400 or 422: the touch path asked for (`mode`) or chosen can't be used or can't reach the target; nothing was sent.
    case touchModeUnavailable = "touch_mode_unavailable"
    /// 400 or 501: the HTTP request itself was rejected (request line, encoding, `Content-Length`, `Transfer-Encoding`).
    case httpMalformed = "http_malformed"
    /// 413 or 431: the body or the head is larger than the runner accepts.
    case requestTooLarge = "request_too_large"
    /// 401: no `Authorization: Bearer <token>`, or not the runner's token.
    case unauthorized
    /// 409: another command is running. Safe to retry.
    case busy
    /// 404: no such endpoint (a runner older than the client, if the endpoint is documented).
    case notFound = "not_found"
    /// 405: the endpoint exists but not with this method.
    case methodNotAllowed = "method_not_allowed"
    /// 422: no element matches the selector (or its `index` is out of range). Waiting may help.
    case elementNotFound = "element_not_found"
    /// 422: more than one element matches and no `index` was given. Waiting won't help.
    case elementAmbiguous = "element_ambiguous"
    /// 422: the element has an empty frame, is outside the screen, or is disabled.
    case elementNotHittable = "element_not_hittable"
    /// 422: `/type` or `/key` found no element with keyboard focus.
    case noKeyboardFocus = "no_keyboard_focus"
    /// 422: on a device with more than one display, the foreground app's display can't be told; nothing was sent.
    case displayUnknown = "display_unknown"
    /// 422 or 500: a synthesized touch failed or did not complete in time.
    case touchFailed = "touch_failed"
    /// 422: XCUI reported a failure (a recorded test issue, a snapshot that failed).
    case xcuiFailed = "xcui_failed"
    /// 500: anything else that went wrong in the runner.
    case internalError = "internal_error"

    /// The error body without extra fields.
    func body(_ message: String) -> [String: Any] {
        ["ok": false, "code": rawValue, "error": message]
    }

    /// The code of an error body, or nil when there is none: a runner from before codes, a code this
    /// client doesn't know yet, or a body that isn't JSON.
    static func parse(body: Data) -> RunnerErrorCode? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = object["code"] as? String else { return nil }
        return RunnerErrorCode(rawValue: code)
    }
}

/// The errors a runner command throws; the runner answers each with `status` and `json`.
enum RunnerError: Error, CustomStringConvertible {
    case invalidJSON
    case missingField(String)
    case invalidField(String)
    /// A point outside the screen; the reason from `RunnerRequestValues.pointOutsideScreen`.
    case pointOffscreen(String)
    /// `mode: private` asked for where it can't be used (400, worded as an invalid `mode`).
    case touchModeRejected(String)
    /// The chosen touch path can't reach the target (422); nothing was sent.
    case touchUnreachable(String)
    case notFound
    case methodNotAllowed
    case internalError(String)
    /// A synthesized touch that failed or timed out (422).
    case touchFailed(String)
    /// The synthesizer refused the touch before sending it (500, as before codes).
    case touchSynthesisError(String)
    /// An XCUI failure that has no code of its own (422).
    case actionFailed(String)
    case noKeyboardFocus(bundleID: String)
    /// The app's display can't be told, or is gone (422).
    case displayUnknown(String)
    /// A selector that didn't lead to one touchable element; answered with the failure's JSON.
    case elementNotResolved(RunnerElementLookupFailure)

    var description: String {
        switch self {
        case .invalidJSON: return "request body must be a JSON object"
        case .missingField(let name): return "missing required field: \(name)"
        case .invalidField(let name), .pointOffscreen(let name), .touchModeRejected(let name): return "invalid field: \(name)"
        case .notFound: return "not found"
        case .methodNotAllowed: return "method not allowed"
        case .internalError(let message), .touchFailed(let message), .touchSynthesisError(let message),
             .actionFailed(let message), .touchUnreachable(let message), .displayUnknown(let message):
            return message
        case .noKeyboardFocus(let bundleID): return RunnerTyping.missingKeyboardFocusMessage(bundleID: bundleID)
        case .elementNotResolved(let failure): return failure.message
        }
    }

    var status: Int {
        switch self {
        case .invalidJSON, .missingField, .invalidField, .pointOffscreen, .touchModeRejected: return 400
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .internalError, .touchSynthesisError: return 500
        case .touchFailed, .actionFailed, .touchUnreachable, .noKeyboardFocus, .displayUnknown, .elementNotResolved: return 422
        }
    }

    var code: RunnerErrorCode {
        switch self {
        case .invalidJSON, .missingField, .invalidField: return .invalidRequest
        case .pointOffscreen: return .pointOffscreen
        case .touchModeRejected, .touchUnreachable: return .touchModeUnavailable
        case .notFound: return .notFound
        case .methodNotAllowed: return .methodNotAllowed
        case .internalError: return .internalError
        case .touchFailed, .touchSynthesisError: return .touchFailed
        case .actionFailed: return .xcuiFailed
        case .noKeyboardFocus: return .noKeyboardFocus
        case .displayUnknown: return .displayUnknown
        case .elementNotResolved(let failure): return failure.code
        }
    }

    /// The response body: `code` and `error`, plus `reason`, `count`, and `candidates` for an element lookup.
    var json: [String: Any] {
        if case .elementNotResolved(let failure) = self {
            return failure.json
        }
        return code.body(description)
    }
}
