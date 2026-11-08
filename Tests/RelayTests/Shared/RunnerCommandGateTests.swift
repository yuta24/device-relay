import Foundation
@testable import Relay
import Testing

struct CommandGateTests {
  /// A clock the test moves by hand, in nanoseconds.
  private func makeClock() -> Locked<UInt64> {
    Locked(5_000_000_000)
  }

  @Test func admitsOneCommandAtATime() {
    let gate = CommandGate()
    #expect(gate.tryEnter())
    #expect(!gate.tryEnter())
    gate.leave()
    #expect(gate.tryEnter())
  }

  @Test func reportsElapsedTimeOnlyWhileBusy() {
    let clock = makeClock()
    let gate = CommandGate(now: { clock.value })
    #expect(gate.busyForMs() == nil)
    #expect(gate.tryEnter())
    clock.withLock { $0 += 1_234_999_999 }
    #expect(gate.busyForMs() == 1234)
    // A rejected request doesn't restart the clock.
    #expect(!gate.tryEnter())
    clock.withLock { $0 += 1_000_000 }
    #expect(gate.busyForMs() == 1235)
    gate.leave()
    #expect(gate.busyForMs() == nil)
  }

  @Test func pingBodyHasNullElapsedTimeWhenIdle() throws {
    let clock = makeClock()
    let gate = CommandGate(now: { clock.value })
    let idle = try JSONSerialization.data(withJSONObject: gate.pingBody(), options: [.sortedKeys])
    #expect(String(decoding: idle, as: UTF8.self) == #"{"busy":false,"busyForMs":null,"ok":true}"#)

    #expect(gate.tryEnter())
    clock.withLock { $0 += 3_000_000_000 }
    let busy = try JSONSerialization.data(withJSONObject: gate.pingBody(), options: [.sortedKeys])
    #expect(String(decoding: busy, as: UTF8.self) == #"{"busy":true,"busyForMs":3000,"ok":true}"#)
  }
}
