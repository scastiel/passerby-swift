import Foundation

/// What a call to the public API asks for.
enum Record: Sendable {
  case view(screen: String, props: [String: Property])
  case event(name: String, props: [String: Property])
}

/// The Visit, the queue and delivery (docs/tracker-contracts.md, "Visit lifecycle" and
/// "Queue and delivery"). All in memory: nothing outlives the process.
actor Tracker {
  static let batchSize = 25
  static let capacity = 500
  static let flushInterval: TimeInterval = 5
  static let visitTimeout: TimeInterval = 30 * 60
  static let maxBackoff: TimeInterval = 5 * 60

  private let appKey: String
  private let endpoint: URL
  private let environment: Environment

  private(set) var visit = UUID().uuidString
  private var lastEventAt: Date?
  private var lastScreen: String?

  private var pending: [WireEvent] = []
  private var isSending = false
  private var wake: (any Cancellable)?
  /// Bumped on every cancellation, so a wake that already left its sleep cannot run late.
  private var wakeGeneration = 0
  /// Failed attempts in a row, and when the next one may go out.
  private var failures = 0
  private var retryAt: Date?
  private var isOverflowing = false

  init(appKey: String, url: URL, environment: Environment) {
    self.appKey = appKey
    self.endpoint = url.appendingPathComponent("api/events")
    self.environment = environment
  }

  var pendingCount: Int { pending.count }

  func record(_ record: Record, at date: Date) async {
    if let last = lastEventAt, date.timeIntervalSince(last) > Self.visitTimeout {
      visit = UUID().uuidString
    }
    lastEventAt = date

    let name: String
    let props: [String: Property]
    switch record {
    case let .view(screen, viewProps):
      lastScreen = screen
      name = "view"
      props = viewProps
    case let .event(eventName, eventProps):
      name = eventName
      props = eventProps
    }
    pending.append(
      WireEvent(
        ts: Timestamp.string(from: date), visit: visit, name: name, screen: lastScreen,
        appVersion: environment.device.appVersion, device: environment.device.model,
        props: props.isEmpty ? nil : props))
    trimToCapacity()

    if pending.count >= Self.batchSize {
      await flush()
    } else if wake == nil, !isSending {
      scheduleWake()
    }
  }

  /// Sends one batch, then another straight away while 25 more are waiting. Does nothing while
  /// a request is in flight or a backoff is running.
  func flush() async {
    while !isSending, !pending.isEmpty, !isBackingOff {
      cancelWake()
      isSending = true
      let batch = Array(pending.prefix(Self.batchSize))
      pending.removeFirst(batch.count)

      let outcome = await send(batch)

      isSending = false
      switch outcome {
      case .done:
        failures = 0
        retryAt = nil
      case let .retry(retryAfter, reason):
        pending.insert(contentsOf: batch, at: 0)
        trimToCapacity()
        failures += 1
        let backoff = min(Self.flushInterval * pow(2, Double(failures - 1)), Self.maxBackoff)
        // A 429's Retry-After sets the first delay; later ones never shorten the backoff.
        let delay = min(
          retryAfter.map { failures == 1 ? $0 : max($0, backoff) } ?? backoff, Self.maxBackoff)
        retryAt = environment.now().addingTimeInterval(delay)
        environment.log.log(.error, "\(reason); retrying in \(Int(delay.rounded())) s")
      }
      if pending.count < Self.batchSize { break }
    }
    if !isSending { scheduleWake() }
  }

  private var isBackingOff: Bool {
    guard let retryAt else { return false }
    return environment.now() < retryAt
  }

  private func wakeUp(_ generation: Int) async {
    guard generation == wakeGeneration else { return }
    wake = nil
    await flush()
  }

  private func cancelWake() {
    wake?.cancel()
    wake = nil
    wakeGeneration += 1
  }

  /// One pending wake at most: 5 s after the queue starts filling, or the end of the backoff.
  private func scheduleWake() {
    cancelWake()
    guard !pending.isEmpty else { return }
    let delay = retryAt.map { max($0.timeIntervalSince(environment.now()), 0) }
      ?? Self.flushInterval
    let generation = wakeGeneration
    wake = environment.scheduler.schedule(after: delay) { [weak self] in
      await self?.wakeUp(generation)
    }
  }

  private func trimToCapacity() {
    let excess = pending.count - Self.capacity
    guard excess > 0 else {
      isOverflowing = false
      return
    }
    pending.removeFirst(excess)
    if !isOverflowing {
      isOverflowing = true
      environment.log.log(
        .error, "the queue holds \(Self.capacity) Events: dropping the oldest until a send succeeds")
    }
  }

  // MARK: - One request

  private enum Outcome {
    /// Delivered, or dropped for good: either way the batch leaves the queue.
    case done
    case retry(after: TimeInterval?, reason: String)

    static func retry(_ reason: String) -> Outcome { .retry(after: nil, reason: reason) }
  }

  private func send(_ batch: [WireEvent]) async -> Outcome {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(environment.device.userAgent, forHTTPHeaderField: "User-Agent")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      request.httpBody = try encoder.encode(Envelope(app: appKey, events: batch))
    } catch {
      // Unreachable with these types (a non-finite Double is the one way); never retried.
      environment.log.log(.error, "dropped \(batch.count) Events: \(error)")
      return .done
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await environment.session.data(for: request)
    } catch {
      return .retry("network error: \(error.localizedDescription)")
    }
    guard let http = response as? HTTPURLResponse else {
      return .retry("no HTTP response")
    }

    let verdict = try? JSONDecoder().decode(Verdict.self, from: data)
    let status = http.statusCode
    switch status {
    case 200..<300:
      environment.log.log(
        .debug,
        "sent \(batch.count) Events: \(verdict?.accepted ?? batch.count) accepted")
      logRejections(verdict, in: batch)
      return .done
    case 429:
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        .map { max($0, 0) }
      return .retry(after: retryAfter, reason: "HTTP 429 (throttled)")
    case 400..<500:
      environment.log.log(
        .error,
        "dropped \(batch.count) Events: HTTP \(status): \(reason(verdict, data))")
      logRejections(verdict, in: batch)
      return .done
    default:
      return .retry("HTTP \(status): \(reason(verdict, data))")
    }
  }

  private func logRejections(_ verdict: Verdict?, in batch: [WireEvent]) {
    for rejection in verdict?.rejected ?? [] {
      let name = batch.indices.contains(rejection.index) ? batch[rejection.index].name : "?"
      environment.log.log(
        .error,
        "Event \(rejection.index) (\(name)) rejected: \(rejection.code): \(rejection.message)")
    }
  }

  private func reason(_ verdict: Verdict?, _ data: Data) -> String {
    if let error = verdict?.error {
      return [error, verdict?.message].compactMap { $0 }.joined(separator: ": ")
    }
    if verdict?.rejected?.isEmpty == false { return "no Event accepted" }
    return String(decoding: data.prefix(512), as: UTF8.self)
  }
}
