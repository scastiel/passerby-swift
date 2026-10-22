import Foundation
import os

/// Everything the Tracker reads from the outside world, injected so the tests control time,
/// the network and backgrounding.
struct Environment: Sendable {
  var session: URLSession
  var now: @Sendable () -> Date
  var scheduler: any Scheduler
  var log: any LogSink
  var notificationCenter: NotificationCenter
  /// Runs a flush the app has asked for on its way to the background, keeping the process
  /// alive until it ends.
  var runInBackground: @Sendable (@escaping @Sendable () async -> Void) -> Void
  var device: DeviceInfo
  var isDebugBuild: Bool

  static var live: Environment {
    Environment(
      session: liveSession,
      now: { Date() },
      scheduler: TaskScheduler(),
      log: OSLogSink(),
      notificationCenter: .default,
      runInBackground: runWhileExpiring,
      device: .current,
      isDebugBuild: {
        #if DEBUG
          return true
        #else
          return false
        #endif
      }())
  }

  /// No cache, no cookies, no credentials: nothing the Tracker sends or receives lands on disk.
  private static let liveSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    return URLSession(configuration: configuration)
  }()

  @Sendable private static func runWhileExpiring(_ work: @escaping @Sendable () async -> Void) {
    ProcessInfo.processInfo.performExpiringActivity(
      withReason: "Passerby: send the pending Events"
    ) { expired in
      // Called a second time with `true` when the time is up; the first call is still waiting.
      guard !expired else { return }
      let done = DispatchSemaphore(value: 0)
      Task {
        await work()
        done.signal()
      }
      _ = done.wait(timeout: .now() + 25)
    }
  }
}

/// What the User-Agent and every Event say about the device.
struct DeviceInfo: Sendable {
  /// `18.6.2`, as `UIDevice.systemVersion` spells it.
  var systemVersion: String
  /// `Locale.current.identifier`: `fr_CA`.
  var locale: String
  /// `CFBundleShortVersionString` of the app.
  var appVersion: String
  /// `utsname.machine`: `iPhone15,2`.
  var model: String

  var userAgent: String { "iOS/\(systemVersion) \(locale)" }

  static var current: DeviceInfo {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    var system = "\(version.majorVersion).\(version.minorVersion)"
    if version.patchVersion != 0 { system += ".\(version.patchVersion)" }

    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    return DeviceInfo(
      systemVersion: system,
      locale: Locale.current.identifier,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "",
      model: machine)
  }
}

// MARK: - Scheduling

protocol Cancellable: Sendable {
  func cancel()
}

protocol Scheduler: Sendable {
  /// Runs `work` once, `delay` seconds from now, unless cancelled first.
  func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void)
    -> any Cancellable
}

extension Task: Cancellable where Success == Void, Failure == Never {}

struct TaskScheduler: Scheduler {
  func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void)
    -> any Cancellable
  {
    Task {
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await work()
    }
  }
}

// MARK: - Logging

enum LogLevel: Sendable {
  case debug, error
}

protocol LogSink: Sendable {
  func log(_ level: LogLevel, _ message: String)
}

/// `os.Logger` under the package's bundle id: sends at `.debug`, failures at `.error`.
struct OSLogSink: LogSink {
  private let logger = Logger(
    subsystem: Passerby.resources.bundleIdentifier ?? "passerby-swift", category: "Passerby")

  func log(_ level: LogLevel, _ message: String) {
    switch level {
    case .debug: logger.debug("\(message, privacy: .public)")
    case .error: logger.error("\(message, privacy: .public)")
    }
  }
}
