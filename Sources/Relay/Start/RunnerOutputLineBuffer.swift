import Foundation

/// Splits xcodebuild's output into lines as it arrives in arbitrary chunks.
///
/// Splitting works on bytes, not on `String`: on a device xcodebuild ends lines with `\r\n`, which Swift
/// treats as a single `Character` that never equals `"\n"`. Decoding only complete lines also keeps a
/// multibyte UTF-8 character intact when a chunk boundary falls inside it.
struct RunnerOutputLineBuffer {
    /// A line longer than this is emitted in pieces, so output without newlines cannot grow without bound.
    static let defaultMaxLineLength = 64 * 1024

    let maxLineLength: Int
    private var pending = Data()

    init(maxLineLength: Int = defaultMaxLineLength) {
        precondition(maxLineLength >= 4, "a piece must fit one UTF-8 character")
        self.maxLineLength = maxLineLength
    }

    /// Appends a chunk and returns the lines it completed, without their terminators.
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Self.decode(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        while pending.count > maxLineLength {
            let end = Self.characterBoundary(in: pending, before: pending.startIndex + maxLineLength)
            lines.append(Self.decode(pending[pending.startIndex..<end]))
            pending.removeSubrange(pending.startIndex..<end)
        }
        return lines
    }

    /// Returns the unterminated last line, if any, once the output has ended.
    mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    /// Drops the `\r` of `\r\n`. A `\r` elsewhere stays: xcodebuild does not redraw lines with it.
    private static func decode(_ bytes: Data) -> String {
        var line = bytes
        while line.last == 0x0D {
            line.removeLast()
        }
        return String(decoding: line, as: UTF8.self)
    }

    /// Moves `index` back to the start of a UTF-8 character, so a long line is never cut inside one.
    private static func characterBoundary(in data: Data, before index: Data.Index) -> Data.Index {
        var boundary = index
        while boundary > data.startIndex, index - boundary < 3, data[boundary] & 0xC0 == 0x80 {
            boundary -= 1
        }
        return data[boundary] & 0xC0 == 0x80 ? index : boundary
    }
}
