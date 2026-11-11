import UIKit
import XCTest

/// A long-running "test" that serves device-control commands over HTTP until `/shutdown` is called.
///
/// HTTP is handled on a background queue, and every XCUI call is dispatched to the main queue.
/// The main queue is drained serially, so commands never run concurrently.
final class RelayRunnerUITests: XCTestCase {
  static let readyMarker = "RELAY_RUNNER_READY"
  /// The address the server binds to, or nil for every interface. A simulator shares the Mac's network, so
  /// listening everywhere would open the runner to the Mac's LAN; relay reaches it at 127.0.0.1 only.
  /// A device listens everywhere: relay reaches it over the CoreDevice tunnel, or Wi-Fi with --allow-wifi.
  #if targetEnvironment(simulator)
    private static let listenHost: String? = "127.0.0.1"
  #else
    private static let listenHost: String? = nil
  #endif
  private static let springboardBundleID = "com.apple.springboard"

  private var shouldStop = false
  private var capturedIssues: [String]?
  private var lastActivatedBundleID: String?
  /// Portrait size and scale; they don't change with rotation, so they are measured once.
  private var cachedScreen: (size: CGSize, scale: CGFloat)?
  /// Every display of the device, measured once like `cachedScreen` (they don't change).
  private var cachedDisplays: [RunnerDisplay]?
  /// The display the running command acts on, looked up once per command; `handle` clears it.
  private var commandDisplay: DisplayLookup?
  /// Where the app's window is, from the command's latest element tree on iPad; nil when nothing was looked up.
  private var commandWindow: RunnerWindowLookup?
  /// Why elements of the command's latest element tree inside the share sheet could not be placed on the screen
  /// (`RunnerRemoteViews`); empty when they all were.
  private var commandRemoteViews: [String] = []
  private var commandSnapshot: XCUIElementSnapshot?

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
    let server = try RunnerHTTPServer(port: port, host: Self.listenHost, tokenHash: tokenHash) { [weak self] request, respond in
      if request.path == "/ping" {
        // The liveness check: answered here, so it never takes the gate from a command and never
        // waits for the main queue. Not logged, because relay sends it every few seconds.
        var body = gate.pingBody()
        body["runner"] = Self.buildVersion
        respond(request.method == "GET" ? .json(body) : .error(RunnerError.methodNotAllowed))
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
        respond(.error(.busy, "busy", status: 409))
        return
      }
      DispatchQueue.main.async {
        let response = self?.handle(request) ?? .error(.internalError, "runner is shutting down", status: 500)
        // Leave before responding so a client that sends its next request right after the
        // response never sees a stale busy state.
        gate.leave()
        respond(response)
      }
    }

