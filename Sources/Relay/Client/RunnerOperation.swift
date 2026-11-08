import Foundation

/// One request to the runner, as the runner commands (`relay tap`, `relay find`, ...) describe it.
///
/// Kept apart from argument parsing and from output so another front end (an MCP server, say) can build
/// the same operations from its own input and send them with `RunnerControl`.
enum RunnerOperation: Equatable {
  case ping
  case health
  case foreground
  case screenshot(RunnerScreenshot)
  case source(format: String?, maxDepth: Int?, filter: String?, bundleID: String?)
  case find(RunnerElementSelector, limit: Int?, timeout: TimeInterval?, bundleID: String?)
  case tap(RunnerTouch)
  case press(RunnerTouch)
  case swipe(from: RunnerPoint, to: RunnerPoint, duration: TimeInterval?, hold: TimeInterval?, mode: String?)
  case type(text: String?, keys: [String], bundleID: String?)
  case key(String, bundleID: String?)
  case button(String)
  case orientation(String)
  case launch(bundleID: String)
  case terminate(bundleID: String)
  case shutdown

  /// The name of the `relay` command that sends it.
  var commandName: String {
    switch self {
    case .ping: return "ping"
    case .health: return "health"
    case .foreground: return "foreground"
    case .screenshot: return "screenshot"
    case .source: return "source"
    case .find: return "find"
    case .tap: return "tap"
    case .press: return "press"
    case .swipe: return "swipe"
    case .type: return "type"
    case .key: return "key"
    case .button: return "button"
    case .orientation: return "orientation"
    case .launch: return "launch"
    case .terminate: return "terminate"
    case .shutdown: return "shutdown"
    }
  }

  var request: RunnerHTTPRequest {
    switch self {
    case .ping: return .get("/ping")
    case .health: return .get("/health")
    case .foreground: return .get("/foreground")
    case .screenshot(let screenshot):
      return .get("/screenshot", query: [
        ("format", screenshot.format),
        ("quality", screenshot.quality.map { String($0) }),
        ("maxSize", screenshot.maxSize.map(String.init)),
        ("scale", screenshot.scale.map { String($0) })
      ])
    case .source(let format, let maxDepth, let filter, let bundleID):
      return .get("/source", query: [
        ("format", format), ("maxDepth", maxDepth.map(String.init)), ("filter", filter), ("bundleId", bundleID)
      ])
    case .find(let selector, let limit, let timeout, let bundleID):
      var body: [String: Any] = ["element": selector.json]
      body["limit"] = limit
      body["timeout"] = timeout
      body["bundleId"] = bundleID
      return .post("/find", body)
    case .tap(let touch): return .post("/tap", touch.json)
    case .press(let touch): return .post("/press", touch.json)
    case .swipe(let from, let to, let duration, let hold, let mode):
      var body: [String: Any] = ["from": from.json, "to": to.json]
      body["duration"] = duration
      body["hold"] = hold
      body["mode"] = mode
      return .post("/swipe", body)
    case .type(let text, let keys, let bundleID):
      var body: [String: Any] = [:]
      body["text"] = text
      body["keys"] = keys.isEmpty ? nil : keys
      body["bundleId"] = bundleID
      return .post("/type", body)
    case .key(let key, let bundleID):
      var body: [String: Any] = ["key": key]
      body["bundleId"] = bundleID
      return .post("/key", body)
    case .button(let name): return .post("/button", ["name": name])
    case .orientation(let name): return .post("/orientation", ["orientation": name])
    case .launch(let bundleID): return .post("/launch", ["bundleId": bundleID])
    case .terminate(let bundleID): return .post("/terminate", ["bundleId": bundleID])
    case .shutdown: return .post("/shutdown", [:])
    }
  }

