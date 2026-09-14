import Foundation

/// How samples of a type combine over time.
public enum AggregationStyle: String, Codable, Sendable {
    /// Values add up (steps, energy, distance).
    case cumulative
    /// Values are independent readings (heart rate, weight, SpO2).
    case discrete
}

public enum HealthDataKind: String, Codable, Sendable {
    case quantity
    case category
}

public enum HealthCategory: String, Codable, Sendable, CaseIterable {
    case activity, vitals, body, heart, respiratory, sleep, nutrition, mobility, hearing, mindfulness, reproductive, other
}

/// One entry in the supported-type catalog. `identifier` is the HealthKit
/// identifier (also what the Health export XML uses), which keeps every
/// provider speaking the same vocabulary.
public struct HealthDataType: Codable, Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let kind: HealthDataKind
    public let unit: String
    public let aggregation: AggregationStyle
    public let category: HealthCategory
    public let description: String

    public init(identifier: String, name: String, kind: HealthDataKind, unit: String, aggregation: AggregationStyle,
                category: HealthCategory, description: String) {
        self.identifier = identifier
        self.name = name
        self.kind = kind
        self.unit = unit
        self.aggregation = aggregation
        self.category = category
        self.description = description
    }

    /// A short alias agents can use instead of the full identifier, e.g. `stepCount`.
    public var shortName: String {
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier"] where identifier.hasPrefix(prefix) {
            return String(identifier.dropFirst(prefix.count)).lowercasedFirst
        }
        return identifier
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// The catalog of types the bridge understands. Providers may support a subset.
public enum HealthTypeCatalog {
    public static let all: [HealthDataType] = [
        // Activity
        q("StepCount", "Steps", "count", .cumulative, .activity, "Steps taken."),
        q("DistanceWalkingRunning", "Walking + Running Distance", "km", .cumulative, .activity, "Distance covered on foot."),
        q("DistanceCycling", "Cycling Distance", "km", .cumulative, .activity, "Distance cycled."),
        q("DistanceSwimming", "Swimming Distance", "m", .cumulative, .activity, "Distance swum."),
        q("FlightsClimbed", "Flights Climbed", "count", .cumulative, .activity, "Floors climbed."),
        q("ActiveEnergyBurned", "Active Energy", "kcal", .cumulative, .activity, "Energy burned through activity."),
        q("BasalEnergyBurned", "Resting Energy", "kcal", .cumulative, .activity, "Energy burned at rest."),
        q("AppleExerciseTime", "Exercise Minutes", "min", .cumulative, .activity, "Minutes of brisk activity."),
        q("AppleStandTime", "Stand Minutes", "min", .cumulative, .activity, "Minutes spent standing and moving."),
        q("AppleMoveTime", "Move Minutes", "min", .cumulative, .activity, "Minutes of movement (move mode)."),
        q("PhysicalEffort", "Physical Effort", "kcal/(kg·hr)", .discrete, .activity, "Estimated MET-style effort."),
        q("TimeInDaylight", "Time in Daylight", "min", .cumulative, .activity, "Minutes spent in daylight."),
        c("AppleStandHour", "Stand Hours", .activity, "Hours in which the user stood (0 = stood, 1 = idle)."),

        // Heart
        q("HeartRate", "Heart Rate", "count/min", .discrete, .heart, "Instantaneous heart rate."),
        q("RestingHeartRate", "Resting Heart Rate", "count/min", .discrete, .heart, "Daily resting heart rate estimate."),
        q("WalkingHeartRateAverage", "Walking Heart Rate Average", "count/min", .discrete, .heart, "Average heart rate while walking."),
        q("HeartRateVariabilitySDNN", "Heart Rate Variability", "ms", .discrete, .heart, "HRV (SDNN)."),
        q("HeartRateRecoveryOneMinute", "Cardio Recovery", "count/min", .discrete, .heart, "Heart rate drop one minute after exercise."),
        q("AtrialFibrillationBurden", "AFib History", "%", .discrete, .heart, "Percentage of time in atrial fibrillation."),
        q("VO2Max", "Cardio Fitness (VO2 max)", "mL/min·kg", .discrete, .heart, "Estimated maximal oxygen uptake."),
        q("BloodPressureSystolic", "Blood Pressure (Systolic)", "mmHg", .discrete, .vitals, "Systolic blood pressure."),
        q("BloodPressureDiastolic", "Blood Pressure (Diastolic)", "mmHg", .discrete, .vitals, "Diastolic blood pressure."),
        c("LowHeartRateEvent", "Low Heart Rate Events", .heart, "Low heart rate notifications."),
        c("HighHeartRateEvent", "High Heart Rate Events", .heart, "High heart rate notifications."),
        c("IrregularHeartRhythmEvent", "Irregular Rhythm Events", .heart, "Irregular rhythm notifications."),

        // Respiratory / vitals
        q("OxygenSaturation", "Blood Oxygen", "%", .discrete, .respiratory, "SpO2."),
        q("RespiratoryRate", "Respiratory Rate", "count/min", .discrete, .respiratory, "Breaths per minute."),
        q("BodyTemperature", "Body Temperature", "degC", .discrete, .vitals, "Body temperature."),
        q("AppleSleepingWristTemperature", "Wrist Temperature", "degC", .discrete, .vitals, "Sleeping wrist temperature."),
        q("BloodGlucose", "Blood Glucose", "mg/dL", .discrete, .vitals, "Blood glucose."),
        q("PeripheralPerfusionIndex", "Peripheral Perfusion Index", "%", .discrete, .vitals, "Perfusion index."),

        // Body
        q("BodyMass", "Weight", "kg", .discrete, .body, "Body weight."),
        q("BodyMassIndex", "Body Mass Index", "count", .discrete, .body, "BMI."),
        q("BodyFatPercentage", "Body Fat Percentage", "%", .discrete, .body, "Body fat."),
        q("LeanBodyMass", "Lean Body Mass", "kg", .discrete, .body, "Lean body mass."),
        q("Height", "Height", "cm", .discrete, .body, "Height."),
        q("WaistCircumference", "Waist Circumference", "cm", .discrete, .body, "Waist circumference."),

        // Sleep
        c("SleepAnalysis", "Sleep", .sleep, "Sleep stages: inBed, asleepUnspecified, awake, asleepCore, asleepDeep, asleepREM."),

        // Mobility
        q("WalkingSpeed", "Walking Speed", "km/h", .discrete, .mobility, "Walking speed."),
        q("WalkingStepLength", "Walking Step Length", "cm", .discrete, .mobility, "Step length."),
        q("WalkingAsymmetryPercentage", "Walking Asymmetry", "%", .discrete, .mobility, "Gait asymmetry."),
        q("WalkingDoubleSupportPercentage", "Double Support Time", "%", .discrete, .mobility, "Double support percentage."),
        q("SixMinuteWalkTestDistance", "Six-Minute Walk", "m", .discrete, .mobility, "Six-minute walk test distance."),
        q("StairAscentSpeed", "Stair Speed: Up", "m/s", .discrete, .mobility, "Stair ascent speed."),
        q("StairDescentSpeed", "Stair Speed: Down", "m/s", .discrete, .mobility, "Stair descent speed."),
        q("AppleWalkingSteadiness", "Walking Steadiness", "%", .discrete, .mobility, "Walking steadiness."),
        q("RunningPower", "Running Power", "W", .discrete, .mobility, "Running power."),
        q("RunningSpeed", "Running Speed", "km/h", .discrete, .mobility, "Running speed."),

        // Hearing
        q("EnvironmentalAudioExposure", "Environmental Sound Levels", "dBASPL", .discrete, .hearing, "Ambient sound exposure."),
        q("HeadphoneAudioExposure", "Headphone Audio Levels", "dBASPL", .discrete, .hearing, "Headphone sound exposure."),

        // Nutrition
        q("DietaryEnergyConsumed", "Dietary Energy", "kcal", .cumulative, .nutrition, "Calories consumed."),
        q("DietaryWater", "Water", "mL", .cumulative, .nutrition, "Water consumed."),
        q("DietaryCaffeine", "Caffeine", "mg", .cumulative, .nutrition, "Caffeine consumed."),
        q("DietaryProtein", "Protein", "g", .cumulative, .nutrition, "Protein consumed."),
        q("DietaryCarbohydrates", "Carbohydrates", "g", .cumulative, .nutrition, "Carbohydrates consumed."),
        q("DietaryFatTotal", "Total Fat", "g", .cumulative, .nutrition, "Fat consumed."),
        q("DietaryFiber", "Fiber", "g", .cumulative, .nutrition, "Fiber consumed."),
        q("DietarySugar", "Sugar", "g", .cumulative, .nutrition, "Sugar consumed."),

        // Mindfulness / reproductive
        c("MindfulSession", "Mindful Minutes", .mindfulness, "Mindfulness sessions."),
        c("MenstrualFlow", "Menstruation", .reproductive, "Menstrual flow (1 unspecified, 2 light, 3 medium, 4 heavy, 5 none)."),
    ]