    var startupError: Error?
    server.start(
      onReady: {
        let addresses = Self.listenHost.map { ["lo0=\($0)"] }
          ?? NetworkAddresses.current().map { "\($0.interface)=\($0.address)" }
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
    commandDisplay = nil
    commandWindow = nil
    commandRemoteViews = []
    commandSnapshot = nil
    defer {
      capturedIssues = nil
      commandDisplay = nil
      commandWindow = nil
      commandRemoteViews = []
      commandSnapshot = nil
    }

    var response: RunnerHTTPResponse
    do {
      response = try route(request)
    } catch let error as RunnerError {
      response = .error(error)
    } catch {
      response = .error(.internalError, String(describing: error), status: 500)
    }
    if let issues = capturedIssues, !issues.isEmpty {
      response = .error(.xcuiFailed, issues.joined(separator: "; "), status: 422)
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
    var object: [String: Any] = [
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
      "touchSynthesis": (privateTouchIsDefault ? TouchMode.private : .xcui).rawValue,
      "typeSynthesis": (privateTypingIsDefault ? TouchMode.private : .xcui).rawValue,
      "foreground": foregroundApplication().json,
      "runner": Self.buildVersion
    ]
    // `screen` is the display the foreground app is on; `display` names it (null when that can't be told on a
    // device with more than one, where `screen` falls back to the main display and touches answer 422).
    let displays = self.displays()
    if !displays.isEmpty {
      object["displays"] = displays.map(\.json)
      switch appDisplay() {
      case .single: object["display"] = displays[0].id
      case .found(let display): object["display"] = display.id
      case .unknown: object["display"] = NSNull()
      }
    }
    return object
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
  /// switch, when both apps are listed with the new one first, and on iPad with windowed apps, when
  /// every app on screen and SpringBoard are listed with the focused one first, so the first is used
  /// (`RunnerWindows.foregroundIndex` leaves out the Dock's folder service). Without it, fall back to
  /// the last `/launch`ed app if the public `state` still says it is in the foreground, and to
  /// SpringBoard otherwise.
  private func foregroundApplication() -> ForegroundApplication {
    if let applications = activeApplications(),
       let index = RunnerWindows.foregroundIndex(activeBundleIDs: applications.map(\.bundleIdentifier)) {
      let active = applications[index]
      return ForegroundApplication(bundleID: active.bundleIdentifier, pid: active.processIdentifier, source: .private)
    }
    if let bundleID = lastActivatedBundleID {
      let (state, failed) = ignoringIssues { XCUIApplication(bundleIdentifier: bundleID).state }
      if !failed, state == .runningForeground {
        return ForegroundApplication(bundleID: bundleID, pid: nil, source: .fallback)
      }
    }
    return ForegroundApplication(bundleID: Self.springboardBundleID, pid: nil, source: .fallback)
  }

  /// The active applications, or nil when they can't be read. /health needs them too, so a failed lookup
  /// must not turn into a 422.
  private func activeApplications() -> [RelayActiveApplicationInfo]? {
    guard RelayActiveApplication.isAvailable else { return nil }
    let (applications, failed) = ignoringIssues { try? RelayActiveApplication.activeApplications() }
    return failed ? nil : applications
  }

  // MARK: - Keyboard

  /// Types `text`, then each of `keys`, into the focused element of `bundleID`.
  ///
  /// Keys go after the text as their `XCUIKeyboardKey` characters (return is "\r", delete is
  /// U+007F). `typeKey(_:modifierFlags:)` sends hardware key events instead, but on iPhone (simulator
  /// and device) only space and tab arrived that way; return, delete, and escape were dropped.
  ///
  /// The text goes through XCTest's private event synthesizer when it is available (`RelayTextSynthesizer`):
  /// `typeText` waits for the app to idle before and after typing: for an app that never idles, 60 s each
  /// way with a pause (a spindump, it seems) in between, while the client gave up long before. On a device with more than one
  /// display, `typeText` is kept, since synthesized text has not been tried there.
  private func type(text: String, keys: [RunnerKey], bundleID: String) throws {
    let application = XCUIApplication(bundleIdentifier: bundleID)
    let typed = text + keys.map { Self.keyboardKey($0).rawValue }.joined()
    if privateTypingIsDefault {
      try requireKeyboardFocus(application, bundleID: bundleID)
      try synthesizeText(typed, within: RunnerTyping.wait(text: text, keyCount: keys.count) + RunnerTyping.synthesisGrace)
      return
    }
    let issueCount = capturedIssues?.count ?? 0
    application.typeText(typed)
    // typeText fails with a long XCUI message that dumps the element tree; say what went wrong instead.
    if let issues = capturedIssues, issues.count > issueCount,
       issues[issueCount...].contains(where: RunnerTyping.isMissingKeyboardFocus) {
      capturedIssues?.removeSubrange(issueCount...)
      throw RunnerError.noKeyboardFocus(bundleID: bundleID)
    }
  }

  /// Whether `/type` and `/key` synthesize the text (`/health`'s `typeSynthesis`); see `type(text:keys:bundleID:)`.
  /// The focus check needs the private `hasKeyboardFocus` attribute: without it every query would match
  /// nothing, so `typeText`, which checks focus itself, is kept.
  private var privateTypingIsDefault: Bool {
    RelayTextSynthesizer.isAvailable && Self.snapshotsHaveKeyboardFocus && displays().count <= 1
  }

  private static let snapshotsHaveKeyboardFocus =
    NSClassFromString("XCElementSnapshot")?.instancesRespond(to: hasKeyboardFocusSelector) == true

  /// Throws `noKeyboardFocus` unless an element of `application` has keyboard focus, the check `typeText`
  /// makes (its query, `hasKeyboardFocus == 1`), done here because synthesized text skips it.
  ///
  /// `typeText` waited for the app to idle before checking, which gave a field just tapped time to take focus;
  /// this looks again for up to `focusWait` instead.
  private func requireKeyboardFocus(_ application: XCUIApplication, bundleID: String) throws {
    let query = application.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == 1"))
    let deadline = Date(timeIntervalSinceNow: Self.focusWait)
    while true {
      let issueCount = capturedIssues?.count ?? 0
      let count = query.count
      switch RunnerTyping.focusCheck(matchCount: count, queryFailed: (capturedIssues?.count ?? 0) > issueCount) {
      case .focused:
        return
      case .queryFailed:
        // Nothing is typed: the text would go to whatever has focus, another app's field even. The recorded
        // issue stays, so the answer is xcui_failed with XCUI's message, as with typeText.
        throw RunnerError.actionFailed("failed to look up keyboard focus in \(bundleID); nothing was typed")
      case .notFocused:
        break
      }
      guard Date() < deadline else { throw RunnerError.noKeyboardFocus(bundleID: bundleID) }
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
  }

  /// How long `requireKeyboardFocus` looks for focus.
  private static let focusWait: TimeInterval = 1

  /// Types `text` with the private synthesizer and waits for it, up to `seconds`, the same way
  /// `synthesizeTouch` waits for a touch (spinning the run loop, since the callback may come on the main queue).
  /// Past `seconds` the runner answers instead of staying busy; XCTest may still be typing the rest.
  private func synthesizeText(_ text: String, within seconds: TimeInterval) throws {
    let completion = TouchCompletion()
    do {
      try RelayTextSynthesizer.synthesizeText(text, typingSpeed: UInt(RunnerTyping.typingSpeed)) { completion.finish($0) }
    } catch {
      throw RunnerError.typingFailed("text synthesis failed: \(error.localizedDescription); nothing was typed", status: 500)
    }
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !completion.isFinished {
      guard Date() < deadline else {
        throw RunnerError.typingFailed(RunnerTyping.synthesisTimeoutMessage(seconds: seconds), status: 422)
      }
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    if let error = completion.error {
      throw RunnerError.typingFailed("text synthesis failed: \(error.localizedDescription)", status: 422)
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
    let warning = RunnerWindows.compactWarning(lookup: commandWindow)
      + RunnerRemoteViews.compactWarning(unknown: commandRemoteViews)
    guard let filter else {
      if format == "compact" {
        return Self.text(warning + RunnerElementTree.compactText(root))
      }
      return annotated(["ok": true, "bundleId": bundleID, "tree": RunnerElementTree.json(root)])
    }
    // Filtering runs here, next to the snapshot, so only the short list is serialized and sent.
    let screen = CGRect(origin: .zero, size: self.screen(in: interfaceOrientation()).size)
    // Where hit testing isn't checked (iPad windows, several displays), a candidate under a later control's
    // frame is dropped by the frames alone, as before hit testing was added.
    var verifyHit: ([Int], CGPoint) -> Bool? = { _, _ in false }
    if canVerifyCommandHit {
      verifyHit = { path, point in
        guard let hitPath = self.hitPath(at: point),
              RunnerElementTree.hitControl(at: point, path: hitPath, in: root) != nil else { return nil }
        return RunnerElementTree.isRelatedHit(hitPath, to: path)
      }
    }
    let elements = RunnerElementTree.interactiveElements(in: root, screen: screen, verifyHit: verifyHit)
    if format == "compact" {
      return Self.text(warning + RunnerElementTree.compactText(elements))
    }
    return annotated(RunnerElementTree.filteredJSON(elements, filter: filter, bundleID: bundleID))
  }

  /// `body` with what it should say about the app's window (`RunnerWindows.annotate`) and the share sheet
  /// (`RunnerRemoteViews.annotate`).
  private func annotated(_ body: [String: Any]) -> RunnerHTTPResponse {
    var body = body
    RunnerWindows.annotate(&body, lookup: commandWindow)
    RunnerRemoteViews.annotate(&body, unknown: commandRemoteViews)
    return .json(body)
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
    commandSnapshot = snapshot
    // The share sheet's elements are placed in the app's space first, so that an iPad window or another display
    // converts them with the rest.
    let (root, unknownRemoteViews) = RunnerRemoteViews.placed(Self.elementNode(snapshot, depth: 0, maxDepth: maxDepth))
    commandRemoteViews = unknownRemoteViews
    let displays = self.displays()
    guard displays.count > 1 else { return onScreen(root, bundleID: bundleID) }
    // The windows' display IDs say where the app is, so a command that snapshots needs no second snapshot
    // to look its display up. SpringBoard has windows on every display, so it is looked up by `appDisplay`.
    let windowDisplayIDs = snapshot.children.map(Self.displayID(of:))
    if commandDisplay == nil, bundleID != Self.springboardBundleID,
       let display = RunnerDisplays.windowDisplay(windowDisplayIDs, in: displays) {
      commandDisplay = .found(display)
    }
    guard case .found(let display) = appDisplay() else { return root }
    return RunnerDisplays.tree(root, windowDisplayIDs: windowDisplayIDs, display: display,
                               orientation: Self.runnerOrientation(interfaceOrientation()))
  }

  // MARK: - Windows

  /// On iPad, `root` (in the coordinates of the app's window) in screen coordinates, and `commandWindow`
  /// says how. Other devices have no windows and pay for nothing here.
  private func onScreen(_ root: RunnerElementNode, bundleID: String) -> RunnerElementNode {
    commandWindow = nil
    guard Self.isPad, bundleID != Self.springboardBundleID else { return root }
    let orientation = interfaceOrientation()
    let runnerOrientation = Self.runnerOrientation(orientation)
    let screen = self.screen(in: orientation).size
    let portraitSize = displayScreen().size
    let active = activeApplications()?.map(\.bundleIdentifier)
    guard RunnerWindows.mayBeWindowed(appFrame: root.frame, screen: screen, activeBundleIDs: active) else {
      return RunnerWindows.fullScreenTree(root, orientation: runnerOrientation, portraitSize: portraitSize)
    }
    let lookup = RunnerWindows.lookup(bundleID: bundleID, appFrame: root.frame,
                                      cards: windowCards(of: bundleID, orientation: orientation), screen: screen)
    commandWindow = lookup
    switch lookup {
    case .placed(let placement):
      return placement.onScreen(root: root, screen: screen, orientation: runnerOrientation, portraitSize: portraitSize)
    case .fullScreen:
      return RunnerWindows.fullScreenTree(root, orientation: runnerOrientation, portraitSize: portraitSize)
    case .unknown:
      return root
    }
  }

  /// The frames in the displayed orientation of the app's windows in SpringBoard's tree, front one first; nil
  /// when the tree can't be read. The window that holds them is read first since it is much smaller. Only the
  /// first such window (about 13 ms): resolving all of them takes about 33 ms, no faster than all of SpringBoard,
  /// which is read when that window has no card of the app and so finds the cards in any other.
  private func windowCards(of bundleID: String, orientation: UIInterfaceOrientation) -> [CGRect]? {
    let (switcher, switcherFailed) = ignoringIssues {
      try? springboard.windows.matching(RunnerWindows.switcherWindowPredicate).firstMatch.snapshot()
    }
    var cards = switcherFailed ? nil : switcher.map { Self.cards(of: bundleID, in: $0) }
    var container = switcher?.frame
    if cards?.isEmpty ?? true {
      let (whole, failed) = ignoringIssues { try? springboard.snapshot() }
      if !failed, let whole {
        cards = Self.cards(of: bundleID, in: whole)
        container = whole.frame
      }
    }
    guard let cards, let container else { return nil }
    let portraitSize = displayScreen().size
    return cards.map {
      RunnerWindows.displayedFrame(card: $0, container: container, orientation: Self.runnerOrientation(orientation),
                                   portraitSize: portraitSize)
    }
  }

  private static func cards(of bundleID: String, in snapshot: XCUIElementSnapshot) -> [CGRect] {
    var frames: [CGRect] = []
    func visit(_ element: XCUIElementSnapshot) {
      guard !RunnerWindows.isCard(identifier: element.identifier, of: bundleID) else {
        frames.append(element.frame)
        return
      }
      element.children.forEach(visit)
    }
    visit(snapshot)
    return frames
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
    let target = try waitForElements(bundleID: bundleID, timeout: timeout) { root, isLastAttempt -> RunnerElementTarget? in
      // Without the window's position a frame says nothing about the screen, and a touch would miss
      // while reporting success. It can be passing, as while a window moves, so it is waited out too.
      if case .unknown(let message)? = self.commandWindow {
        guard isLastAttempt else { return nil }
        throw RunnerError.windowPositionUnknown(RunnerWindows.touchError(message))
      }
      let screen = CGRect(origin: .zero, size: self.screen(in: self.interfaceOrientation()).size)
      var resolved = selector.resolve(in: root, screen: screen)
      if case .success(let target) = resolved {
        try self.requireUncovered(bundleID)
        if self.canVerifyCommandHit {
          resolved = target.verified(hitPath: self.hitPath(at: target.point), in: root)
        }
      }
      switch resolved {
      case .success(let target):
        return target
      case .failure(let failure):
        guard isLastAttempt || !failure.isRetryable else { return nil }
        throw RunnerError.elementNotResolved(failure)
      }
    }
    let x = Double(target.point.x), y = Double(target.point.y)
    return annotated([
      "ok": true,
      "mode": try touch(x: x, y: y, duration: duration, mode: mode).rawValue,
      "bundleId": bundleID,
      "element": target.match.json,
      "point": RunnerElementTree.json(target.point)
    ])
  }

  private var canVerifyCommandHit: Bool {
    RunnerElementTree.canVerifyHit(window: commandWindow, displayCount: displays().count)
  }

  private func hitPath(at point: CGPoint) -> [Int]? {
    guard let snapshot = commandSnapshot else { return nil }
    let (path, failed) = ignoringIssues {
      RelayActiveApplication.hitPath(at: point, snapshot: snapshot)?.map { $0.intValue }
    }
    return failed ? nil : path
  }

  /// Throws 422 (`covered_by_other_app`) without touching when SpringBoard is in front of `bundleID`, read
  /// again right before the touch: the app was picked, and its snapshot taken, maybe before an alert came up,
  /// and its frames don't show the alert. A covered app is waited for briefly, as an alert leaves the list
  /// some 230 ms after the touch that dismissed it (`RunnerCoverage`). Without the private API, nothing is checked.
  private func requireUncovered(_ bundleID: String) throws {
    let covering = RunnerCoverage.settle(
      target: bundleID,
      wait: { seconds in
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
          _ = RunLoop.current.run(mode: .default, before: until)
        }
      },
      activeBundleIDs: { self.activeApplications()?.map(\.bundleIdentifier) }
    )
    guard let covering else { return }
    throw RunnerError.coveredByOtherApp(RunnerCoverage.Covered(target: bundleID, foreground: covering,
                                                               alert: springboardAlertLabel()))
  }

  /// The label of the alert SpringBoard shows, or nil. It snapshots SpringBoard, so it is only looked up for a
  /// touch already refused.
  private func springboardAlertLabel() -> String? {
    let (root, failed) = ignoringIssues { try? elementTree(springboard, bundleID: Self.springboardBundleID) }
    guard !failed, let root else { return nil }
    return RunnerCoverage.alertLabel(in: root)
  }

  /// Throws 400 when a point of `/tap`, `/press`, or `/swipe` is outside the screen in the displayed
  /// orientation (`RunnerRequestValues.pointOutsideScreen`), before anything is sent: such a touch reaches
  /// nothing, and answering 200 for it hides the mistake. Element targets need no check, since their point
  /// is already inside the screen. Skipped while the screen size is only UIScreen's guess (SpringBoard's
  /// frame could not be read), which on devices is the 320x480 compatibility size and would reject real points.
  private func requireOnScreen(_ points: [(name: String, x: Double, y: Double)]) throws {
    // The screen to check against is the app's display, so it must be known first.
    _ = try touchDisplay()
    let orientation = interfaceOrientation()
    let size = screen(in: orientation).size
    guard cachedScreen != nil else { return }
    for point in points {
      if let reason = RunnerRequestValues.pointOutsideScreen(point.name, x: point.x, y: point.y, screen: size,
                                                             orientation: Self.name(of: orientation)) {
        throw RunnerError.pointOffscreen(reason)
      }
    }
  }

  private func touch(x: Double, y: Double, duration: TimeInterval?, mode: TouchMode) throws -> TouchMode {
    switch mode {
    case .private:
      try synthesizeTouch(points: [(x, y)], offsets: [], liftOffset: duration ?? Self.tapDuration)
    case .xcui:
      if let duration {
        try coordinate(x: x, y: y).press(forDuration: duration)
      } else {
        try coordinate(x: x, y: y).tap()
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
    return annotated(RunnerElementLookup.findJSON(matches, count: count, limit: limit, bundleID: bundleID))
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

  /// Snapshot frames of the foreground app are already in its interface orientation. They are the same
  /// space as `/tap`, except in an iPad window, which `onScreen(_:bundleID:)` converts afterwards.
  private static func elementNode(_ snapshot: XCUIElementSnapshot, depth: Int, maxDepth: Int, path: [Int] = []) -> RunnerElementNode {
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
      children: expand ? children.enumerated().map { index, child in
        elementNode(child, depth: depth + 1, maxDepth: maxDepth, path: path + [index])
      } : [],
      truncated: !expand && !children.isEmpty,
      snapshotPath: path
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
    let screen = displayScreen()
    guard orientation.isLandscape else { return screen }
    return (CGSize(width: screen.size.height, height: screen.size.width), screen.scale)
  }

  /// The portrait size and scale of the display the foreground app is on: `portraitScreen()` on a device
  /// with one display, and also while the display can't be told (touches answer 422 then).
  private func displayScreen() -> (size: CGSize, scale: CGFloat) {
    guard case .found(let display) = appDisplay() else { return portraitScreen() }
    return (display.size, display.scale)
  }

  // MARK: - Displays

  /// Which display a command acts on.
  private enum DisplayLookup {
    /// The device has one display (or its displays can't be listed): the main one, as always.
    case single
    case found(RunnerDisplay)
    /// More than one display, and which one the app is on can't be told.
    case unknown
  }

  /// The displays from `XCUIScreen.screens`, listed once. A device with one display gets one entry, without
  /// slowing anything down. Empty when this Xcode has no private display IDs and sizes, which leaves
  /// everything on the main display as before. Also empty, and listed again by the next command like
  /// `portraitScreen()`, while the screen size is only UIScreen's guess or a screen can't be read.
  private func displays() -> [RunnerDisplay] {
    if let cachedDisplays {
      return cachedDisplays
    }
    let main = portraitScreen()
    guard cachedScreen != nil else { return [] }
    let (screens, failed) = ignoringIssues { XCUIScreen.screens.map(Self.reading(of:)) }
    let (displays, keep) = RunnerDisplays.displays(reading: failed ? nil : screens, mainPortraitPoints: main.size)
    if keep {
      cachedDisplays = displays
    }
    return displays
  }

  private static let displayIDSelector = NSSelectorFromString("displayID")
  private static let boundsSelector = NSSelectorFromString("bounds")

  private static let traitsSelector = NSSelectorFromString("traits")

  /// `-[XCUIScreen displayID]`, `-[XCUIScreen bounds]` (native pixels), and `-[XCUIScreen traits]` are
  /// private. Without `traits`, a screen counts as part of the device.
  private static func reading(of screen: XCUIScreen) -> RunnerDisplays.ScreenReading {
    let object = screen as NSObject
    guard object.responds(to: displayIDSelector), object.responds(to: boundsSelector) else { return .unsupported }
    guard let id = (object.value(forKey: "displayID") as? NSNumber)?.intValue,
          let bounds = (object.value(forKey: "bounds") as? NSValue)?.cgRectValue else { return .unreadable }
    let traits = object.responds(to: traitsSelector) ? (object.value(forKey: "traits") as? NSNumber)?.intValue : nil
    return .screen(RunnerDisplays.Screen(id: id, pixels: bounds.size, isMain: screen.isEqual(XCUIScreen.main),
                                         isIntegrated: traits.map { $0 & RunnerDisplays.integratedTrait != 0 } ?? true))
  }

  /// `-[XCElementSnapshot displayID]` is private; windows have the ID of their display, other elements 0.
  private static func displayID(of snapshot: XCUIElementSnapshot) -> Int? {
    guard let object = snapshot as? NSObject, object.responds(to: displayIDSelector) else { return nil }
    return (object.value(forKey: "displayID") as? NSNumber)?.intValue
  }

  /// The display the foreground app is on, looked up once per command.
  private func appDisplay() -> DisplayLookup {
    if let commandDisplay {
      return commandDisplay
    }
    let lookup = lookUpDisplay()
    commandDisplay = lookup
    return lookup
  }

  /// On a device with more than one display (iPhone Duo), an app's windows name its display (a snapshot,
  /// about 50 ms in Settings). SpringBoard has windows on every display, so for it, and for an app whose
  /// windows can't be read, the display is the only lit one: the dark display's screenshot is black
  /// (one screenshot per display, about 150 ms each). Neither gives an answer while all are dark.
  private func lookUpDisplay() -> DisplayLookup {
    let displays = self.displays()
    guard displays.count > 1 else { return .single }
    let bundleID = foregroundApplication().bundleID
    if bundleID != Self.springboardBundleID {
      let (windowDisplayIDs, failed) = ignoringIssues { () -> [Int?] in
        guard let snapshot = try? XCUIApplication(bundleIdentifier: bundleID).snapshot() else { return [] }
        return snapshot.children.map(Self.displayID(of:))
      }
      if !failed, let display = RunnerDisplays.windowDisplay(windowDisplayIDs, in: displays) {
        return .found(display)
      }
    }
    let shots = displays.compactMap { display -> (display: RunnerDisplay, isBlank: Bool)? in
      guard let screen = Self.xcuiScreen(display) else { return nil }
      let (blank, failed) = ignoringIssues { Self.isBlank(screen.screenshot().image) }
      return failed ? nil : (display, blank)
    }
    return RunnerDisplays.litDisplay(shots).map { .found($0) } ?? .unknown
  }

  private static func xcuiScreen(_ display: RunnerDisplay) -> XCUIScreen? {
    XCUIScreen.screens.first { screen in
      guard case .screen(let read) = reading(of: screen) else { return false }
      return read.id == display.id
    }
  }

  /// Whether `image` is black, judged on a 32x32 copy.
  private static func isBlank(_ image: UIImage) -> Bool {
    guard let cgImage = image.cgImage else { return true }
    let side = 32
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    return drawn && RunnerDisplays.isBlank(rgba: pixels)
  }

  /// The display touches go to: nil on a device with one display, where they go to the main display as
  /// always. Throws (422) when the device has more than one and the app's can't be told, rather than send a
  /// touch that may land on the dark display and report it as done.
  private func touchDisplay() throws -> RunnerDisplay? {
    switch appDisplay() {
    case .single:
      return nil
    case .found(let display):
      return display
    case .unknown:
      throw RunnerError.displayUnknown(RunnerDisplays.unknownDisplayMessage(bundleID: foregroundApplication().bundleID,
                                                                            displays: displays()))
    }
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
    let (imageOrientation, _) = ignoringIssues { appScreen().screenshot().image.imageOrientation }
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

    let screen = try screenshotDisplay()
    let screenshot = screen.xcuiScreen.screenshot()
    // The pixels are always portrait, with the rotation only in the image orientation. Redraw them
    // upright so pixel coordinates are points x scale in the displayed orientation. Shrinking happens
    // in the same draw: one pass over the full-size pixels, and the encoder sees only the small image.
    let image = screenshot.image
    let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let size = RunnerRequestValues.screenshotSize(pixels: pixels, screenScale: screen.scale, maxSize: maxSize, scale: scale)
    let renderer = image.imageOrientation == .up && size == pixels ? nil : Self.renderer(size: size)
    let draw: (UIGraphicsImageRendererContext) -> Void = { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    let points = pixels.width > pixels.height
      ? CGSize(width: screen.size.height, height: screen.size.width)
      : screen.size
    var headers = RunnerRequestValues.screenshotHeaders(image: size, screen: points)
    if let display = screen.display {
      headers[RunnerRequestValues.ScreenshotHeader.display] = String(display.id)
    }
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

  /// The screen to capture and its portrait size and scale: the display the foreground app is on. On a device
  /// with more than one display, `XCUIScreen.main` is the cover display of iPhone Duo even while it is dark,
  /// so the app's display is captured instead, and `display` names it for the `X-Relay-Display` header.
  /// Throws (422) when that display can't be told, rather than return a picture of a dark display.
  private func screenshotDisplay() throws -> (xcuiScreen: XCUIScreen, size: CGSize, scale: CGFloat, display: RunnerDisplay?) {
    guard let display = try touchDisplay() else {
      let screen = portraitScreen()
      return (XCUIScreen.main, screen.size, screen.scale, nil)
    }
    guard let xcuiScreen = Self.xcuiScreen(display) else {
      throw RunnerError.displayUnknown("display \(display.id) is no longer listed by XCUIScreen.screens")
    }
    return (xcuiScreen, display.size, display.scale, display)
  }

  /// The screen of the app's display without looking it up: `XCUIScreen.main` unless a command already did.
  private func appScreen() -> XCUIScreen {
    guard case .found(let display)? = commandDisplay, let screen = Self.xcuiScreen(display) else { return XCUIScreen.main }
    return screen
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
    try coordinate(x: from.x, y: from.y).press(
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

  /// Whether `auto` touches use the private path: when it is available and, on a device with more than one
  /// display, can name the display (`/health`'s `touchSynthesis` reports the same).
  private var privateTouchIsDefault: Bool {
    RelayTouchSynthesizer.isAvailable && (displays().count <= 1 || RelayTouchSynthesizer.supportsDisplayID)
  }

  /// How long a synthesized tap keeps the finger down.
  private static let tapDuration: TimeInterval = 0.05

  /// `"mode"` in the body forces a path; when omitted, the private path is used if available.
  private func touchMode(_ body: RunnerJSON) throws -> TouchMode {
    switch body.optionalString("mode") {
    case nil, "auto":
      return privateTouchIsDefault ? .private : .xcui
    case "xcui":
      return .xcui
    case "private":
      if let reason = RelayTouchSynthesizer.unavailableReason {
        throw RunnerError.touchModeRejected("mode: private touch synthesis is unavailable (\(reason))")
      }
      if displays().count > 1, !RelayTouchSynthesizer.supportsDisplayID {
        throw RunnerError.touchModeRejected("mode: private touch synthesis can't aim at a display on this Xcode "
          + "(XCSynthesizedEventRecord has no initWithName:displayID:interfaceOrientation:)")
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
    let orientation = Self.runnerOrientation(interfaceOrientation())
    // On a device with more than one display, every touch names its display, the main one too: on iPhone Duo,
    // a touch without one stopped reaching the cover display after the device was unfolded and folded again.
    // Points are in that display's own portrait space. A device with one display gets no ID, as before.
    let display = try touchDisplay()
    let displayID = display.map { NSNumber(value: $0.id) }
    if let display, !RelayTouchSynthesizer.supportsDisplayID {
      throw RunnerError.touchUnreachable("private touch synthesis can't aim at display \(display.id) "
        + "(XCSynthesizedEventRecord has no initWithName:displayID:interfaceOrientation:); nothing was sent")
    }
    let portraitSize = display?.size ?? portraitScreen().size
    let completion = TouchCompletion()
    do {
      try RelayTouchSynthesizer.synthesizeTouch(
        withPoints: points.map {
          NSValue(cgPoint: RunnerDisplays.portraitPoint(CGPoint(x: $0.x, y: $0.y), from: orientation, portraitSize: portraitSize))
        },
        offsets: offsets.map { NSNumber(value: $0) },
        liftOffset: liftOffset,
        interfaceOrientation: .portrait,
        displayID: displayID,
        completion: { completion.finish($0) }
      )
    } catch {
      throw RunnerError.touchSynthesisError("touch synthesis failed: \(error.localizedDescription)")
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

  /// `orientation` as the shared `RunnerDisplays` functions take it.
  ///
  /// The synthesizer takes native portrait points: the record's interface orientation is not applied
  /// to them (a landscape point passed with `.landscapeRight` lands somewhere else), so points are
  /// rotated with `RunnerDisplays.portraitPoint` and `.portrait` is always passed.
  private static func runnerOrientation(_ orientation: UIInterfaceOrientation) -> RunnerInterfaceOrientation {
    switch orientation {
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    default: return .portrait
    }
  }

  private func pressButton(_ name: String) throws {
    switch name {
    case "home":
      #if targetEnvironment(simulator)
        // On a device with more than one display (iPhone Duo, on either display) the button reports success
        // and does nothing, like on devices, so go home with the gesture there too.
        if try touchDisplay() != nil {
          try swipeHome()
        } else {
          XCUIDevice.shared.press(.home)
        }
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
    if privateTouchIsDefault {
      let to = (x: from.x, y: Double(size.height * 0.6))
      let duration = 0.12
      // Same shape as a private /swipe with hold 0: the extra move at `from` makes the synthesizer
      // interpolate the drag; a lone move from the touch-down point arrives as a single jump.
      try synthesizeTouch(points: [from, from, to], offsets: [0, duration], liftOffset: duration)
    } else {
      // XCUI drags only go home with a short press first; with forDuration 0 nothing happens.
      let to = (x: from.x, y: Double(size.height * 0.5))
      let duration = 0.2
      try coordinate(x: from.x, y: from.y).press(
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
  ///
  /// SpringBoard's coordinates are on the main display. On another display (the inner one of iPhone Duo),
  /// XCUI touches arrive only through an element there, so offsets are taken from the foreground app's
  /// first window, which is on its display (offsets from SpringBoard's frame or the app's do nothing there);
  /// SpringBoard has windows on every display, so it can't be used.
  private func coordinate(x: Double, y: Double) throws -> XCUICoordinate {
    guard let display = try touchDisplay(), !display.isMain else {
      return springboard
        .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        .withOffset(CGVector(dx: x, dy: y))
    }
    let bundleID = foregroundApplication().bundleID
    guard bundleID != Self.springboardBundleID else {
      throw RunnerError.touchUnreachable("xcui touches can't reach display \(display.id) while SpringBoard is in front "
        + "(its coordinates are on the main display); use mode private; nothing was sent")
    }
    let window = XCUIApplication(bundleIdentifier: bundleID).windows.firstMatch
    // An app that stays portrait on a landscape display is shown rotated, with a portrait window. XCUI
    // coordinate touches reported success and did nothing there, with offsets in either orientation.
    let (frame, failed) = ignoringIssues { window.frame }
    guard !failed else {
      throw RunnerError.touchUnreachable("can't find a window of \(bundleID) on display \(display.id); nothing was sent")
    }
    guard !RunnerDisplays.isPortrait(frame, in: Self.runnerOrientation(interfaceOrientation())) else {
      throw RunnerError.touchUnreachable("xcui touches can't reach \(bundleID) on display \(display.id) "
        + "(it stays portrait and is shown rotated); use mode private; nothing was sent")
    }
    // The window need not start at the display's corner: an app shown rotated sat at (282, 0), so the offset
    // is taken from the window's origin.
    return window
      .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: x - frame.minX, dy: y - frame.minY))
  }

  private func ok() -> RunnerHTTPResponse {
    .json(["ok": true])
  }

  private func ok(mode: TouchMode) -> RunnerHTTPResponse {
    .json(["ok": true, "mode": mode.rawValue])
  }

  /// What this build was made from, as `/ping` and `/health` report it: relay passes its version and the
  /// hash of the runner sources to xcodebuild as build settings, and the UI test target's Info.plist expands
  /// them (`Info.plist` next to this file). Read from the bundle, so it describes the build, not the launch;
  /// null for a build made without them (from Xcode, say).
  private static let buildVersion: [String: Any] = {
    let info = Bundle(for: RelayRunnerUITests.self).infoDictionary ?? [:]
    func value(_ key: String) -> Any {
      guard let string = info[key] as? String, !string.isEmpty else { return NSNull() }
      return string
    }
    return ["version": value("RelayRunnerVersion"), "sourceHash": value("RelayRunnerSourceHash")]
  }()

  /// The device, not the runner's idiom: only iPads have app windows.
  private static let isPad = UIDevice.current.model.hasPrefix("iPad")

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
