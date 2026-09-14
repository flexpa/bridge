import Foundation
import HealthKit

/// Live HealthKit. On today's macOS the framework links but
/// `HKHealthStore.isHealthDataAvailable()` is false; this provider reports
/// that honestly and becomes fully functional the day Apple turns it on.
public final class HealthKitProvider: HealthDataProvider, @unchecked Sendable {
    public let kind = "healthkit"

    private let store: HKHealthStore?
    private let defaults = UserDefaults.standard
    private let requestedKey = "HealthKitProvider.authorizationRequested"

    public init() {
        store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Type mapping

    private func objectType(for type: HealthDataType) -> HKSampleType? {
        switch type.kind {
        case .quantity: return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: type.identifier))
        case .category: return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: type.identifier))
        }
    }

    private func unit(for type: HealthDataType) -> HKUnit {
        HKUnit(from: Self.healthKitUnitString(type.unit))
    }

    /// The catalog uses friendly unit strings; HKUnit wants its own spelling.
    static func healthKitUnitString(_ unit: String) -> String {
        switch unit {
        case "km/h": return "km/hr"
        case "kcal/(kg·hr)": return "kcal/(kg*hr)"
        case "mL/min·kg": return "mL/(kg*min)"
        default: return unit
        }
    }

    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        for t in HealthTypeCatalog.all {
            if let o = objectType(for: t) { set.insert(o) }
        }
        set.insert(HKObjectType.workoutType())
        for id in [HKCharacteristicTypeIdentifier.dateOfBirth, .biologicalSex, .bloodType, .fitzpatrickSkinType, .wheelchairUse, .activityMoveMode] {
            if let c = HKObjectType.characteristicType(forIdentifier: id) { set.insert(c) }
        }
        if let store, store.supportsHealthRecords() {
            for kind in ClinicalRecordKind.allCases {
                if let c = HKObjectType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: kind.healthKitIdentifier)) {
                    set.insert(c)
                }
            }
        }
        return set
    }

    // MARK: Status

    public func status() async -> ProviderStatus {
        guard let store else {
            return ProviderStatus(
                kind: kind,
                description: "HealthKit (unavailable on this Mac)",
                available: false,
                authorization: .unavailable,
                detail: "HKHealthStore.isHealthDataAvailable() is false. This macOS release has no Health data store. Import a Health app export instead."
            )
        }
        var auth: AuthorizationState = defaults.bool(forKey: requestedKey) ? .requested : .notRequested
        if let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes) {
            switch status {
            case .unnecessary: auth = .requested
            case .shouldRequest: auth = .notRequested
            default: break
            }
        }
        return ProviderStatus(kind: kind, description: "HealthKit (live)", available: true, authorization: auth,
                              detail: auth == .requested ? nil : "Grant Health access from the Flexpa Health Bridge menu.",
                              supportsClinicalRecords: store.supportsHealthRecords())
    }

    public func availableTypes() async -> [HealthDataType] {
        store == nil ? [] : HealthTypeCatalog.all.filter { objectType(for: $0) != nil }
    }

    public func requestAuthorization() async throws {
        guard let store else { throw HealthDataError.unavailable("HealthKit is not available on this Mac") }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        defaults.set(true, forKey: requestedKey)
    }

    // MARK: Queries

    private func requireStore() throws -> HKHealthStore {
        guard let store else { throw HealthDataError.unavailable("HealthKit is not available on this Mac") }
        return store
    }

    private func predicate(for range: DateInterval?) -> NSPredicate? {
        guard let range else { return nil }
        return HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: [])
    }

    private func runSampleQuery(store: HKHealthStore, type: HKSampleType, predicate: NSPredicate?, limit: Int,
                                ascending: Bool) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit == Int.max ? HKObjectQueryNoLimit : limit,
                                      sortDescriptors: [sort]) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(query)
        }
    }

    public func samples(of type: HealthDataType, in range: DateInterval?, limit: Int, ascending: Bool) async throws -> [HealthSample] {
        let store = try requireStore()
        guard let hkType = objectType(for: type) else { throw HealthDataError.unsupportedType(type.identifier) }
        let results = try await runSampleQuery(store: store, type: hkType, predicate: predicate(for: range), limit: limit, ascending: ascending)
        return results.compactMap { convert($0, type: type) }
    }

    private func convert(_ sample: HKSample, type: HealthDataType) -> HealthSample? {
        let source = sample.sourceRevision.source.name
        let device = sample.device?.name
        var metadata: [String: String]? = nil
        if let md = sample.metadata, !md.isEmpty {
            metadata = md.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
        }
        if let q = sample as? HKQuantitySample {
            let hkUnit = unit(for: type)
            guard q.quantity.is(compatibleWith: hkUnit) else { return nil }
            return HealthSample(type: type.identifier, start: q.startDate, end: q.endDate, value: q.quantity.doubleValue(for: hkUnit),
                                unit: type.unit, source: source, device: device, metadata: metadata)
        }
        if let c = sample as? HKCategorySample {
            var label: String? = nil
            if type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
                label = SleepStage(rawCategoryValue: c.value)?.rawValue
            } else if type.identifier == HKCategoryTypeIdentifier.appleStandHour.rawValue {
                label = c.value == 0 ? "stood" : "idle"
            }
            return HealthSample(type: type.identifier, start: c.startDate, end: c.endDate, value: Double(c.value), unit: "",
                                categoryValue: label, source: source, device: device, metadata: metadata)
        }
        return nil
    }

    public func statistics(of type: HealthDataType, in range: DateInterval, interval: StatisticsInterval) async throws -> [StatisticsBucket] {
        let store = try requireStore()
        guard type.kind == .quantity, let qType = objectType(for: type) as? HKQuantityType else {
            // Category types: bucket by hand.
            let list = try await samples(of: type, in: range, limit: Int.max, ascending: true)
            return HealthMath.buckets(for: list, type: type, range: range, interval: interval)
        }
        let options: HKStatisticsOptions = type.aggregation == .cumulative ? [.cumulativeSum] : [.discreteAverage, .discreteMin, .discreteMax]
        let anchor = HealthMath.alignedStart(of: range.start, interval: interval, calendar: .current)
        let hkUnit = unit(for: type)
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(quantityType: qType, quantitySamplePredicate: predicate(for: range), options: options,
                                                    anchorDate: anchor, intervalComponents: interval.dateComponents)
            query.initialResultsHandler = { _, result, error in
                if let error { cont.resume(throwing: error) } else if let result { cont.resume(returning: result) } else {
                    cont.resume(throwing: HealthDataError.internalError("no statistics returned"))
                }
            }
            store.execute(query)
        }
        var buckets: [StatisticsBucket] = []
        collection.enumerateStatistics(from: anchor, to: range.end) { stats, _ in
            switch type.aggregation {
            case .cumulative:
                buckets.append(StatisticsBucket(start: stats.startDate, end: stats.endDate, count: stats.sumQuantity() == nil ? 0 : 1,
                                                sum: stats.sumQuantity()?.doubleValue(for: hkUnit) ?? 0, unit: type.unit))
            case .discrete:
                buckets.append(StatisticsBucket(start: stats.startDate, end: stats.endDate, count: stats.averageQuantity() == nil ? 0 : 1,
                                                average: stats.averageQuantity()?.doubleValue(for: hkUnit),
                                                min: stats.minimumQuantity()?.doubleValue(for: hkUnit),
                                                max: stats.maximumQuantity()?.doubleValue(for: hkUnit), unit: type.unit))
            }
        }
        return buckets
    }

    public func latestSample(of type: HealthDataType) async throws -> HealthSample? {
        try await samples(of: type, in: nil, limit: 1, ascending: false).first
    }

    public func sleepSegments(in range: DateInterval) async throws -> [SleepSegment] {
        let type = HealthTypeCatalog.byIdentifier[HKCategoryTypeIdentifier.sleepAnalysis.rawValue]!
        let list = try await samples(of: type, in: range, limit: Int.max, ascending: true)
        return list.compactMap { s in
            guard let stage = SleepStage(rawCategoryValue: Int(s.value)) else { return nil }
            return SleepSegment(start: s.start, end: s.end, stage: stage, source: s.source)
        }
    }

    public func workouts(in range: DateInterval?, activityType: String?, limit: Int) async throws -> [Workout] {
        let store = try requireStore()
        let results = try await runSampleQuery(store: store, type: HKObjectType.workoutType(), predicate: predicate(for: range),
                                               limit: activityType == nil ? limit : Int.max, ascending: false)
        var list: [Workout] = results.compactMap { $0 as? HKWorkout }.map { w in
            let name = WorkoutActivityNames.name(for: w.workoutActivityType)
            func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
                guard let qt = HKObjectType.quantityType(forIdentifier: id) else { return nil }
                return w.statistics(for: qt)?.sumQuantity()?.doubleValue(for: unit)
            }
            func avg(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> (Double?, Double?) {
                guard let qt = HKObjectType.quantityType(forIdentifier: id), let s = w.statistics(for: qt) else { return (nil, nil) }
                return (s.averageQuantity()?.doubleValue(for: unit), s.maximumQuantity()?.doubleValue(for: unit))
            }
            let energy = sum(.activeEnergyBurned, .kilocalorie())
            let distance = sum(.distanceWalkingRunning, .meterUnit(with: .kilo)) ?? sum(.distanceCycling, .meterUnit(with: .kilo))
                ?? sum(.distanceSwimming, .meterUnit(with: .kilo))
            let hr = avg(.heartRate, HKUnit.count().unitDivided(by: .minute()))
            var metadata: [String: String]? = nil
            if let md = w.metadata, !md.isEmpty { metadata = md.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) } }
            return Workout(activityType: name, start: w.startDate, end: w.endDate, durationMinutes: w.duration / 60,
                           totalEnergyKcal: energy, totalDistanceKm: distance, averageHeartRate: hr.0, maxHeartRate: hr.1,
                           source: w.sourceRevision.source.name, metadata: metadata)
        }
        if let activityType {
            list = list.filter { $0.activityType.lowercased() == activityType.lowercased() }
        }
        return Array(list.prefix(limit))
    }

    public func characteristics() async throws -> Characteristics {
        let store = try requireStore()
        var c = Characteristics()
        if let dob = try? store.dateOfBirthComponents(), let date = Calendar.current.date(from: dob) {
            c.dateOfBirth = ISO8601.dayString(date)
            c.ageYears = Calendar.current.dateComponents([.year], from: date, to: Date()).year
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: c.biologicalSex = "female"
            case .male: c.biologicalSex = "male"
            case .other: c.biologicalSex = "other"
            default: c.biologicalSex = "notSet"
            }
        }
        if let blood = try? store.bloodType().bloodType {
            let names: [HKBloodType: String] = [.aPositive: "A+", .aNegative: "A-", .bPositive: "B+", .bNegative: "B-",
                                                .abPositive: "AB+", .abNegative: "AB-", .oPositive: "O+", .oNegative: "O-"]
            c.bloodType = names[blood] ?? "notSet"
        }
        if let skin = try? store.fitzpatrickSkinType().skinType {
            c.fitzpatrickSkinType = skin == .notSet ? "notSet" : "type\(skin.rawValue)"
        }
        if let wheelchair = try? store.wheelchairUse().wheelchairUse {
            switch wheelchair {
            case .yes: c.wheelchairUse = "yes"
            case .no: c.wheelchairUse = "no"
            default: c.wheelchairUse = "notSet"
            }
        }
        if let mode = try? store.activityMoveMode().activityMoveMode {
            c.activityMoveMode = mode == .appleMoveTime ? "moveTime" : "activeEnergy"
        }
        return c
    }

    public func clinicalRecords(kind: ClinicalRecordKind?, since: Date?, limit: Int) async throws -> [ClinicalRecord] {
        let store = try requireStore()
        guard store.supportsHealthRecords() else { throw HealthDataError.unavailable("Health Records are not supported on this device") }
        let kinds = kind.map { [$0] } ?? ClinicalRecordKind.allCases
        var out: [ClinicalRecord] = []
        for k in kinds {
            guard let type = HKObjectType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: k.healthKitIdentifier)) else { continue }
            let pred = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
            let results = try await runSampleQuery(store: store, type: type, predicate: pred, limit: limit, ascending: false)
            for case let record as HKClinicalRecord in results {
                let resource: JSONValue = record.fhirResource.flatMap { try? JSON.parse($0.data) } ?? .null
                out.append(ClinicalRecord(kind: k, displayName: record.displayName,
                                          fhirResourceType: record.fhirResource?.resourceType.rawValue ?? "Unknown",
                                          fhirVersion: record.fhirResource?.fhirVersion.stringRepresentation,
                                          identifier: record.fhirResource?.identifier,
                                          sourceURL: record.fhirResource?.sourceURL?.absoluteString,
                                          source: record.sourceRevision.source.name, date: record.startDate, resource: resource))
            }
        }
        return Array(out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }
}