    public static let byIdentifier: [String: HealthDataType] = {
        var dict: [String: HealthDataType] = [:]
        for t in all { dict[t.identifier] = t }
        return dict
    }()

    private static let byShortName: [String: HealthDataType] = {
        var dict: [String: HealthDataType] = [:]
        for t in all { dict[t.shortName.lowercased()] = t }
        return dict
    }()

    /// Resolves an identifier, a short alias (`stepCount`, `heart_rate`), or a
    /// display name, case-insensitively.
    public static func resolve(_ raw: String) -> HealthDataType? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = byIdentifier[trimmed] { return t }
        let collapsed = trimmed.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        if let t = byShortName[collapsed] { return t }
        if let t = all.first(where: { $0.name.replacingOccurrences(of: " ", with: "").lowercased() == collapsed }) { return t }
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier"] {
            if let t = byIdentifier[prefix + trimmed] { return t }
        }
        return nil
    }

    private static func q(_ id: String, _ name: String, _ unit: String, _ agg: AggregationStyle, _ cat: HealthCategory,
                          _ desc: String) -> HealthDataType {
        HealthDataType(identifier: "HKQuantityTypeIdentifier" + id, name: name, kind: .quantity, unit: unit,
                       aggregation: agg, category: cat, description: desc)
    }

    private static func c(_ id: String, _ name: String, _ cat: HealthCategory, _ desc: String) -> HealthDataType {
        HealthDataType(identifier: "HKCategoryTypeIdentifier" + id, name: name, kind: .category, unit: "",
                       aggregation: .discrete, category: cat, description: desc)
    }
}

