import SwiftUI
import UIKit
import XCTest
@testable import Passerby

/// `configure`, the calls before it, DEBUG silence and `.trackScreen`, per
/// docs/tracker-contracts.md "Public API" and "Debug builds".
final class PublicAPITests: XCTestCase {
  override func tearDown() {
    Passerby.reset()
    super.tearDown()
  }

  private static func flushInBackground(_ h: Harness) async {
    await Passerby.drain()
    postDidEnterBackground(on: h.notifications)
    await h.background.runAll()
  }

  func testCallsBeforeConfigureAreANoOpWithOneLogLineEach() async throws {
    let h = Harness()
    Passerby.unconfiguredLog = h.log
    defer { Passerby.unconfiguredLog = Passerby.liveLog }

    Passerby.view("Home")
    Passerby.event("signup")

    let lines = h.log.all.map(\.1)
    XCTAssertEqual(lines.count, 2, "\(lines)")
    XCTAssertTrue(lines.allSatisfy { $0.contains("configure") })
    XCTAssertTrue(h.requests.isEmpty)
  }

  func testADebugBuildIsSilentByDefault() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, environment: h.environment(isDebugBuild: true))

    Passerby.view("Home")
    Passerby.event("signup")
    await Self.flushInBackground(h)

    XCTAssertTrue(h.requests.isEmpty)
    XCTAssertTrue(h.scheduler.pending.isEmpty)
    XCTAssertEqual(h.log.all.count, 1, "one line at configure, nothing per call")
    XCTAssertTrue(h.log.all[0].1.contains("sendInDebugBuilds"))
  }

  func testADebugBuildSendsWhenOptedIn() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, sendInDebugBuilds: true,
      environment: h.environment(isDebugBuild: true))

    Passerby.view("Home")
    await Self.flushInBackground(h)

    XCTAssertEqual(h.requests.count, 1)
  }

  func testAReleaseBuildAlwaysSends() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, environment: h.environment(isDebugBuild: false))

    Passerby.view("Home")
    await Self.flushInBackground(h)

    XCTAssertEqual(h.requests.count, 1)
  }

  func testTheseTestsRunInADebugBuild() {
    XCTAssertTrue(Environment.live.isDebugBuild, "the default is #if DEBUG")
  }

  func testASecondConfigureIsIgnored() async throws {
    let h = Harness()
    Passerby.configure(
      appKey: Harness.appKey, url: Harness.url, environment: h.environment())
    Passerby.configure(
      appKey: "other", url: URL(string: "https://b.example.com")!, environment: h.environment())

    Passerby.view("Home")
    await Self.flushInBackground(h)

    XCTAssertEqual(h.requests.first?.json["app"] as? String, Harness.appKey)
    XCTAssertTrue(h.log.messages(at: .error).contains { $0.contains("once") })
  }

  func testTheCallOrderIsTheEventOrder() async throws {
    let h = Harness()
    Passerby.configure(appKey: Harness.appKey, url: Harness.url, environment: h.environment())

    Passerby.view("Home")
    Passerby.event("a")
    Passerby.view("Paywall")
    Passerby.event("b")
    await Self.flushInBackground(h)

    let events = h.requests.flatMap(\.events)
    XCTAssertEqual(events.map { $0["name"] as? String }, ["view", "a", "view", "b"])
    XCTAssertEqual(events.map { $0["screen"] as? String }, ["Home", "Home", "Paywall", "Paywall"])
  }

  func testTheTimestampIsTheTimeOfTheCall() async throws {
    let h = Harness()
    Passerby.configure(appKey: Harness.appKey, url: Harness.url, environment: h.environment())

    let calledAt = h.clock.now
    Passerby.view("Home")
    h.clock.advance(by: 3)
    await Self.flushInBackground(h)

    let ts = try XCTUnwrap(h.requests.first?.events.first?["ts"] as? String)
    XCTAssertEqual(ts, Timestamp.string(from: calledAt))
  }

  @MainActor
  func testTrackScreenSendsAViewOnEveryAppear() async throws {
    let h = Harness()
    Passerby.configure(appKey: Harness.appKey, url: Harness.url, environment: h.environment())

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    for _ in 0..<2 {
      let host = UIHostingController(rootView: Text("Settings").trackScreen("Settings"))
      window.rootViewController = host
      window.makeKeyAndVisible()
      host.view.layoutIfNeeded()
      // onAppear runs on the main run loop after the hosting view lays out.
      Self.spinMainRunLoop()
      window.rootViewController = nil
    }
    await Self.flushInBackground(h)

    let screens = h.requests.flatMap(\.events).map { $0["screen"] as? String }
    XCTAssertEqual(screens, ["Settings", "Settings"])
  }

  /// Lets UIKit run its pending layout and appearance callbacks.
  @MainActor
  private static func spinMainRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }
}
