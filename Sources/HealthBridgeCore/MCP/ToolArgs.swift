import Foundation

/// Typed access to tool-call arguments with descriptive errors.
public struct ToolArgs: Sendable {
    public let raw: JSONValue
    public let now: Date

    public init(_ raw: JSONValue, now: Date = Date()) {
        self.raw = raw
        self.now = now
    }

    public func string(_ key: String) -> String? {
        raw[key]?.stringValue
    }

    public func requireString(_ key: String) throws -> String {
        guard let s = string(key), !s.isEmpty else { throw HealthDataError.invalidArgument("'\(key)' is required") }
        return s
    }

    public func int(_ key: String, default def: Int, min lo: Int = 1, max hi: Int = Int.max) -> Int {
        let v = raw[key]?.intValue ?? def
        return Swift.max(lo, Swift.min(hi, v))
    }

    public func bool(_ key: String, default def: Bool) -> Bool {
        raw[key]?.boolValue ?? def
    }

    public func strings(_ key: String) -> [String]? {
        if let arr = raw[key]?.arrayValue { return arr.compactMap(\.stringValue) }
        if let s = raw[key]?.stringValue { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }

    public func date(_ key: String) throws -> Date? {
        guard let s = string(key) else { return nil }
        guard let d = ISO8601.date(from: s, now: now) else {
            throw HealthDataError.invalidArgument("'\(key)' must be an ISO 8601 date or date-time, got '\(s)'")
        }
        return d
    }

    /// Parses `start`/`end`. Missing end defaults to now; missing start defaults
    /// to `defaultDays` before end. Caps the span at `maxDays` when given.
    public func range(defaultDays: Int, maxDays: Int? = nil) throws -> DateInterval {
        let end = try date("end") ?? now
        var start = try date("start") ?? Calendar.current.date(byAdding: .day, value: -defaultDays, to: end)!
        if let endOnly = string("end"), endOnly.count == 10, string("start") == nil {
            // A bare date for `end` means the whole of that day.
            start = Calendar.current.date(byAdding: .day, value: -defaultDays, to: end)!
        }
        guard start <= end else { throw HealthDataError.invalidArgument("'start' must be before 'end'") }
        if let maxDays, end.timeIntervalSince(start) > Double(maxDays) * 86400 + 1 {
            throw HealthDataError.invalidArgument("Range may not exceed \(maxDays) days")
        }
        return DateInterval(start: start, end: end)
    }

    public func type(_ key: String = "type") throws -> HealthDataType {
        let raw = try requireString(key)
        guard let t = HealthTypeCatalog.resolve(raw) else {
            throw HealthDataError.unsupportedType("'\(raw)'. Call list_health_types for the supported identifiers.")
        }
        return t
    }
}
