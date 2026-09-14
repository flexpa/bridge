import Foundation
import HealthKit

/// Maps Apple's internal integer type codes (the `data_type` column in
/// `healthdb_secure.sqlite`) to HealthKit identifiers.
///
/// The authoritative source is the HealthKit framework on this Mac: every
/// `HKObjectType` carries its code in a private `code` property, and the macOS
/// SDK gains new types the same year iOS does. A small seed table, verified
/// against the framework on 2026-09-14, covers the case where the private
/// property disappears; disagreements between the two are reported, never
/// silently resolved.
public struct TypeCodeTable: Sendable {
    public let codeToIdentifier: [Int: String]
    public let identifierToCode: [String: Int]
    /// Identifiers whose code came from the framework (vs. the seed).
    public let derivedFromFramework: Set<String>
    /// Codes where the framework and the seed disagree: (code, framework identifier, seed identifier).
    public let conflicts: [(Int, String, String)]

    public static let workoutIdentifier = "HKWorkoutTypeIdentifier"

    /// Verified on macOS 26.4.1 with Xcode 26.
    static let seed: [Int: String] = [
        3: "HKQuantityTypeIdentifierBodyMass",
        5: "HKQuantityTypeIdentifierHeartRate",
        7: "HKQuantityTypeIdentifierStepCount",
        8: "HKQuantityTypeIdentifierDistanceWalkingRunning",
        10: "HKQuantityTypeIdentifierActiveEnergyBurned",
        63: "HKCategoryTypeIdentifierSleepAnalysis",
        70: "HKCategoryTypeIdentifierAppleStandHour",
        79: workoutIdentifier,
        139: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        279: "HKQuantityTypeIdentifierTimeInDaylight",
    ]

    /// Every HealthKit sample identifier we know how to ask the framework about.
    /// The catalog is a subset; the rest lets us name types we do not serve yet.
    static let quantityIdentifiers: [String] = [
        "BodyMassIndex", "BodyFatPercentage", "Height", "BodyMass", "LeanBodyMass", "WaistCircumference",
        "AppleSleepingWristTemperature", "StepCount", "DistanceWalkingRunning", "DistanceCycling", "DistanceWheelchair",
        "BasalEnergyBurned", "ActiveEnergyBurned", "FlightsClimbed", "NikeFuel", "AppleExerciseTime", "PushCount",
        "DistanceSwimming", "SwimmingStrokeCount", "VO2Max", "DistanceDownhillSnowSports", "AppleStandTime",
        "WalkingSpeed", "WalkingDoubleSupportPercentage", "WalkingAsymmetryPercentage", "WalkingStepLength",
        "SixMinuteWalkTestDistance", "StairAscentSpeed", "StairDescentSpeed", "AppleMoveTime", "AppleWalkingSteadiness",
        "RunningStrideLength", "RunningVerticalOscillation", "RunningGroundContactTime", "RunningPower", "RunningSpeed",
        "CyclingSpeed", "CyclingPower", "CyclingFunctionalThresholdPower", "CyclingCadence", "PhysicalEffort",
        "TimeInDaylight", "HeartRate", "BodyTemperature", "BasalBodyTemperature", "BloodPressureSystolic",
        "BloodPressureDiastolic", "RespiratoryRate", "RestingHeartRate", "WalkingHeartRateAverage",
        "HeartRateVariabilitySDNN", "HeartRateRecoveryOneMinute", "AtrialFibrillationBurden", "OxygenSaturation",
        "PeripheralPerfusionIndex", "BloodGlucose", "NumberOfTimesFallen", "ElectrodermalActivity", "InhalerUsage",
        "InsulinDelivery", "BloodAlcoholContent", "ForcedVitalCapacity", "ForcedExpiratoryVolume1",
        "PeakExpiratoryFlowRate", "EnvironmentalAudioExposure", "HeadphoneAudioExposure", "EnvironmentalSoundReduction",
        "NumberOfAlcoholicBeverages", "DietaryFatTotal", "DietaryFatPolyunsaturated", "DietaryFatMonounsaturated",
        "DietaryFatSaturated", "DietaryCholesterol", "DietarySodium", "DietaryCarbohydrates", "DietaryFiber",
        "DietarySugar", "DietaryEnergyConsumed", "DietaryProtein", "DietaryVitaminA", "DietaryVitaminB6",
        "DietaryVitaminB12", "DietaryVitaminC", "DietaryVitaminD", "DietaryVitaminE", "DietaryVitaminK",
        "DietaryCalcium", "DietaryIron", "DietaryThiamin", "DietaryRiboflavin", "DietaryNiacin", "DietaryFolate",
        "DietaryBiotin", "DietaryPantothenicAcid", "DietaryPhosphorus", "DietaryIodine", "DietaryMagnesium",
        "DietaryZinc", "DietarySelenium", "DietaryCopper", "DietaryManganese", "DietaryChromium", "DietaryMolybdenum",
        "DietaryChloride", "DietaryPotassium", "DietaryCaffeine", "DietaryWater", "UVExposure", "UnderwaterDepth",
        "WaterTemperature", "AppleSleepingBreathingDisturbances", "CrossCountrySkiingSpeed", "DistanceCrossCountrySkiing",
        "DistancePaddleSports", "DistanceRowing", "DistanceSkatingSports", "EstimatedWorkoutEffortScore",
        "PaddleSportsSpeed", "RowingSpeed", "WorkoutEffortScore",
    ]

