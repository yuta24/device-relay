import Foundation
import Network

struct RunnerHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct RunnerHTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> RunnerHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return RunnerHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func error(_ message: String, status: Int) -> RunnerHTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }
}

/// Minimal HTTP/1.1 server on Network.framework. Supports keep-alive and Content-Length bodies only.
final class RunnerHTTPServer {
    typealias Handler = (RunnerHTTPRequest, @escaping (RunnerHTTPResponse) -> Void) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "relay.runner.http")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RunnerError.invalidField("port")
        }
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.handler = handler
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onReady()
            case .failed(let error):
                onFailure(error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue, handler] connection in
            RunnerHTTPConnection(connection: connection, queue: queue, handler: handler).start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }
}

private final class RunnerHTTPConnection {
    private static let maxRequestSize = 16 * 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: RunnerHTTPServer.Handler
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping RunnerHTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data {
                self.buffer.append(data)
            }
            if self.processBuffer() {
                return
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    /// Returns true when a request was dispatched; reading resumes after its response is sent.
    private func processBuffer() -> Bool {
        guard let headerEnd = buffer.range(of: Self.headerTerminator) else {
            if buffer.count > Self.maxRequestSize {
                send(.error("request too large", status: 413), keepAlive: false)
                return true
            }
            return false
        }
        guard let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            send(.error("invalid request head", status: 400), keepAlive: false)
            return true
        }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            send(.error("invalid request line", status: 400), keepAlive: false)
            return true
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= Self.maxRequestSize else {
            send(.error("request too large", status: 413), keepAlive: false)
            return true
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
            return false
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let request = RunnerHTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: body
        )
        let keepAlive = headers["connection"]?.lowercased() != "close"

        handler(request) { response in
            self.queue.async {
                self.send(response, keepAlive: keepAlive)
            }
        }
        return true
    }

    private func send(_ response: RunnerHTTPResponse, keepAlive: Bool) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)

        connection.send(content: data, completion: .contentProcessed { error in
            guard keepAlive, error == nil else {
                self.connection.cancel()
                return
            }
            if !self.processBuffer() {
                self.receive()
            }
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 501: return "Not Implemented"
        default: return "Internal Server Error"
        }
    }
}
