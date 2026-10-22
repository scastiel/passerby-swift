import XCTest
@testable import Passerby

/// The request and the envelope, per docs/tracker-contracts.md "The envelope" (iOS columns).
final class EnvelopeTests: XCTestCase {
  func testAViewIsPostedAsTheIOSEnvelope() async throws {
    let h = Harness()
    let tracker = h.tracker()

    await tracker.view("Home", at: h.clock.now)
    await h.fire()

    let sent = try XCTUnwrap(h.requests.first)
    XCTAssertEqual(sent.request.httpMethod, "POST")
    XCTAssertEqual(sent.request.url?.absoluteString, "https://a.example.com/api/events")
    XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(sent.request.value(forHTTPHeaderField: "User-Agent"), "iOS/18.6.2 fr_CA")

    XCTAssertEqual(Set(sent.json.keys), ["app", "platform", "events"])
    XCTAssertEqual(sent.json["app"] as? String, "k7f3x9q2m1pz")
    XCTAssertEqual(sent.json["platform"] as? String, "ios")

    let event = try XCTUnwrap(sent.events.first)
    XCTAssertEqual(sent.events.count, 1)
    XCTAssertEqual(
      Set(event.keys), ["ts", "visit", "name", "screen", "app_version", "device"],
      "no props key when there are none")
    XCTAssertEqual(event["name"] as? String, "view")
    XCTAssertEqual(event["screen"] as? String, "Home")
    XCTAssertEqual(event["app_version"] as? String, "1.4.2")
    XCTAssertEqual(event["device"] as? String, "iPhone15,2")
    let visit = await tracker.visit
    XCTAssertEqual(event["visit"] as? String, visit)
    XCTAssertNotNil(UUID(uuidString: event["visit"] as? String ?? ""))
  }

  func testTheTimestampIsRFC3339InUTCWithMilliseconds() async throws {
    let h = Harness()
    let tracker = h.tracker()

    // 2026-09-18T14:03:22.1234Z: milliseconds, truncated
    await tracker.view("Home", at: Date(timeIntervalSince1970: 1_789_740_202.1234))
    await h.fire()

    let event = try XCTUnwrap(h.requests.first?.events.first)
    XCTAssertEqual(event["ts"] as? String, "2026-09-18T14:03:22.123Z")
  }

  func testTheURLKeepsAPathPrefixAndAToleratesATrailingSlash() async throws {
    for (base, expected) in [
      ("https://a.example.com/", "https://a.example.com/api/events"),
      ("https://example.com/passerby", "https://example.com/passerby/api/events"),
    ] {
      let h = Harness()
      let tracker = Tracker(
        appKey: Harness.appKey, url: URL(string: base)!, environment: h.environment())
      await tracker.view("Home", at: h.clock.now)
      await h.fire()
      XCTAssertEqual(h.requests.first?.request.url?.absoluteString, expected)
    }
  }

  func testACustomEventBeforeAnyScreenHasNoScreen() async throws {
    let h = Harness()
    let tracker = h.tracker()

    await tracker.event("launched", at: h.clock.now)
    await h.fire()

    let event = try XCTUnwrap(h.requests.first?.events.first)
    XCTAssertEqual(event["name"] as? String, "launched")
    XCTAssertNil(event["screen"], "omitted before any Screen")
  }

  func testACustomEventCarriesTheLastScreenSeen() async throws {
    let h = Harness()
    let tracker = h.tracker()

    await tracker.view("Home", at: h.clock.now)
    await tracker.view("Paywall", at: h.clock.now)
    await tracker.event("signup", at: h.clock.now)
    await h.fire()

    let events = try XCTUnwrap(h.requests.first?.events)
    XCTAssertEqual(events.map { $0["name"] as? String }, ["view", "view", "signup"])
    XCTAssertEqual(events[2]["screen"] as? String, "Paywall")
  }

  func testEachPropertyLiteralTypeIsEncodedAsItsJSONType() async throws {
    let h = Harness()
    let tracker = h.tracker()

    await tracker.event(
      "signup", props: ["plan": "pro", "seats": 3, "ratio": 0.5, "trial": true], at: h.clock.now)
    await h.fire()

    let body = try XCTUnwrap(h.requests.first?.body)
    let props = try XCTUnwrap(h.requests.first?.events.first?["props"] as? [String: Any])
    XCTAssertEqual(props["plan"] as? String, "pro")
    XCTAssertEqual(props["seats"] as? Double, 3)
    XCTAssertEqual(props["ratio"] as? Double, 0.5)
    XCTAssertEqual(props["trial"] as? Bool, true)
    // JSONSerialization bridges true to 1 too; the raw body says which it is.
    let text = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(text.contains(#""trial":true"#), text)
    XCTAssertTrue(text.contains(#""seats":3"#), text)
    XCTAssertTrue(text.contains(#""plan":"pro""#), text)
  }

  func testPropertyLiteralsBuildTheThreeCases() {
    let props: [String: Property] = ["s": "pro", "i": 3, "f": 2.5, "b": false]
    XCTAssertEqual(props["s"], .string("pro"))
    XCTAssertEqual(props["i"], .number(3))
    XCTAssertEqual(props["f"], .number(2.5))
    XCTAssertEqual(props["b"], .bool(false))
  }

  func testAViewWithPropsSendsThem() async throws {
    let h = Harness()
    let tracker = h.tracker()

    await tracker.view("Article", props: ["id": "42"], at: h.clock.now)
    await h.fire()

    let event = try XCTUnwrap(h.requests.first?.events.first)
    XCTAssertEqual((event["props"] as? [String: Any])?["id"] as? String, "42")
  }
}
