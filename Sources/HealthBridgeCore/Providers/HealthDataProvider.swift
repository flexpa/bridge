import Foundation

public enum AuthorizationState: String, Codable, Sendable {
    /// The store is not available on this device (no health data on this Mac).
    case unavailable
    /// The user has not been asked yet.
    case notRequested
    /// The permission sheet was presented. HealthKit does not reveal whether
    /// read access was granted or denied; a denied type simply returns no data.
    case requested
    /// Provider does not need authorization (imported or demo data).
    case notApplicable
}

public struct ProviderStatus: Codable, Equatable, Sendable {
    public var kind: String
    public var description: String
    public var available: Bool
    public var authorization: AuthorizationState
    public var detail: String?
    public var supportsClinicalRecords: Bool
    public var dataRange: DateInterval?
    public var sampleCount: Int?

    public init(kind: String, description: String, available: Bool, authorization: AuthorizationState,
                detail: String? = nil, supportsClinicalRecords: Bool = false, dataRange: DateInterval? = nil,
                sampleCount: Int? = nil) {
        self.kind = kind
        self.description = description
        self.available = available
        self.authorization = authorization
        self.detail = detail
        self.supportsClinicalRecords = supportsClinicalRecords
        self.dataRange = dataRange
        self.sampleCount = sampleCount
    }
}

/// The read-only surface the MCP tools are built on. Implementations: live
/// HealthKit, an imported Health app export, and an in-memory demo set.
public protocol HealthDataProvider: AnyObject, Sendable {
    var kind: String { get }

    func status() async -> ProviderStatus

    /// Types that have (or may have) data. Used by `health_status`.
    func availableTypes() async -> [HealthDataType]

    func requestAuthorization() async throws

    func samples(of type: HealthDataType, in range: DateInterval?, limit: Int, ascending: Bool) async throws -> [HealthSample]

    func statistics(of type: HealthDataType, in range: DateInterval, interval: StatisticsInterval) async throws -> [StatisticsBucket]

    func latestSample(of type: HealthDataType) async throws -> HealthSample?

    func sleepSegments(in range: DateInterval) async throws -> [SleepSegment]

    func workouts(in range: DateInterval?, activityType: String?, limit: Int) async throws -> [Workout]

    func characteristics() async throws -> Characteristics

    func clinicalRecords(kind: ClinicalRecordKind?, since: Date?, limit: Int) async throws -> [ClinicalRecord]
}

// MARK: - Shared computations

