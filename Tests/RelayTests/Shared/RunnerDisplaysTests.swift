import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerDisplaysTests {
  /// iPhone Duo (iOS 27.2 simulator): the cover display is main, 1398x2034 px; the inner one 2007x2853 px.
  static let screens = [
    RunnerDisplays.Screen(id: 1, pixels: CGSize(width: 1398, height: 2034), isMain: true),
    RunnerDisplays.Screen(id: 3, pixels: CGSize(width: 2007, height: 2853), isMain: false)
  ]
  static let cover = RunnerDisplay(id: 1, size: CGSize(width: 466, height: 678), scale: 3, isMain: true)
  static let inner = RunnerDisplay(id: 3, size: CGSize(width: 669, height: 951), scale: 3, isMain: false)

  @Test func listsDisplaysInPortraitPointsWithTheMainScale() throws {
    let displays = try #require(RunnerDisplays.displays(Self.screens, mainPortraitPoints: CGSize(width: 466, height: 678)))
    #expect(displays == [Self.cover, Self.inner])
    // SpringBoard's frame may be landscape (iPad), and a screen's pixels too; both are normalized.
    let rotated = [RunnerDisplays.Screen(id: 1, pixels: CGSize(width: 2034, height: 1398), isMain: true)]
    #expect(RunnerDisplays.displays(rotated, mainPortraitPoints: CGSize(width: 678, height: 466)) == [Self.cover])
    #expect(Self.inner.json["width"] as? CGFloat == 669)
    #expect(Self.inner.json["main"] as? Bool == false)
  }

  @Test func leavesOutWirelessDisplays() throws {
    // An iPhone 14 Pro listed an AirPlay display (1889x4096 px) next to its own: it has one display.
    let screens = [
      RunnerDisplays.Screen(id: 1, pixels: CGSize(width: 1179, height: 2556), isMain: true),
      RunnerDisplays.Screen(id: 2, pixels: CGSize(width: 1889, height: 4096), isMain: false, isIntegrated: false)
    ]
    let displays = try #require(RunnerDisplays.displays(screens, mainPortraitPoints: CGSize(width: 393, height: 852)))
    #expect(displays == [RunnerDisplay(id: 1, size: CGSize(width: 393, height: 852), scale: 3, isMain: true)])
    // A wireless main display leaves no display of the device to act on.
    let wirelessMain = [RunnerDisplays.Screen(id: 2, pixels: CGSize(width: 1889, height: 4096), isMain: true, isIntegrated: false)]
    #expect(RunnerDisplays.displays(wirelessMain, mainPortraitPoints: CGSize(width: 393, height: 852)) == nil)
  }

  @Test func refusesScreensWithoutOneMainOrWithAnEmptySize() {
    let points = CGSize(width: 466, height: 678)
    #expect(RunnerDisplays.displays([], mainPortraitPoints: points) == nil)
    #expect(RunnerDisplays.displays([Self.screens[1]], mainPortraitPoints: points) == nil)
    let twoMains = [Self.screens[0], RunnerDisplays.Screen(id: 3, pixels: CGSize(width: 2007, height: 2853), isMain: true)]
    #expect(RunnerDisplays.displays(twoMains, mainPortraitPoints: points) == nil)
    let empty = [Self.screens[0], RunnerDisplays.Screen(id: 3, pixels: .zero, isMain: false)]
    #expect(RunnerDisplays.displays(empty, mainPortraitPoints: points) == nil)
    #expect(RunnerDisplays.displays(Self.screens, mainPortraitPoints: .zero) == nil)
  }

  @Test func keepsOnlyAListAndAnXcodeWithoutTheFields() {
    let points = CGSize(width: 466, height: 678)
    let read = Self.screens.map { RunnerDisplays.ScreenReading.screen($0) }
    let listed = RunnerDisplays.displays(reading: read, mainPortraitPoints: points)
    #expect(listed.displays == [Self.cover, Self.inner] && listed.keep)
    // An Xcode without the private fields never lists them: one display, for the whole session.
    let unsupported = RunnerDisplays.displays(reading: [.unsupported, .unsupported], mainPortraitPoints: points)
    #expect(unsupported.displays.isEmpty && unsupported.keep)
    #expect(RunnerDisplays.displays(reading: [read[0], .unreadable, .unsupported], mainPortraitPoints: points).keep)
  }

  @Test func readsAgainAfterAnIssueOrAnUnreadableScreen() {
    let points = CGSize(width: 466, height: 678)
    let read = Self.screens.map { RunnerDisplays.ScreenReading.screen($0) }
    // An XCTest issue, one screen whose values can't be read, or values that make no display list.
    for screens in [nil, [read[0], .unreadable], [], [read[1]]] as [[RunnerDisplays.ScreenReading]?] {
      let result = RunnerDisplays.displays(reading: screens, mainPortraitPoints: points)
      #expect(result.displays.isEmpty && !result.keep)
    }
    #expect(!RunnerDisplays.displays(reading: read, mainPortraitPoints: .zero).keep)
  }

  @Test func findsTheDisplayOfTheFirstWindowThatNamesOne() {
    let displays = [Self.cover, Self.inner]
    #expect(RunnerDisplays.windowDisplay([3], in: displays) == Self.inner)
    // The app element itself reports 0, and unknown IDs are skipped.
    #expect(RunnerDisplays.windowDisplay([nil, 0, 1, 3], in: displays) == Self.cover)
    #expect(RunnerDisplays.windowDisplay([nil, 0, 7], in: displays) == nil)
    #expect(RunnerDisplays.windowDisplay([], in: displays) == nil)
  }

  @Test func picksTheOnlyLitDisplay() {
    #expect(RunnerDisplays.litDisplay([(Self.cover, true), (Self.inner, false)]) == Self.inner)
    #expect(RunnerDisplays.litDisplay([(Self.cover, false), (Self.inner, true)]) == Self.cover)
    // All dark (locked, asleep) or several lit: no answer rather than a guess.
    #expect(RunnerDisplays.litDisplay([(Self.cover, true), (Self.inner, true)]) == nil)
    #expect(RunnerDisplays.litDisplay([(Self.cover, false), (Self.inner, false)]) == nil)
    #expect(RunnerDisplays.litDisplay([]) == nil)
  }

  @Test func blankIsNoChannelAboveTheThreshold() {
    #expect(RunnerDisplays.isBlank(rgba: [0, 0, 0, 255, 8, 8, 8, 255]))
    #expect(!RunnerDisplays.isBlank(rgba: [0, 0, 0, 255, 0, 0, 9, 255]))
    // Alpha alone doesn't count.
    #expect(RunnerDisplays.isBlank(rgba: [0, 0, 0, 0, 0, 0, 0, 200]))
    #expect(RunnerDisplays.isBlank(rgba: []))
  }

  @Test func screenSizeSwapsInLandscape() {
    #expect(RunnerDisplays.screenSize(portrait: Self.inner.size, orientation: .landscapeLeft) == CGSize(width: 951, height: 669))
    #expect(RunnerDisplays.screenSize(portrait: Self.inner.size, orientation: .portraitUpsideDown) == Self.inner.size)
  }

  @Test func portraitPointMatchesTheSynthesizerSpace() {
    let size = CGSize(width: 402, height: 874)
    #expect(RunnerDisplays.portraitPoint(CGPoint(x: 10, y: 20), from: .portrait, portraitSize: size) == CGPoint(x: 10, y: 20))
    #expect(RunnerDisplays.portraitPoint(CGPoint(x: 10, y: 20), from: .portraitUpsideDown, portraitSize: size) == CGPoint(x: 392, y: 854))
    #expect(RunnerDisplays.portraitPoint(CGPoint(x: 10, y: 20), from: .landscapeRight, portraitSize: size) == CGPoint(x: 382, y: 10))
    #expect(RunnerDisplays.portraitPoint(CGPoint(x: 10, y: 20), from: .landscapeLeft, portraitSize: size) == CGPoint(x: 20, y: 864))
    // The inner display of iPhone Duo is landscapeLeft: Settings' Accessibility row at (160, 332) was hit at
    // (332, 791) in its portrait points.
    #expect(RunnerDisplays.portraitPoint(CGPoint(x: 160, y: 332), from: .landscapeLeft, portraitSize: Self.inner.size)
      == CGPoint(x: 332, y: 791))
  }

  @Test func interfaceRectInvertsPortraitPoint() {
    let size = Self.inner.size
    let rect = CGRect(x: 52, y: 419, width: 87, height: 64)
    for orientation in [RunnerInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
      let converted = RunnerDisplays.interfaceRect(fromPortrait: rect, orientation: orientation, portraitSize: size)
      #expect(converted.width * converted.height == rect.width * rect.height)
      // Both corners map back onto the corners of the original rectangle.
      let corners = [CGPoint(x: converted.minX, y: converted.minY), CGPoint(x: converted.maxX, y: converted.maxY)]
        .map { RunnerDisplays.portraitPoint($0, from: orientation, portraitSize: size) }
      let back = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                        width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y))
      #expect(back == rect)
    }
    // SpringBoard's Fitness icon on the inner display, shown at about (500, 85) in landscape.
    #expect(RunnerDisplays.interfaceRect(fromPortrait: rect, orientation: .landscapeLeft, portraitSize: size)
      == CGRect(x: 468, y: 52, width: 64, height: 87))
  }

  static func node(_ type: String, _ frame: CGRect, _ children: [RunnerElementNode] = []) -> RunnerElementNode {
    RunnerElementNode(type: type, identifier: "", label: "", value: nil, placeholder: nil, frame: frame,
                      enabled: true, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children)
  }

  @Test func treeKeepsTheDisplaysWindowsInTheDisplayedOrientation() {
    // SpringBoard with the inner display lit in landscape: a cover window, an inner window (portrait, with
    // frames in the display's portrait points), and a window whose display is unknown.
    let icon = Self.node("icon", CGRect(x: 52, y: 419, width: 87, height: 64))
    let root = Self.node("application", CGRect(x: 0, y: 0, width: 466, height: 678), [
      Self.node("window", CGRect(x: 0, y: 0, width: 466, height: 678)),
      Self.node("window", CGRect(x: 0, y: 0, width: 669, height: 951), [icon]),
      Self.node("window", CGRect(x: 0, y: 0, width: 951, height: 669))
    ])
    let tree = RunnerDisplays.tree(root, windowDisplayIDs: [1, 3], display: Self.inner, orientation: .landscapeLeft)
    #expect(tree.children.map(\.frame) == [CGRect(x: 0, y: 0, width: 951, height: 669), CGRect(x: 0, y: 0, width: 951, height: 669)])
    #expect(tree.children[0].children.map(\.frame) == [CGRect(x: 468, y: 52, width: 64, height: 87)])
    #expect(tree.frame == root.frame)
  }

  @Test func treeLeavesWindowsThatRotateAndPortraitInterfacesAlone() {
    // Settings rotates with the inner display: its window and frames are already landscape.
    let row = Self.node("button", CGRect(x: 20, y: 306, width: 280, height: 52))
    let settings = Self.node("application", CGRect(x: 0, y: 0, width: 669, height: 951), [
      Self.node("window", CGRect(x: 0, y: 0, width: 951, height: 669), [row])
    ])
    let tree = RunnerDisplays.tree(settings, windowDisplayIDs: [3], display: Self.inner, orientation: .landscapeLeft)
    #expect(tree.children[0].children[0].frame == row.frame)
    #expect(tree.frame == CGRect(x: 0, y: 0, width: 951, height: 669))
    // On the cover display in portrait nothing is converted, and the inner windows are dropped.
    let springboard = Self.node("application", CGRect(x: 0, y: 0, width: 466, height: 678), [
      Self.node("window", CGRect(x: 0, y: 0, width: 466, height: 678), [row]),
      Self.node("window", CGRect(x: 0, y: 0, width: 669, height: 951), [row])
    ])
    let cover = RunnerDisplays.tree(springboard, windowDisplayIDs: [1, 3], display: Self.cover, orientation: .portrait)
    #expect(cover.children.count == 1)
    #expect(cover.children[0].children[0].frame == row.frame)
    #expect(cover.frame == springboard.frame)
  }

  @Test func unknownDisplayMessageNamesTheAppAndDisplays() {
    let message = RunnerDisplays.unknownDisplayMessage(bundleID: "com.apple.springboard", displays: [Self.cover, Self.inner])
    #expect(message.hasPrefix("cannot tell which display com.apple.springboard is on (displays 1, 3)"))
    #expect(message.hasSuffix("nothing was sent"))
  }
}