    static let categoryIdentifiers: [String] = [
        "SleepAnalysis", "AppleStandHour", "CervicalMucusQuality", "OvulationTestResult", "MenstrualFlow",
        "IntermenstrualBleeding", "SexualActivity", "MindfulSession", "HighHeartRateEvent", "LowHeartRateEvent",
        "IrregularHeartRhythmEvent", "AudioExposureEvent", "ToothbrushingEvent", "PregnancyTestResult",
        "ProgesteroneTestResult", "EnvironmentalAudioExposureEvent", "HeadphoneAudioExposureEvent", "HandwashingEvent",
        "LowCardioFitnessEvent", "AppleWalkingSteadinessEvent", "InfrequentMenstrualCycles", "IrregularMenstrualCycles",
        "PersistentIntermenstrualBleeding", "ProlongedMenstrualPeriods", "Lactation", "Contraceptive", "Pregnancy",
        "AbdominalCramps", "Acne", "AppetiteChanges", "BladderIncontinence", "Bloating", "BreastPain", "ChestTightnessOrPain",
        "Chills", "Constipation", "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting", "Fatigue", "Fever",
        "GeneralizedBodyAche", "HairLoss", "Headache", "Heartburn", "HotFlashes", "LossOfSmell", "LossOfTaste",
        "LowerBackPain", "MemoryLapse", "MoodChanges", "Nausea", "NightSweats", "PelvicPain", "RapidPoundingOrFlutteringHeartbeat",
        "RunnyNose", "ShortnessOfBreath", "SinusCongestion", "SkippedHeartbeat", "SleepChanges", "SoreThroat",
        "VaginalDryness", "Vomiting", "Wheezing", "SleepApneaEvent", "BleedingDuringPregnancy", "BleedingAfterPregnancy",
        "MenopausalState", "BleedingAfterMenopause",
    ]

    /// Builds the table from the framework, falling back to the seed for anything it cannot resolve.
    public static func fromFramework() -> TypeCodeTable {
        var codeToID: [Int: String] = [:]
        var idToCode: [String: Int] = [:]
        var derived = Set<String>()
        var conflicts: [(Int, String, String)] = []

        func record(_ identifier: String, _ type: HKObjectType?) {
            guard let type, let code = privateCode(of: type) else { return }
            codeToID[code] = identifier
            idToCode[identifier] = code
            derived.insert(identifier)
        }
        for suffix in quantityIdentifiers {
            let id = "HKQuantityTypeIdentifier" + suffix
            record(id, HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)))
        }
        for suffix in categoryIdentifiers {
            let id = "HKCategoryTypeIdentifier" + suffix
            record(id, HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: id)))
        }
        record(workoutIdentifier, HKObjectType.workoutType())
        // Non-quantity object types. We do not serve them yet, but naming them turns an
        // "unknown code" into "a type we do not serve yet" in the import report.
        for id in [HKCorrelationTypeIdentifier.bloodPressure, .food] {
            record(id.rawValue, HKObjectType.correlationType(forIdentifier: id))
        }
        for id in [HKSeriesType.heartbeat().identifier, HKSeriesType.workoutRoute().identifier] {
            record(id, id == HKSeriesType.heartbeat().identifier ? HKSeriesType.heartbeat() : HKSeriesType.workoutRoute())
        }
        record(HKObjectType.electrocardiogramType().identifier, HKObjectType.electrocardiogramType())
        record(HKObjectType.audiogramSampleType().identifier, HKObjectType.audiogramSampleType())
        record(HKObjectType.activitySummaryType().identifier, HKObjectType.activitySummaryType())
        record(HKObjectType.visionPrescriptionType().identifier, HKObjectType.visionPrescriptionType())
        if #available(macOS 15.0, *) {
            record(HKObjectType.stateOfMindType().identifier, HKObjectType.stateOfMindType())
        }
        for kind in ClinicalRecordKind.allCases {
            record(kind.healthKitIdentifier, HKObjectType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: kind.healthKitIdentifier)))
        }

        for (code, identifier) in seed {
            if let fromFramework = codeToID[code] {
                if fromFramework != identifier { conflicts.append((code, fromFramework, identifier)) }
            } else if idToCode[identifier] == nil {
                codeToID[code] = identifier
                idToCode[identifier] = code
            }
        }
        return TypeCodeTable(codeToIdentifier: codeToID, identifierToCode: idToCode, derivedFromFramework: derived, conflicts: conflicts)
    }

    /// Seed-only table, for tests and for platforms where the framework refuses to answer.
    public static var seedOnly: TypeCodeTable {
        var idToCode: [String: Int] = [:]
        for (c, id) in seed { idToCode[id] = c }
        return TypeCodeTable(codeToIdentifier: seed, identifierToCode: idToCode, derivedFromFramework: [], conflicts: [])
    }

    /// Reads the private `-[HKObjectType code]` property, if present.
    static func privateCode(of type: HKObjectType) -> Int? {
        let selector = Selector(("code"))
        guard type.responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int
        let imp = type.method(for: selector)
        let value = unsafeBitCast(imp, to: Fn.self)(type, selector)
        // Body mass index is code 0; negative means the framework has no code for this type.
        return value >= 0 ? value : nil
    }

    public func identifier(for code: Int) -> String? { codeToIdentifier[code] }
    public func code(for identifier: String) -> Int? { identifierToCode[identifier] }
}

