import Foundation

struct RunnerResponse {
    let status: Int
    let body: Data
}

/// Small synchronous HTTP client for the on-device runner.
struct RunnerClient {
    let baseURL: URL
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
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .success(RunnerResponse(status: status, body: data ?? Data()))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
