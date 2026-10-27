import Foundation

enum Bench {
    static func run(_ options: BenchOptions) throws {
        guard let baseURL = URL(string: options.url) else {
            throw ArgumentError(description: "invalid --url: \(options.url)")
        }
        let client = RunnerClient(baseURL: baseURL)

        var cases: [(name: String, request: () throws -> RunnerResponse)] = [
            ("GET /health", { try client.get("/health") }),
            ("GET /screenshot (png)", { try client.get("/screenshot") }),
            ("GET /screenshot (jpeg q=0.5)", { try client.get("/screenshot?format=jpeg&quality=0.5") })
        ]
        if let tap = options.tap {
            cases.append(("POST /tap", { try client.post("/tap", json: ["x": tap.x, "y": tap.y]) }))
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
                    throw ArgumentError(description: "\(benchCase.name) returned \(response.status): \(body)")
                }
                bytes = response.body.count
            }
            print(format(benchCase.name, samples: samples, bytes: bytes))
        }
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