// MARK: - Samples

public struct HealthSample: Codable, Equatable, Sendable {
    public var type: String
    public var start: Date
    public var end: Date
    /// Numeric value for quantity types; the raw category value for category types.
    public var value: Double
    public var unit: String
    /// Human-readable category value (e.g. `asleepDeep`) for category samples.
    public var categoryValue: String?
    public var source: String?
    public var device: String?
    public var metadata: [String: String]?

    public init(type: String, start: Date, end: Date, value: Double, unit: String, categoryValue: String? = nil,
                source: String? = nil, device: String? = nil, metadata: [String: String]? = nil) {
        self.type = type
        self.start = start
        self.end = end
        self.value = value
        self.unit = unit
        self.categoryValue = categoryValue
        self.source = source
        self.device = device
        self.metadata = metadata
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public enum StatisticsInterval: String, Codable, Sendable, CaseIterable {
    case hour, day, week, month

    public var component: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    public var dateComponents: DateComponents {
        switch self {
        case .hour: return DateComponents(hour: 1)
        case .day: return DateComponents(day: 1)
        case .week: return DateComponents(day: 7)
        case .month: return DateComponents(month: 1)
        }
    }
}

public struct StatisticsBucket: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var count: Int
    public var sum: Double?
    public var average: Double?
    public var min: Double?
    public var max: Double?
    public var unit: String

    public init(start: Date, end: Date, count: Int, sum: Double? = nil, average: Double? = nil, min: Double? = nil,
                max: Double? = nil, unit: String) {
        self.start = start
        self.end = end
        self.count = count
        self.sum = sum
        self.average = average
        self.min = min
        self.max = max
        self.unit = unit
    }
}

// MARK: - Sleep

public enum SleepStage: String, Codable, Sendable, CaseIterable {
    case inBed, asleepUnspecified, awake, asleepCore, asleepDeep, asleepREM

