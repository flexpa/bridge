import Foundation

public struct ToolSpec: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var handler: @Sendable (ToolArgs, HealthDataProvider, BridgeSettings) async throws -> JSONValue

    public var listing: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ]),
        ])
    }
}

/// The MCP tool surface. Every tool is read-only.
public enum HealthTools {
    public static let all: [ToolSpec] = [
        healthStatus, listHealthTypes, getSamples, getStatistics, getLatest, getSleep, getWorkouts, getDailySummary,
        getCharacteristics, getClinicalRecords,
    ]

    public static let byName: [String: ToolSpec] = {
        var d: [String: ToolSpec] = [:]
        for t in all { d[t.name] = t }
        return d
    }()

    // MARK: Schemas

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { obj["required"] = .array(required.map { .string($0) }) }
        return .object(obj)
    }

    private static let typeProp: JSONValue = [
        "type": "string",
        "description": "Health data type. Accepts a HealthKit identifier (HKQuantityTypeIdentifierStepCount), a short alias (stepCount, heart_rate), or a display name (Steps). See list_health_types.",
    ]
    private static let startProp: JSONValue = [
        "type": "string",
        "description": "Start of the range: ISO 8601 date-time, YYYY-MM-DD (local midnight), or today/yesterday/now.",
    ]
    private static let endProp: JSONValue = [
        "type": "string",
        "description": "End of the range (exclusive). Same formats as start. Defaults to now.",
    ]

    // MARK: Tools

    static let healthStatus = ToolSpec(
        name: "health_status",
        title: "Health data status",
        description: "Reports whether health data is available, which data source is active (live HealthKit, an imported Health export, or demo data), the authorization state, and which data types have data. Call this first.",
        inputSchema: schema([:]),
        handler: { _, provider, settings in
            let status = await provider.status()
            let types = await provider.availableTypes()
            var obj = try JSON.value(status).objectValue ?? [:]
            obj["dataSourcePreference"] = .string(settings.dataSource.rawValue)
            obj["availableTypes"] = .array(types.map { .string($0.identifier) })
            obj["clinicalRecordsExposed"] = .bool(settings.exposeClinicalRecords && status.supportsClinicalRecords)
            obj["timeZone"] = .string(TimeZone.current.identifier)
            obj["now"] = .string(ISO8601.string(from: Date()))
            return .object(obj)
        }
    )

    static let listHealthTypes = ToolSpec(
        name: "list_health_types",
        title: "List health data types",
        description: "Lists the health data types the bridge understands, with identifiers, units, and whether values are cumulative (sum them) or discrete (average them). Optionally filter by category.",
        inputSchema: schema([
            "category": [
                "type": "string",
                "enum": .array(HealthCategory.allCases.map { .string($0.rawValue) }),
                "description": "Filter to one category.",
            ],
            "only_available": [
                "type": "boolean",
                "description": "Return only types the active data source has data for. Default false.",
            ],
        ]),
        handler: { args, provider, _ in
            var types = HealthTypeCatalog.all
            if let cat = args.string("category") {
                guard let c = HealthCategory(rawValue: cat) else { throw HealthDataError.invalidArgument("unknown category '\(cat)'") }
                types = types.filter { $0.category == c }
            }
            if args.bool("only_available", default: false) {
                let available = Set(await provider.availableTypes().map(\.identifier))
                types = types.filter { available.contains($0.identifier) }
            }
            let items: [JSONValue] = types.map {
                .object([
                    "identifier": .string($0.identifier),
                    "alias": .string($0.shortName),
                    "name": .string($0.name),
                    "kind": .string($0.kind.rawValue),
                    "unit": .string($0.unit),
                    "aggregation": .string($0.aggregation.rawValue),
                    "category": .string($0.category.rawValue),
                    "description": .string($0.description),
                ])
            }
            return .object(["types": .array(items), "count": .number(Double(items.count))])
        }
    )

    static let getSamples = ToolSpec(
        name: "get_samples",
        title: "Get raw samples",
        description: "Returns individual samples of one type within a range, newest first by default. Use get_statistics for totals and averages over time; raw samples can be very numerous for heart rate and steps.",
        inputSchema: schema([
            "type": typeProp,
            "start": startProp,
            "end": endProp,
            "limit": ["type": "integer", "description": "Maximum samples to return (1-2000). Default 100.", "minimum": 1, "maximum": 2000],
            "order": ["type": "string", "enum": ["asc", "desc"], "description": "Sort by start date. Default desc."],
        ], required: ["type"]),
        handler: { args, provider, _ in
            let type = try args.type()
            let range = try args.range(defaultDays: 7)
            let limit = args.int("limit", default: 100, min: 1, max: 2000)
            let ascending = args.string("order")?.lowercased() == "asc"
            let samples = try await provider.samples(of: type, in: range, limit: limit, ascending: ascending)
            return .object([
                "type": .string(type.identifier),
                "name": .string(type.name),
                "unit": .string(type.unit),
                "start": .string(ISO8601.string(from: range.start)),
                "end": .string(ISO8601.string(from: range.end)),
                "count": .number(Double(samples.count)),
                "truncated": .bool(samples.count >= limit),
                "samples": try JSON.value(samples),
            ])
        }
    )

    static let getStatistics = ToolSpec(
        name: "get_statistics",
        title: "Get statistics over time",
        description: "Aggregates one type into calendar buckets (hour, day, week, or month). Cumulative types (steps, energy, distance) return sums; discrete types (heart rate, weight, SpO2) return average, min, and max. This is the right tool for trends and totals.",
        inputSchema: schema([
            "type": typeProp,
            "start": startProp,
            "end": endProp,
            "interval": ["type": "string", "enum": ["hour", "day", "week", "month"], "description": "Bucket size. Default day."],
        ], required: ["type"]),
        handler: { args, provider, _ in
            let type = try args.type()
            let range = try args.range(defaultDays: 30, maxDays: 3660)
            let intervalRaw = args.string("interval") ?? "day"
            guard let interval = StatisticsInterval(rawValue: intervalRaw) else {
                throw HealthDataError.invalidArgument("interval must be hour, day, week, or month")
            }
            if interval == .hour, range.duration > 31 * 86400 {
                throw HealthDataError.invalidArgument("hourly statistics are limited to 31 days")
            }
            let buckets = try await provider.statistics(of: type, in: range, interval: interval)
            let total: JSONValue
            switch type.aggregation {
            case .cumulative: total = .number(buckets.reduce(0) { $0 + ($1.sum ?? 0) })
            case .discrete:
                let vals = buckets.compactMap(\.average)
                total = vals.isEmpty ? .null : .number(vals.reduce(0, +) / Double(vals.count))
            }
            return .object([
                "type": .string(type.identifier),
                "name": .string(type.name),
                "unit": .string(type.unit),
                "aggregation": .string(type.aggregation.rawValue),
                "interval": .string(interval.rawValue),
                "start": .string(ISO8601.string(from: range.start)),
                "end": .string(ISO8601.string(from: range.end)),
                (type.aggregation == .cumulative ? "total" : "overallAverage"): total,
                "buckets": try JSON.value(buckets),
            ])
        }
    )

    static let getLatest = ToolSpec(
        name: "get_latest",
        title: "Get latest values",
        description: "Returns the most recent sample for each requested type, e.g. current weight, last resting heart rate, latest VO2 max.",
        inputSchema: schema([
            "types": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Up to 25 type identifiers or aliases.",
                "minItems": 1,
                "maxItems": 25,
            ],
        ], required: ["types"]),
        handler: { args, provider, _ in
            guard let raws = args.strings("types"), !raws.isEmpty else { throw HealthDataError.invalidArgument("'types' is required") }
            var results: [String: JSONValue] = [:]
            for raw in raws.prefix(25) {
                guard let type = HealthTypeCatalog.resolve(raw) else {
                    results[raw] = .object(["error": .string("unsupported type")])
                    continue
                }
                if let s = try await provider.latestSample(of: type) {
                    results[type.identifier] = try JSON.value(s)
                } else {
                    results[type.identifier] = .null
                }
            }
            return .object(["latest": .object(results)])
        }
    )

    static let getSleep = ToolSpec(
        name: "get_sleep",
        title: "Get sleep",
        description: "Returns sleep grouped into nights (keyed by wake-up date) with time in bed, time asleep, and minutes per stage (core, deep, REM, awake). Set include_segments for the raw stage timeline.",
        inputSchema: schema([
            "start": startProp,
            "end": endProp,
            "include_segments": ["type": "boolean", "description": "Include each stage segment. Default false."],
        ]),
        handler: { args, provider, _ in
            let range = try args.range(defaultDays: 14, maxDays: 366)
            // Widen the query so a night that started before `start` is complete.
            let padded = DateInterval(start: range.start.addingTimeInterval(-18 * 3600), end: range.end)
            let segments = try await provider.sleepSegments(in: padded)
            let nights = HealthMath.nights(from: segments, includeSegments: args.bool("include_segments", default: false))
                .filter { $0.wakeTime >= range.start && $0.wakeTime <= range.end }
            let asleep = nights.map(\.asleepMinutes)
            return .object([
                "start": .string(ISO8601.string(from: range.start)),
                "end": .string(ISO8601.string(from: range.end)),
                "nightCount": .number(Double(nights.count)),
                "averageAsleepMinutes": asleep.isEmpty ? .null : .number(asleep.reduce(0, +) / Double(asleep.count)),
                "nights": try JSON.value(nights),
            ])
        }
    )

    static let getWorkouts = ToolSpec(
        name: "get_workouts",
        title: "Get workouts",
        description: "Returns workouts with type, duration, energy, distance, and heart rate where available.",
        inputSchema: schema([
            "start": startProp,
            "end": endProp,
            "activity_type": ["type": "string", "description": "Filter by activity, e.g. running, cycling, walking, functionalStrengthTraining."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50."],
        ]),
        handler: { args, provider, _ in
            let range = try args.range(defaultDays: 30)
            let limit = args.int("limit", default: 50, min: 1, max: 500)
            let workouts = try await provider.workouts(in: range, activityType: args.string("activity_type"), limit: limit)
            return .object([
                "start": .string(ISO8601.string(from: range.start)),
                "end": .string(ISO8601.string(from: range.end)),
                "count": .number(Double(workouts.count)),
                "totalMinutes": .number(workouts.reduce(0) { $0 + $1.durationMinutes }),
                "workouts": try JSON.value(workouts),
            ])
        }
    )

    static let getDailySummary = ToolSpec(
        name: "get_daily_summary",
        title: "Get daily summary",
        description: "One row per day with steps, distance, active energy, exercise minutes, resting and average heart rate, HRV, SpO2, sleep, weight, and workouts. Pass a single date or a start/end range of up to 92 days. Defaults to the last 7 days.",
        inputSchema: schema([
            "date": ["type": "string", "description": "A single day, YYYY-MM-DD."],
            "start": startProp,
            "end": endProp,
        ]),
        handler: { args, provider, _ in
            let cal = Calendar.current
            let range: DateInterval
            if let day = try args.date("date") {
                let s = cal.startOfDay(for: day)
                range = DateInterval(start: s, end: cal.date(byAdding: .day, value: 1, to: s)!)
            } else {
                let r = try args.range(defaultDays: 7, maxDays: 92)
                let s = cal.startOfDay(for: r.start)
                let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: r.end.addingTimeInterval(-1)))!
                range = DateInterval(start: s, end: max(e, cal.date(byAdding: .day, value: 1, to: s)!))
            }
            let summaries = try await DailySummaryBuilder.build(provider: provider, range: range)
            return .object([
                "start": .string(ISO8601.dayString(range.start)),
                "end": .string(ISO8601.dayString(range.end.addingTimeInterval(-1))),
                "days": try JSON.value(summaries),
            ])
        }
    )

    static let getCharacteristics = ToolSpec(
        name: "get_characteristics",
        title: "Get profile characteristics",
        description: "Returns fixed profile data: date of birth and age, biological sex, blood type, Fitzpatrick skin type, wheelchair use, and activity move mode.",
        inputSchema: schema([:]),
        handler: { _, provider, _ in
            try JSON.value(try await provider.characteristics())
        }
    )

    static let getClinicalRecords = ToolSpec(
        name: "get_clinical_records",
        title: "Get clinical records (FHIR)",
        description: "Returns clinical health records synced from providers into Apple Health, as FHIR resources: allergies, conditions, immunizations, lab results, medications, procedures, vital signs, coverage, and clinical notes.",
        inputSchema: schema([
            "kind": [
                "type": "string",
                "enum": .array(ClinicalRecordKind.allCases.map { .string($0.rawValue) }),
                "description": "Filter to one record kind.",
            ],
            "since": ["type": "string", "description": "Only records dated on or after this ISO 8601 date."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50."],
            "include_resources": ["type": "boolean", "description": "Include the full FHIR resource JSON. Default true."],
        ]),
        handler: { args, provider, settings in
            guard settings.exposeClinicalRecords else {
                throw HealthDataError.notAuthorized("Clinical records are disabled in Health Bridge settings.")
            }
            var kind: ClinicalRecordKind? = nil
            if let k = args.string("kind") {
                guard let parsed = ClinicalRecordKind(rawValue: k) else { throw HealthDataError.invalidArgument("unknown kind '\(k)'") }
                kind = parsed
            }
            let since = try args.date("since")
            let limit = args.int("limit", default: 50, min: 1, max: 500)
            let includeResources = args.bool("include_resources", default: true)
            let records = try await provider.clinicalRecords(kind: kind, since: since, limit: limit)
            let items: [JSONValue] = try records.map { r in
                var obj = try JSON.value(r).objectValue ?? [:]
                if !includeResources { obj.removeValue(forKey: "resource") }
                return .object(obj)
            }
            return .object(["count": .number(Double(items.count)), "records": .array(items)])
        }
    )
}

