import Foundation

/// Checks on request values that the runner can't leave to a cast.
///
/// Like `RunnerAuth.swift`, this file is compiled into both the `relay` CLI and the runner target so the
/// SwiftPM unit tests cover it.
enum RunnerRequestValues {
    static let jpegQualityRange = 0.05...1.0
    static let defaultJPEGQuality = 0.7

    /// The value of a JSON number, or nil for anything else. JSONSerialization returns `true`/`false` as
    /// NSNumber too, so booleans are told apart by their CF type.
    static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// The `quality` query value: the default when absent, nil when it isn't a number in `jpegQualityRange`.
    static func jpegQuality(_ value: String?) -> Double? {
        guard let value else { return defaultJPEGQuality }
        guard let quality = Double(value), jpegQualityRange.contains(quality) else { return nil }
        return quality
    }

    /// The smallest `maxSize`; anything smaller is too blurry to read.
    static let minScreenshotMaxSize = 16
    static let screenshotScaleRange = 0.1...10.0

    /// A `maxSize` query value (pixels of the longer edge): an integer of at least `minScreenshotMaxSize`.
    /// Nil when invalid.
    static func screenshotMaxSize(_ value: String) -> Int? {
        guard let size = Int(value), size >= minScreenshotMaxSize else { return nil }
        return size
    }

    /// A `scale` query value (image pixels per point, like `/health`'s `screen.scale`): a number in
    /// `screenshotScaleRange`. Nil when invalid.
    static func screenshotScale(_ value: String) -> Double? {
        guard let scale = Double(value), screenshotScaleRange.contains(scale) else { return nil }
        return scale
    }

    /// The size in pixels to encode a screenshot of `pixels` at, for a screen of `screenScale` pixels per
    /// point. `maxSize` caps the longer edge and `scale` the pixels per point; with both, the smaller wins.
    /// It never upscales, keeps the aspect ratio, and returns `pixels` itself when nothing shrinks.
    static func screenshotSize(pixels: CGSize, screenScale: CGFloat, maxSize: Int?, scale: Double?) -> CGSize {
        var factor: CGFloat = 1
        if let maxSize, max(pixels.width, pixels.height) > 0 {
            factor = min(factor, CGFloat(maxSize) / max(pixels.width, pixels.height))
        }
        if let scale, screenScale > 0 {
            factor = min(factor, CGFloat(scale) / screenScale)
        }
        guard factor < 1 else { return pixels }
        return CGSize(width: max(1, (pixels.width * factor).rounded()), height: max(1, (pixels.height * factor).rounded()))
    }

    /// Response headers of `/screenshot` that relate the image to the tap coordinates: its size in pixels,
    /// the screen in points in the displayed orientation (as `/health` reports it), and pixels per point.
    enum ScreenshotHeader {
        static let imageWidth = "X-Relay-Image-Width"
        static let imageHeight = "X-Relay-Image-Height"
        static let screenWidth = "X-Relay-Screen-Width"
        static let screenHeight = "X-Relay-Screen-Height"
        static let scale = "X-Relay-Image-Scale"
    }

    /// The `ScreenshotHeader` values for an image of `image` pixels of a screen of `screen` points.
    static func screenshotHeaders(image: CGSize, screen: CGSize) -> [String: String] {
        let scale = screen.width > 0 ? image.width / screen.width : 0
        return [
            ScreenshotHeader.imageWidth: decimal(image.width),
            ScreenshotHeader.imageHeight: decimal(image.height),
            ScreenshotHeader.screenWidth: decimal(screen.width),
            ScreenshotHeader.screenHeight: decimal(screen.height),
            ScreenshotHeader.scale: decimal(scale)
        ]
    }

    /// The shortest decimal of `value` rounded to 1/1000, like the frames of `/source` ("402", "1.172").
    static func decimal(_ value: CGFloat) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (Double(value) * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
