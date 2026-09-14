import Foundation

/// Deterministic, plausible-looking data for development, tests, and for
/// showing an agent the tool surface before real data is connected.
public final class DemoHealthProvider: HealthDataProvider, @unchecked Sendable {
    public let kind = "demo"

    private let samplesByType: [String: [HealthSample]]
    private let sleep: [SleepSegment]
    private let workoutList: [Workout]
    private let days: Int

    public init(days: Int = 45, seed: UInt64 = 42, now: Date = Date()) {
        self.days = days
        var rng = SeededGenerator(seed: seed)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var samples: [String: [HealthSample]] = [:]
        var sleepSegments: [SleepSegment] = []
        var workouts: [Workout] = []

        func add(_ id: String, _ s: HealthSample) { samples[id, default: []].append(s) }
        func t(_ id: String) -> HealthDataType { HealthTypeCatalog.byIdentifier[id]! }

        for dayOffset in stride(from: days, through: 1, by: -1) {
            let day = cal.date(byAdding: .day, value: -dayOffset, to: today)!
            let weekend = cal.isDateInWeekend(day)

            // Steps: hourly chunks 07:00-22:00.
            let dailySteps = weekend ? rng.next(in: 4000...9000) : rng.next(in: 6000...12500)
            var remaining = Double(dailySteps)
            for hour in 7..<22 {
                let start = cal.date(byAdding: .hour, value: hour, to: day)!
                let end = cal.date(byAdding: .minute, value: 59, to: start)!
                let share = hour == 21 ? remaining : min(remaining, Double(rng.next(in: 100...1400)))
                remaining -= share
                let type = t("HKQuantityTypeIdentifierStepCount")
                add(type.identifier, HealthSample(type: type.identifier, start: start, end: end, value: share.rounded(),
                                                  unit: type.unit, source: "Demo Watch"))
                let dist = t("HKQuantityTypeIdentifierDistanceWalkingRunning")
                add(dist.identifier, HealthSample(type: dist.identifier, start: start, end: end, value: (share * 0.00075 * 100).rounded() / 100,
                                                  unit: dist.unit, source: "Demo Watch"))
                let energy = t("HKQuantityTypeIdentifierActiveEnergyBurned")
                add(energy.identifier, HealthSample(type: energy.identifier, start: start, end: end, value: (share * 0.04 + Double(rng.next(in: 5...20))).rounded(),
                                                    unit: energy.unit, source: "Demo Watch"))
                if share > 900 {
                    let ex = t("HKQuantityTypeIdentifierAppleExerciseTime")
                    add(ex.identifier, HealthSample(type: ex.identifier, start: start, end: end, value: Double(rng.next(in: 5...25)), unit: ex.unit, source: "Demo Watch"))
                }
                let stand = t("HKCategoryTypeIdentifierAppleStandHour")
                add(stand.identifier, HealthSample(type: stand.identifier, start: start, end: end, value: share > 60 ? 0 : 1, unit: "",
                                                   categoryValue: share > 60 ? "stood" : "idle", source: "Demo Watch"))
            }

            // Heart rate every 10 minutes while awake.
            let hrType = t("HKQuantityTypeIdentifierHeartRate")
            for minute in stride(from: 7 * 60, to: 23 * 60, by: 10) {
                let at = cal.date(byAdding: .minute, value: minute, to: day)!
                let base = 62.0 + Double(rng.next(in: 0...30))
                add(hrType.identifier, HealthSample(type: hrType.identifier, start: at, end: at, value: base, unit: hrType.unit, source: "Demo Watch"))
            }
            let rhr = t("HKQuantityTypeIdentifierRestingHeartRate")
            let rhrAt = cal.date(byAdding: .hour, value: 6, to: day)!
            add(rhr.identifier, HealthSample(type: rhr.identifier, start: rhrAt, end: rhrAt, value: Double(rng.next(in: 52...61)), unit: rhr.unit, source: "Demo Watch"))
            let hrv = t("HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
            add(hrv.identifier, HealthSample(type: hrv.identifier, start: rhrAt, end: rhrAt, value: Double(rng.next(in: 28...74)), unit: hrv.unit, source: "Demo Watch"))
            let spo2 = t("HKQuantityTypeIdentifierOxygenSaturation")
            add(spo2.identifier, HealthSample(type: spo2.identifier, start: rhrAt, end: rhrAt, value: Double(rng.next(in: 95...99)), unit: spo2.unit, source: "Demo Watch"))
            let resp = t("HKQuantityTypeIdentifierRespiratoryRate")
            add(resp.identifier, HealthSample(type: resp.identifier, start: rhrAt, end: rhrAt, value: Double(rng.next(in: 13...17)), unit: resp.unit, source: "Demo Watch"))

            // Weight every third day.
            if dayOffset % 3 == 0 {
                let mass = t("HKQuantityTypeIdentifierBodyMass")
                let at = cal.date(byAdding: .hour, value: 7, to: day)!
                add(mass.identifier, HealthSample(type: mass.identifier, start: at, end: at, value: 78.0 + Double(rng.next(in: -12...12)) / 10, unit: mass.unit, source: "Demo Scale"))
            }

            // Sleep: previous night into this morning.
            let bedtime = cal.date(byAdding: .minute, value: -(rng.next(in: 60...120)), to: day)!
            var cursor = bedtime
            let wake = cal.date(byAdding: .minute, value: rng.next(in: 6 * 60...7 * 60 + 30), to: day)!
            sleepSegments.append(SleepSegment(start: bedtime, end: wake, stage: .inBed, source: "Demo Watch"))
            let stages: [SleepStage] = [.asleepCore, .asleepDeep, .asleepCore, .asleepREM, .awake, .asleepCore, .asleepDeep, .asleepREM, .asleepCore, .asleepREM]
            var i = 0
            while cursor < wake {
                let stage = stages[i % stages.count]
                let length = stage == .awake ? rng.next(in: 3...12) : rng.next(in: 25...70)
                let end = min(cal.date(byAdding: .minute, value: length, to: cursor)!, wake)
                sleepSegments.append(SleepSegment(start: cursor, end: end, stage: stage, source: "Demo Watch"))
                cursor = end
                i += 1
            }

            // Workouts a few times a week.
            if [1, 3, 5].contains(cal.component(.weekday, from: day)) || (weekend && rng.next(in: 0...1) == 1) {
                let kinds = ["running", "cycling", "functionalStrengthTraining", "walking", "yoga"]
                let kind = kinds[rng.next(in: 0...(kinds.count - 1))]
                let start = cal.date(byAdding: .minute, value: (weekend ? 9 : 17) * 60 + rng.next(in: 0...45), to: day)!
                let minutes = Double(rng.next(in: 25...65))
                let end = start.addingTimeInterval(minutes * 60)
                let distance: Double? = ["running", "cycling", "walking"].contains(kind) ? (minutes * (kind == "cycling" ? 0.4 : 0.16) * 10).rounded() / 10 : nil
                workouts.append(Workout(activityType: kind, start: start, end: end, durationMinutes: minutes,
                                        totalEnergyKcal: (minutes * Double(rng.next(in: 6...11))).rounded(), totalDistanceKm: distance,
                                        averageHeartRate: Double(rng.next(in: 120...155)), maxHeartRate: Double(rng.next(in: 160...182)),
                                        source: "Demo Watch"))
            }
        }

        for key in samples.keys { samples[key]?.sort { $0.start < $1.start } }
        self.samplesByType = samples
        self.sleep = sleepSegments
        self.workoutList = workouts
    }

    public func status() async -> ProviderStatus {
        let all = samplesByType.values.flatMap { $0 }
        let range = all.isEmpty ? nil : DateInterval(start: all.map(\.start).min()!, end: all.map(\.end).max()!)
        return ProviderStatus(kind: kind, description: "Demo data (\(days) days, synthetic)", available: true,
                              authorization: .notApplicable, detail: "Synthetic data for evaluating the bridge. Not a real person.",
                              supportsClinicalRecords: true, dataRange: range, sampleCount: all.count)
    }

    public func availableTypes() async -> [HealthDataType] {
        HealthTypeCatalog.all.filter { samplesByType[$0.identifier] != nil || $0.identifier == "HKCategoryTypeIdentifierSleepAnalysis" }
    }

    public func requestAuthorization() async throws {}

    public func samples(of type: HealthDataType, in range: DateInterval?, limit: Int, ascending: Bool) async throws -> [HealthSample] {
        var list = samplesByType[type.identifier] ?? []
        if type.identifier == "HKCategoryTypeIdentifierSleepAnalysis" {
            list = sleep.map { HealthSample(type: type.identifier, start: $0.start, end: $0.end, value: Double($0.stage.rawCategoryValue),
                                            unit: "", categoryValue: $0.stage.rawValue, source: $0.source) }
        }
        if let range { list = list.filter { $0.end >= range.start && $0.start < range.end } }
        list.sort { ascending ? $0.start < $1.start : $0.start > $1.start }
        return Array(list.prefix(limit))
    }

    public func statistics(of type: HealthDataType, in range: DateInterval, interval: StatisticsInterval) async throws -> [StatisticsBucket] {
        let list = try await samples(of: type, in: range, limit: Int.max, ascending: true)
        return HealthMath.buckets(for: list, type: type, range: range, interval: interval)
    }

    public func latestSample(of type: HealthDataType) async throws -> HealthSample? {
        try await samples(of: type, in: nil, limit: 1, ascending: false).first
    }

    public func sleepSegments(in range: DateInterval) async throws -> [SleepSegment] {
        sleep.filter { $0.end >= range.start && $0.start < range.end }
    }

    public func workouts(in range: DateInterval?, activityType: String?, limit: Int) async throws -> [Workout] {
        var list = workoutList
        if let range { list = list.filter { $0.start >= range.start && $0.start < range.end } }
        if let activityType { list = list.filter { $0.activityType.lowercased() == activityType.lowercased() } }
        return Array(list.sorted { $0.start > $1.start }.prefix(limit))
    }

    public func characteristics() async throws -> Characteristics {
        Characteristics(dateOfBirth: "1988-04-12", ageYears: Calendar.current.dateComponents([.year], from: ISO8601.date(from: "1988-04-12")!, to: Date()).year,
                        biologicalSex: "notSet", bloodType: "notSet", fitzpatrickSkinType: "notSet", wheelchairUse: "no", activityMoveMode: "activeEnergy")
    }

    public func clinicalRecords(kind: ClinicalRecordKind?, since: Date?, limit: Int) async throws -> [ClinicalRecord] {
        let records: [ClinicalRecord] = [
            ClinicalRecord(kind: .immunizationRecord, displayName: "Influenza vaccine", fhirResourceType: "Immunization", fhirVersion: "4.0.1",
                           identifier: "demo-imm-1", source: "Demo Clinic", date: ISO8601.date(from: "2025-10-14"),
                           resource: ["resourceType": "Immunization", "id": "demo-imm-1", "status": "completed",
                                      "vaccineCode": ["text": "Influenza, seasonal, injectable"], "occurrenceDateTime": "2025-10-14"]),
            ClinicalRecord(kind: .labResultRecord, displayName: "Hemoglobin A1c", fhirResourceType: "Observation", fhirVersion: "4.0.1",
                           identifier: "demo-obs-1", source: "Demo Clinic", date: ISO8601.date(from: "2026-03-02"),
                           resource: ["resourceType": "Observation", "id": "demo-obs-1", "status": "final",
                                      "code": ["coding": [["system": "http://loinc.org", "code": "4548-4", "display": "Hemoglobin A1c"]]],
                                      "valueQuantity": ["value": 5.4, "unit": "%"], "effectiveDateTime": "2026-03-02"]),
            ClinicalRecord(kind: .medicationRecord, displayName: "Atorvastatin 10 mg", fhirResourceType: "MedicationRequest", fhirVersion: "4.0.1",
                           identifier: "demo-med-1", source: "Demo Clinic", date: ISO8601.date(from: "2026-01-20"),
                           resource: ["resourceType": "MedicationRequest", "id": "demo-med-1", "status": "active",
                                      "medicationCodeableConcept": ["text": "Atorvastatin 10 mg tablet"], "authoredOn": "2026-01-20"]),
        ]
        return records
            .filter { kind == nil || $0.kind == kind }
            .filter { since == nil || ($0.date ?? .distantPast) >= since! }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

/// SplitMix64: small, deterministic, good enough for demo data.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % span)
    }
}