/// Friendly names for HKWorkoutActivityType raw values.
enum WorkoutActivityNames {
    static let names: [UInt: String] = [
        1: "americanFootball", 2: "archery", 3: "australianFootball", 4: "badminton", 5: "baseball", 6: "basketball", 7: "bowling",
        8: "boxing", 9: "climbing", 10: "cricket", 11: "crossTraining", 12: "curling", 13: "cycling", 14: "dance",
        16: "elliptical", 17: "equestrianSports", 18: "fencing", 19: "fishing", 20: "functionalStrengthTraining", 21: "golf",
        22: "gymnastics", 23: "handball", 24: "hiking", 25: "hockey", 26: "hunting", 27: "lacrosse", 28: "martialArts",
        29: "mindAndBody", 31: "paddleSports", 32: "play", 33: "preparationAndRecovery", 34: "racquetball", 35: "rowing",
        36: "rugby", 37: "running", 38: "sailing", 39: "skatingSports", 40: "snowSports", 41: "soccer", 42: "softball",
        43: "squash", 44: "stairClimbing", 45: "surfingSports", 46: "swimming", 47: "tableTennis", 48: "tennis",
        49: "trackAndField", 50: "traditionalStrengthTraining", 51: "volleyball", 52: "walking", 53: "waterFitness",
        54: "waterPolo", 55: "waterSports", 56: "wrestling", 57: "yoga", 58: "barre", 59: "coreTraining", 60: "crossCountrySkiing",
        61: "downhillSkiing", 62: "flexibility", 63: "highIntensityIntervalTraining", 64: "jumpRope", 65: "kickboxing",
        66: "pilates", 67: "snowboarding", 68: "stairs", 69: "stepTraining", 70: "wheelchairWalkPace", 71: "wheelchairRunPace",
        72: "taiChi", 73: "mixedCardio", 74: "handCycling", 75: "discSports", 76: "fitnessGaming", 77: "cardioDance",
        78: "socialDance", 79: "pickleball", 80: "cooldown", 82: "swimBikeRun", 83: "transition", 84: "underwaterDiving",
        3000: "other",
    ]

    static func name(for type: HKWorkoutActivityType) -> String {
        names[type.rawValue] ?? "activity\(type.rawValue)"
    }

    /// `HKWorkoutActivityTypeRunning` → `running`.
    static func name(forExportValue value: String) -> String {
        let stripped = value.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        guard let first = stripped.first else { return value }
        return first.lowercased() + stripped.dropFirst()
    }
}
