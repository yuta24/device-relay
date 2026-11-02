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

    /// Why the point `x`, `y` of a `/tap`, `/press`, or `/swipe` field (`name`: `x`/`y`, `from`, `to`) is
    /// outside `screen` (points in the displayed orientation, as `/health` reports it), or nil when it is
    /// inside. A point is inside when 0 <= x < width and 0 <= y < height: the last point row and column
    /// start at width - 1 and height - 1, so `width` itself is past the edge. Such a touch reaches nothing,
    /// so the runner answers 400 and sends nothing rather than report a success that did nothing.
    static func pointOutsideScreen(_ name: String, x: Double, y: Double, screen: CGSize, orientation: String) -> String? {
        let width = Double(screen.width), height = Double(screen.height)
        guard width > 0, height > 0 else { return nil }
        guard !((0..<width).contains(x) && (0..<height).contains(y)) else { return nil }
        return "\(name): (\(decimal(CGFloat(x))), \(decimal(CGFloat(y)))) is outside the screen, "
            + "which is \(decimal(screen.width))x\(decimal(screen.height)) points in \(orientation) "
            + "(0 <= x < \(decimal(screen.width)), 0 <= y < \(decimal(screen.height)); relay health shows the screen)"
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