  /// How long the runner may legitimately take beyond a normal round trip: element waits, gesture
  /// durations, app state waits, and typing, which the HTTP timeout must not cut short. A request cut
  /// short leaves the runner busy with it, so the next command gets 409.
  var waitTime: TimeInterval {
    switch self {
    case .find(_, _, let timeout, _): return timeout ?? 0
    case .tap(let touch): return touch.timeout ?? 0
    case .press(let touch): return (touch.timeout ?? 0) + (touch.duration ?? 1)
    case .swipe(_, _, let duration, let hold, _): return (duration ?? 0.3) + (hold ?? 0.05)
    case .launch, .terminate: return Self.applicationStateWait
    case .type(let text, let keys, _): return Self.typingWait(text: text ?? "", keyCount: keys.count)
    case .key: return Self.typingWait(text: "", keyCount: 1)
    default: return 0
    }
  }

  /// `activate()` and `terminate()` wait for the app to reach the state for up to XCTest's
  /// application state timeout: 60 s once the runner restores it, but 120 s (the scheme's
  /// `-XCUIApplicationStateTimeout`) when the runner cannot, which relay cannot tell from here.
  static let applicationStateWait: TimeInterval = 120

  /// Seconds per character for `typeText`. It typed about 15 ms per character on a simulator (1,000 ASCII
  /// characters in 17 s, Japanese at the same rate); a device is slower (one `/key` took 0.66 s there
  /// against 0.26 s on a simulator), so this leaves several times what was seen.
  static let typingWaitPerCharacter: TimeInterval = 0.1
  /// Seconds per key (`/key`, `/type` `keys`): a key took 0.26 s on a simulator and 0.66 s on a device.
  static let typingWaitPerKey: TimeInterval = 1

  /// Counted in Unicode scalars, not characters, since a character made of several scalars can take
  /// several key events.
  static func typingWait(text: String, keyCount: Int) -> TimeInterval {
    Double(text.unicodeScalars.count) * typingWaitPerCharacter + Double(keyCount) * typingWaitPerKey
  }
}

struct RunnerPoint: Equatable {
  var x: Double
  var y: Double

  var json: [String: Any] { ["x": x, "y": y] }
}

/// `/tap` and `/press`: a point, or the element a selector picks.
struct RunnerTouch: Equatable {
  enum Target: Equatable {
    case point(RunnerPoint)
    case element(RunnerElementSelector)
  }

  var target: Target
  /// `/press` only.
  var duration: TimeInterval?
  /// `private` or `xcui`; nil lets the runner choose.
  var mode: String?
  /// Element targets only: seconds to wait for the element, and the app to look in.
  var timeout: TimeInterval?
  var bundleID: String?

  var json: [String: Any] {
    var body: [String: Any]
    switch target {
    case .point(let point): body = point.json
    case .element(let selector): body = ["element": selector.json]
    }
    body["duration"] = duration
    body["mode"] = mode
    body["timeout"] = timeout
    body["bundleId"] = bundleID
    return body
  }
}

struct RunnerScreenshot: Equatable {
  /// `png` or `jpeg`; nil is the runner's default (png).
  var format: String?
  var quality: Double?
  /// The longest edge in pixels, and the pixels per point; the runner shrinks the image to fit both.
  var maxSize: Int?
  var scale: Double?
  /// Where to save the image: a path, `-` for stdout, or nil for a new file under the temporary directory.
  var output: String?

  var fileExtension: String { format == "jpeg" ? "jpg" : "png" }

  var isResized: Bool { maxSize != nil || scale != nil }
}

extension RunnerElementSelector {
  /// The `element` object of `/tap`, `/press`, and `/find`.
  var json: [String: Any] {
    var object: [String: Any] = [:]
    object["identifier"] = identifier
    object["label"] = label
    object["type"] = type
    object["value"] = value
    object["index"] = index
    return object
  }
}

struct RunnerHTTPRequest {
  var method: String
  /// The path with its query, relative to the runner URL.
  var path: String
  /// The JSON body of a POST.
  var body: [String: Any]?

  static func get(_ path: String, query: [(String, String?)] = []) -> RunnerHTTPRequest {
    var components = URLComponents()
    components.path = path
    let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    components.queryItems = items.isEmpty ? nil : items
    return RunnerHTTPRequest(method: "GET", path: components.string ?? path, body: nil)
  }

  static func post(_ path: String, _ body: [String: Any]) -> RunnerHTTPRequest {
    RunnerHTTPRequest(method: "POST", path: path, body: body)
  }
}
