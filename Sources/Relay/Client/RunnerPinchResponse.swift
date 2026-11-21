import Foundation

extension RunnerPinch {
  /// Validate capability acknowledgement and actual geometry before reporting CLI success.
  static func acceptsAnswer(_ body: Data, options: Options, touch: RunnerTouch) -> Bool {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          RunnerRequestValues.bool(object["ok"] ?? NSNull()) == true,
          object["gesture"] as? String == "pinch",
          let mode = object["mode"] as? String, ["private", "xcui"].contains(mode),
          touch.mode == nil || touch.mode == mode,
          object["scale"].flatMap(RunnerRequestValues.number) == options.scale else { return false }
    if mode == "xcui" {
      guard case .element = touch.target, options.radius == nil, options.duration == nil,
            object["velocity"].flatMap(RunnerRequestValues.number) == options.velocity else { return false }
      return ["center", "radius", "start", "end", "duration"].allSatisfy { object[$0] is NSNull }
    }
    func point(_ value: Any?) -> CGPoint? {
      guard let object = value as? [String: Any],
            let x = object["x"].flatMap(RunnerRequestValues.number), x.isFinite, x >= 0,
            let y = object["y"].flatMap(RunnerRequestValues.number), y.isFinite, y >= 0 else { return nil }
      return CGPoint(x: x, y: y)
    }
    guard let center = point(object["center"]),
          let radius = object["radius"].flatMap(RunnerRequestValues.number), radius.isFinite, radius > 0,
          options.radius == nil || options.radius == radius,
          object["duration"].flatMap(RunnerRequestValues.number) == options.movementDuration,
          let starts = object["start"] as? [Any], let ends = object["end"] as? [Any],
          starts.count == 2, ends.count == 2 else { return false }
    if case .point(let requested) = touch.target,
       abs(center.x - requested.x) > 0.001 || abs(center.y - requested.y) > 0.001 { return false }
    let expected = Geometry(center: center, radius: radius, scale: options.scale, duration: options.movementDuration)
    return zip(starts + ends, expected.start + expected.end).allSatisfy { value, expected in
      guard let actual = point(value) else { return false }
      return abs(actual.x - expected.x) <= 0.002 && abs(actual.y - expected.y) <= 0.002
    }
  }
}
