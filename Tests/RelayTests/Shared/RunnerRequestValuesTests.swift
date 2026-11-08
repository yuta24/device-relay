import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerRequestValuesTests {
  @Test func pointsOnTheScreenPassAndOthersAreRejected() throws {
    let portrait = CGSize(width: 402, height: 874)
    func outside(_ x: Double, _ y: Double, _ screen: CGSize = portrait) -> String? {
      RunnerRequestValues.pointOutsideScreen("x, y", x: x, y: y, screen: screen, orientation: "portrait")
    }
    // 0 <= x < width, 0 <= y < height; fractions inside the last point are fine.
    for (x, y) in [(0.0, 0.0), (401.0, 873.0), (401.9, 873.9), (200, 120)] {
      #expect(outside(x, y) == nil)
    }
    for (x, y) in [(402.0, 100.0), (100.0, 874.0), (500.0, 500.0), (-1.0, 10.0), (10.0, -0.5)] {
      #expect(outside(x, y) != nil)
    }
    // The landscape screen swaps the bounds: (800, 100) is inside it but not inside portrait.
    let landscape = CGSize(width: 874, height: 402)
    #expect(outside(800, 100, landscape) == nil)
    #expect(outside(100, 800, landscape) != nil)
    #expect(outside(800, 100) != nil)
    let message = try #require(RunnerRequestValues.pointOutsideScreen("to", x: 900, y: 100.5, screen: landscape, orientation: "landscapeLeft"))
    #expect(message == "to: (900, 100.5) is outside the screen, which is 874x402 points in landscapeLeft "
      + "(0 <= x < 874, 0 <= y < 402; relay health shows the screen)")
    // An unknown (empty) screen rejects nothing.
    #expect(outside(5000, 5000, .zero) == nil)
  }

  private func number(fromJSON text: String) throws -> Double? {
    let object = try JSONSerialization.jsonObject(with: Data("{\"v\":\(text)}".utf8)) as? [String: Any]
    return try RunnerRequestValues.number(#require(object?["v"]))
  }

  @Test func acceptsJSONNumbers() throws {
    #expect(try number(fromJSON: "1") == 1)
    #expect(try number(fromJSON: "0") == 0)
    #expect(try number(fromJSON: "12.5") == 12.5)
    #expect(try number(fromJSON: "-3") == -3)
  }

  /// `{"x": true, "y": 1}` used to be read as a tap at (1, 1).
  @Test func rejectsBooleansAndNonNumbers() throws {
    #expect(try number(fromJSON: "true") == nil)
    #expect(try number(fromJSON: "false") == nil)
    #expect(try number(fromJSON: "\"1\"") == nil)
    #expect(try number(fromJSON: "null") == nil)
    #expect(try number(fromJSON: "[1]") == nil)
  }

  @Test func jpegQualityDefaultsWhenAbsent() {
    #expect(RunnerRequestValues.jpegQuality(nil) == RunnerRequestValues.defaultJPEGQuality)
  }

  @Test func acceptsJPEGQualityInRange() {
    #expect(RunnerRequestValues.jpegQuality("0.05") == 0.05)
    #expect(RunnerRequestValues.jpegQuality("0.5") == 0.5)
    #expect(RunnerRequestValues.jpegQuality("1") == 1)
  }

  /// Unparsable values used to fall back to 0.7, and out-of-range ones were clamped.
  @Test func rejectsInvalidJPEGQuality() {
    for value in ["abc", "", " 0.5", "0", "0.04", "1.01", "2.0", "-0.5", "nan", "inf"] {
      #expect(RunnerRequestValues.jpegQuality(value) == nil, "\(value)")
    }
  }

  @Test func parsesScreenshotSizeQueries() {
    #expect(RunnerRequestValues.screenshotMaxSize("1024") == 1024)
    #expect(RunnerRequestValues.screenshotMaxSize("16") == 16)
    for value in ["15", "0", "-1", "1.5", "", "abc"] {
      #expect(RunnerRequestValues.screenshotMaxSize(value) == nil, "\(value)")
    }
    #expect(RunnerRequestValues.screenshotScale("1") == 1)
    #expect(RunnerRequestValues.screenshotScale("0.1") == 0.1)
    #expect(RunnerRequestValues.screenshotScale("10") == 10)
    for value in ["0", "0.09", "10.5", "-1", "", "nan", "inf"] {
      #expect(RunnerRequestValues.screenshotScale(value) == nil, "\(value)")
    }
  }

  /// iPhone 17 Pro: 1206x2622 pixels, 402x874 points at 3x.
  private let portrait = CGSize(width: 1206, height: 2622)

  @Test func shrinksScreenshotsToTheLongerEdge() {
    #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: 1024, scale: nil)
      == CGSize(width: 471, height: 1024))
    // Landscape keeps the same pixels per point.
    #expect(RunnerRequestValues.screenshotSize(pixels: CGSize(width: 2622, height: 1206), screenScale: 3, maxSize: 1024, scale: nil)
      == CGSize(width: 1024, height: 471))
  }

  @Test func shrinksScreenshotsToPixelsPerPoint() {
    #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: nil, scale: 1)
      == CGSize(width: 402, height: 874))
    #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: nil, scale: 1.5)
      == CGSize(width: 603, height: 1311))
    // Both: the smaller one wins.
    #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: 600, scale: 1)
      == CGSize(width: 276, height: 600))
    #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: 2000, scale: 1)
      == CGSize(width: 402, height: 874))
  }

  @Test func neverEnlargesScreenshots() {
    for (maxSize, scale) in [(nil, nil), (2622, nil), (5000, nil), (nil, 3.0), (nil, 4.0), (4000, 5.0)] as [(Int?, Double?)] {
      #expect(RunnerRequestValues.screenshotSize(pixels: portrait, screenScale: 3, maxSize: maxSize, scale: scale) == portrait,
              "\(String(describing: maxSize)) \(String(describing: scale))")
    }
  }

  @Test func describesScreenshotsInHeaders() {
    let headers = RunnerRequestValues.screenshotHeaders(image: CGSize(width: 471, height: 1024), screen: CGSize(width: 402, height: 874))
    #expect(headers == [
      "X-Relay-Image-Width": "471", "X-Relay-Image-Height": "1024",
      "X-Relay-Screen-Width": "402", "X-Relay-Screen-Height": "874", "X-Relay-Image-Scale": "1.172"
    ])
    let full = RunnerRequestValues.screenshotHeaders(image: CGSize(width: 2622, height: 1206), screen: CGSize(width: 874, height: 402))
    #expect(full["X-Relay-Image-Scale"] == "3")
  }
}
