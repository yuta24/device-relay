import UIKit
import XCTest

/// A long-running "test" that serves device-control commands over HTTP until `/shutdown` is called.
///
/// HTTP is handled on a background queue, and every XCUI call is dispatched to the main queue.
/// The main queue is drained serially, so commands never run concurrently.
final class RelayRunnerUITests: XCTestCase {
    static let readyMarker = "RELAY_RUNNER_READY"
    private static let springboardBundleID = "com.apple.springboard"

    private var shouldStop = false
    private var capturedIssues: [String]?
    private var lastActivatedBundleID: String?
    /// Portrait size and scale; they don't change with rotation, so they are measured once.
    private var cachedScreen: (size: CGSize, scale: CGFloat)?

    private lazy var springboard = XCUIApplication(bundleIdentifier: Self.springboardBundleID)

    func testRunServer() throws {
        continueAfterFailure = true
        Self.restoreApplicationStateTimeout()

        let environment = ProcessInfo.processInfo.environment
        let port = UInt16(environment["RELAY_RUNNER_PORT"] ?? "") ?? 8100
        // There is no unauthenticated mode: when launched without relay, make a token and print it once.
        // relay passes only the token's hash, so the token never lands in the xcresult bundle.
        let tokenHash: String
        if let given = environment[RunnerAuth.tokenHashEnvironmentKey], !given.isEmpty {
            guard let normalized = RunnerAuth.normalizedTokenHash(given) else {
                throw RunnerError.invalidField("\(RunnerAuth.tokenHashEnvironmentKey): expected 64 hex digits")
            }
            tokenHash = normalized
        } else {
            let token = RunnerAuth.generateToken()
            tokenHash = RunnerAuth.tokenHash(token)
            Self.emit("relay-runner: \(RunnerAuth.tokenHashEnvironmentKey) is not set; generated token: \(token)")
        }

        // Runs on the HTTP queue. The main queue runs one command at a time, and a command can take
        // seconds (a gesture, an app launch), so reject overlapping requests here instead of queueing.
        let gate = CommandGate()
        // The server answers 401 itself before calling this, so unauthenticated clients learn nothing
        // about the busy state or command timing.
        let server = try RunnerHTTPServer(port: port, tokenHash: tokenHash) { [weak self] request, respond in
            if request.path == "/ping" {
                // The liveness check: answered here, so it never takes the gate from a command and never
                // waits for the main queue. Not logged, because relay sends it every few seconds.
                respond(request.method == "GET" ? .json(gate.pingBody()) : .error(RunnerError.methodNotAllowed.description, status: 405))
                return
            }
            if request.method == "POST" && request.path == "/shutdown" {
                // Accepted even while a command runs; the runner stops once that command returns.
                respond(.json(["ok": true]))
                DispatchQueue.main.async { self?.shutdown() }
                return
            }
            guard gate.tryEnter() else {
                Self.emit("relay-runner \(request.method) \(request.path) -> 409")
                respond(.error("busy", status: 409))
                return
            }
            DispatchQueue.main.async {
                let response = self?.handle(request) ?? .error("runner is shutting down", status: 500)
                // Leave before responding so a client that sends its next request right after the
                // response never sees a stale busy state.
                gate.leave()
                respond(response)
            }
        }

        var startupError: Error?
        server.start(
            onReady: {
                let addresses = NetworkAddresses.current().map { "\($0.interface)=\($0.address)" }
                Self.emit("\(Self.readyMarker) port=\(port) addresses=\(addresses.joined(separator: ","))")
            },
            onFailure: { error in
                DispatchQueue.main.async {
                    startupError = error
                    self.shouldStop = true
                }
            }
        )

        while !shouldStop {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
        server.stop()

        if let startupError {
            throw startupError
        }
    }

    /// XCUI failures are recorded as test issues instead of thrown. While a command runs,
    /// capture them so they become an HTTP error and the runner keeps serving.
    override func record(_ issue: XCTIssue) {
        if capturedIssues != nil {
            capturedIssues?.append(issue.compactDescription)
            return
        }
        super.record(issue)
    }

    // MARK: - Routing

    private func handle(_ request: RunnerHTTPRequest) -> RunnerHTTPResponse {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        capturedIssues = []
        defer { capturedIssues = nil }

        var response: RunnerHTTPResponse
        do {
            response = try route(request)
        } catch RunnerError.elementNotResolved(let failure) {
            response = .json(failure.json, status: 422)
        } catch let error as RunnerError {
            response = .error(error.description, status: error.status)
        } catch {
            response = .error(String(describing: error), status: 500)
        }
        if let issues = capturedIssues, !issues.isEmpty {
            response = .error(issues.joined(separator: "; "), status: 422)
        }

        let durationMs = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        Self.emit("relay-runner \(request.method) \(request.path) -> \(response.status) \(durationMs)ms")
        return response
    }

    /// `/shutdown` is answered on the HTTP queue without waiting for the busy gate; this only stops the loop.
    private func shutdown() {
        shouldStop = true
        Self.emit("relay-runner POST /shutdown -> 200")
    }

    private func route(_ request: RunnerHTTPRequest) throws -> RunnerHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(health())
        case ("GET", "/screenshot"):
            return try screenshot(query: request.query)
        case ("GET", "/foreground"):
            var object = foregroundApplication().json
            object["ok"] = true
            return .json(object)
        case ("GET", "/source"):
            return try source(query: request.query)
        case ("POST", "/tap"):
            let body = try RunnerJSON(request.body)
            return try touch(body, duration: nil)
        case ("POST", "/press"):
            let body = try RunnerJSON(request.body)
            return try touch(body, duration: body.positiveDouble("duration", default: 1.0))
        case ("POST", "/find"):
            return try find(RunnerJSON(request.body))
        case ("POST", "/swipe"):
            let body = try RunnerJSON(request.body)
            return ok(mode: try swipe(body, mode: touchMode(body)))
        case ("POST", "/type"):
            let body = try RunnerJSON(request.body)
            let keys = try body.keys()
            let text = try body.typedText(keyCount: keys.count)
            let bundleID = body.optionalString("bundleId") ?? foregroundApplication().bundleID
            try type(text: text, keys: keys, bundleID: bundleID)
            return .json(["ok": true, "bundleId": bundleID])
        case ("POST", "/key"):
            let body = try RunnerJSON(request.body)
            let name = try body.string("key")
            guard let key = RunnerKey(name: name) else {
                throw RunnerError.invalidField(RunnerKeyError.unknownKey(name).description)
            }
            let bundleID = body.optionalString("bundleId") ?? foregroundApplication().bundleID
            try type(text: "", keys: [key], bundleID: bundleID)
            return .json(["ok": true, "bundleId": bundleID])
        case ("POST", "/button"):
            try pressButton(RunnerJSON(request.body).string("name"))
            return ok()
        case ("POST", "/orientation"):
            XCUIDevice.shared.orientation = try orientation(RunnerJSON(request.body).string("orientation"))
            return ok()
        case ("POST", "/launch"):
            let bundleID = try RunnerJSON(request.body).string("bundleId")
            XCUIApplication(bundleIdentifier: bundleID).activate()
            lastActivatedBundleID = bundleID
            return ok()
        case ("POST", "/terminate"):
            let bundleID = try RunnerJSON(request.body).string("bundleId")
            XCUIApplication(bundleIdentifier: bundleID).terminate()
            if lastActivatedBundleID == bundleID {
                lastActivatedBundleID = nil
            }
            return ok()
        case (_, "/health"), (_, "/foreground"), (_, "/screenshot"), (_, "/source"), (_, "/tap"), (_, "/press"),
             (_, "/find"), (_, "/swipe"), (_, "/type"), (_, "/key"), (_, "/button"), (_, "/orientation"), (_, "/launch"),
             (_, "/terminate"), (_, "/shutdown"):
            throw RunnerError.methodNotAllowed
        default:
            throw RunnerError.notFound
        }
    }

    // MARK: - Commands

    private func health() -> [String: Any] {
        let orientation = interfaceOrientation()
        let screen = self.screen(in: orientation)
        return [
            "ok": true,
            "device": [
                "model": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion,
                "simulator": Self.isSimulator
            ],
            "screen": [
                "width": screen.size.width,
                "height": screen.size.height,
                "scale": screen.scale
            ],
            "orientation": Self.name(of: orientation),
            "coordinateSpace": "points",
            "touchSynthesis": (RelayTouchSynthesizer.isAvailable ? TouchMode.private : .xcui).rawValue,
            "foreground": foregroundApplication().json
        ]
    }

    // MARK: - Foreground application

    struct ForegroundApplication {
        let bundleID: String
        let pid: pid_t?
        let source: Source

        enum Source: String {
            /// XCTest's private accessibility client reported it.
            case `private`
            /// The last `/launch`ed app while it is still in the foreground, otherwise SpringBoard.
            case fallback
        }

        var json: [String: Any] {
            ["bundleId": bundleID, "pid": pid.map { Int($0) as Any } ?? NSNull(), "source": source.rawValue]
        }
    }

    /// The app the user sees, including one switched to by hand, which `/type` and `/source` target
    /// by default.
    ///
    /// The private accessibility client (WebDriverAgent's `fb_activeApplication`) reports the active
    /// applications, SpringBoard on the home screen. It reports one, except in the middle of an app
    /// switch, when both apps are listed with the new one first, so the first is used. Without it,
    /// fall back to the last `/launch`ed app if the public `state` still says it is in the foreground,
    /// and to SpringBoard otherwise.
    private func foregroundApplication() -> ForegroundApplication {
        if RelayActiveApplication.isAvailable {
            // /health calls this too, so a failed lookup must not turn into a 422.
            let (applications, failed) = ignoringIssues { try? RelayActiveApplication.activeApplications() }
            if !failed, let active = applications?.first {
                return ForegroundApplication(bundleID: active.bundleIdentifier, pid: active.processIdentifier, source: .private)
            }
        }
        if let bundleID = lastActivatedBundleID {
            let (state, failed) = ignoringIssues { XCUIApplication(bundleIdentifier: bundleID).state }
            if !failed, state == .runningForeground {
                return ForegroundApplication(bundleID: bundleID, pid: nil, source: .fallback)
            }
        }
        return ForegroundApplication(bundleID: Self.springboardBundleID, pid: nil, source: .fallback)
    }

    // MARK: - Keyboard

    /// Types `text`, then each of `keys`, into the focused element of `bundleID`.
    ///
    /// Keys go through `typeText` as their `XCUIKeyboardKey` characters (return is "\r", delete is
    /// U+007F). `typeKey(_:modifierFlags:)` sends hardware key events instead, but on iPhone (simulator
    /// and device) only space and tab arrived that way; return, delete, and escape were dropped.
    private func type(text: String, keys: [RunnerKey], bundleID: String) throws {
        let application = XCUIApplication(bundleIdentifier: bundleID)
        let issueCount = capturedIssues?.count ?? 0
        application.typeText(text + keys.map { Self.keyboardKey($0).rawValue }.joined())
        // typeText fails with a long XCUI message that dumps the element tree; say what went wrong instead.
        if let issues = capturedIssues, issues.count > issueCount,
           issues[issueCount...].contains(where: RunnerTyping.isMissingKeyboardFocus) {
            capturedIssues?.removeSubrange(issueCount...)
            throw RunnerError.actionFailed(RunnerTyping.missingKeyboardFocusMessage(bundleID: bundleID))
        }
    }

    private static func keyboardKey(_ key: RunnerKey) -> XCUIKeyboardKey {
        switch key {
        case .return: return .return
        case .delete: return .delete
        case .space: return .space
        }
    }

    // MARK: - Source

    private func source(query: [String: String]) throws -> RunnerHTTPResponse {
        let bundleID = query["bundleId"].flatMap { $0.isEmpty ? nil : $0 } ?? foregroundApplication().bundleID
        let application = XCUIApplication(bundleIdentifier: bundleID)
        let format = query["format"] ?? "json"
        guard RunnerElementTree.formats.contains(format) else { throw RunnerError.invalidField("format") }
        let filter = try query["filter"].map { value in
            guard let filter = RunnerElementTree.Filter(rawValue: value) else {
                throw RunnerError.invalidField("filter: expected interactive")
            }
            return filter
        }
        if format == "text" {
            guard filter == nil else { throw RunnerError.invalidField("filter: applies to format json and compact") }
            return Self.text(application.debugDescription)
        }

        var maxDepth = Int.max
        if let value = query["maxDepth"] {
            guard let depth = RunnerElementTree.maxDepth(value) else { throw RunnerError.invalidField("maxDepth") }
            maxDepth = depth
        }
        let root = try elementTree(application, bundleID: bundleID, maxDepth: maxDepth)
        guard let filter else {
            if format == "compact" {
                return Self.text(RunnerElementTree.compactText(root))
            }
            return .json(["ok": true, "bundleId": bundleID, "tree": RunnerElementTree.json(root)])
        }
        // Filtering runs here, next to the snapshot, so only the short list is serialized and sent.
        let screen = CGRect(origin: .zero, size: self.screen(in: interfaceOrientation()).size)
        let elements = RunnerElementTree.interactiveElements(in: root, screen: screen)
        if format == "compact" {
            return Self.text(RunnerElementTree.compactText(elements))
        }
        return .json(RunnerElementTree.filteredJSON(elements, filter: filter, bundleID: bundleID))
    }

    private static func text(_ text: String) -> RunnerHTTPResponse {
        RunnerHTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func elementTree(_ application: XCUIApplication, bundleID: String, maxDepth: Int = .max) throws -> RunnerElementNode {
        let snapshot: XCUIElementSnapshot
        do {
            snapshot = try application.snapshot()
        } catch {
            throw RunnerError.actionFailed("failed to snapshot \(bundleID): \(error.localizedDescription)")
        }
        return Self.elementNode(snapshot, depth: 0, maxDepth: maxDepth)
    }

    // MARK: - Elements

    /// `/tap` (duration nil) and `/press` at `x`/`y`, or at the element that `element` selects.
    private func touch(_ body: RunnerJSON, duration: TimeInterval?) throws -> RunnerHTTPResponse {
        guard let element = body.object["element"] else {
            let x = try body.double("x"), y = try body.double("y")
            try requireOnScreen([("x, y", x, y)])
            return .json(["ok": true, "mode": try touch(x: x, y: y, duration: duration, mode: touchMode(body)).rawValue])
        }
        guard body.object["x"] == nil, body.object["y"] == nil else {
            throw RunnerError.invalidField("element: pass either x and y or element, not both")
        }
        let selector = try body.elementSelector(element)
        let timeout = try body.elementTimeout()
        let mode = try touchMode(body)
        let bundleID = body.optionalString("bundleId") ?? foregroundApplication().bundleID
        let target = try waitForElements(bundleID: bundleID, timeout: timeout) { root, isLastAttempt in
            let screen = CGRect(origin: .zero, size: self.screen(in: self.interfaceOrientation()).size)
            switch selector.resolve(in: root, screen: screen) {
            case .success(let target):
                return target
            case .failure(let failure):
                guard isLastAttempt || !failure.isRetryable else { return nil }
                throw RunnerError.elementNotResolved(failure)
            }
        }
        let x = Double(target.point.x), y = Double(target.point.y)
        return .json([
            "ok": true,
            "mode": try touch(x: x, y: y, duration: duration, mode: mode).rawValue,
            "bundleId": bundleID,
            "element": target.match.json,
            "point": RunnerElementTree.json(target.point)
        ])
    }

    /// Throws 400 when a point of `/tap`, `/press`, or `/swipe` is outside the screen in the displayed
    /// orientation (`RunnerRequestValues.pointOutsideScreen`), before anything is sent: such a touch reaches
    /// nothing, and answering 200 for it hides the mistake. Element targets need no check, since their point
    /// is already inside the screen. Skipped while the screen size is only UIScreen's guess (SpringBoard's
    /// frame could not be read), which on devices is the 320x480 compatibility size and would reject real points.
    private func requireOnScreen(_ points: [(name: String, x: Double, y: Double)]) throws {
        let orientation = interfaceOrientation()
        let size = screen(in: orientation).size
        guard cachedScreen != nil else { return }
        for point in points {
            if let reason = RunnerRequestValues.pointOutsideScreen(point.name, x: point.x, y: point.y, screen: size,
                                                                    orientation: Self.name(of: orientation)) {
                throw RunnerError.invalidField(reason)
            }
        }
    }

    private func touch(x: Double, y: Double, duration: TimeInterval?, mode: TouchMode) throws -> TouchMode {
        switch mode {
        case .private:
            try synthesizeTouch(points: [(x, y)], offsets: [], liftOffset: duration ?? Self.tapDuration)
        case .xcui:
            if let duration {
                coordinate(x: x, y: y).press(forDuration: duration)
            } else {
                coordinate(x: x, y: y).tap()
            }
        }
        return mode
    }

    /// `/find`: the elements `element` matches, in document order, waiting up to `timeout` for the first.
    private func find(_ body: RunnerJSON) throws -> RunnerHTTPResponse {
        let selector = try body.elementSelector(body.object["element"] ?? NSNull())
        let timeout = try body.elementTimeout()
        guard let limit = RunnerElementLookup.findLimit(body.object["limit"]) else {
            throw RunnerError.invalidField("limit: expected an integer in 1...\(RunnerElementLookup.maxFindLimit)")
        }
        let bundleID = body.optionalString("bundleId") ?? foregroundApplication().bundleID
        let (matches, count) = try waitForElements(bundleID: bundleID, timeout: timeout) { root, isLastAttempt in
            let all = selector.allMatches(in: root)
            let matches = selector.picked(from: all)
            return matches.isEmpty && !isLastAttempt ? nil : (matches, all.count)
        }
        return .json(RunnerElementLookup.findJSON(matches, count: count, limit: limit, bundleID: bundleID))
    }

    /// Snapshots `bundleID` until `attempt` returns a value, every `pollInterval` for up to `timeout`
    /// seconds. `attempt` returns nil to try again; on the last attempt it must return or throw. A failed
    /// snapshot (the app isn't running yet) is retried too. The command keeps the busy gate while it
    /// waits, so other requests get 409 meanwhile.
    private func waitForElements<T>(
        bundleID: String,
        timeout: TimeInterval,
        _ attempt: (RunnerElementNode, _ isLastAttempt: Bool) throws -> T?
    ) throws -> T {
        let application = XCUIApplication(bundleIdentifier: bundleID)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            let isLastAttempt = Date() >= deadline
            let root: RunnerElementNode?
            do {
                root = try elementTree(application, bundleID: bundleID)
            } catch where !isLastAttempt {
                // Usually the app isn't running yet.
                root = nil
            }
            if let root, let result = try attempt(root, isLastAttempt) {
                return result
            }
            let next = min(deadline, Date(timeIntervalSinceNow: RunnerElementLookup.pollInterval))
            while Date() < next {
                _ = RunLoop.current.run(mode: .default, before: next)
            }
        }
    }

    /// Snapshot frames of the foreground app are already in its interface orientation, the same
    /// space as `/tap`, so they are used as is.
    private static func elementNode(_ snapshot: XCUIElementSnapshot, depth: Int, maxDepth: Int) -> RunnerElementNode {
        let children = snapshot.children
        let expand = depth < maxDepth
        return RunnerElementNode(
            type: RunnerElementTree.typeName(rawValue: snapshot.elementType.rawValue),
            identifier: snapshot.identifier,
            label: snapshot.label,
            value: snapshot.value.map { String(describing: $0) },
            placeholder: snapshot.placeholderValue,
            frame: snapshot.frame,
            enabled: snapshot.isEnabled,
            selected: snapshot.isSelected,
            hasFocus: snapshot.hasFocus,
            hasKeyboardFocus: hasKeyboardFocus(snapshot),
            children: expand ? children.map { elementNode($0, depth: depth + 1, maxDepth: maxDepth) } : [],
            truncated: !expand && !children.isEmpty
        )
    }

    private static let hasKeyboardFocusSelector = NSSelectorFromString("hasKeyboardFocus")

    /// `-[XCElementSnapshot hasKeyboardFocus]` is private; the public `hasFocus` is the focus engine's
    /// focus, which a text field being typed into on iPhone does not have.
    private static func hasKeyboardFocus(_ snapshot: XCUIElementSnapshot) -> Bool? {
        guard let object = snapshot as? NSObject, object.responds(to: hasKeyboardFocusSelector) else { return nil }
        return (object.value(forKey: "hasKeyboardFocus") as? NSNumber)?.boolValue
    }

    /// The screen size in points as the foreground app is displayed (landscape swaps width and height).
    private func screen(in orientation: UIInterfaceOrientation) -> (size: CGSize, scale: CGFloat) {
        let screen = portraitScreen()
        guard orientation.isLandscape else { return screen }
        return (CGSize(width: screen.size.height, height: screen.size.width), screen.scale)
    }

    /// The real portrait screen size in points, taken from SpringBoard's frame.
    /// UIScreen can't be trusted: on devices the xctrunner has no launch screen and runs in a 320x480
    /// compatibility mode. The scale is derived from a screenshot so points x scale = screenshot pixels.
    private func portraitScreen() -> (size: CGSize, scale: CGFloat) {
        if let cachedScreen {
            return cachedScreen
        }
        // /health is the readiness probe, so a failed snapshot must not turn it into a 422.
        let (snapshot, failed) = ignoringIssues { () -> (CGRect, CGImage?) in
            let frame = springboard.frame
            return (frame, frame.isEmpty ? nil : XCUIScreen.main.screenshot().image.cgImage)
        }
        let (frame, image) = snapshot
        guard !failed, !frame.isEmpty, let image else {
            return (Self.portrait(UIScreen.main.bounds.size), UIScreen.main.scale)
        }

        let scale = CGFloat(max(image.width, image.height)) / max(frame.width, frame.height)
        // SpringBoard doesn't rotate on iPhone, but it does on iPad, so normalize to portrait.
        let screen = (size: Self.portrait(frame.size), scale: scale)
        cachedScreen = screen
        return screen
    }

    /// The foreground app's interface orientation, which touches and screenshots follow. It is read on
    /// every request because it changes without `/orientation`: the device can be turned by hand, the
    /// home screen stays portrait on a landscape iPhone, and iPhone apps ignore portraitUpsideDown.
    ///
    /// `-[XCUIApplication interfaceOrientation]` is private, but it is cheap (about 1 ms; testmanagerd
    /// pushes updates) and reports the active app's orientation even when asked through SpringBoard.
    /// Without it, fall back to the screenshot's image orientation (about 90 ms).
    private func interfaceOrientation() -> UIInterfaceOrientation {
        let (raw, failed) = ignoringIssues { () -> Int? in
            guard springboard.responds(to: NSSelectorFromString("interfaceOrientation")) else { return nil }
            return (springboard.value(forKey: "interfaceOrientation") as? NSNumber)?.intValue
        }
        if !failed, let raw, let orientation = UIInterfaceOrientation(rawValue: raw), orientation != .unknown {
            return orientation
        }
        let (imageOrientation, _) = ignoringIssues { XCUIScreen.main.screenshot().image.imageOrientation }
        switch imageOrientation {
        case .down: return .portraitUpsideDown
        case .left: return .landscapeRight
        case .right: return .landscapeLeft
        default: return .portrait
        }
    }

    private func screenshot(query: [String: String]) throws -> RunnerHTTPResponse {
        let format = query["format"] ?? "png"
        var quality: Double?
        switch format {
        case "png":
            guard query["quality"] == nil else { throw RunnerError.invalidField("quality") }
        case "jpeg", "jpg":
            guard let value = RunnerRequestValues.jpegQuality(query["quality"]) else {
                throw RunnerError.invalidField("quality")
            }
            quality = value
        default:
            throw RunnerError.invalidField("format")
        }
        let maxSize = try query["maxSize"].map { value in
            guard let size = RunnerRequestValues.screenshotMaxSize(value) else {
                throw RunnerError.invalidField("maxSize: expected an integer of at least \(RunnerRequestValues.minScreenshotMaxSize)")
            }
            return size
        }
        let scale = try query["scale"].map { value in
            guard let scale = RunnerRequestValues.screenshotScale(value) else {
                let range = RunnerRequestValues.screenshotScaleRange
                throw RunnerError.invalidField("scale: expected a number in \(range.lowerBound)...\(range.upperBound)")
            }
            return scale
        }

        let screenshot = XCUIScreen.main.screenshot()
        // The pixels are always portrait, with the rotation only in the image orientation. Redraw them
        // upright so pixel coordinates are points x scale in the displayed orientation. Shrinking happens
        // in the same draw: one pass over the full-size pixels, and the encoder sees only the small image.
        let image = screenshot.image
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let screen = portraitScreen()
        let size = RunnerRequestValues.screenshotSize(pixels: pixels, screenScale: screen.scale, maxSize: maxSize, scale: scale)
        let renderer = image.imageOrientation == .up && size == pixels ? nil : Self.renderer(size: size)
        let draw: (UIGraphicsImageRendererContext) -> Void = { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let points = pixels.width > pixels.height
            ? CGSize(width: screen.size.height, height: screen.size.width)
            : screen.size
        let headers = RunnerRequestValues.screenshotHeaders(image: size, screen: points)
        if let quality {
            let data = renderer.map { $0.jpegData(withCompressionQuality: quality, actions: draw) }
                ?? image.jpegData(compressionQuality: quality)
            guard let data else {
                throw RunnerError.internalError("failed to encode JPEG")
            }
            return RunnerHTTPResponse(status: 200, contentType: "image/jpeg", body: data, headers: headers)
        }
        let data = renderer?.pngData(actions: draw) ?? screenshot.pngRepresentation
        return RunnerHTTPResponse(status: 200, contentType: "image/png", body: data, headers: headers)
    }

    /// Draws `size` pixels (scale 1, so points are pixels); 8-bit sRGB even on wide-color devices.
    private static func renderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private func swipe(_ body: RunnerJSON, mode: TouchMode) throws -> TouchMode {
        let from = try body.point("from")
        let to = try body.point("to")
        let duration = try body.positiveDouble("duration", default: 0.3)
        let hold = try body.nonNegativeDouble("hold", default: 0.05)
        try requireOnScreen([("from", from.x, from.y), ("to", to.x, to.y)])
        if mode == .private {
            // Down at `from`, rest for `hold`, move to `to` over `duration`, lift immediately.
            try synthesizeTouch(
                points: [from, from, to],
                offsets: [hold, hold + duration],
                liftOffset: hold + duration
            )
            return .private
        }
        let distance = hypot(to.x - from.x, to.y - from.y)
        let velocity = XCUIGestureVelocity(rawValue: max(distance / duration, 1))
        coordinate(x: from.x, y: from.y).press(
            forDuration: hold,
            thenDragTo: coordinate(x: to.x, y: to.y),
            withVelocity: velocity,
            thenHoldForDuration: 0
        )
        return .xcui
    }

    // MARK: - Touch synthesis

    enum TouchMode: String {
        /// XCTest's private event synthesizer: no wait for the app to become idle.
        case `private`
        /// Public `XCUICoordinate` gestures, which wait for quiescence before and after.
        case xcui
    }

    /// How long a synthesized tap keeps the finger down.
    private static let tapDuration: TimeInterval = 0.05

    /// `"mode"` in the body forces a path; when omitted, the private path is used if available.
    private func touchMode(_ body: RunnerJSON) throws -> TouchMode {
        switch body.optionalString("mode") {
        case nil, "auto":
            return RelayTouchSynthesizer.isAvailable ? .private : .xcui
        case "xcui":
            return .xcui
        case "private":
            if let reason = RelayTouchSynthesizer.unavailableReason {
                throw RunnerError.invalidField("mode: private touch synthesis is unavailable (\(reason))")
            }
            return .private
        default:
            throw RunnerError.invalidField("mode: expected private, xcui, or auto")
        }
    }

    /// Sends one synthesized touch and waits for its completion before returning.
    ///
    /// This runs on the main queue, and the synthesizer may call back on the main queue, so wait by
    /// spinning the run loop instead of blocking (a semaphore here would deadlock).
    private func synthesizeTouch(
        points: [(x: Double, y: Double)],
        offsets: [TimeInterval],
        liftOffset: TimeInterval
    ) throws {
        let orientation = interfaceOrientation()
        let portraitSize = portraitScreen().size
        let completion = TouchCompletion()
        do {
            try RelayTouchSynthesizer.synthesizeTouch(
                withPoints: points.map {
                    NSValue(cgPoint: Self.portraitPoint(CGPoint(x: $0.x, y: $0.y), from: orientation, portraitSize: portraitSize))
                },
                offsets: offsets.map { NSNumber(value: $0) },
                liftOffset: liftOffset,
                interfaceOrientation: .portrait,
                completion: { completion.finish($0) }
            )
        } catch {
            throw RunnerError.internalError("touch synthesis failed: \(error.localizedDescription)")
        }

        let deadline = Date(timeIntervalSinceNow: liftOffset + 10)
        while !completion.isFinished {
            guard Date() < deadline else {
                throw RunnerError.touchFailed("touch synthesis did not complete within \(Int(liftOffset + 10))s")
            }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        if let error = completion.error {
            throw RunnerError.touchFailed("touch synthesis failed: \(error.localizedDescription)")
        }
    }

    /// Converts a point in the displayed orientation to the screen's native portrait space.
    ///
    /// The synthesizer takes native portrait points: the record's interface orientation is not applied
    /// to them (a landscape point passed with `.landscapeRight` lands somewhere else), so rotate here
    /// and always pass `.portrait`.
    private static func portraitPoint(_ point: CGPoint, from orientation: UIInterfaceOrientation, portraitSize size: CGSize) -> CGPoint {
        switch orientation {
        case .portraitUpsideDown: return CGPoint(x: size.width - point.x, y: size.height - point.y)
        // The top of the interface is the right edge of the portrait screen.
        case .landscapeRight: return CGPoint(x: size.width - point.y, y: point.x)
        // The top of the interface is the left edge of the portrait screen.
        case .landscapeLeft: return CGPoint(x: point.y, y: size.height - point.x)
        default: return point
        }
    }

    private func pressButton(_ name: String) throws {
        switch name {
        case "home":
            #if targetEnvironment(simulator)
            XCUIDevice.shared.press(.home)
            #else
            try swipeHome()
            #endif
        #if !targetEnvironment(simulator)
        case "volumeUp", "volume-up":
            XCUIDevice.shared.press(.volumeUp)
        case "volumeDown", "volume-down":
            XCUIDevice.shared.press(.volumeDown)
        #endif
        default:
            throw RunnerError.invalidField("name: unsupported button '\(name)'")
        }
    }

    /// Goes home with the home-indicator gesture: a quick swipe up from the bottom edge.
    ///
    /// On devices `XCUIDevice.press(.home)` reports success but does nothing (seen on iOS 26.7.1 with
    /// Xcode 27): testmanagerd logs "Failed to load displays from CADisplay" and sends the button from a
    /// keyboard that isn't tied to the display, which SpringBoard ignores. This assumes a device without
    /// a home button, where the same swipe would open Control Center instead.
    private func swipeHome() throws {
        let size = screen(in: interfaceOrientation()).size
        let from = (x: Double(size.width / 2), y: Double(size.height - 3))
        if RelayTouchSynthesizer.isAvailable {
            let to = (x: from.x, y: Double(size.height * 0.6))
            let duration = 0.12
            // Same shape as a private /swipe with hold 0: the extra move at `from` makes the synthesizer
            // interpolate the drag; a lone move from the touch-down point arrives as a single jump.
            try synthesizeTouch(points: [from, from, to], offsets: [0, duration], liftOffset: duration)
        } else {
            // XCUI drags only go home with a short press first; with forDuration 0 nothing happens.
            let to = (x: from.x, y: Double(size.height * 0.5))
            let duration = 0.2
            coordinate(x: from.x, y: from.y).press(
                forDuration: 0.02,
                thenDragTo: coordinate(x: to.x, y: to.y),
                withVelocity: XCUIGestureVelocity(rawValue: (from.y - to.y) / duration),
                thenHoldForDuration: 0
            )
        }
    }

    private func orientation(_ name: String) throws -> UIDeviceOrientation {
        switch name {
        case "portrait": return .portrait
        case "portraitUpsideDown": return .portraitUpsideDown
        case "landscapeLeft": return .landscapeLeft
        case "landscapeRight": return .landscapeRight
        default: throw RunnerError.invalidField("orientation")
        }
    }

    /// The `/orientation` name of the device orientation that shows this interface orientation, so
    /// `/health` reports `landscapeLeft` after `/orientation landscapeLeft`. The landscape cases are
    /// mirrored because UIKit names device orientations by the home button and interface ones by the top.
    private static func name(of orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeRight: return "landscapeLeft"
        case .landscapeLeft: return "landscapeRight"
        default: return "portrait"
        }
    }

    private static func portrait(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
    }

    /// Runs `body` and drops the XCUI issues it records, reporting only whether any were recorded.
    private func ignoringIssues<T>(_ body: () -> T) -> (T, failed: Bool) {
        let issueCount = capturedIssues?.count ?? 0
        let result = body()
        let failed = (capturedIssues?.count ?? 0) > issueCount
        if failed {
            capturedIssues?.removeSubrange(issueCount...)
        }
        return (result, failed)
    }

    /// Screen coordinates in points from the top-left corner in the displayed orientation. SpringBoard's
    /// frame stays portrait, but XCTest converts the point with the active interface orientation.
    private func coordinate(x: Double, y: Double) -> XCUICoordinate {
        springboard
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x, dy: y))
    }

    private func ok() -> RunnerHTTPResponse {
        .json(["ok": true])
    }

    private func ok(mode: TouchMode) -> RunnerHTTPResponse {
        .json(["ok": true, "mode": mode.rawValue])
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }

    /// XCTest's default wait for an app to reach a requested state, which `/launch` and `/terminate` use.
    private static let defaultApplicationStateTimeout: Double = 60

    /// The scheme passes `-XCUIApplicationStateTimeout 120` because XCTest waits that long, before any test
    /// runs, for testmanagerd to enable automation mode, and a device may wait for its passcode before it does.
    /// Once that is done, put the timeout back so a hung app launch doesn't hold a command for two minutes.
    /// `_XCTSetApplicationStateTimeout` is private (XCUIAutomation.framework); without it, keep the longer one.
    private static func restoreApplicationStateTimeout() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_XCTSetApplicationStateTimeout") else { return }
        typealias SetTimeout = @convention(c) (Double) -> Void
        unsafeBitCast(symbol, to: SetTimeout.self)(defaultApplicationStateTimeout)
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case invalidJSON
    case missingField(String)
    case invalidField(String)
    case notFound
    case methodNotAllowed
    case internalError(String)
    case touchFailed(String)
    case actionFailed(String)
    /// A selector that didn't lead to one touchable element; answered with the failure's JSON.
    case elementNotResolved(RunnerElementLookupFailure)

    var description: String {
        switch self {
        case .invalidJSON: return "request body must be a JSON object"
        case .missingField(let name): return "missing required field: \(name)"
        case .invalidField(let name): return "invalid field: \(name)"
        case .notFound: return "not found"
        case .methodNotAllowed: return "method not allowed"
        case .internalError(let message), .touchFailed(let message), .actionFailed(let message): return message
        case .elementNotResolved(let failure): return failure.message
        }
    }

    var status: Int {
        switch self {
        case .invalidJSON, .missingField, .invalidField: return 400
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .internalError: return 500
        case .touchFailed, .actionFailed, .elementNotResolved: return 422
        }
    }
}