// MARK: - Daily summary

enum DailySummaryBuilder {
    private static func type(_ id: String) -> HealthDataType { HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifier" + id]! }

    static func build(provider: HealthDataProvider, range: DateInterval) async throws -> [DailySummary] {
        let cal = Calendar.current

        async let steps = try provider.statistics(of: type("StepCount"), in: range, interval: .day)
        async let distance = try provider.statistics(of: type("DistanceWalkingRunning"), in: range, interval: .day)
        async let energy = try provider.statistics(of: type("ActiveEnergyBurned"), in: range, interval: .day)
        async let exercise = try provider.statistics(of: type("AppleExerciseTime"), in: range, interval: .day)
        async let flights = try provider.statistics(of: type("FlightsClimbed"), in: range, interval: .day)
        async let restingHR = try provider.statistics(of: type("RestingHeartRate"), in: range, interval: .day)
        async let hr = try provider.statistics(of: type("HeartRate"), in: range, interval: .day)
        async let hrv = try provider.statistics(of: type("HeartRateVariabilitySDNN"), in: range, interval: .day)
        async let resp = try provider.statistics(of: type("RespiratoryRate"), in: range, interval: .day)
        async let spo2 = try provider.statistics(of: type("OxygenSaturation"), in: range, interval: .day)
        async let mass = try provider.statistics(of: type("BodyMass"), in: range, interval: .day)
        async let standHours = try provider.samples(of: HealthTypeCatalog.byIdentifier["HKCategoryTypeIdentifierAppleStandHour"]!,
                                                    in: range, limit: 5000, ascending: true)
        async let sleepSegs = try provider.sleepSegments(in: DateInterval(start: range.start.addingTimeInterval(-18 * 3600), end: range.end))
        async let workouts = try provider.workouts(in: range, activityType: nil, limit: 500)

        let s = try await steps, d = try await distance, e = try await energy, ex = try await exercise, f = try await flights
        let rhr = try await restingHR, h = try await hr, v = try await hrv, r = try await resp, o = try await spo2, m = try await mass
        let stand = try await standHours
        let nights = HealthMath.nights(from: try await sleepSegs, includeSegments: false)
        let w = try await workouts

        func byDay(_ buckets: [StatisticsBucket]) -> [String: StatisticsBucket] {
            var dict: [String: StatisticsBucket] = [:]
            for b in buckets { dict[ISO8601.dayString(b.start)] = b }
            return dict
        }
        let sD = byDay(s), dD = byDay(d), eD = byDay(e), exD = byDay(ex), fD = byDay(f), rhrD = byDay(rhr), hD = byDay(h)
        let vD = byDay(v), rD = byDay(r), oD = byDay(o), mD = byDay(m)
        var standByDay: [String: Double] = [:]
        for sample in stand where sample.value == 0 { standByDay[ISO8601.dayString(sample.start), default: 0] += 1 }
        // A day can hold several sleep groups: a night plus a nap, or a night the watch split.
        // Keep the longest, so a twenty-minute nap cannot replace eight hours of sleep.
        var nightsByDay: [String: SleepNight] = [:]
        for n in nights where (nightsByDay[n.date]?.asleepMinutes ?? -1) < n.asleepMinutes {
            nightsByDay[n.date] = n
        }

        var result: [DailySummary] = []
        var cursor = range.start
        while cursor < range.end {
            let key = ISO8601.dayString(cursor)
            let next = cal.date(byAdding: .day, value: 1, to: cursor)!
            let dayWorkouts = w.filter { $0.start >= cursor && $0.start < next }
            result.append(DailySummary(
                date: key,
                steps: sD[key]?.sum,
                distanceKm: dD[key]?.sum,
                activeEnergyKcal: eD[key]?.sum,
                exerciseMinutes: exD[key]?.sum,
                standHours: standByDay[key],
                flightsClimbed: fD[key]?.sum,
                restingHeartRate: rhrD[key]?.average,
                heartRateAverage: hD[key]?.average,
                heartRateMin: hD[key]?.min,
                heartRateMax: hD[key]?.max,
                hrvSDNN: vD[key]?.average,
                respiratoryRate: rD[key]?.average,
                oxygenSaturation: oD[key]?.average,
                sleepAsleepMinutes: nightsByDay[key]?.asleepMinutes,
                sleepInBedMinutes: nightsByDay[key]?.inBedMinutes,
                bodyMassKg: mD[key]?.average,
                workouts: dayWorkouts
            ))
            cursor = next
        }
        return result
    }
}