    /// HKCategoryValueSleepAnalysis raw values.
    public init?(rawCategoryValue: Int) {
        switch rawCategoryValue {
        case 0: self = .inBed
        case 1: self = .asleepUnspecified
        case 2: self = .awake
        case 3: self = .asleepCore
        case 4: self = .asleepDeep
        case 5: self = .asleepREM
        default: return nil
        }
    }

    public var rawCategoryValue: Int {
        switch self {
        case .inBed: return 0
        case .asleepUnspecified: return 1
        case .awake: return 2
        case .asleepCore: return 3
        case .asleepDeep: return 4
        case .asleepREM: return 5
        }
    }

    /// Parses the Health export spelling, e.g. `HKCategoryValueSleepAnalysisAsleepDeep`.
    public init?(exportValue: String) {
        let suffix = exportValue.replacingOccurrences(of: "HKCategoryValueSleepAnalysis", with: "")
        switch suffix.lowercased() {
        case "inbed": self = .inBed
        case "asleep", "asleepunspecified": self = .asleepUnspecified
        case "awake": self = .awake
        case "asleepcore": self = .asleepCore
        case "asleepdeep": self = .asleepDeep
        case "asleeprem": self = .asleepREM
        default: return nil
        }
    }

    public var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: return true
        case .inBed, .awake: return false
        }
    }
}

public struct SleepSegment: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public var source: String?

    public init(start: Date, end: Date, stage: SleepStage, source: String? = nil) {
        self.start = start
        self.end = end
        self.stage = stage
        self.source = source
    }

    public var minutes: Double { end.timeIntervalSince(start) / 60 }
}

/// One night of sleep, keyed by the calendar day the user woke up.
public struct SleepNight: Codable, Equatable, Sendable {
    public var date: String
    public var bedtime: Date
    public var wakeTime: Date
    public var inBedMinutes: Double
    public var asleepMinutes: Double
    public var awakeMinutes: Double
    public var coreMinutes: Double
    public var deepMinutes: Double
    public var remMinutes: Double
    public var unspecifiedMinutes: Double
    public var segments: [SleepSegment]?
}

// MARK: - Workouts

public struct Workout: Codable, Equatable, Sendable {
    public var activityType: String
    public var start: Date
    public var end: Date
    public var durationMinutes: Double
    public var totalEnergyKcal: Double?
    public var totalDistanceKm: Double?
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    public var source: String?
    public var metadata: [String: String]?

    public init(activityType: String, start: Date, end: Date, durationMinutes: Double, totalEnergyKcal: Double? = nil,
                totalDistanceKm: Double? = nil, averageHeartRate: Double? = nil, maxHeartRate: Double? = nil,
                source: String? = nil, metadata: [String: String]? = nil) {
        self.activityType = activityType
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.totalEnergyKcal = totalEnergyKcal
        self.totalDistanceKm = totalDistanceKm
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.source = source
        self.metadata = metadata
    }
}

// MARK: - Characteristics

