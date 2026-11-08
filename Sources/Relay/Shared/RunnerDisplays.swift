import Foundation

/// One display of the device. iPhone Duo has two, the cover display (the main one) and the inner one,
/// and only the one in use is lit; every other device has one.
///
/// Like `RunnerRequestValues.swift`, this file is compiled into both the `relay` CLI and the runner target
/// so the SwiftPM unit tests cover it.
struct RunnerDisplay: Equatable {
  /// `XCUIScreen`'s display ID, the `displayId` that `xcrun devicectl device info displays` lists.
  let id: Int
  /// Portrait size in points.
  let size: CGSize
  /// Screenshot pixels per point.
  let scale: CGFloat
  /// `XCUIScreen.main`, which XCUI screenshots and coordinates use unless told otherwise.
  let isMain: Bool

  /// `/health`'s `displays` entry: the portrait size, like the `devicectl` bounds divided by the scale.
  var json: [String: Any] {
    ["id": id, "width": size.width, "height": size.height, "scale": scale, "main": isMain]
  }
}

/// UIKit's interface orientation, named by where the top of the interface is (so `landscapeLeft` is
/// `/orientation landscapeRight`), without UIKit so the CLI tests can use it.
enum RunnerInterfaceOrientation {
  case portrait
  case portraitUpsideDown
  case landscapeLeft
  case landscapeRight

  var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

enum RunnerDisplays {
  /// An `XCUIScreen`: its display ID and its native (portrait) size in pixels.
  struct Screen: Equatable {
    let id: Int
    let pixels: CGSize
    let isMain: Bool
    /// Part of the device, as opposed to a wireless (AirPlay) display, which an iPhone can list too.
    var isIntegrated = true
  }

  /// The bit of `-[XCUIScreen traits]` for a display that is part of the device (`integrated` in the
  /// screen's description). An iPhone 14 Pro listed its display with traits 1 and a wireless AirPlay
  /// display with 6 (`wireless, airplay`; `devicectl device info displays` shows it as type `wireless`).
  static let integratedTrait = 1

  /// The displays of `screens` that are part of the device, or nil when there is no single main screen
  /// among them or a size is empty.
  ///
  /// `mainPortraitPoints` is the main display's portrait size in points (SpringBoard's frame). Its scale
  /// is the main screen's longer pixel edge over that size's longer edge, and every display is taken to
  /// have the same scale: XCUIScreen gives no point size, and both displays of iPhone Duo are 3x
  /// (`pointScale` in `devicectl device info displays`).
  static func displays(_ screens: [Screen], mainPortraitPoints: CGSize) -> [RunnerDisplay]? {
    // Touches and screenshots of a wireless display reach nothing on the device, and counting one would
    // make a one-display iPhone pay for looking up the display of every command.
    let screens = screens.filter(\.isIntegrated)
    let mains = screens.filter(\.isMain)
    guard mains.count == 1, let main = mains.first, max(mainPortraitPoints.width, mainPortraitPoints.height) > 0,
          screens.allSatisfy({ min($0.pixels.width, $0.pixels.height) > 0 }) else { return nil }
    let scale = max(main.pixels.width, main.pixels.height) / max(mainPortraitPoints.width, mainPortraitPoints.height)
    return screens.map { screen in
      let pixels = portrait(screen.pixels)
      let size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
      return RunnerDisplay(id: screen.id, size: screen.isMain ? portrait(mainPortraitPoints) : size, scale: scale,
                           isMain: screen.isMain)
    }
  }

  /// What reading one `XCUIScreen` gave.
  enum ScreenReading: Equatable {
    case screen(Screen)
    /// The screen does not answer the private `displayID` or `bounds`: this Xcode has no such fields,
    /// and reading again won't change that.
    case unsupported
    /// It answers them, but a value could not be read.
    case unreadable
  }

  /// The displays from reading every `XCUIScreen` (nil when the reading recorded an XCTest issue), and
  /// whether to keep them for the session.
  ///
  /// Only a list and an Xcode without the private fields are kept; the latter gives `[]`, so a device with
  /// one display stays as fast as before. Anything else may be passing, and gives `[]` for this command
  /// only: kept, it would leave iPhone Duo acting as one display, its touches sent to the dark one.
  static func displays(reading screens: [ScreenReading]?, mainPortraitPoints: CGSize) -> (displays: [RunnerDisplay], keep: Bool) {
    guard let screens else { return ([], false) }
    if screens.contains(.unsupported) {
      return ([], true)
    }
    let read = screens.compactMap { reading -> Screen? in
      guard case .screen(let screen) = reading else { return nil }
      return screen
    }
    // Every screen must be readable; a display that couldn't be told apart would be left out unseen.
    guard read.count == screens.count, let displays = displays(read, mainPortraitPoints: mainPortraitPoints) else {
      return ([], false)
    }
    return (displays, true)
  }

  /// The display the foreground app is on, from the display IDs of its top-level windows (nil where a
  /// window's ID could not be read): the first that names one of `displays`. An app has windows only on
  /// the display it is on; SpringBoard has windows on every display, so it is told apart with `litDisplay`.
  static func windowDisplay(_ windowDisplayIDs: [Int?], in displays: [RunnerDisplay]) -> RunnerDisplay? {
    for case let id? in windowDisplayIDs {
      if let display = displays.first(where: { $0.id == id }) {
        return display
      }
    }
    return nil
  }

