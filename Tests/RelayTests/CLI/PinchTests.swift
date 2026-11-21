import Foundation
@testable import Relay
import Testing

struct PinchTests {
  private func operation(_ args: [String]) throws -> RunnerOperation {
    guard case .runner(let options) = try Arguments.parse(["pinch"] + args) else { throw RunnerPinch.Invalid("expected runner") }
    return options.operation
  }

  @Test func argumentsRequestsAliasesAndScenario() throws {
    let op = try operation(["201", "500", "--scale=2", "--radius=50", "--duration=0.6", "--mode=private"])
    #expect(op.commandName == "pinch")
    #expect(op.request.path == "/pinch")
    #expect(op.request.method == "POST")
    #expect(op.request.body?["x"] as? Double == 201)
    #expect(op.request.body?["scale"] as? Double == 2)
    #expect(op.request.body?["radius"] as? Double == 50)
    #expect(op.request.body?["duration"] as? Double == 0.6)
    #expect(op.selector == nil)
    let element = try operation(["--id", "canvas", "--scale", "0.5", "--bundle-id", "host", "--timeout", "3", "--hittable"])
    #expect(element.selector?.json["identifier"] as? String == "canvas")
    #expect(element.selectorTimeout == 3)
    #expect(try element.resolvingHostAlias("example.Host").request.body?["bundleId"] as? String == "example.Host")
    #expect(try op.resolvingHostAlias(nil) == op)
    #expect(throws: SetupError.self) { try element.resolvingHostAlias(nil) }
    #expect(try Scenario.action(["pinch", "201", "500", "--scale", "2"]) == .runner(operation(["201", "500", "--scale", "2"])))
    #expect(try operation(["--label-match", "^Canvas", "--type", "other", "--index", "0", "--onscreen", "--scale", "2"]).selector != nil)
    #expect(try operation(["--id", "canvas", "--scale", "2", "--mode", "xcui"]).request.body?["radius"] == nil)
  }

  @Test func rejectsInvalidCLICombinationsBeforeSending() {
    for args in [
      ["201", "500"], ["--scale", "2"], ["201", "--scale", "2"], ["1", "2", "3", "--scale", "2"],
      ["1", "2", "--id", "canvas", "--scale", "2"], ["1", "2", "--scale", "2", "--timeout", "1"],
      ["1", "2", "--scale", "2", "--bundle-id", "a"], ["1", "2", "--scale", "2", "--mode", "xcui"],
      ["--id", "canvas", "--scale", "2", "--mode", "xcui", "--radius", "1"],
      ["--id", "canvas", "--scale", "2", "--mode", "xcui", "--duration", "1"],
      ["--id", "canvas", "--scale", "2", "--scroll", "down"], ["1", "2", "--scale", "2", "--count", "2"]
    ] {
      #expect(throws: ArgumentError.self, "\(args)") { try operation(args) }
    }
    for (option, values) in [("--scale", ["0", "-1", "1", "0.09", "10.01", "nan", "inf", "true"]),
                             ("--radius", ["0", "-1", "nan", "inf"]), ("--duration", ["0", "0.049", "5.01", "inf"])] {
      for value in values {
        let args = option == "--scale" ? ["1", "2", option, value] : ["1", "2", "--scale", "2", option, value]
        #expect(throws: ArgumentError.self, "\(args)") { try operation(args) }
      }
    }
  }

  @Test func strictJSONAndModeValidation() throws {
    for scale in [0.1, 0.5, 2, 10] {
      #expect(try RunnerPinch.Options(json: ["scale": scale]).scale == scale)
    }
    for value: Any in [true, false, "2", NSNull(), 0, -1, 1, 0.09, 11, Double.infinity, Double.nan] {
      #expect(throws: RunnerPinch.Invalid.self) { try RunnerPinch.Options(json: ["scale": value]) }
    }
    #expect(throws: RunnerPinch.Invalid.self) { try RunnerPinch.Options(json: [:]) }
    for key in ["radius", "duration"] {
      for value: Any in [true, "1", NSNull(), 0, -1, Double.infinity, Double.nan] {
        #expect(throws: RunnerPinch.Invalid.self) { try RunnerPinch.Options(json: ["scale": 2, key: value]) }
      }
    }
    for fields: [String: Any] in [["taps": 2], ["mode": true], ["mode": "bogus"], ["mode": NSNull()],
                                  ["timeout": 1], ["bundleId": "a"], ["element": [:], "x": 1],
                                  ["element": [:], "y": 1], ["mode": "xcui"],
                                  ["element": [:], "mode": "xcui", "radius": 20],
                                  ["element": [:], "mode": "xcui", "duration": 0.6]] {
      #expect(throws: RunnerPinch.Invalid.self) { try RunnerPinch.Options(json: ["scale": 2].merging(fields) { _, r in r }) }
    }
    for mode in ["auto", "private", "xcui"] {
      let options = try RunnerPinch.Options(json: ["scale": 0.5, "mode": mode, "element": [:]])
      try options.validateXCUI(hasElement: true)
      #expect(options.velocity == -1)
      #expect(options.movementDuration == 0.6)
    }
    let explicit = try RunnerPinch.Options(json: ["scale": 2, "radius": 1])
    #expect(throws: RunnerPinch.Invalid.self) { try explicit.validateXCUI(hasElement: true) }
  }

