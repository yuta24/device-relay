import Foundation

enum Bench {
    static func run(_ options: BenchOptions) throws {
        // A session's runner.json only: the search below could find another runner's.
        let sessionURL = try sessionInfoURL(options)
        let sessionInfo = try sessionURL.map { try RunnerInfo.read(from: $0) }
        let url = options.url.isEmpty ? (sessionInfo?.url ?? "") : options.url
        guard let baseURL = URL(string: url), !url.isEmpty else {
            throw ArgumentError(description: "invalid --url: \(url)")
        }
        let client = RunnerClient(baseURL: baseURL, token: try token(options, infoURL: sessionURL))

        var cases: [(name: String, request: () throws -> RunnerResponse)] = [
            ("GET /health", { try client.get("/health") }),
            ("GET /screenshot (png)", { try client.get("/screenshot") }),
            ("GET /screenshot (jpeg q=0.5)", { try client.get("/screenshot?format=jpeg&quality=0.5") }),
            ("GET /screenshot (png scale=1)", { try client.get("/screenshot?scale=1") }),
            ("GET /screenshot (jpeg 1024px)", { try client.get("/screenshot?format=jpeg&maxSize=1024") })
        ]
        if let tap = options.tap {
            var body: [String: Any] = ["x": tap.x, "y": tap.y]
            body["mode"] = options.mode
            cases.append(("POST /tap (\(options.mode ?? "auto"))", { try client.post("/tap", json: body) }))
        }

        print("runner: \(baseURL.absoluteString)  iterations: \(options.count)")
        print("name".padding(toLength: 30, withPad: " ", startingAt: 0) + "   min    p50    p90    max  bytes")
        for benchCase in cases {
            var samples: [Double] = []
            var bytes = 0
            for _ in 0..<options.count {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let response = try benchCase.request()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                guard response.status == 200 else {
                    let body = String(decoding: response.body.prefix(300), as: UTF8.self)
                    throw SetupError(description: "\(benchCase.name) returned \(response.status): \(body)")
                }
                bytes = response.body.count
            }
            print(format(benchCase.name, samples: samples, bytes: bytes))
        }
    }

    /// The runner.json of `--session` or `$RELAY_SESSION`, unless `--runner`-like `$RELAY_RUNNER` is what selects
    /// the runner (`RunnerLocator.selection`); nil without a session. Nothing is read with both `--url` and `--token`.
    static func sessionInfoURL(_ options: BenchOptions, environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = UserHome.url) throws -> URL? {
        guard options.url.isEmpty || options.token == nil,
              case .session = try RunnerLocator.selection(explicitPath: nil, session: options.session, environment: environment) else {
            return nil
        }
        return try RunnerLocator.locate(explicitPath: nil, session: options.session, environment: environment, home: home)
    }

    /// `--token`, or the token `relay start` saved in the runner.json the runner commands find (`RunnerLocator`).
    static func token(_ options: BenchOptions, infoURL: URL? = nil) throws -> String {
        if let token = options.token {
            return token
        }
        let infoURL = infoURL ?? (try? RunnerLocator.locate(explicitPath: nil)) ?? RunnerLocator.userURL()
        guard let info = try? RunnerInfo.read(from: infoURL) else {
            throw SetupError(description: "no runner token: pass --token or start the runner with relay start (reads \(infoURL.path))")
        }
        return info.token
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func format(_ name: String, samples: [Double], bytes: Int) -> String {
        let sorted = samples.sorted()
        let columns = [sorted.first ?? 0, percentile(sorted, 0.5), percentile(sorted, 0.9), sorted.last ?? 0]
            .map { String(format: "%6.0f", $0) }
            .joined(separator: " ")
        return name.padding(toLength: 30, withPad: " ", startingAt: 0) + columns + "  \(bytes)"
    }
}
