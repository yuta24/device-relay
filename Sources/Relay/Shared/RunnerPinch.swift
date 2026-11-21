import Foundation

/// Pinch input validation and displayed-space geometry, shared by the runner and CLI tests.
enum RunnerPinch {
  static let scaleRange = 0.1 ... 10.0
  static let durationRange = 0.05 ... 5.0
  static let defaultDuration = 0.6
  static let rest = 0.05
  /// A default geometry margin, not a guarantee against system edge gestures or cutouts.
  static let margin = 16.0
  /// XCUI may wait 60 s before and after; at +/-1 scale/s the longest gesture is 9 s.
  static let xcuiAnswer = RunnerAdjusting.idleWait + 10

  struct Invalid: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  struct Options: Equatable {
    let scale: Double
    let radius: Double?
    let duration: Double?

    init(json: [String: Any]) throws {
      let allowed: Set<String> = ["x", "y", "element", "scale", "radius", "duration", "mode", "bundleId", "timeout"]
      if let key = json.keys.sorted().first(where: { !allowed.contains($0) }) {
        throw Invalid("pinch: unknown key '\(key)'")
      }
      guard let scale = json["scale"].flatMap(RunnerRequestValues.number), scale.isFinite,
            RunnerPinch.scaleRange.contains(scale), scale != 1 else {
        throw Invalid("scale: expected 0.1...10, other than 1 (end radius / start radius)")
      }
      self.scale = scale
      radius = try Self.optionalNumber("radius", json: json) { $0 > 0 }
      duration = try Self.optionalNumber("duration", json: json) { RunnerPinch.durationRange.contains($0) }
      if let given = json["mode"] {
        guard let mode = given as? String, ["auto", "private", "xcui"].contains(mode) else {
          throw Invalid("mode: expected private, xcui, or auto")
        }
      }
      if json["element"] == nil {
        guard json["bundleId"] == nil, json["timeout"] == nil else {
          throw Invalid("bundleId and timeout require element")
        }
      } else if json["x"] != nil || json["y"] != nil {
        throw Invalid("pass either x and y or element, not both")
      }
      if json["mode"] as? String == "xcui" {
        try validateXCUI(hasElement: json["element"] != nil)
      }
    }

    private static func optionalNumber(_ key: String, json: [String: Any], valid: (Double) -> Bool) throws -> Double? {
      guard let value = json[key] else { return nil }
      guard let number = RunnerRequestValues.number(value), number.isFinite, valid(number) else {
        throw Invalid("\(key): expected \(key == "radius" ? "finite points greater than zero" : "seconds in 0.05...5")")
      }
      return number
    }

    func validateXCUI(hasElement: Bool) throws {
      guard hasElement else { throw Invalid("mode xcui requires element; coordinate pinch needs private synthesis") }
      guard radius == nil, duration == nil else { throw Invalid("radius and duration are only available with private pinch") }
    }

    var movementDuration: Double { duration ?? RunnerPinch.defaultDuration }
    var velocity: Double { scale > 1 ? 1 : -1 }
  }

  struct Geometry: Equatable {
    let center: CGPoint
    let radius: Double
    let scale: Double
    let duration: Double

    var start: [CGPoint] { pair(radius) }
    var end: [CGPoint] { pair(radius * scale) }
    var liftOffset: Double { duration + 2 * RunnerPinch.rest }

    private func pair(_ radius: Double) -> [CGPoint] {
      [CGPoint(x: center.x - radius, y: center.y), CGPoint(x: center.x + radius, y: center.y)]
    }

    /// One shared clock and stable finger order; no per-finger HTTP round trips.
    var paths: [[CGPoint]] {
      (0 ..< 2).map { finger in
        [start[finger], start[finger]] + (1 ... 30).map { step in
          let t = Double(step) / 30
          return CGPoint(x: start[finger].x + (end[finger].x - start[finger].x) * t, y: center.y)
        }
      }
    }

    var offsets: [Double] { [RunnerPinch.rest] + (1 ... 30).map { RunnerPinch.rest + duration * Double($0) / 30 } }

    var json: [String: Any] {
      ["center": RunnerElementTree.json(center), "radius": radius, "duration": duration,
       "start": start.map(RunnerElementTree.json), "end": end.map(RunnerElementTree.json)]
    }
  }

  /// Explicit radii are untouched; the caller checks all four endpoints with pointOutsideScreen.
  /// Defaults fit both the screen margin and the visible target, conservatively in both axes.
  static func geometry(options: Options, center: CGPoint, screen: CGSize, element: CGRect? = nil) throws -> Geometry {
    guard center.x.isFinite, center.y.isFinite, screen.width.isFinite, screen.height.isFinite,
          screen.width > 0, screen.height > 0 else { throw Invalid("pinch: screen geometry is unavailable") }
    let radius: Double
    if let explicit = options.radius {
      radius = explicit
    } else {
      var area = CGRect(origin: .zero, size: screen).insetBy(dx: margin, dy: margin)
      if let element { area = area.intersection(element) }
      let reach = min(center.x - area.minX, area.maxX - center.x, center.y - area.minY, area.maxY - center.y)
      guard !area.isNull, !area.isEmpty, reach.isFinite, reach > 0 else {
        throw Invalid("radius: cannot fit a default pinch inside the screen's 16 pt margin and the visible element; choose another center or an explicit radius")
      }
      radius = min(min(screen.width, screen.height) / 4, reach / max(options.scale, 1))
    }
    guard radius.isFinite, radius > 0, (radius * options.scale).isFinite else { throw Invalid("radius: pinch geometry overflows") }
    let geometry = Geometry(center: center, radius: radius, scale: options.scale, duration: options.movementDuration)
    guard (geometry.start + geometry.end).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
      throw Invalid("radius: pinch endpoints overflow")
    }
    guard geometry.start[0] != geometry.start[1], geometry.end[0] != geometry.end[1] else {
      throw Invalid("radius: contacts are indistinguishable at this coordinate precision")
    }
    return geometry
  }
}