public enum HealthMath {
    /// Buckets samples into calendar-aligned intervals. Cumulative types sum
    /// (splitting a sample that spans buckets proportionally); discrete types
    /// report average/min/max.
    public static func buckets(for samples: [HealthSample], type: HealthDataType, range: DateInterval,
                               interval: StatisticsInterval, calendar: Calendar = .current) -> [StatisticsBucket] {
        var boundaries: [Date] = []
        var cursor = alignedStart(of: range.start, interval: interval, calendar: calendar)
        var guardCount = 0
        while cursor < range.end, guardCount < 100_000 {
            boundaries.append(cursor)
            guard let next = calendar.date(byAdding: interval.dateComponents, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        boundaries.append(cursor)
        guard boundaries.count >= 2 else { return [] }

        var sums = [Double](repeating: 0, count: boundaries.count - 1)
        var counts = [Int](repeating: 0, count: boundaries.count - 1)
        var mins = [Double?](repeating: nil, count: boundaries.count - 1)
        var maxs = [Double?](repeating: nil, count: boundaries.count - 1)

        for s in samples {
            switch type.aggregation {
            case .cumulative:
                // Distribute across the buckets the sample overlaps.
                let total = max(s.end.timeIntervalSince(s.start), 0)
                for i in 0..<(boundaries.count - 1) {
                    let bStart = boundaries[i], bEnd = boundaries[i + 1]
                    let overlapStart = max(bStart, s.start)
                    let overlapEnd = min(bEnd, s.end)
                    if total == 0 {
                        if s.start >= bStart && s.start < bEnd {
                            sums[i] += s.value
                            counts[i] += 1
                        }
                    } else if overlapEnd > overlapStart {
                        let fraction = overlapEnd.timeIntervalSince(overlapStart) / total
                        sums[i] += s.value * fraction
                        counts[i] += 1
                    }
                }
            case .discrete:
                guard let i = bucketIndex(for: s.start, boundaries: boundaries) else { continue }
                sums[i] += s.value
                counts[i] += 1
                mins[i] = Swift.min(mins[i] ?? s.value, s.value)
                maxs[i] = Swift.max(maxs[i] ?? s.value, s.value)
            }
        }

        var result: [StatisticsBucket] = []
        for i in 0..<(boundaries.count - 1) {
            let count = counts[i]
            switch type.aggregation {
            case .cumulative:
                result.append(StatisticsBucket(start: boundaries[i], end: boundaries[i + 1], count: count,
                                               sum: count > 0 ? sums[i] : 0, unit: type.unit))
            case .discrete:
                result.append(StatisticsBucket(start: boundaries[i], end: boundaries[i + 1], count: count,
                                               average: count > 0 ? sums[i] / Double(count) : nil,
                                               min: mins[i], max: maxs[i], unit: type.unit))
            }
        }
        return result
    }

    static func alignedStart(of date: Date, interval: StatisticsInterval, calendar: Calendar) -> Date {
        switch interval {
        case .hour:
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: comps) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private static func bucketIndex(for date: Date, boundaries: [Date]) -> Int? {
        guard let first = boundaries.first, let last = boundaries.last, date >= first, date < last else { return nil }
        // Binary search for the bucket containing `date`.
        var lo = 0, hi = boundaries.count - 2
        while lo <= hi {
            let mid = (lo + hi) / 2
            if date < boundaries[mid] {
                hi = mid - 1
            } else if date >= boundaries[mid + 1] {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// Groups sleep segments into nights. A night is keyed by the day the last
    /// segment ends; segments separated by more than `gap` start a new night.
    public static func nights(from segments: [SleepSegment], includeSegments: Bool, gap: TimeInterval = 4 * 3600,
                              calendar: Calendar = .current) -> [SleepNight] {
        let sorted = segments.sorted { $0.start < $1.start }
        var groups: [[SleepSegment]] = []
        for seg in sorted {
            if let last = groups.last?.last, seg.start.timeIntervalSince(last.end) <= gap {
                groups[groups.count - 1].append(seg)
            } else {
                groups.append([seg])
            }
        }
        return groups.map { group in
            let bedtime = group.map(\.start).min()!
            let wake = group.map(\.end).max()!
            func minutes(_ stages: Set<SleepStage>) -> Double {
                group.filter { stages.contains($0.stage) }.reduce(0) { $0 + $1.minutes }
            }
            let staged = minutes([.asleepCore, .asleepDeep, .asleepREM])
            let unspecified = minutes([.asleepUnspecified])
            // Some sources log only inBed; treat inBed as the outer envelope.
            let inBedExplicit = minutes([.inBed])
            let inBed = inBedExplicit > 0 ? inBedExplicit : wake.timeIntervalSince(bedtime) / 60
            return SleepNight(
                date: ISO8601.dayString(wake),
                bedtime: bedtime,
                wakeTime: wake,
                inBedMinutes: inBed,
                asleepMinutes: staged + unspecified,
                awakeMinutes: minutes([.awake]),
                coreMinutes: minutes([.asleepCore]),
                deepMinutes: minutes([.asleepDeep]),
                remMinutes: minutes([.asleepREM]),
                unspecifiedMinutes: unspecified,
                segments: includeSegments ? group : nil
            )
        }
    }
}

// MARK: - Unit conversion for import

public enum UnitConversion {
    /// Converts `value` in `unit` to the catalog's canonical unit for `type`.
    /// HealthKit's own unit arithmetic handles any pair it understands (so
    /// `count/s` to `count/min` or `mi` to `km` need no table); the factor
    /// table covers spellings HealthKit does not parse. Unknown pairs return
    /// the input unchanged so nothing is silently rescaled.
    public static func canonicalize(value: Double, unit: String, type: HealthDataType) -> (Double, String) {
        let target = type.unit
        if unit == target || target.isEmpty { return (value, unit) }
        if let converted = HealthKitUnits.convert(value, from: unit, to: target) { return (converted, target) }
        let key = "\(unit)->\(target)"
        if let factor = factors[key] { return (value * factor, target) }
        switch key {
        case "degF->degC": return ((value - 32) * 5 / 9, target)
        case "degC->degF": return (value * 9 / 5 + 32, target)
        default: return (value, unit)
        }
    }

    private static let factors: [String: Double] = [
        "mi->km": 1.609344, "m->km": 0.001, "km->m": 1000, "ft->m": 0.3048, "yd->m": 0.9144,
        "ft->cm": 30.48, "in->cm": 2.54, "m->cm": 100,
        "lb->kg": 0.45359237, "st->kg": 6.35029318, "g->kg": 0.001,
        "Cal->kcal": 1, "cal->kcal": 0.001, "kJ->kcal": 0.239006, "J->kcal": 0.000239006,
        "s->min": 1.0 / 60, "hr->min": 60, "ms->min": 1.0 / 60000,
        "m/s->km/h": 3.6, "mi/hr->km/h": 1.609344, "km/hr->km/h": 1,
        "L->mL": 1000, "fl_oz_us->mL": 29.5735, "cup_us->mL": 236.588,
        "mmol/L->mg/dL": 18.0182, "mmol<180.1558800000541>/L->mg/dL": 18.0182,
    ]
}
