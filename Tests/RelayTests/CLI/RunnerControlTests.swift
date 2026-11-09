import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerControlTests {
  @Test func tellsAConnectionTheOSRefusedFromNothingListening() {
    // What URLSession reported under a Seatbelt profile that denies localhost (macOS 27).
    let sandboxed = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 1])
    #expect(RunnerConnectionError.isRefusedByOS(sandboxed))
    // Nothing listening: NSURLErrorDomain -1004 over a CFNetwork error with ECONNREFUSED (61).
    let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
      "_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 61,
      NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: -1004, userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 61])
    ])
    #expect(!RunnerConnectionError.isRefusedByOS(refused))
    #expect(!RunnerConnectionError.isRefusedByOS(URLError(.timedOut)))
    // EPERM wrapped in a URL error, in its CFStream fields or as the underlying error.
    #expect(RunnerConnectionError.isRefusedByOS(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                                        userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 1])))
    #expect(RunnerConnectionError.isRefusedByOS(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                                        userInfo: [NSUnderlyingErrorKey: sandboxed])))
    // Error code 1 of another CFStream domain (2 is kCFStreamErrorDomainNetDB) is not EPERM.
    #expect(!RunnerConnectionError.isRefusedByOS(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                                         userInfo: ["_kCFStreamErrorDomainKey": 2, "_kCFStreamErrorCodeKey": 1])))
  }

  @Test func mapsStatusesToExitCodes() {
    #expect(RunnerExitCode(status: 200) == .success)
    #expect(RunnerExitCode(status: 400) == .badRequest)
    #expect(RunnerExitCode(status: 401) == .unauthorized)
    #expect(RunnerExitCode(status: 404) == .badRequest)
    #expect(RunnerExitCode(status: 409) == .busy)
    #expect(RunnerExitCode(status: 422) == .actionFailed)
    #expect(RunnerExitCode(status: 501) == .runnerError)
    #expect(RunnerExitCode(status: 0) == .runnerError)
  }

  @Test func savesScreenshotsUnderTheTemporaryDirectoryByDefault() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-29T01:02:03Z"))
    let temporary = URL(fileURLWithPath: "/private/tmp/t")
    let current = URL(fileURLWithPath: "/work/app")
    let url = RunnerControl.screenshotURL(RunnerScreenshot(format: "jpeg"), now: now, currentDirectory: current, temporaryDirectory: temporary)
    #expect(url.deletingLastPathComponent().path == "/private/tmp/t/relay")
    #expect(url.lastPathComponent.hasPrefix("screenshot-"))
    #expect(url.pathExtension == "jpg")

    #expect(RunnerControl.screenshotURL(RunnerScreenshot(output: "shots/a.png"), currentDirectory: current, temporaryDirectory: temporary).path
      == "/work/app/shots/a.png")
    #expect(RunnerControl.screenshotURL(RunnerScreenshot(output: "/abs/b.png"), currentDirectory: current, temporaryDirectory: temporary).path
      == "/abs/b.png")
  }

  @Test func summarizesScreenshotHeaders() {
    let headers = RunnerRequestValues.screenshotHeaders(image: CGSize(width: 1024, height: 471), screen: CGSize(width: 874, height: 402))
    #expect(RunnerControl.screenshotSummary(headers)
      == "image 1024x471 px, screen 874x402 pt, 1.172 px/pt (tap in points: px / 1.172)")
    // URLSession may hand the names back in another case.
    let lowercased = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    #expect(RunnerControl.screenshotSummary(lowercased) == RunnerControl.screenshotSummary(headers))
    // A runner from before the headers.
    #expect(RunnerControl.screenshotSummary(["Content-Type": "image/png"]) == nil)
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
    let covered = RunnerControl.hint(for: .actionFailed, errorCode: .coveredByOtherApp, infoURL: infoURL)
    #expect(covered?.contains("relay find --type alert --bundle-id com.apple.springboard") == true)
    let remote = RunnerControl.hint(for: .actionFailed, errorCode: .remoteViewPositionUnknown, infoURL: infoURL)
    #expect(remote?.contains("relay screenshot") == true && remote?.contains("relay tap <x> <y>") == true)
    // Codes whose message already says what to do get no hint.
    for code in [RunnerErrorCode.pointOffscreen, .invalidRequest, .elementNotHittable, .displayUnknown, .xcuiFailed, .touchFailed] {
      #expect(RunnerControl.hint(for: .actionFailed, errorCode: code, infoURL: infoURL) == nil, "\(code)")
    }
  }

  /// A touch refused inside the share sheet: the runner's 422 exits 6 with the coordinates hint.
  @Test func aTouchRefusedInsideTheShareSheetExits6WithAHint() throws {
    let message = "cannot tell where the elements inside ShareSheet.RemoteContainerView (9,501,384,364) are on the screen"
    var copy = RunnerElementNode(type: "cell", identifier: "actionGroupCell", label: "Copy", value: nil, placeholder: nil,
                                 frame: CGRect(x: 20, y: 230, width: 82, height: 134), enabled: true, selected: false,
                                 hasFocus: false, hasKeyboardFocus: nil, children: [])
    copy.positionUnknown = message
    let failure = RunnerElementLookupFailure(reason: .positionUnknown, count: 1,
                                             candidates: [RunnerElementMatch(index: 0, node: copy)])
    let error = RunnerError.elementNotResolved(failure)
    let body = try JSONSerialization.data(withJSONObject: error.json)
    let exit = RunnerExitCode(status: error.status)
    #expect(exit == .actionFailed && exit.rawValue == 6)
    let code = try #require(RunnerErrorCode.parse(body: body))
    #expect(code == .remoteViewPositionUnknown)
    #expect(RunnerControl.hint(for: exit, errorCode: code, infoURL: infoURL)?.contains("relay tap <x> <y>") == true)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["reason"] as? String == "positionUnknown")
    #expect((object["error"] as? String)?.hasPrefix(message + "; nothing was sent") == true)
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
