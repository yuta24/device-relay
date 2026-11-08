import Foundation

enum Bench {
  static func run(_ options: BenchOptions) throws {
    let target = try resolveTarget(options)
    guard let baseURL = URL(string: target.url), !target.url.isEmpty else {
      throw ArgumentError(description: "invalid --url: \(target.url)")
    }
    let client = RunnerClient(baseURL: baseURL, token: target.token)

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
      for _ in 0 ..< options.count {
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

  /// The URL and token to measure: `--url` and `--token` when given, else those of the runner.json the other
  /// runner commands find (`RunnerLocator`: `--runner`, `--session`, `$RELAY_RUNNER`, `$RELAY_SESSION`,
  /// `~/.relay/runner.json`). Nothing is read with both `--url` and `--token`. Throws `RunnerUnavailableError`
  /// (exit 3) when the runner.json is needed and not there.
  static func resolveTarget(
    _ options: BenchOptions,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: URL = WorkingDirectory.url,
    home: URL = UserHome.url
  ) throws -> (url: String, token: String) {
    if !options.url.isEmpty, let token = options.token {
      return (options.url, token)
    }
    let infoURL: URL
    do {
      infoURL = try RunnerLocator.locate(explicitPath: options.runnerPath, session: options.session, environment: environment,
                                         currentDirectory: currentDirectory, home: home)
    } catch let error as RunnerUnavailableError where !options.url.isEmpty {
      throw RunnerUnavailableError(description: "\(error.description); or pass --token with --url")
    }
    let info = try RunnerInfo.read(from: infoURL)
    return (options.url.isEmpty ? info.url : options.url, options.token ?? info.token)
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
