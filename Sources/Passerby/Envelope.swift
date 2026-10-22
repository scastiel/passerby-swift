import Foundation

/// The body of `POST /api/events` (docs/tracker-contracts.md, "The envelope").
struct Envelope: Encodable {
  let app: String
  let platform = "ios"
  let events: [WireEvent]
}

/// One self-contained Event, with the fields of the iOS column.
struct WireEvent: Encodable, Sendable {
  let ts: String
  let visit: String
  let name: String
  let screen: String?
  let appVersion: String
  let device: String
  let props: [String: Property]?

  enum CodingKeys: String, CodingKey {
    case ts, visit, name, screen, device, props
    case appVersion = "app_version"
  }
}

/// The Collector's verdict on a batch it parsed (ADR-0011).
struct Verdict: Decodable {
  struct Rejection: Decodable {
    let index: Int
    let code: String
    let message: String
  }

  let accepted: Int?
  let rejected: [Rejection]?
  let error: String?
  let message: String?
}

enum Timestamp {
  private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// RFC 3339 in UTC with milliseconds: `2026-09-18T14:03:22.123Z`.
  static func string(from date: Date) -> String { date.formatted(style) }
}