  /// The only display whose screenshot is not blank, or nil when none or several are. iPhone Duo lights one
  /// display at a time, and XCUI returns an all-black screenshot of the dark one.
  static func litDisplay(_ displays: [(display: RunnerDisplay, isBlank: Bool)]) -> RunnerDisplay? {
    let lit = displays.filter { !$0.isBlank }
    return lit.count == 1 ? lit[0].display : nil
  }

  /// Whether `rgba` (8-bit RGBA pixels, such as a screenshot drawn small) is black: no color channel
  /// above `threshold`. Alpha is ignored.
  static func isBlank(rgba: [UInt8], threshold: UInt8 = 8) -> Bool {
    var index = 0
    while index + 2 < rgba.count {
      if rgba[index] > threshold || rgba[index + 1] > threshold || rgba[index + 2] > threshold {
        return false
      }
      index += 4
    }
    return true
  }

  /// The size of a display of `portraitSize` points as `orientation` shows it.
  static func screenSize(portrait portraitSize: CGSize, orientation: RunnerInterfaceOrientation) -> CGSize {
    orientation.isLandscape ? CGSize(width: portraitSize.height, height: portraitSize.width) : portraitSize
  }

  /// Converts a point in the displayed orientation to the display's native portrait space, which the
  /// private event synthesizer takes: its record's interface orientation is not applied to the points.
  static func portraitPoint(_ point: CGPoint, from orientation: RunnerInterfaceOrientation, portraitSize size: CGSize) -> CGPoint {
    switch orientation {
    case .portraitUpsideDown: return CGPoint(x: size.width - point.x, y: size.height - point.y)
    // The top of the interface is the right edge of the portrait screen.
    case .landscapeRight: return CGPoint(x: size.width - point.y, y: point.x)
    // The top of the interface is the left edge of the portrait screen.
    case .landscapeLeft: return CGPoint(x: point.y, y: size.height - point.x)
    case .portrait: return point
    }
  }

  /// The inverse of `portraitPoint` for a rectangle: a rectangle in the native portrait space of a display
  /// of `portraitSize` points, in the displayed orientation.
  static func interfaceRect(fromPortrait rect: CGRect, orientation: RunnerInterfaceOrientation, portraitSize size: CGSize) -> CGRect {
    switch orientation {
    case .portrait:
      return rect
    case .portraitUpsideDown:
      return CGRect(x: size.width - rect.maxX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    case .landscapeRight:
      return CGRect(x: rect.minY, y: size.width - rect.maxX, width: rect.height, height: rect.width)
    case .landscapeLeft:
      return CGRect(x: size.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
    }
  }

  /// `root` (an app's snapshot, whose children are its windows) limited to `display` and in the displayed
  /// orientation, for devices with more than one display.
  ///
  /// SpringBoard has windows on every display, and those of the dark display would match selectors at
  /// points of the lit one, so windows whose display ID (`windowDisplayIDs`, one per child; nil when
  /// unknown) names another display are dropped. Apps that rotate report frames in the displayed
  /// orientation, but SpringBoard and apps that stay portrait (shown rotated, as iPhone apps are on the
  /// landscape inner display of iPhone Duo) report a portrait window and frames in the display's native
  /// portrait space; those are converted, so every frame is in the same space as `/tap` and `/screenshot`.
  static func tree(
    _ root: RunnerElementNode,
    windowDisplayIDs: [Int?],
    display: RunnerDisplay,
    orientation: RunnerInterfaceOrientation
  ) -> RunnerElementNode {
    var result = root
    result.children = root.children.indices.compactMap { index in
      let window = root.children[index]
      let id = index < windowDisplayIDs.count ? windowDisplayIDs[index] : nil
      guard id == nil || id == display.id else { return nil }
      return isPortrait(window.frame, in: orientation) ? converted(window, orientation: orientation, portraitSize: display.size) : window
    }
    // The app element spans its display, except SpringBoard's, which is the main display's whichever is lit.
    if isPortrait(root.frame, in: orientation), root.frame.size == display.size {
      result.frame = interfaceRect(fromPortrait: root.frame, orientation: orientation, portraitSize: display.size)
    }
    return result
  }

  /// A portrait frame while the interface is landscape: one in the native portrait space.
  static func isPortrait(_ frame: CGRect, in orientation: RunnerInterfaceOrientation) -> Bool {
    orientation.isLandscape && frame.height > frame.width
  }

  private static func converted(_ node: RunnerElementNode, orientation: RunnerInterfaceOrientation, portraitSize: CGSize) -> RunnerElementNode {
    var node = node
    node.frame = interfaceRect(fromPortrait: node.frame, orientation: orientation, portraitSize: portraitSize)
    node.children = node.children.map { converted($0, orientation: orientation, portraitSize: portraitSize) }
    return node
  }

  /// Why a command can't tell which display to act on, for the 422 of touches and the note of `/health`.
  static func unknownDisplayMessage(bundleID: String, displays: [RunnerDisplay]) -> String {
    "cannot tell which display \(bundleID) is on (displays \(displays.map { String($0.id) }.joined(separator: ", "))): "
      + "its windows name none of them and not exactly one display is lit; nothing was sent"
  }

  private static func portrait(_ size: CGSize) -> CGSize {
    CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
  }
}
