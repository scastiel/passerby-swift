import Foundation
import UIKit
import XCTest
@testable import Passerby

// MARK: - The Collector, stubbed at the URLProtocol level

/// What the stub answers to one request.
enum StubReply {
  case status(Int, headers: [String: String] = [:], body: String = #"{"accepted":0,"rejected":[]}"#)
  case networkError

  static func accepted(_ n: Int = 0) -> StubReply {
    .status(200, body: #"{"accepted":\#(n),"rejected":[]}"#)
  }
}

/// One request the Tracker sent, with its body decoded.
struct SentRequest {
  let request: URLRequest
  let body: Data

  var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
  }
  var events: [[String: Any]] { json["events"] as? [[String: Any]] ?? [] }
  var names: [String] { events.compactMap { $0["name"] as? String } }
}

/// The process-wide state behind `StubURLProtocol`: replies are consumed in order, then the
/// default reply answers every further request.
final class StubCollector: @unchecked Sendable {
  static let shared = StubCollector()

  private let lock = NSLock()
  private var replies: [StubReply] = []
  private var sent: [SentRequest] = []
  private var fallback: StubReply = .accepted()

  func reset() {
    lock.withLock {
      replies = []
      sent = []
      fallback = .accepted()
    }
  }

  func reply(_ replies: StubReply...) {
    lock.withLock { self.replies.append(contentsOf: replies) }
  }

  func alwaysReply(_ reply: StubReply) {
    lock.withLock { fallback = reply }
  }

  var requests: [SentRequest] { lock.withLock { sent } }

  fileprivate func handle(_ request: URLRequest, body: Data) -> StubReply {
    lock.withLock {
      sent.append(SentRequest(request: request, body: body))
      return replies.isEmpty ? fallback : replies.removeFirst()
    }
  }
}

final class StubURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
    switch StubCollector.shared.handle(request, body: body) {
    case let .status(code, headers, text):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
        headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(text.utf8))
      client?.urlProtocolDidFinishLoading(self)
    case .networkError:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
  }

  override func stopLoading() {}

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let n = stream.read(&buffer, maxLength: buffer.count)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

// MARK: - Time, scheduling, logs and backgrounding, under the test's control

final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ start: Date = Date(timeIntervalSince1970: 1_789_740_202.123)) { current = start }

  var now: Date { lock.withLock { current } }
  func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Holds scheduled work until the test fires it.
final class ManualScheduler: Scheduler, @unchecked Sendable {
  private final class Entry: Cancellable, @unchecked Sendable {
    let delay: TimeInterval
    let work: @Sendable () async -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(delay: TimeInterval, work: @escaping @Sendable () async -> Void) {
      self.delay = delay
      self.work = work
    }

    func cancel() { lock.withLock { cancelled = true } }
    var isLive: Bool { lock.withLock { !cancelled } }
  }

  private let lock = NSLock()
  private var entries: [Entry] = []

  func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void)
    -> any Cancellable
  {
    let entry = Entry(delay: delay, work: work)
    lock.withLock { entries.append(entry) }
    return entry
  }

  /// The delays of the work scheduled and not cancelled, oldest first.
  var pending: [TimeInterval] { live.map(\.delay) }

  private var live: [Entry] {
    lock.withLock {
      entries.removeAll { !$0.isLive }
      return entries
    }
  }

  /// Advances the clock by the next live wake's delay and runs it.
  func fire(advancing clock: ManualClock, file: StaticString = #filePath, line: UInt = #line)
    async
  {
    guard let entry = live.first else {
      return XCTFail("nothing is scheduled", file: file, line: line)
    }
    lock.withLock { entries.removeAll { $0 === entry } }
    clock.advance(by: entry.delay)
    await entry.work()
  }
}

final class RecordingLog: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [(LogLevel, String)] = []

  func log(_ level: LogLevel, _ message: String) {
    lock.withLock { entries.append((level, message)) }
  }

  var all: [(LogLevel, String)] { lock.withLock { entries } }
  func messages(at level: LogLevel) -> [String] {
    all.filter { $0.0 == level }.map(\.1)
  }
}

/// Stands in for `performExpiringActivity`: keeps the work until the test runs it.
final class ManualBackground: @unchecked Sendable {
  private let lock = NSLock()
  private var work: [@Sendable () async -> Void] = []

  func run(_ body: @escaping @Sendable () async -> Void) {
    lock.withLock { work.append(body) }
  }

  func runAll() async {
    let all = lock.withLock { () -> [@Sendable () async -> Void] in
      defer { work = [] }
      return work
    }
    for body in all { await body() }
  }
}

/// Everything a test needs to drive one Tracker.
struct Harness {
  let clock = ManualClock()
  let scheduler = ManualScheduler()
  let log = RecordingLog()
  let background = ManualBackground()
  let notifications = NotificationCenter()

  static let url = URL(string: "https://a.example.com")!
  static let appKey = "k7f3x9q2m1pz"
  static let device = DeviceInfo(
    systemVersion: "18.6.2", locale: "fr_CA", appVersion: "1.4.2", model: "iPhone15,2")

  init() { StubCollector.shared.reset() }

  func environment(isDebugBuild: Bool = false) -> Environment {
    let clock = clock
    let background = background
    return Environment(
      session: StubURLProtocol.session(),
      now: { clock.now },
      scheduler: scheduler,
      log: log,
      notificationCenter: notifications,
      runInBackground: { background.run($0) },
      device: Self.device,
      isDebugBuild: isDebugBuild)
  }

  func tracker() -> Tracker {
    Tracker(appKey: Self.appKey, url: Self.url, environment: environment())
  }

  var collector: StubCollector { .shared }
  var requests: [SentRequest] { collector.requests }

  /// Fires the pending wake: the 5-second flush or the end of a backoff.
  func fire(file: StaticString = #filePath, line: UInt = #line) async {
    await scheduler.fire(advancing: clock, file: file, line: line)
  }
}

extension Tracker {
  func view(_ screen: String, props: [String: Property] = [:], at date: Date) async {
    await record(.view(screen: screen, props: props), at: date)
  }

  func event(_ name: String, props: [String: Property] = [:], at date: Date) async {
    await record(.event(name: name, props: props), at: date)
  }
}

/// Posts what UIKit posts when the app enters the background. Synchronous, because the Xcode 15
/// SDK isolates the notification's name to the main actor and an async test could not read it.
func postDidEnterBackground(on center: NotificationCenter) {
  center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
}
