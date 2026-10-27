import Foundation

// Line-buffer stdout so `ready: <url>` reaches pipes and files immediately, not only TTYs.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    switch try Arguments.parse(Array(CommandLine.arguments.dropFirst())) {
    case .start(let options):
        exit(try RunnerLauncher(options: options).run())
    case .bench(let options):
        try Bench.run(options)
    case .help:
        print(Arguments.usage)
    }
} catch {
    FileHandle.standardError.write(Data("relay: \(error)\n\n\(Arguments.usage)\n".utf8))
    exit(1)
}
