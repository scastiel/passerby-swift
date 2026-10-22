import UIKit
import XCTest
@testable import Passerby

/// The real Tracker against a real Collector. Skipped unless both variables are set; with
/// `xcodebuild`, pass them as `TEST_RUNNER_PASSERBY_E2E_URL` and `TEST_RUNNER_PASSERBY_E2E_APP_KEY`.
final class EndToEndTests: XCTestCase {
  func testAViewAndACustomEventReachARealCollector() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["PASSERBY_E2E_URL"].flatMap(URL.init(string:)),
      let appKey = env["PASSERBY_E2E_APP_KEY"]
    else {
      throw XCTSkip("set PASSERBY_E2E_URL and PASSERBY_E2E_APP_KEY to run against an Instance")
    }

    let log = RecordingLog()
    var environment = Environment.live
    environment.log = TeeLog(Environment.live.log, log)
    Passerby.configure(appKey: appKey, url: url, sendInDebugBuilds: true, environment: environment)
    defer { Passerby.reset() }

    Passerby.view("E2E Home", props: ["source": "xctest"])
    Passerby.event("e2e_signup", props: ["plan": "pro", "seats": 3, "trial": true])
    // The real path: the notification, the expiring activity, URLSession.
    await Passerby.drain()
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, !log.all.contains(where: { $0.1.hasPrefix("sent") }) {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertEqual(log.messages(at: .error), [])
    let sent = try XCTUnwrap(log.messages(at: .debug).first { $0.hasPrefix("sent") })
    XCTAssertTrue(sent.contains("2 accepted"), sent)
    print("PASSERBY_E2E_VISIT=\(await Passerby.currentVisit ?? "")")
  }
}

struct TeeLog: LogSink {
  let sinks: [any LogSink]
  init(_ sinks: any LogSink...) { self.sinks = sinks }
  func log(_ level: LogLevel, _ message: String) { sinks.forEach { $0.log(level, message) } }
}