/// The unit `quantity_samples.quantity` is stored in, per type. HealthKit keeps
/// each quantity in the type's canonical unit, which the framework exposes
/// through the private `-[HKQuantityType canonicalUnit]`. Heart rate, for
/// example, is stored in count/s (72 bpm is 1.2), while resting heart rate is
/// count/min; a hand-written table gets those wrong, the framework does not.
public enum CanonicalUnits {
    /// Verified against the framework on macOS 26.4.1; used only when the private API is missing.
    static let seed: [String: String] = [
        "HKQuantityTypeIdentifierStepCount": "count", "HKQuantityTypeIdentifierDistanceWalkingRunning": "m",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "kcal", "HKQuantityTypeIdentifierAppleExerciseTime": "min",
        "HKQuantityTypeIdentifierHeartRate": "count/s", "HKQuantityTypeIdentifierRestingHeartRate": "count/min",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "ms", "HKQuantityTypeIdentifierOxygenSaturation": "%",
        "HKQuantityTypeIdentifierBodyMass": "kg", "HKQuantityTypeIdentifierHeight": "m",
        "HKQuantityTypeIdentifierBodyTemperature": "degC", "HKQuantityTypeIdentifierBloodPressureSystolic": "mmHg",
        "HKQuantityTypeIdentifierBloodGlucose": "mg/dL", "HKQuantityTypeIdentifierVO2Max": "mL/min·kg",
        "HKQuantityTypeIdentifierWalkingSpeed": "m/s", "HKQuantityTypeIdentifierRespiratoryRate": "count/s",
        "HKQuantityTypeIdentifierDietaryWater": "mL", "HKQuantityTypeIdentifierDietaryCaffeine": "g",
        "HKQuantityTypeIdentifierTimeInDaylight": "min", "HKQuantityTypeIdentifierBodyMassIndex": "count",
    ]

    private static let cache: [String: HKUnit] = {
        var out: [String: HKUnit] = [:]
        for t in HealthTypeCatalog.all where t.kind == .quantity {
            if let q = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: t.identifier)), let u = privateCanonicalUnit(q) {
                out[t.identifier] = u
            } else if let s = seed[t.identifier] {
                out[t.identifier] = HKUnit(from: s)
            }
        }
        return out
    }()

    /// The storage unit for a catalog quantity type, or nil when neither the framework nor the seed knows it.
    public static func unit(for identifier: String) -> HKUnit? { cache[identifier] }

    public static func unitString(for identifier: String) -> String? { cache[identifier]?.unitString }

    static func privateCanonicalUnit(_ type: HKQuantityType) -> HKUnit? {
        let selector = Selector(("canonicalUnit"))
        guard type.responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<HKUnit>?
        return unsafeBitCast(type.method(for: selector), to: Fn.self)(type, selector)?.takeUnretainedValue()
    }

    /// Converts a stored `quantity` to the catalog's unit for that type. Percent
    /// units carry fractions in HealthKit (0.97 is 97%), so they are scaled.
    public static func convertStored(_ value: Double, identifier: String, to catalogUnit: String) -> (Double, String)? {
        guard let stored = unit(for: identifier) else { return nil }
        let target = HKUnit(from: HealthKitProvider.healthKitUnitString(catalogUnit))
        if stored.unitString == "%" && target.unitString == "%" { return (value * 100, catalogUnit) }
        let quantity = HKQuantity(unit: stored, doubleValue: value)
        guard quantity.is(compatibleWith: target) else { return (value, stored.unitString) }
        return (quantity.doubleValue(for: target), catalogUnit)
    }
}
