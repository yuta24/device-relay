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

    private lazy var springboard = XCUIApplication(bundleIdentifier: Self.springboardBundleID)

    func testRunServer() throws {
        continueAfterFailure = true

        let environment = ProcessInfo.processInfo.environment
        let port = UInt16(environment["RELAY_RUNNER_PORT"] ?? "") ?? 8100

        let server = try RunnerHTTPServer(port: port) { [weak self] request, respond in
            DispatchQueue.main.async {
                guard let self else {
                    respond(.error("runner is shutting down", status: 500))
                    return
                }
                respond(self.handle(request))
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

    private func route(_ request: RunnerHTTPRequest) throws -> RunnerHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(health())
        case ("GET", "/screenshot"):
            return try screenshot(query: request.query)
        case ("GET", "/source"):
            let bundleID = request.query["bundleId"] ?? lastActivatedBundleID ?? Self.springboardBundleID
            let source = XCUIApplication(bundleIdentifier: bundleID).debugDescription
            return RunnerHTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(source.utf8))
        case ("POST", "/tap"):
            let body = try RunnerJSON(request.body)
            let x = try body.double("x"), y = try body.double("y")
            switch try touchMode(body) {
            case .private:
                try synthesizeTouch(points: [(x, y)], offsets: [], liftOffset: Self.tapDuration)
                return ok(mode: .private)
            case .xcui:
                coordinate(x: x, y: y).tap()
                return ok(mode: .xcui)
            }
        case ("POST", "/press"):
            let body = try RunnerJSON(request.body)
            let duration = try body.positiveDouble("duration", default: 1.0)
            let x = try body.double("x"), y = try body.double("y")
            switch try touchMode(body) {
            case .private:
                try synthesizeTouch(points: [(x, y)], offsets: [], liftOffset: duration)
                return ok(mode: .private)
            case .xcui:
                coordinate(x: x, y: y).press(forDuration: duration)
                return ok(mode: .xcui)
            }
        case ("POST", "/swipe"):
            let body = try RunnerJSON(request.body)
            return ok(mode: try swipe(body, mode: touchMode(body)))
        case ("POST", "/type"):
            let body = try RunnerJSON(request.body)
            let text = try body.string("text")
            let bundleID = body.optionalString("bundleId") ?? lastActivatedBundleID ?? Self.springboardBundleID
            XCUIApplication(bundleIdentifier: bundleID).typeText(text)
            return ok()
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
        case ("POST", "/shutdown"):
            shouldStop = true
            return ok()
        case (_, "/health"), (_, "/screenshot"), (_, "/source"), (_, "/tap"), (_, "/press"), (_, "/swipe"),
             (_, "/type"), (_, "/button"), (_, "/orientation"), (_, "/launch"), (_, "/terminate"), (_, "/shutdown"):
            throw RunnerError.methodNotAllowed
        default:
            throw RunnerError.notFound
        }
    }

    // MARK: - Commands

    private func health() -> [String: Any] {
        let screen = UIScreen.main
        return [
            "ok": true,
            "device": [
                "model": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion,
                "simulator": Self.isSimulator
            ],
            "screen": [
                "width": screen.bounds.width,
                "height": screen.bounds.height,
                "scale": screen.scale
            ],
            "coordinateSpace": "points",
            "touchSynthesis": (RelayTouchSynthesizer.isAvailable ? TouchMode.private : .xcui).rawValue
        ]
    }

    private func screenshot(query: [String: String]) throws -> RunnerHTTPResponse {
        let screenshot = XCUIScreen.main.screenshot()
        switch query["format"] ?? "png" {
        case "png":
            return RunnerHTTPResponse(status: 200, contentType: "image/png", body: screenshot.pngRepresentation)
        case "jpeg", "jpg":
            let quality = Double(query["quality"] ?? "") ?? 0.7
            guard let data = screenshot.image.jpegData(compressionQuality: min(max(quality, 0.05), 1.0)) else {
                throw RunnerError.internalError("failed to encode JPEG")
            }
            return RunnerHTTPResponse(status: 200, contentType: "image/jpeg", body: data)
        default:
            throw RunnerError.invalidField("format")
        }
    }

    private func swipe(_ body: RunnerJSON, mode: TouchMode) throws -> TouchMode {
        let from = try body.point("from")
        let to = try body.point("to")
        let duration = try body.positiveDouble("duration", default: 0.3)
        let hold = try body.nonNegativeDouble("hold", default: 0.05)
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
        let completion = TouchCompletion()
        do {
            try RelayTouchSynthesizer.synthesizeTouch(
                withPoints: points.map { NSValue(cgPoint: CGPoint(x: $0.x, y: $0.y)) },
                offsets: offsets.map { NSNumber(value: $0) },
                liftOffset: liftOffset,
                interfaceOrientation: Self.interfaceOrientation,
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

    /// The interface orientation matching the current device orientation (portrait when flat or unknown).
    private static var interfaceOrientation: UIInterfaceOrientation {
        switch XCUIDevice.shared.orientation {
        case .portraitUpsideDown: return .portraitUpsideDown
        // Device and interface landscape orientations are mirrored.
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return .portrait
        }
    }

    private func pressButton(_ name: String) throws {
        switch name {
        case "home":
            XCUIDevice.shared.press(.home)
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

    private func orientation(_ name: String) throws -> UIDeviceOrientation {
        switch name {
        case "portrait": return .portrait
        case "portraitUpsideDown": return .portraitUpsideDown
        case "landscapeLeft": return .landscapeLeft
        case "landscapeRight": return .landscapeRight
        default: throw RunnerError.invalidField("orientation")
        }
    }

    /// Screen coordinates in points, measured from the top-left corner of SpringBoard's frame.
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
}

enum RunnerError: Error, CustomStringConvertible {
    case invalidJSON
    case missingField(String)
    case invalidField(String)
    case notFound
    case methodNotAllowed
    case internalError(String)
    case touchFailed(String)

    var description: String {
        switch self {
        case .invalidJSON: return "request body must be a JSON object"
        case .missingField(let name): return "missing required field: \(name)"
        case .invalidField(let name): return "invalid field: \(name)"
        case .notFound: return "not found"
        case .methodNotAllowed: return "method not allowed"
        case .internalError(let message), .touchFailed(let message): return message
        }
    }

    var status: Int {
        switch self {
        case .invalidJSON, .missingField, .invalidField: return 400
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .internalError: return 500
        case .touchFailed: return 422
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
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else {
            throw RunnerError.invalidField(name)
        }
        return number.doubleValue
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
