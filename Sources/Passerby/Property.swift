/// A Property value: one of the three types the Collector accepts (ADR-0006).
///
/// Literals build it, so a dictionary of Properties reads like JSON:
/// `["plan": "pro", "seats": 3, "trial": true]`.
public enum Property: Sendable, Equatable, Encodable,
  ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
  case string(String)
  case number(Double)
  case bool(Bool)

  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    }
  }
}
