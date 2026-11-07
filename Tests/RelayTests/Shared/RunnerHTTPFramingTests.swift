import Foundation
@testable import Relay
import Testing

struct RunnerHTTPFramingTests {
    private func parse(_ text: String) -> RunnerHTTPFraming.Result {
        RunnerHTTPFraming.parseHead(Data(text.utf8))
    }

    private func status(_ text: String) -> Int? {
        if case .failure(let failure) = parse(text) { return failure.status }
        return nil
    }

    @Test func parsesHeadAndBodyOffset() {
        let text = "POST /tap?x=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 7\r\nAuthorization: Bearer t\r\n\r\n{\"a\":1}"
        guard case .head(let head, let headerLength) = parse(text) else {
            Issue.record("expected a head")
            return
        }
        #expect(head.method == "POST")
        #expect(head.target == "/tap?x=1")
        #expect(head.contentLength == 7)
        #expect(head.headers["authorization"] == "Bearer t")
        #expect(headerLength == text.utf8.count - 7)
    }

    @Test func missingContentLengthMeansNoBody() {
        guard case .head(let head, _) = parse("GET /health HTTP/1.1\r\nHost: x\r\n\r\n") else {
            Issue.record("expected a head")
            return
        }
        #expect(head.contentLength == 0)
    }

    @Test func waitsForTheBlankLine() {
        #expect(parse("GET /health HTTP/1.1\r\nHost: x\r\n") == .incomplete)
        #expect(parse("") == .incomplete)
    }

    /// `Content-Length: -1` used to pass `Int(_:)` and crash the runner with an invalid range.
    @Test func rejectsNegativeAndNonNumericContentLength() {
        for value in ["-1", "+5", "abc", "", "1.5", "0x10", " 5 5", "99999999999999999999999"] {
            #expect(status("POST /tap HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n") == 400, "\(value)")
        }
    }

    @Test func rejectsConflictingContentLengths() {
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n") == 400)
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: 5, 6\r\n\r\n") == 400)
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: 5,\r\n\r\n") == 400)
    }

    @Test func acceptsRepeatedEqualContentLengths() {
        guard case .head(let head, _) = parse("POST /tap HTTP/1.1\r\nContent-Length: 5\r\ncontent-length: 5, 5\r\n\r\n") else {
            Issue.record("expected a head")
            return
        }
        #expect(head.contentLength == 5)
    }

    @Test func rejectsOversizedBodiesUpFront() {
        let tooLarge = RunnerHTTPFraming.maxBodySize + 1
        #expect(status("POST /tap HTTP/1.1\r\nContent-Length: \(tooLarge)\r\n\r\n") == 413)
    }

    @Test func limitsTheHeadSize() {
        let filler = String(repeating: "a", count: RunnerHTTPFraming.maxHeaderSize)
        // Still waiting for the terminator, but already past the limit.
        #expect(status("GET / HTTP/1.1\r\nX: \(filler)") == 431)
        // Complete, but too large.
        #expect(status("GET / HTTP/1.1\r\nX: \(filler)\r\n\r\n") == 431)
        // Just under the limit is fine.
        let fits = String(repeating: "a", count: RunnerHTTPFraming.maxHeaderSize - 100)
        #expect(status("GET / HTTP/1.1\r\nX: \(fits)\r\n\r\n") == nil)
    }

    /// A chunked body used to be read as empty, and its bytes then parsed as the next request.
    @Test func rejectsTransferEncoding() {
        #expect(status("POST /tap HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n") == 501)
        #expect(status("POST /tap HTTP/1.1\r\ntransfer-encoding: identity\r\nContent-Length: 5\r\n\r\n") == 501)
        #expect(status("GET /health HTTP/1.1\r\nTransfer-Encoding: \r\n\r\n") == 501)
    }

    @Test func rejectsInvalidRequestLineAndEncoding() {
        #expect(status("GARBAGE\r\n\r\n") == 400)
        var bytes = Data("GET /\u{FF} HTTP/1.1\r\n\r\n".utf8)
        bytes[5] = 0xFF
        if case .failure(let failure) = RunnerHTTPFraming.parseHead(bytes) {
            #expect(failure.status == 400)
        } else {
            Issue.record("expected invalid UTF-8 to be rejected")
        }
    }
}