public struct Characteristics: Codable, Equatable, Sendable {
    public var dateOfBirth: String?
    public var ageYears: Int?
    public var biologicalSex: String?
    public var bloodType: String?
    public var fitzpatrickSkinType: String?
    public var wheelchairUse: String?
    public var activityMoveMode: String?

    public init(dateOfBirth: String? = nil, ageYears: Int? = nil, biologicalSex: String? = nil, bloodType: String? = nil,
                fitzpatrickSkinType: String? = nil, wheelchairUse: String? = nil, activityMoveMode: String? = nil) {
        self.dateOfBirth = dateOfBirth
        self.ageYears = ageYears
        self.biologicalSex = biologicalSex
        self.bloodType = bloodType
        self.fitzpatrickSkinType = fitzpatrickSkinType
        self.wheelchairUse = wheelchairUse
        self.activityMoveMode = activityMoveMode
    }
}

// MARK: - Clinical records (FHIR)

public enum ClinicalRecordKind: String, Codable, Sendable, CaseIterable {
    case allergyRecord, conditionRecord, coverageRecord, immunizationRecord, labResultRecord, medicationRecord,
         procedureRecord, vitalSignRecord, clinicalNoteRecord

    public var healthKitIdentifier: String { "HKClinicalTypeIdentifier" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Maps a FHIR resource type to the HealthKit clinical record kind.
    public init?(fhirResourceType: String) {
        switch fhirResourceType {
        case "AllergyIntolerance": self = .allergyRecord
        case "Condition": self = .conditionRecord
        case "Coverage": self = .coverageRecord
        case "Immunization": self = .immunizationRecord
        case "Observation": self = .labResultRecord
        case "MedicationOrder", "MedicationRequest", "MedicationStatement", "MedicationDispense": self = .medicationRecord
        case "Procedure": self = .procedureRecord
        case "DocumentReference", "DiagnosticReport": self = .clinicalNoteRecord
        default: return nil
        }
    }
}

public struct ClinicalRecord: Codable, Equatable, Sendable {
    public var kind: ClinicalRecordKind
    public var displayName: String
    public var fhirResourceType: String
    public var fhirVersion: String?
    public var identifier: String?
    public var sourceURL: String?
    public var source: String?
    public var date: Date?
    /// The FHIR resource as JSON.
    public var resource: JSONValue

    public init(kind: ClinicalRecordKind, displayName: String, fhirResourceType: String, fhirVersion: String? = nil,
                identifier: String? = nil, sourceURL: String? = nil, source: String? = nil, date: Date? = nil,
                resource: JSONValue) {
        self.kind = kind
        self.displayName = displayName
        self.fhirResourceType = fhirResourceType
        self.fhirVersion = fhirVersion
        self.identifier = identifier
        self.sourceURL = sourceURL
        self.source = source
        self.date = date
        self.resource = resource
    }
}

// MARK: - Daily summary

public struct DailySummary: Codable, Equatable, Sendable {
    public var date: String
    public var steps: Double?
    public var distanceKm: Double?
    public var activeEnergyKcal: Double?
    public var exerciseMinutes: Double?
    public var standHours: Double?
    public var flightsClimbed: Double?
    public var restingHeartRate: Double?
    public var heartRateAverage: Double?
    public var heartRateMin: Double?
    public var heartRateMax: Double?
    public var hrvSDNN: Double?
    public var respiratoryRate: Double?
    public var oxygenSaturation: Double?
    public var sleepAsleepMinutes: Double?
    public var sleepInBedMinutes: Double?
    public var bodyMassKg: Double?
    public var workouts: [Workout]
}

// MARK: - Errors

public enum HealthDataError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case notAuthorized(String)
    case unsupportedType(String)
    case invalidArgument(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let s): return "Health data unavailable: \(s)"
        case .notAuthorized(let s): return "Not authorized: \(s)"
        case .unsupportedType(let s): return "Unsupported type: \(s)"
        case .invalidArgument(let s): return "Invalid argument: \(s)"
        case .internalError(let s): return "Internal error: \(s)"
        }
    }
}
