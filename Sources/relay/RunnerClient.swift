import Foundation

struct RunnerResponse {
    let status: Int
    let body: Data
    /// As URLSession reports them; the case of the names may differ from what the runner sent.
    var headers: [String: String] = [:]
}

/// Why a request got no answer from the runner, for the `relay:` lines.
enum RunnerConnectionError {
    /// What follows "cannot reach the runner" when the OS refused the connection: relay itself is not
    /// allowed to connect, so the runner may well be running.
    static let refusedByOSHint = "the OS refused the connection (Operation not permitted); relay may be running inside a sandbox "
        + "(an AI agent's, for example) that blocks localhost. Run relay outside the sandbox or let it connect to localhost; "
        + "see the sandbox section of docs/setup.md in device-relay"

    /// Whether the connection was refused by this Mac (EPERM), not by the other end. A sandbox that blocks
    /// localhost, such as macOS Seatbelt in an agent's sandbox, fails `connect()` with EPERM, which URLSession
    /// reports as `NSPOSIXErrorDomain` 1, or as an `NSURLErrorDomain` error whose CFStream fields or
    /// underlying error say so. Nothing listening (ECONNREFUSED, 61) and timeouts are not.
    static func isRefusedByOS(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) {
            return true
        }
        // kCFStreamErrorDomainPOSIX is 1.
        if (error.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.intValue == 1,
           (error.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue == Int(EPERM) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRefusedByOS(underlying)
        }
        return false
    }
}

/// Small synchronous HTTP client for the on-device runner.
struct RunnerClient {
    let baseURL: URL
    /// Sent as `Authorization: Bearer <token>`; the runner answers 401 without it.
    var token: String?
    var timeout: TimeInterval = 30

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func get(_ path: String) throws -> RunnerResponse {
        try send(method: "GET", path: path, body: nil)
    }

    func post(_ path: String, json: [String: Any] = [:]) throws -> RunnerResponse {
        try send(method: "POST", path: path, body: JSONSerialization.data(withJSONObject: json))
    }

    private func send(method: String, path: String, body: Data?) throws -> RunnerResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ArgumentError(description: "invalid runner path: \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token {
            request.setValue(RunnerAuth.authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<RunnerResponse, Error> = .failure(URLError(.unknown))
        Self.session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for case let (name as String, value as String) in http?.allHeaderFields ?? [:] {
                    headers[name] = value
                }
                result = .success(RunnerResponse(status: http?.statusCode ?? 0, body: data ?? Data(), headers: headers))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
