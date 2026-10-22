import Foundation
import UIKit
import os

/// The Passerby Tracker for iOS: configure it once at launch, then record Views and Custom
/// events from anywhere. Every call is safe from any thread and returns immediately.
public enum Passerby {
  /// Starts the Tracker and a Visit. Call it once, at launch.
  ///
  /// - Parameters:
  ///   - appKey: The App key `passerby app create` printed.
  ///   - url: The Instance's public URL; the Tracker appends `/api/events`.
  ///   - sendInDebugBuilds: A DEBUG build sends nothing unless this is `true`; use a separate
  ///     App key for development. Release builds, TestFlight included, always send.
  public static func configure(appKey: String, url: URL, sendInDebugBuilds: Bool = false) {
    configure(appKey: appKey, url: url, sendInDebugBuilds: sendInDebugBuilds, environment: .live)
  }

  /// Records a View of the named Screen.
  public static func view(_ screen: String, props: [String: Property] = [:]) {
    submit(.view(screen: screen, props: props), call: "view")
  }

  /// Records a Custom event on the last Screen seen.
  public static func event(_ name: String, props: [String: Property] = [:]) {
    submit(.event(name: name, props: props), call: "event")
  }

  // MARK: - Internals

  private enum State: Sendable {
    case unconfigured
    /// A DEBUG build that did not opt in.
    case silent
    case active(Client)
  }

  private static let state = OSAllocatedUnfairLock<State>(initialState: .unconfigured)

  static let liveLog: any LogSink = OSLogSink()
  /// Where a call made before `configure` is reported; the tests swap it.
  static var unconfiguredLog: any LogSink {
    get { unconfiguredLogLock.withLock { $0 } }
    set { unconfiguredLogLock.withLock { $0 = newValue } }
  }
  private static let unconfiguredLogLock = OSAllocatedUnfairLock<any LogSink>(
    initialState: liveLog)

  /// The package's resource bundle, which holds `PrivacyInfo.xcprivacy`.
  static var resources: Bundle { .module }

  static func configure(
    appKey: String, url: URL, sendInDebugBuilds: Bool = false, environment: Environment
  ) {
    let silent = environment.isDebugBuild && !sendInDebugBuilds
    state.withLock { state in
      guard case .unconfigured = state else {
        environment.log.log(.error, "Passerby.configure is called once; this call is ignored")
        return
      }
      if silent {
        environment.log.log(
          .debug,
          "a DEBUG build sends nothing; pass sendInDebugBuilds: true (with a development App key) to send")
        state = .silent
      } else {
        state = .active(Client(appKey: appKey, url: url, environment: environment))
      }
    }
  }

  private static func submit(_ record: Record, call: String) {
    switch state.withLock({ $0 }) {
    case .unconfigured:
      unconfiguredLog.log(
        .error, "Passerby.\(call) was called before Passerby.configure; nothing was recorded")
    case .silent:
      break
    case .active(let client):
      client.submit(record)
    }
  }

  /// Waits until every call made so far has reached the Tracker (tests only).
  static func drain() async {
    guard case .active(let client) = state.withLock({ $0 }) else { return }
    await client.drain()
  }

  static var currentVisit: String? {
    get async {
      guard case .active(let client) = state.withLock({ $0 }) else { return nil }
      return await client.tracker.visit
    }
  }

  /// Forgets the configuration, so the next test can configure again (tests only).
  static func reset() {
    let previous = state.withLock { state -> State in
      defer { state = .unconfigured }
      return state
    }
    if case .active(let client) = previous { client.stop() }
  }
}

/// Carries calls, in call order, to the Tracker actor, and watches for backgrounding.
private final class Client: Sendable {
  enum Command: Sendable {
    case record(Record, at: Date)
    case flush(CheckedContinuation<Void, Never>)
    case barrier(CheckedContinuation<Void, Never>)
  }

  let tracker: Tracker
  private let now: @Sendable () -> Date
  private let commands: AsyncStream<Command>.Continuation
  private let consumer: Task<Void, Never>
  private let observer: Observation

  init(appKey: String, url: URL, environment: Environment) {
    let tracker = Tracker(appKey: appKey, url: url, environment: environment)
    let (stream, commands) = AsyncStream.makeStream(of: Command.self)
    self.tracker = tracker
    self.now = environment.now
    self.commands = commands
    self.consumer = Task {
      for await command in stream {
        switch command {
        case let .record(record, date):
          await tracker.record(record, at: date)
        case let .flush(done):
          await tracker.flush()
          done.resume()
        case let .barrier(done):
          done.resume()
        }
      }
    }
    let runInBackground = environment.runInBackground
    self.observer = Observation(
      center: environment.notificationCenter,
      name: UIApplication.didEnterBackgroundNotification
    ) {
      runInBackground {
        await withCheckedContinuation { commands.yield(.flush($0)) }
      }
    }
  }

  func submit(_ record: Record) {
    commands.yield(.record(record, at: now()))
  }

  func drain() async {
    await withCheckedContinuation { commands.yield(.barrier($0)) }
  }

  func stop() {
    observer.cancel()
    commands.finish()
    consumer.cancel()
  }
}

/// A NotificationCenter observer token, removed on `cancel`. The token is immutable and
/// `removeObserver` is thread-safe, which is what makes this Sendable.
private final class Observation: @unchecked Sendable {
  private let center: NotificationCenter
  private let token: any NSObjectProtocol

  init(
    center: NotificationCenter, name: Notification.Name,
    _ handler: @escaping @Sendable () -> Void
  ) {
    self.center = center
    self.token = center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
  }

  func cancel() { center.removeObserver(token) }
}
