import Foundation

/// Parses the head of an HTTP/1.1 request for the on-device runner's server.
///
/// This runs before authentication, so it must reject anything malformed instead of trusting it.
/// Like `RunnerAuth.swift`, this file is compiled into both the `relay` CLI and the runner target so the
/// SwiftPM unit tests cover it.
enum RunnerHTTPFraming {
    /// Request line and headers. Anything larger is rejected before the terminator arrives.
    static let maxHeaderSize = 64 * 1024
    static let maxBodySize = 16 * 1024 * 1024

    static let headerTerminator = Data("\r\n\r\n".utf8)

    struct Head: Equatable {
        var method: String
        var target: String
        /// Lowercased names. When a header repeats, the last value wins (Content-Length is checked separately).
        var headers: [String: String]
        var contentLength: Int
    }

    struct Failure: Error, Equatable {
        var status: Int
        var code: RunnerErrorCode
        var message: String

        /// The response body.
        var json: [String: Any] { code.body(message) }
    }

    enum Result: Equatable {
        /// Wait for more bytes.
        case incomplete
        /// `headerLength` includes the blank line; the body starts right after it.
        case head(Head, headerLength: Int)
        /// Respond with the failure and close the connection.
        case failure(Failure)
    }

    static func parseHead(_ buffer: Data) -> Result {
        guard let terminator = buffer.range(of: headerTerminator) else {
            // Without the terminator the head is still growing; the terminator may be split across reads.
            return buffer.count > maxHeaderSize + headerTerminator.count - 1 ? .failure(headerTooLarge) : .incomplete
        }
        let headerLength = buffer.distance(from: buffer.startIndex, to: terminator.upperBound)
        guard headerLength <= maxHeaderSize else {
            return .failure(headerTooLarge)
        }
        guard let text = String(data: buffer[buffer.startIndex..<terminator.lowerBound], encoding: .utf8) else {
            return .failure(Failure(status: 400, code: .httpMalformed, message: "invalid request head"))
        }

        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            return .failure(Failure(status: 400, code: .httpMalformed, message: "invalid request line"))
        }
        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length" {
                // A list ("5, 5") counts as repeated headers (RFC 9110, section 8.6).
                contentLengths += value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        // Only Content-Length bodies are read. Treating a chunked body as empty would make its bytes
        // the next request on this connection, so any transfer coding is refused (RFC 9112, section 6.1).
        guard headers["transfer-encoding"] == nil else {
            return .failure(Failure(status: 501, code: .httpMalformed, message: "Transfer-Encoding is not supported"))
        }
        let contentLength: Int
        switch parseContentLength(contentLengths) {
        case .success(let length): contentLength = length
        case .failure(let failure): return .failure(failure)
        }
        let head = Head(
            method: String(requestLine[0]).uppercased(),
            target: String(requestLine[1]),
            headers: headers,
            contentLength: contentLength
        )
        return .head(head, headerLength: headerLength)
    }

    /// Every value must be plain decimal digits (no sign), and repeated values must agree.
    static func parseContentLength(_ values: [String]) -> Swift.Result<Int, Failure> {
        guard !values.isEmpty else { return .success(0) }
        let invalid = Failure(status: 400, code: .httpMalformed, message: "invalid Content-Length")
        var length: Int?
        for value in values {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                  let parsed = Int(value) else {
                return .failure(invalid)
            }
            if let length, length != parsed {
                return .failure(invalid)
            }
            length = parsed
        }
        guard let length, length <= maxBodySize else {
            return .failure(Failure(status: 413, code: .requestTooLarge, message: "request too large"))
        }
        return .success(length)
    }

    private static let headerTooLarge = Failure(status: 431, code: .requestTooLarge, message: "request header too large")
}
