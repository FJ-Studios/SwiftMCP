import Foundation

// MARK: - JSONValue
// Recursive JSON value type. Shared between Core, Server, and consumer packages.

public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
            return
        }
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
            return
        }
        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }
        if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
            return
        }
        if let arrVal = try? container.decode([JSONValue].self) {
            self = .array(arrVal)
            return
        }
        if let objVal = try? container.decode([String: JSONValue].self) {
            self = .object(objVal)
            return
        }

        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Cannot decode JSONValue")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

// MARK: - JSONValue helpers

extension JSONValue {
    /// Access a string value or nil
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Access an int value or nil
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// Access a double value or nil
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }

    /// Access a bool value or nil
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Access an object value or nil
    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// Access an array value or nil
    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// Subscript for object keys
    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    /// Build a JSONValue from a Foundation JSONObject (Any) — used in bridge helpers
    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case let str as String: return .string(str)
        case let int as Int: return .int(int)
        case let double as Double: return .double(double)
        case let bool as Bool: return .bool(bool)
        case let arr as [Any]: return .array(arr.map { from($0) })
        case let dict as [String: Any]: return .object(dict.mapValues { from($0) })
        default: return .null
        }
    }
}
