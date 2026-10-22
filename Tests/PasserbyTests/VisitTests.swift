import UIKit
import XCTest
@testable import Passerby

/// Visit lifecycle, per docs/tracker-contracts.md "Visit lifecycle".
final class VisitTests: XCTestCase {
  func testEachLaunchMintsAVisit() async throws {
    let h = Harness()
    let first = await h.tracker().visit
    let second = await h.tracker().visit

    XCTAssertNotNil(UUID(uuidString: first))
    XCTAssertNotEqual(first, second, "every configure starts a Visit")
  }

  func testEventsWithinThirtyMinutesShareTheVisit() async throws {
    let h = Harness()
    let tracker = h.tracker()
    let launch = await tracker.visit

    await tracker.view("Home", at: h.clock.now)
    h.clock.advance(by: 30 * 60)  // exactly the timeout: not more than it
    await tracker.event("tap", at: h.clock.now)
    h.clock.advance(by: 29 * 60)
    await tracker.event("tap", at: h.clock.now)

    let visit = await tracker.visit
    XCTAssertEqual(visit, launch, "the gap is measured from the previous Event")
  }

  func testAnEventMoreThanThirtyMinutesAfterThePreviousOneStartsANewVisit() async throws {
    let h = Harness()
    let tracker = h.tracker()
    let launch = await tracker.visit

    await tracker.view("Home", at: h.clock.now)
    h.clock.advance(by: 30 * 60 + 1)
    await tracker.event("back", at: h.clock.now)
    await tracker.event("again", at: h.clock.now)
    await h.fire()

    let events = h.requests.flatMap(\.events)
    XCTAssertEqual(events.count, 3)
    XCTAssertEqual(events[0]["visit"] as? String, launch)
    let rotated = try XCTUnwrap(events[1]["visit"] as? String)
    XCTAssertNotEqual(rotated, launch)
    XCTAssertNotNil(UUID(uuidString: rotated))
    XCTAssertEqual(events[2]["visit"] as? String, rotated)
  }

  func testBackgroundingNeverEndsAVisitNorSendsALifecycleEvent() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, sendInDebugBuilds: true,
      environment: h.environment())
    defer { Passerby.reset() }

    Passerby.view("Home")
    await Passerby.drain()
    postDidEnterBackground(on: h.notifications)
    await h.background.runAll()
    h.clock.advance(by: 10 * 60)
    Passerby.event("resumed")
    await Passerby.drain()
    await h.fire()

    let events = h.requests.flatMap(\.events)
    XCTAssertEqual(events.map { $0["name"] as? String }, ["view", "resumed"], "no lifecycle Events")
    XCTAssertEqual(events[0]["visit"] as? String, events[1]["visit"] as? String)
  }
}
