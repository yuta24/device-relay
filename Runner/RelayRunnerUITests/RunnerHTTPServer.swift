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
    /// Sent after the standard headers, such as the image size of `/screenshot`.
    var headers: [String: String] = [:]

    static func json(_ object: [String: Any], status: Int = 200) -> RunnerHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return RunnerHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func error(_ message: String, status: Int) -> RunnerHTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }
}

/// Minimal HTTP/1.1 server on Network.framework. Supports keep-alive and Content-Length bodies only.
///
/// Every request must carry `Authorization: Bearer <token>`. The server holds only the token's
/// normalized SHA-256 and compares the hash of the presented token against it. The check runs on the
/// HTTP queue as soon as the head is parsed, before the body is read and before the handler sees the request.
final class RunnerHTTPServer {
    typealias Handler = (RunnerHTTPRequest, @escaping (RunnerHTTPResponse) -> Void) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "relay.runner.http")
    private let tokenHash: String
    private let handler: Handler

    init(port: UInt16, tokenHash: String, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RunnerError.invalidField("port")
        }
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.tokenHash = tokenHash
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
        listener.newConnectionHandler = { [queue, tokenHash, handler] connection in
            RunnerHTTPConnection(connection: connection, queue: queue, tokenHash: tokenHash, handler: handler).start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }
}

private final class RunnerHTTPConnection {
    /// A request must arrive in full within this time of the connection opening or the previous
    /// response being sent; otherwise the connection is closed. The clock stops while a request runs.
    private static let requestTimeout: TimeInterval = 30

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let tokenHash: String
    private let handler: RunnerHTTPServer.Handler
    private var buffer = Data()
    private var requestDeadline: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, tokenHash: String, handler: @escaping RunnerHTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.tokenHash = tokenHash
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        armRequestDeadline()
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
                self.close()
                return
            }
            self.receive()
        }
    }

    /// Returns true when a request was dispatched or rejected; reading resumes after the response is sent.
    private func processBuffer() -> Bool {
        let head: RunnerHTTPFraming.Head
        let headerLength: Int
        switch RunnerHTTPFraming.parseHead(buffer) {
        case .incomplete:
            return false
        case .failure(let failure):
            reject(.error(failure.message, status: failure.status))
            return true
        case .head(let parsed, let length):
            head = parsed
            headerLength = length
        }
        // Before reading the body, so unauthenticated clients can't make the runner buffer it.
        guard RunnerAuth.isAuthorized(authorizationHeader: head.headers["authorization"], tokenHash: tokenHash) else {
            reject(.error("unauthorized", status: 401))
            return true
        }

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= head.contentLength else {
            return false
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: head.contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])

        let components = URLComponents(string: head.target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let request = RunnerHTTPRequest(
            method: head.method,
            path: components?.path ?? head.target,
            query: query,
            headers: head.headers,
            body: body
        )
        let keepAlive = head.headers["connection"]?.lowercased() != "close"

        cancelRequestDeadline()
        handler(request) { response in
            self.queue.async {
                self.send(response, keepAlive: keepAlive)
            }
        }
        return true
    }

    /// Answers and closes: the rest of the buffer can't be trusted to start at a request boundary.
    private func reject(_ response: RunnerHTTPResponse) {
        cancelRequestDeadline()
        buffer = Data()
        send(response, keepAlive: false)
    }

    private func armRequestDeadline() {
        cancelRequestDeadline()
        let deadline = DispatchWorkItem { [weak self] in
            self?.close()
        }
        requestDeadline = deadline
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: deadline)
    }

    private func cancelRequestDeadline() {
        requestDeadline?.cancel()
        requestDeadline = nil
    }

    private func close() {
        cancelRequestDeadline()
        connection.cancel()
    }

    private func send(_ response: RunnerHTTPResponse, keepAlive: Bool) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)

        connection.send(content: data, completion: .contentProcessed { error in
            guard keepAlive, error == nil else {
                self.close()
                return
            }
            self.armRequestDeadline()
            if !self.processBuffer() {
                self.receive()
            }
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 422: return "Unprocessable Entity"
        case 501: return "Not Implemented"
        default: return "Internal Server Error"
        }
    }
}
