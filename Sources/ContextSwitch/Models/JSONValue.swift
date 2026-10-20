import Foundation

/// Any JSON value, kept as it was read. A profile this version can't read
/// (saved by a newer one, or mistyped by hand) is held as one of these, so
/// saving writes it back instead of dropping it.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Past Int64.max, which Double would round.
    case uint(UInt64)
    /// Anything JSONEncoder writes comes back exactly.
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value at `key`, if this is an object.
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // JSONDecoder won't read a number as a Bool or vice versa, nor 1.5
        // as an Int64, so the first that decodes is the one.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .uint(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .uint(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
