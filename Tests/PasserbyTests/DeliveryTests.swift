import XCTest
@testable import Passerby

/// What the Tracker does with each status, per docs/collector-contract.md
/// "What a client should do with each status".
final class DeliveryTests: XCTestCase {
  func testA200DropsTheBatchAndLogsEachRejectionAtError() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(
      .status(
        200,
        body: """
          {"accepted":1,"rejected":[{"index":1,"code":"name_too_long","message":"name is longer than 64 characters"}]}
          """))

    await tracker.view("Home", at: h.clock.now)
    await tracker.event(String(repeating: "x", count: 65), at: h.clock.now)
    await h.fire()

    let errors = h.log.messages(at: .error)
    XCTAssertEqual(errors.count, 1, "\(errors)")
    XCTAssertTrue(errors[0].contains("name_too_long"), errors[0])
    XCTAssertTrue(errors[0].contains("name is longer than 64 characters"), errors[0])
    XCTAssertTrue(errors[0].contains("1"), "names the index")
    XCTAssertTrue(h.log.messages(at: .debug).contains { $0.contains("sent 2") })
    let pending = await tracker.pendingCount
    XCTAssertEqual(pending, 0)
    XCTAssertTrue(h.scheduler.pending.isEmpty, "nothing left to flush")
  }

  func testA400DropsTheBatchAndLogsTheReason() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(
      .status(400, body: #"{"error":"bad_batch","message":"events must hold 1 to 25 Events"}"#))

    await tracker.view("Home", at: h.clock.now)
    await h.fire()

    let errors = h.log.messages(at: .error)
    XCTAssertEqual(errors.count, 1, "\(errors)")
    XCTAssertTrue(errors[0].contains("400"), errors[0])
    XCTAssertTrue(errors[0].contains("bad_batch"), errors[0])
    XCTAssertTrue(errors[0].contains("events must hold 1 to 25 Events"), errors[0])
    let pending = await tracker.pendingCount
    XCTAssertEqual(pending, 0)
    XCTAssertTrue(h.scheduler.pending.isEmpty, "not retried")
  }

  func testA400WithEveryEventRejectedLogsEachRejection() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(
      .status(
        400,
        body: #"{"accepted":0,"rejected":[{"index":0,"code":"screen_too_long","message":"too long"}]}"#
      ))

    await tracker.view(String(repeating: "s", count: 300), at: h.clock.now)
    await h.fire()

    XCTAssertTrue(h.log.messages(at: .error).contains { $0.contains("screen_too_long") })
    let pending = await tracker.pendingCount
    XCTAssertEqual(pending, 0)
  }

  func testA403DropsTheBatchAndLogsTheReason() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(
      .status(403, body: #"{"error":"unknown_app","message":"no active App has this key"}"#))

    await tracker.view("Home", at: h.clock.now)
    await h.fire()
    await tracker.view("Next", at: h.clock.now)
    await h.fire()

    XCTAssertEqual(h.requests.count, 2)
    XCTAssertEqual(h.requests[1].events.count, 1, "the dropped batch is never resent")
    XCTAssertEqual(h.requests[1].events.first?["screen"] as? String, "Next")
    XCTAssertTrue(h.log.messages(at: .error)[0].contains("unknown_app"))
  }

  func testA429KeepsTheBatchWaitsForRetryAfterThenBacksOff() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(
      .status(429, headers: ["Retry-After": "7"]), .status(503), .networkError, .accepted(1))

    await tracker.view("Home", at: h.clock.now)
    await h.fire()  // 429
    XCTAssertEqual(h.scheduler.pending, [7], "Retry-After sets the first delay")
    let kept = await tracker.pendingCount
    XCTAssertEqual(kept, 1)

    await h.fire()  // 503
    XCTAssertEqual(h.scheduler.pending, [10], "then the backoff: 5 s doubled")
    await h.fire()  // network error
    XCTAssertEqual(h.scheduler.pending, [20])
    await h.fire()  // 200

    XCTAssertEqual(h.requests.count, 4)
    let first = h.requests[0].body
    for sent in h.requests { XCTAssertEqual(sent.body, first, "the same batch, retried as is") }
    let pending = await tracker.pendingCount
    XCTAssertEqual(pending, 0)
    XCTAssertTrue(h.scheduler.pending.isEmpty)
  }

  func testA503IsRetriedWithBackoffCappedAtFiveMinutes() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.alwaysReply(.status(503))

    await tracker.view("Home", at: h.clock.now)
    var delays: [TimeInterval] = []
    for _ in 0..<9 {
      await h.fire()
      delays += h.scheduler.pending
    }

    XCTAssertEqual(delays, [5, 10, 20, 40, 80, 160, 300, 300, 300])
    XCTAssertTrue(h.log.messages(at: .error).allSatisfy { $0.contains("503") })
  }

  func testANetworkErrorIsRetriedAndASuccessResetsTheBackoff() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(.networkError, .networkError, .accepted(1), .networkError)

    await tracker.view("Home", at: h.clock.now)
    await h.fire()
    await h.fire()
    XCTAssertEqual(h.scheduler.pending, [10])
    await h.fire()  // delivered
    XCTAssertEqual(h.requests.count, 3)
    let pending = await tracker.pendingCount
    XCTAssertEqual(pending, 0)

    await tracker.view("Next", at: h.clock.now)
    XCTAssertEqual(h.scheduler.pending, [5], "a new Event flushes at the regular 5 s")
    await h.fire()  // network error
    XCTAssertEqual(h.scheduler.pending, [5], "the backoff starts again from 5 s")
    XCTAssertTrue(h.log.messages(at: .error).contains { $0.lowercased().contains("network") })
  }

  func testNoFlushTriggerSendsBeforeTheBackoffEnds() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(.status(429, headers: ["Retry-After": "60"]))

    await tracker.view("Home", at: h.clock.now)
    await h.fire()
    for i in 0..<30 { await tracker.event("e\(i)", at: h.clock.now) }
    await tracker.flush()  // as the background notification does

    XCTAssertEqual(h.requests.count, 1, "neither 25 pending nor backgrounding skips the wait")
    XCTAssertEqual(h.scheduler.pending, [60])
  }
}
