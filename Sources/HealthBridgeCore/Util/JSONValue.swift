import Foundation

/// A small dynamic JSON representation used for JSON-RPC payloads and tool
/// arguments. Integers survive a round trip (`5` encodes as `5`, not `5.0`).
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
}

// MARK: - Accessors

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true } else { return false } }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let d):
            guard d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
            return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
    }

    subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }
}

// MARK: - Foundation bridging

public extension JSONValue {
    init(any: Any?) {
        guard let any else { self = .null; return }
        switch any {
        case is NSNull: self = .null
        case let v as JSONValue: self = v
        case let n as NSNumber:
            // Must come before `as Bool`: NSNumber(1) would otherwise bridge to `true`.
            // Swift Bool/Int/Double in an Any box also land here via bridging.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let f as Float: self = .number(Double(f))
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]:
            var dict: [String: JSONValue] = [:]
            for (k, v) in o { dict[k] = JSONValue(any: v) }
            self = .object(dict)
        case let d as Date: self = .string(ISO8601.string(from: d))
        default: self = .string(String(describing: any))
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { return Int(d) }
            return d
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o):
            var dict: [String: Any] = [:]
            for (k, v) in o { dict[k] = v.anyValue }
            return dict
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let d = try? container.decode(Double.self) {
            // Numbers before Bool: JSONDecoder would read 0/1 as false/true.
            self = .number(d)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 {
                try container.encode(Int(d))
            } else {
                try container.encode(d)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Serialization helpers

public enum JSON {
    public static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    public static func data(_ value: JSONValue, pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: value.anyValue, options: options)) ?? Data("null".utf8)
    }

    public static func string(_ value: JSONValue, pretty: Bool = false) -> String {
        String(decoding: data(value, pretty: pretty), as: UTF8.self)
    }

    /// Encodes any Encodable as a JSONValue by round-tripping through JSONEncoder.
    public static func value<T: Encodable>(_ encodable: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        let data = try encoder.encode(encodable)
        return try parse(data)
    }
}

// MARK: - Dates

/// ISO 8601 rendering in the user's local time zone, which is what the Health
/// app shows and what agents should reason about.
public enum ISO8601 {
    private static let outputFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func string(from date: Date) -> String {
        outputFormatter.string(from: date)
    }

    /// Parses ISO 8601 date-times, `YYYY-MM-DD` (local midnight), and a few
    /// relative words (`now`, `today`, `yesterday`, `tomorrow`).
    public static func date(from string: String, now: Date = Date()) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let cal = Calendar.current
        switch s.lowercased() {
        case "now": return now
        case "today": return cal.startOfDay(for: now)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        default: break
        }
        if let d = fractionalFormatter.date(from: s) { return d }
        if let d = plainFormatter.date(from: s) { return d }
        // Date only: YYYY-MM-DD
        let parts = s.split(separator: "-")
        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d
            return cal.date(from: comps)
        }
        // Date-time without zone: YYYY-MM-DDTHH:MM[:SS]
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            localFormatter.dateFormat = fmt
            if let d = localFormatter.date(from: s) { return d }
        }
        return nil
    }

    /// Parses the Health app export timestamp format: `2026-09-14 08:00:00 -0400`.
    public static func exportDate(from string: String) -> Date? {
        exportFormatter.date(from: string)
    }

    private static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    public static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
