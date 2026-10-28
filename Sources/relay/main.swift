import Foundation

// Line-buffer stdout so `ready: <url>` reaches pipes and files immediately, not only TTYs.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch try Arguments.parse(arguments) {
    case .start(let options):
        exit(try RunnerLauncher(options: options).run())
    case .bench(let options):
        try Bench.run(options)
    case .runner(let options):
        exit(RunnerControl.run(options))
    case .help:
        print(Arguments.usage)
    case .commandHelp(let name):
        print(Arguments.usage(for: name))
    }
} catch {
    FileHandle.standardError.write(Data("relay: \(error)\n\n\(Arguments.errorUsage(for: arguments.first))\n".utf8))
    exit(1)
}
