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
}
