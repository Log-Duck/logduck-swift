import Foundation

/// An event to send to LogDuck.
public struct LogDuckEvent: Sendable {
    /// What happened, e.g. `user.signup` (required, max 100 characters).
    ///
    /// The server lowercases this and requires it to match
    /// `^[a-z][a-z0-9_.]*$` — letters, digits, underscores and dots, starting
    /// with a letter. A hyphen is rejected with a 400.
    public var type: String

    /// The resource the event is about, e.g. a user or order id (max 500).
    public var subject: String?

    /// Groups related events within a session (max 256).
    public var sessionId: String?

    /// When it happened. Defaults to server time if unset.
    public var time: Date?

    /// Arbitrary JSON payload.
    public var data: [String: JSONValue]?

    /// Shown alongside the event in the dashboard (max 10 characters).
    public var emoji: String?

    public init(
        type: String,
        subject: String? = nil,
        sessionId: String? = nil,
        time: Date? = nil,
        data: [String: JSONValue]? = nil,
        emoji: String? = nil
    ) {
        self.type = type
        self.subject = subject
        self.sessionId = sessionId
        self.time = time
        self.data = data
        self.emoji = emoji
    }
}

/// What LogDuck returns for an accepted event.
public struct LogDuckResponse: Sendable, Decodable {
    public let success: Bool
    public let eventId: String
    public let time: String
}

/// Any value that survives a round trip through JSON.
///
/// Swift has no `Any`-shaped type that is both `Sendable` and `Encodable`, and
/// `[String: Any]` would force the client to be non-`Sendable` — which in turn
/// would make it unusable from a concurrent context without warnings. Spelling
/// the cases out keeps the payload strongly typed all the way to the wire.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

// Literal conformances, so a payload reads like the JSON it becomes:
//
//     ["total": 4999, "currency": "NOK", "gift": false]

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
