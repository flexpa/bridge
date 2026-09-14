import CLibProc
import Foundation
import HealthKit

/// Safe access to HealthKit unit parsing and conversion.
public enum HealthKitUnits {
    private static let lock = NSLock()
    private static var cache: [String: HKUnit?] = [:]

    /// Parses a unit string without risking the NSException `HKUnit(from:)` raises on bad input.
    public static func unit(_ string: String) -> HKUnit? {
        // HealthKit parses "" as a dimensionless unit; for us an empty string means "no unit".
        guard !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let spelled = HealthKitProvider.healthKitUnitString(string)
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[spelled] { return cached }
        var result: HKUnit? = nil
        if let raw = spelled.withCString({ hb_unit_from_string($0) }) {
            result = Unmanaged<HKUnit>.fromOpaque(raw).takeRetainedValue()
        }
        cache[spelled] = result
        return result
    }

    /// Converts between two unit strings when HealthKit knows both and they are dimensionally compatible.
    public static func convert(_ value: Double, from: String, to: String) -> Double? {
        guard let a = unit(from), let b = unit(to) else { return nil }
        let quantity = HKQuantity(unit: a, doubleValue: value)
        guard quantity.is(compatibleWith: b) else { return nil }
        // HealthKit's percent unit is a fraction (0.97 is 97 %); our catalog uses whole percentages.
        let converted = quantity.doubleValue(for: b)
        if b.unitString == "%" && a.unitString != "%" { return converted * 100 }
        return converted
    }
}
