import Foundation

/// `/adjust`: what to set a slider or a picker wheel to, which elements take it, and whether the value read
/// afterwards is what was asked for.
///
/// Like `RunnerAuth.swift`, this file is compiled into both the `relay` CLI and the runner target so the SwiftPM
/// unit tests cover it.
enum RunnerAdjusting {
  enum Target: Equatable, Sendable {
    /// A slider's normalized position, 0...1 (`adjust(toNormalizedSliderPosition:)`).
    case position(Double)
    /// The value a picker wheel shows (`adjust(toPickerWheelValue:)`), compared exactly with its value afterwards.
    case pickerValue(String)

    /// The element type that takes it, as `/source` names it.
    var elementType: String {
      switch self {
      case .position: return "slider"
      case .pickerValue: return "pickerWheel"
      }
    }
  }

  enum TargetError: Error, Equatable, CustomStringConvertible {
    case missing
    case both
    case position
    case pickerValue

    var description: String {
      switch self {
      case .missing: return "position or pickerValue: expected one of them"
      case .both: return "position and pickerValue: expected one of them, not both"
      case .position: return "position: expected a number in 0...1"
      case .pickerValue: return "pickerValue: expected a non-empty string"
      }
    }
  }

  /// `position` and `pickerValue` of an `/adjust` body: exactly one, a number in 0...1 or a non-empty string.
  static func target(position: Any?, pickerValue: Any?) -> Result<Target, TargetError> {
    switch (position, pickerValue) {
    case (nil, nil): return .failure(.missing)
    case (_?, _?): return .failure(.both)
    case (let position?, nil):
      guard let number = RunnerRequestValues.number(position), number.isFinite, (0 ... 1).contains(number) else {
        return .failure(.position)
      }
      return .success(.position(number))
    case (nil, let value?):
      guard let text = value as? String, !text.isEmpty else { return .failure(.pickerValue) }
      return .success(.pickerValue(text))
    }
  }

  /// Why `element` can't take `target`, or nil when it can. XCUI's adjust on another type fails.
  static func typeMismatch(_ target: Target, element: RunnerElementNode) -> String? {
    guard element.type != target.elementType else { return nil }
    let what = target.elementType == "slider" ? "position applies to a slider" : "pickerValue applies to a picker wheel"
    return "the element is a \(element.type), not a \(target.elementType) (\(what)); nothing was adjusted"
  }

  /// What an `/adjust` did: the element as it was found, and its value (and a slider's position) read afterwards;
  /// nil when it could not be read.
  struct Outcome: Sendable {
    var bundleID: String
    var element: RunnerElementMatch
    var value: String?
    var position: Double?
    var target: Target

    /// The answer's fields: `bundleId`, `element`, `value`, and for a slider `position`.
    var json: [String: Any] {
      var object: [String: Any] = ["bundleId": bundleID, "element": element.json, "value": value ?? NSNull()]
      if case .position = target {
        object["position"] = position ?? NSNull()
      }
      return object
    }
  }

  /// How far a slider may end from `position` and still count as set: 2% of its track, some 7 points of an iPhone's
  /// full-width slider. XCUI's adjust alone ended up to 0.09 off, and did not get closer when called again, so the
  /// runner corrects it with drags (`correction(from:to:frame:)`).
  static let positionTolerance = 0.02

  /// Whether a slider at `position` counts as at `wanted`: within `positionTolerance`, the bound included (0.52 is
  /// 0.020000000000000018 from 0.5 in floating point).
  static func isClose(_ position: Double, _ wanted: Double) -> Bool {
    abs(position - wanted) <= positionTolerance + 1e-9
  }

  /// The most drags that correct a slider after XCUI's adjust.
  static let maxCorrections = 4

  /// The runner starts no correction this long after it started the adjust, and answers with the slider where it is.
  /// On the simulator a slider took 1.8-4.3 s in all (2 s of it XCUI's adjust, which waits for the app to be idle)
  /// and a picker wheel 0.13-0.9 s. XCUI's adjust itself can't be cut short: an app that is never idle keeps it,
  /// and the runner busy, longer.
  static let correctionStop: TimeInterval = 10

  /// A correction holds the thumb this long, then drags it over `correctionDuration`.
  static let correctionHold: TimeInterval = 0.05
  static let correctionDuration: TimeInterval = 0.2