/// Completion state shared with the synthesizer callback, which may arrive on any thread.
private final class TouchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var storedError: Error?

    var isFinished: Bool { lock.withLock { finished } }
    var error: Error? { lock.withLock { storedError } }

    func finish(_ error: Error?) {
        lock.withLock {
            storedError = error
            finished = true
        }
    }
}

struct RunnerJSON {
    let object: [String: Any]

    init(_ data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RunnerError.invalidJSON
        }
        self.object = object
    }

    private init(object: [String: Any]) {
        self.object = object
    }

    func double(_ name: String) throws -> Double {
        guard let value = object[name] else { throw RunnerError.missingField(name) }
        guard let number = RunnerRequestValues.number(value), number.isFinite, number >= 0 else {
            throw RunnerError.invalidField(name)
        }
        return number
    }

    func positiveDouble(_ name: String, default defaultValue: Double) throws -> Double {
        guard object[name] != nil else { return defaultValue }
        let value = try double(name)
        guard value > 0 else { throw RunnerError.invalidField(name) }
        return value
    }

    func nonNegativeDouble(_ name: String, default defaultValue: Double) throws -> Double {
        guard object[name] != nil else { return defaultValue }
        return try double(name)
    }

    func string(_ name: String) throws -> String {
        guard let value = optionalString(name) else { throw RunnerError.missingField(name) }
        return value
    }

    func optionalString(_ name: String) -> String? {
        guard let value = object[name] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// The optional `keys` array of key names; empty when absent.
    func keys() throws -> [RunnerKey] {
        guard let value = object["keys"] else { return [] }
        do {
            return try RunnerKey.parse(value)
        } catch let error as RunnerKeyError {
            throw RunnerError.invalidField(error.description)
        }
    }

    /// The `text` of `/type`; see `RunnerTyping.text(_:keyCount:)`.
    func typedText(keyCount: Int) throws -> String {
        do {
            return try RunnerTyping.text(object["text"], keyCount: keyCount)
        } catch RunnerTextError.missing {
            throw RunnerError.missingField("text")
        } catch RunnerTextError.notAString {
            throw RunnerError.invalidField("text")
        }
    }

    /// The `element` selector of `/tap`, `/press`, and `/find`.
    func elementSelector(_ value: Any) throws -> RunnerElementSelector {
        guard !(value is NSNull) else { throw RunnerError.missingField("element") }
        do {
            return try RunnerElementSelector(json: value)
        } catch let error as RunnerElementSelectorError {
            throw RunnerError.invalidField(error.description)
        }
    }

    /// The optional `timeout` (seconds) to wait for an element; see `RunnerElementLookup.timeout(_:)`.
    func elementTimeout() throws -> TimeInterval {
        guard let timeout = RunnerElementLookup.timeout(object["timeout"]) else {
            throw RunnerError.invalidField("timeout: expected seconds in 0...\(Int(RunnerElementLookup.maxTimeout))")
        }
        return timeout
    }

    func point(_ name: String) throws -> (x: Double, y: Double) {
        guard let nested = object[name] as? [String: Any] else { throw RunnerError.missingField(name) }
        let point = RunnerJSON(object: nested)
        return (try point.double("x"), try point.double("y"))
    }
}

enum NetworkAddresses {
    struct Entry {
        let interface: String
        let address: String
    }

    /// Non-loopback IPv4/IPv6 addresses, so the host can find a reachable URL.
    static func current() -> [Entry] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var entries: [Entry] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // Link-local IPv6 needs a scope id and is rarely routable from the host.
            if text.hasPrefix("fe80:") { continue }
            entries.append(Entry(interface: String(cString: interface.pointee.ifa_name), address: text))
        }
        return entries
    }
}
