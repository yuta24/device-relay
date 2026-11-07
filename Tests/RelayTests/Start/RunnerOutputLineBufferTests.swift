import Foundation
@testable import Relay
import Testing

struct RunnerOutputLineBufferTests {
    @Test func splitsOnNewlines() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("one\ntwo\n\nthr".utf8)) == ["one", "two", ""])
        #expect(buffer.append(Data("ee\n".utf8)) == ["three"])
        #expect(buffer.finish() == nil)
    }

    @Test func stripsCarriageReturnsOfCRLF() {
        var buffer = RunnerOutputLineBuffer()
        let lines = buffer.append(Data("RELAY_RUNNER_READY port=8100 addresses=en0=10.0.0.2\r\n** TEST EXECUTE FAILED **\r\r\n".utf8))
        #expect(lines == ["RELAY_RUNNER_READY port=8100 addresses=en0=10.0.0.2", "** TEST EXECUTE FAILED **"])
        #expect(RunnerLauncher.parseReadyLine(lines[0]) == ["10.0.0.2"])
        #expect(RunnerLauncher.startupFailure(in: lines[1])?.message == "** TEST EXECUTE FAILED **")
    }

    @Test func handlesCRLFSplitAcrossChunks() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("relay-runner GET /health -> 200 1ms\r".utf8)).isEmpty)
        #expect(buffer.append(Data("\nnext".utf8)) == ["relay-runner GET /health -> 200 1ms"])
    }

    @Test func keepsLoneCarriageReturnsInsideALine() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("a\rb\n".utf8)) == ["a\rb"])
    }

    @Test func decodesMultibyteCharactersSplitAcrossChunks() {
        var buffer = RunnerOutputLineBuffer()
        let bytes = Array("ログ🎉\r\n".utf8)
        // Cut inside the 3-byte "グ" and inside the 4-byte emoji.
        #expect(buffer.append(Data(bytes[..<4])).isEmpty)
        #expect(buffer.append(Data(bytes[4..<8])).isEmpty)
        #expect(buffer.append(Data(bytes[8...])) == ["ログ🎉"])
    }

    @Test func emitsTheUnterminatedLastLineOnFinish() {
        var buffer = RunnerOutputLineBuffer()
        #expect(buffer.append(Data("done\r\n** TEST EXECUTE SUCCEEDED **\r".utf8)) == ["done"])
        #expect(buffer.finish() == "** TEST EXECUTE SUCCEEDED **")
        #expect(buffer.finish() == nil)
    }

    @Test func cutsLinesLongerThanTheLimit() {
        var buffer = RunnerOutputLineBuffer(maxLineLength: 8)
        #expect(buffer.append(Data("abcdefghij".utf8)) == ["abcdefgh"])
        #expect(buffer.append(Data("klmnopqrst".utf8)) == ["ijklmnop"])
        #expect(buffer.append(Data("u\n".utf8)) == ["qrstu"])
    }

    @Test func neverCutsInsideAMultibyteCharacter() {
        var buffer = RunnerOutputLineBuffer(maxLineLength: 8)
        // "グ" occupies bytes 6..<9, so the first piece stops before it.
        #expect(buffer.append(Data("abcdefグhi".utf8)) == ["abcdef"])
        #expect(buffer.append(Data("\n".utf8)) == ["グhi"])
    }
}