  /// The longest a correction can take: its drag, and the 10 s the runner waits past a synthesized touch's lift.
  static let correctionLength: TimeInterval = correctionHold + correctionDuration + 10

  /// When the runner answers at the latest after it found the element, once XCUI's adjust has returned quickly: the
  /// last correction may start just before `correctionStop`. `longestAnswer` adds XCUI's idle waits.
  static let giveUp: TimeInterval = correctionStop + correctionLength

  /// How long XCUI's adjust may wait for the app to be idle, before and after it acts: on a screen that never idles
  /// (a repeating animation) it gave up on each wait after about 60 s and went on, and the runner answered after
  /// 120.2 s (a wheel) and 121.0 s (a slider). The same idea as `/launch`'s 120 s.
  static let idleWait: TimeInterval = 120

  /// When the runner answers at the latest after it found the element: XCUI's idle waits, then `giveUp`. A slider
  /// whose adjust took longer than `correctionStop` is not corrected. Not a bound for corrections sent as XCUI drags
  /// (private touch synthesis unavailable) in an app that never idles: each of those waits for it too.
  /// `relay adjust` waits this long on top of the 30 s and `--timeout`, so it waits at least 20 s past the answer.
  static let longestAnswer: TimeInterval = idleWait + giveUp

  /// The track of a horizontal slider: its frame less half its height at each end, taking the thumb to be as wide
  /// as the slider is high. An error in that only scales a correction, which the next one makes up for. Nil for a
  /// slider higher than wide (vertical), whose direction can't be told from its frame.
  static func track(of frame: CGRect) -> (minX: CGFloat, width: CGFloat)? {
    guard frame.width > frame.height, frame.height > 0 else { return nil }
    return (frame.minX + frame.height / 2, frame.width - frame.height)
  }

  /// The drag that moves a horizontal slider's thumb from `position` to `wanted`: from the thumb's center, by the
  /// difference along the track plus `slack` points, which a slider lets the finger move before the thumb follows.
  static func correction(from position: Double, to wanted: Double, frame: CGRect, slack: CGFloat) -> (from: CGPoint, to: CGPoint)? {
    guard let track = track(of: frame), position != wanted else { return nil }
    let start = track.minX + CGFloat(position) * track.width
    let move = CGFloat(wanted - position) * track.width
    let end = start + move + (move < 0 ? -slack : slack)
    return (CGPoint(x: start, y: frame.midY), CGPoint(x: end, y: frame.midY))
  }

  /// How far the finger moved without the thumb in a correction that went from `before` to `after`: what the next
  /// correction adds. On iOS 27 a slider's thumb stayed some 10 points behind the finger, so a drag of less than
  /// that did nothing; 0 when the thumb went the other way or further (nothing is learned from that).
  static func slack(fingerMoved: CGFloat, before: Double, after: Double, frame: CGRect) -> CGFloat {
    guard let track = track(of: frame) else { return 0 }
    let thumbMoved = CGFloat(after - before) * track.width
    guard fingerMoved != 0, (thumbMoved >= 0) == (fingerMoved > 0) || thumbMoved == 0 else { return 0 }
    return max(0, abs(fingerMoved) - abs(thumbMoved))
  }

  /// Why the adjust did not reach `target`, or nil when it did: XCUI's own failure, a value that could not be
  /// read, or a value read afterwards that is not the target.
  static func failure(_ target: Target, value: String?, position: Double?, issues: [String]) -> String? {
    if !issues.isEmpty {
      return "XCUI could not adjust the element: " + issues.joined(separator: "; ")
    }
    switch target {
    case .position(let wanted):
      guard let position else { return "cannot read the slider's position after adjusting it" }
      guard isClose(position, wanted) else {
        return "the slider ended at \(RunnerRequestValues.decimal(CGFloat(position))), not \(RunnerRequestValues.decimal(CGFloat(wanted))) "
          + "(within \(RunnerRequestValues.decimal(CGFloat(positionTolerance))))"
      }
      return nil
    case .pickerValue(let wanted):
      guard let value else { return "cannot read the picker wheel's value after adjusting it" }
      guard value == wanted else { return "the picker wheel shows \(value.debugDescription), not \(wanted.debugDescription)" }
      return nil
    }
  }
}
