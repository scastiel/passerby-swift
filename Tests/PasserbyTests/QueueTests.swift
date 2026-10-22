import UIKit
import XCTest
@testable import Passerby

/// The in-memory queue, per docs/tracker-contracts.md "Queue and delivery".
final class QueueTests: XCTestCase {
  func testTheQueueFlushesFiveSecondsAfterAnEvent() async throws {
    let h = Harness()
    let tracker = h.tracker()

    XCTAssertTrue(h.scheduler.pending.isEmpty, "an idle Tracker schedules nothing")
    await tracker.view("Home", at: h.clock.now)
    await tracker.event("tap", at: h.clock.now)
    XCTAssertEqual(h.scheduler.pending, [5], "one wake, not one per Event")
    XCTAssertTrue(h.requests.isEmpty)

    await h.fire()
    XCTAssertEqual(h.requests.count, 1)
    XCTAssertEqual(h.requests[0].names, ["view", "tap"])
    XCTAssertTrue(h.scheduler.pending.isEmpty)
  }

  func testTheQueueFlushesAsSoonAsTwentyFiveEventsArePending() async throws {
    let h = Harness()
    let tracker = h.tracker()

    for i in 0..<24 { await tracker.event("e\(i)", at: h.clock.now) }
    XCTAssertTrue(h.requests.isEmpty)
    await tracker.event("e24", at: h.clock.now)

    XCTAssertEqual(h.requests.count, 1, "sent without waiting for the 5 s")
    XCTAssertEqual(h.requests[0].events.count, 25)
    XCTAssertTrue(h.scheduler.pending.isEmpty)
  }

  func testTheQueueFlushesWhenTheAppEntersTheBackground() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, sendInDebugBuilds: true,
      environment: h.environment())
    defer { Passerby.reset() }

    Passerby.view("Home")
    await Passerby.drain()
    XCTAssertTrue(h.requests.isEmpty)
    h.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    await h.background.runAll()

    XCTAssertEqual(h.requests.count, 1)
    XCTAssertEqual(h.requests[0].names, ["view"])
  }

  func testAFlushSendsAtMostTwentyFiveEventsPerRequest() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(.status(503))

    for i in 0..<24 { await tracker.event("e\(i)", at: h.clock.now) }
    await h.fire()  // 503: the 24 stay queued, in backoff
    for i in 24..<60 { await tracker.event("e\(i)", at: h.clock.now) }
    await h.fire()  // backoff over: 25, then 25 straight away
    XCTAssertEqual(h.requests.count, 3)
    XCTAssertEqual(h.scheduler.pending, [5], "the remaining 10 wait for the next flush")
    await h.fire()

    let batches = h.requests.dropFirst().map(\.names)
    XCTAssertEqual(batches.map(\.count), [25, 25, 10])
    XCTAssertEqual(batches.flatMap { $0 }, (0..<60).map { "e\($0)" }, "in order, none twice")
  }

  func testTheQueueHoldsAtMost500EventsAndDropsTheOldest() async throws {
    let h = Harness()
    let tracker = h.tracker()
    h.collector.reply(.status(503))

    await tracker.event("e0", at: h.clock.now)
    await h.fire()  // 503, in backoff: nothing else is sent
    for i in 1..<510 { await tracker.event("e\(i)", at: h.clock.now) }
    let pending = await tracker.pendingCount
    XCTAssertEqual(pending, 500)
    XCTAssertTrue(h.log.messages(at: .error).contains { $0.contains("oldest") })

    h.collector.alwaysReply(.accepted(25))
    await h.fire()
    while !h.scheduler.pending.isEmpty { await h.fire() }

    let sent = h.requests.dropFirst().flatMap(\.names)
    XCTAssertEqual(sent.count, 500)
    XCTAssertEqual(sent.first, "e10")
    XCTAssertEqual(sent.last, "e509")
  }

  func testEveryCallIsSafeFromAnyThread() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, sendInDebugBuilds: true,
      environment: h.environment())
    defer { Passerby.reset() }

    DispatchQueue.concurrentPerform(iterations: 200) { i in
      if i.isMultiple(of: 2) { Passerby.view("S\(i)") } else { Passerby.event("e\(i)") }
    }
    await Passerby.drain()
    while !h.scheduler.pending.isEmpty { await h.fire() }

    let names = h.requests.flatMap(\.names)
    XCTAssertEqual(names.count, 200)
    XCTAssertTrue(h.requests.allSatisfy { $0.events.count <= 25 })
  }
}