  @Test func automaticRadiusExplicitGeometryAndSynchronizedPaths() throws {
    let options = try RunnerPinch.Options(json: ["scale": 2])
    let screen = CGSize(width: 402, height: 874)
    let geometry = try RunnerPinch.geometry(options: options, center: CGPoint(x: 201, y: 500), screen: screen)
    #expect(geometry.radius == 92.5)
    #expect(geometry.start == [CGPoint(x: 108.5, y: 500), CGPoint(x: 293.5, y: 500)])
    #expect(geometry.end == [CGPoint(x: 16, y: 500), CGPoint(x: 386, y: 500)])
    #expect(abs(geometry.liftOffset - 0.7) < 0.0001)
    #expect(geometry.paths.count == 2)
    #expect(geometry.paths[0].count == geometry.offsets.count + 1)
    #expect(geometry.paths[0].prefix(2) == [geometry.start[0], geometry.start[0]])
    #expect(geometry.paths[1].last == geometry.end[1])
    #expect(geometry.offsets.first == 0.05)
    #expect(abs(geometry.offsets.last! - 0.65) < 0.0001)
    #expect(zip(geometry.offsets, geometry.offsets.dropFirst()).allSatisfy { $0 < $1 })
    for pair in zip(geometry.paths[0], geometry.paths[1]) { #expect((pair.0.x + pair.1.x) / 2 == 201) }
    let small = try RunnerPinch.geometry(options: options, center: CGPoint(x: 201, y: 500), screen: screen,
                                         element: CGRect(x: 151, y: 450, width: 100, height: 100))
    #expect(small.radius == 25)
    let shrinking = try RunnerPinch.geometry(options: .init(json: ["scale": 0.5]), center: CGPoint(x: 201, y: 500), screen: screen)
    #expect(shrinking.radius == 100.5)
    let explicit = try RunnerPinch.geometry(options: .init(json: ["scale": 2, "radius": 50, "duration": 5]),
                                            center: CGPoint(x: 50, y: 500), screen: screen)
    #expect(explicit.radius == 50)
    #expect(explicit.end[0].x == -50)
    #expect(RunnerRequestValues.pointOutsideScreen("end[0]", x: explicit.end[0].x, y: 500, screen: screen, orientation: "portrait") != nil)
    #expect(explicit.json["duration"] as? Double == 5)
    for center in [CGPoint(x: 16, y: 500), CGPoint(x: 10, y: 500), CGPoint(x: 201, y: 0)] {
      #expect(throws: RunnerPinch.Invalid.self) { try RunnerPinch.geometry(options: options, center: center, screen: screen) }
    }
    #expect(throws: RunnerPinch.Invalid.self) {
      try RunnerPinch.geometry(options: options, center: CGPoint(x: 201, y: 500), screen: screen,
                               element: CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    #expect(throws: RunnerPinch.Invalid.self) {
      try RunnerPinch.geometry(options: .init(json: ["scale": 0.1, "radius": Double.leastNonzeroMagnitude]),
                               center: CGPoint(x: 201, y: 500), screen: screen)
    }
    #expect(RunnerRequestValues.pointOutsideScreen("x", x: Double.greatestFiniteMagnitude, y: 0,
                                                   screen: screen, orientation: "portrait") != nil)
    #expect(RunnerRequestValues.decimal(-Double.greatestFiniteMagnitude) == String(-Double.greatestFiniteMagnitude))
    for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 100)] {
      #expect(throws: RunnerPinch.Invalid.self) { try RunnerPinch.geometry(options: options, center: .zero, screen: size) }
    }
    #expect(throws: RunnerPinch.Invalid.self) {
      try RunnerPinch.geometry(options: .init(json: ["scale": 10, "radius": Double.greatestFiniteMagnitude]), center: .zero, screen: screen)
    }
    #expect(throws: RunnerPinch.Invalid.self) {
      try RunnerPinch.geometry(options: .init(json: ["scale": 2, "radius": Double.greatestFiniteMagnitude / 4]),
                               center: CGPoint(x: Double.greatestFiniteMagnitude, y: 500), screen: screen)
    }
  }

  @Test func displayedPathsRotateTogetherOnBothDisplays() throws {
    let options = try RunnerPinch.Options(json: ["scale": 2, "radius": 50])
    for size in [CGSize(width: 402, height: 874), CGSize(width: 669, height: 951)] {
      let center = CGPoint(x: 200, y: 300)
      let g = try RunnerPinch.geometry(options: options, center: center, screen: size)
      let expected: [(RunnerInterfaceOrientation, CGPoint, CGPoint)] = [
        (.portrait, CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300)),
        (.portraitUpsideDown, CGPoint(x: size.width - 100, y: size.height - 300), CGPoint(x: size.width - 300, y: size.height - 300)),
        (.landscapeLeft, CGPoint(x: 300, y: size.height - 100), CGPoint(x: 300, y: size.height - 300)),
        (.landscapeRight, CGPoint(x: size.width - 300, y: 100), CGPoint(x: size.width - 300, y: 300))
      ]
      for (orientation, a, b) in expected {
        #expect(RunnerDisplays.portraitPoint(g.end[0], from: orientation, portraitSize: size) == a)
        #expect(RunnerDisplays.portraitPoint(g.end[1], from: orientation, portraitSize: size) == b)
      }
    }
  }

  @Test func answerValidationAndTimeoutBudgets() throws {
    let point = RunnerTouch(target: .point(.init(x: 201, y: 500)), mode: "private")
    let options = try RunnerPinch.Options(json: ["scale": 2, "radius": 50])
    let geometry = try RunnerPinch.geometry(options: options, center: CGPoint(x: 201, y: 500), screen: CGSize(width: 402, height: 874))
    let good = geometry.json.merging(["ok": true, "gesture": "pinch", "mode": "private", "scale": 2]) { _, r in r }
    func accepts(_ value: [String: Any], touch: RunnerTouch = point, options: RunnerPinch.Options = options) throws -> Bool {
      RunnerPinch.acceptsAnswer(try JSONSerialization.data(withJSONObject: value), options: options, touch: touch)
    }
    #expect(try accepts(good))
    for patch: [String: Any] in [["ok": 1], ["gesture": "tap"], ["mode": "unknown"], ["mode": "xcui"], ["scale": true],
                                 ["scale": 3], ["radius": 0], ["radius": 51], ["duration": 1], ["start": []], ["end": []],
                                 ["center": ["x": 202, "y": 500]], ["center": ["x": true, "y": 500]],
                                 ["start": [["x": -1, "y": 500], ["x": 251, "y": 500]]],
                                 ["end": [["x": 102, "y": 500], ["x": 301, "y": 500]]]] {
      #expect(try !accepts(good.merging(patch) { _, r in r }))
    }
    #expect(!RunnerPinch.acceptsAnswer(Data("wrong".utf8), options: options, touch: point))
    let selector = try RunnerElementSelector(json: ["identifier": "canvas"])
    let element = RunnerTouch(target: .element(selector), mode: "xcui", timeout: 3)
    let native = try RunnerPinch.Options(json: ["element": [:], "mode": "xcui", "scale": 0.5])
    var answer: [String: Any] = ["ok": true, "gesture": "pinch", "mode": "xcui", "scale": 0.5, "velocity": -1]
    for key in ["center", "radius", "start", "end", "duration"] { answer[key] = NSNull() }
    #expect(try accepts(answer, touch: element, options: native))
    answer["velocity"] = 1
    #expect(try !accepts(answer, touch: element, options: native))
    answer["velocity"] = -1
    answer["center"] = ["x": 1, "y": 1]
    #expect(try !accepts(answer, touch: element, options: native))
    #expect(RunnerOperation.pinch(element, native).waitTime == 133)
    #expect(RunnerControl.baseTimeout + RunnerOperation.pinch(point, options).waitTime >= geometry.liftOffset + 10 + 20)
    #expect(RunnerControl.baseTimeout + RunnerOperation.pinch(element, native).waitTime >= 3 + RunnerPinch.xcuiAnswer + 20)
  }

  @Test func oldRunnerAndMalformedSuccessFailWithRebuildHint() throws {
    let op = try operation(["201", "500", "--scale", "2"])
    let connection = RunnerConnection(infoURL: URL(fileURLWithPath: "/tmp/runner.json"),
                                      info: RunnerInfo(url: "http://runner.invalid/", token: "secret", udid: "SIM"),
                                      baseURL: URL(string: "http://runner.invalid/")!)
    for (status, body, expected) in [(404, #"{"ok":false}"#, 8), (200, #"{"ok":true}"#, 8),
                                     (400, #"{"ok":false,"code":"point_offscreen"}"#, 7),
                                     (422, #"{"ok":false,"code":"touch_failed"}"#, 6)] {
      let pipe = Pipe()
      let result = RunnerControl.perform(op, on: connection, failureOutput: pipe.fileHandleForWriting) { req in
        #expect(req.url?.path == "/pinch")
        #expect(req.timeoutInterval >= RunnerPinch.xcuiAnswer + 30)
        return RunnerResponse(status: status, body: Data(body.utf8))
      }
      try pipe.fileHandleForWriting.close()
      let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
      #expect(result == Int32(expected))
      if expected == 8 {
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("runner_bad_response"))
        #expect(text.contains("relay start --rebuild"))
      }
    }
  }
}
