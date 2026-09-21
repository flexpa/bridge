import Foundation

/// Canonical URLs and code systems from the HL7 Personal Health Record IG
/// (`hl7.fhir.uv.phr`, 1.0.0-ballot2). The Patient Generated Health Data pages
/// define one code per HealthKit type; the profiles fix the category and value type.
/// https://build.fhir.org/ig/HL7/personal-health-record-format-ig/en/pghd-code-mapping.html
public enum PHRIG {
    public static let version = "1.0.0-ballot2"
    public static let canonical = "http://hl7.org/fhir/uv/phr"
    public static let pghdCodeSystem = canonical + "/CodeSystem/observation-pghd-codes"
    public static let sleepAnalysisCodeSystem = canonical + "/CodeSystem/sleep-analysis-codes"
    public static let sleepEpisodeCodeSystem = canonical + "/CodeSystem/sleep-episode-codes"
    public static let observationCategorySystem = "http://terminology.hl7.org/CodeSystem/observation-category"
    public static let provenanceParticipantSystem = "http://terminology.hl7.org/CodeSystem/provenance-participant-type"
    public static let loinc = "http://loinc.org"
    public static let ucum = "http://unitsofmeasure.org"
    /// FHIR's own extension for carrying the same quantity in a second unit (used by the blood glucose profile).
    public static let quantityTranslationExtension = "http://hl7.org/fhir/StructureDefinition/iso21090-PQ-translation"
    public static let ndjsonMediaType = "application/x-ndjson"

    public static func profile(_ name: String) -> String { canonical + "/StructureDefinition/" + name }
}

/// The PGHD profiles this exporter emits, with the observation category each one fixes.
public enum PGHDProfile: String, Sendable, CaseIterable {
    case activity = "pghd-activity"
    case vitalSigns = "pghd-vitalsigns"
    case cardiacFunction = "pghd-cardiac-function"
    case bodyMeasurement = "pghd-bodymeasurement"
    case mobility = "pghd-mobility"
    case hearing = "pghd-hearing"
    case nutrition = "pghd-nutrition"
    case mindfulness = "pghd-mindfulness"
    case reproductiveHealth = "pghd-reproductive-health"
    case sleep = "pghd-sleep"
    case sleepEpisode = "pghd-sleep-episode"
    case workout = "pghd-workout"
    case testResult = "pghd-testresult"
    case heartRate = "pghd-heartrate"
    case bloodPressure = "pghd-bloodpressure"
    case bodyWeight = "pghd-bodyweight"
    case bodyHeight = "pghd-bodyheight"
    case bmi = "pghd-bmi"
    case bodyTemperature = "pghd-bodytemperature"
    case oxygenSaturation = "pghd-oxygenSaturation"
    case respiratoryRate = "pghd-respiratoryrate"
    case bloodGlucose = "pghd-blood-glucose"
    case device = "pghd-device"

    public var url: String { PHRIG.profile(rawValue) }

    /// `Observation.category` code fixed by the profile (FHIR observation-category).
    public var category: (code: String, display: String) {
        switch self {
        case .activity, .mobility, .mindfulness, .workout:
            return ("activity", "Activity")
        case .vitalSigns, .cardiacFunction, .heartRate, .bloodPressure, .bodyWeight, .bodyHeight, .bmi, .bodyTemperature,
             .oxygenSaturation, .respiratoryRate, .bloodGlucose:
            return ("vital-signs", "Vital Signs")
        case .bodyMeasurement, .testResult:
            return ("exam", "Exam")
        case .hearing, .nutrition, .reproductiveHealth, .sleep, .sleepEpisode:
            return ("social-history", "Social History")
        case .device:
            return ("", "")
        }
    }
}

public struct FHIRCoding: Sendable, Equatable {
    public var system: String
    public var code: String
    public var display: String?

    public init(_ system: String, _ code: String, _ display: String? = nil) {
        self.system = system
        self.code = code
        self.display = display
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["system": .string(system), "code": .string(code)]
        if let display { o["display"] = .string(display) }
        return .object(o)
    }
}

/// How one HealthKit type becomes a PGHD Observation.
public struct PGHDMapping: Sendable {
    /// Code in the PGHD code system (matches the HealthKit short name).
    public var code: String
    public var display: String
    public var profile: PGHDProfile
    /// LOINC codings from the IG's mapping table, when it lists one.
    public var loinc: [FHIRCoding]
    /// UCUM code the IG assigns to the PGHD code, or nil for observations that carry no value.
    public var unitCode: String?
    /// Human unit label for `Quantity.unit`.
    public var unitDisplay: String?
    /// Multiplier from the bridge's canonical unit to the IG's unit.
    public var factor: Double

    public var pghdCoding: FHIRCoding { FHIRCoding(PHRIG.pghdCodeSystem, code, display) }
}

/// HealthKit identifier → PGHD mapping, transcribed from the IG's code mapping table and
/// the unit property of each concept in the PGHD code system. Units follow the IG even
/// where it is inconsistent with itself (cycling distance in metres, walking distance in
/// kilometres) so that a receiving PHR sees exactly what the profiles declare.
public enum PGHDCodeMap {
    public static func mapping(for identifier: String) -> PGHDMapping? { table[identifier] }

    public static let table: [String: PGHDMapping] = {
        var t: [String: PGHDMapping] = [:]
        func q(_ id: String, _ code: String, _ display: String, _ profile: PGHDProfile, unit: String?, label: String? = nil,
               factor: Double = 1, loinc: [FHIRCoding] = []) {
            t["HKQuantityTypeIdentifier" + id] = PGHDMapping(code: code, display: display, profile: profile, loinc: loinc,
                                                            unitCode: unit, unitDisplay: label ?? unit, factor: factor)
        }
        func c(_ id: String, _ code: String, _ display: String, _ profile: PGHDProfile, unit: String? = nil, label: String? = nil) {
            t["HKCategoryTypeIdentifier" + id] = PGHDMapping(code: code, display: display, profile: profile, loinc: [],
                                                            unitCode: unit, unitDisplay: label ?? unit, factor: 1)
        }
        func l(_ code: String, _ display: String? = nil) -> FHIRCoding { FHIRCoding(PHRIG.loinc, code, display) }

        // Activity
        q("StepCount", "stepCount", "Step count", .activity, unit: "{steps}", label: "steps",
          loinc: [l("55423-8", "Number of steps in unspecified time Pedometer")])
        q("DistanceWalkingRunning", "distanceWalkingRunning", "Distance walking running", .activity, unit: "km")
        q("DistanceCycling", "distanceCycling", "Distance cycling", .activity, unit: "m", factor: 1000, loinc: [l("93818-3")])
        q("DistanceSwimming", "distanceSwimming", "Distance swimming", .activity, unit: "m", loinc: [l("93816-7")])
        q("FlightsClimbed", "flightsClimbed", "Flights climbed", .activity, unit: "{flights}", label: "flights")
        q("ActiveEnergyBurned", "activeEnergyBurned", "Active energy burned", .activity, unit: "kcal")
        q("BasalEnergyBurned", "basalEnergyBurned", "Basal energy burned", .activity, unit: "kcal")
        q("AppleExerciseTime", "appleExerciseTime", "Apple exercise time", .activity, unit: "min")
        q("AppleStandTime", "appleStandTime", "Apple stand time", .activity, unit: "min")
        q("AppleMoveTime", "appleMoveTime", "Apple move time", .activity, unit: "min")
        q("PhysicalEffort", "physicalEffort", "Physical effort", .activity, unit: "kcal/(kg.h)", label: "kcal/(kg·h)")
        q("TimeInDaylight", "timeInDaylight", "Time in daylight", .testResult, unit: "min")
        c("AppleStandHour", "appleStandHour", "Apple stand hour", .activity, unit: "h", label: "h")
        q("VO2Max", "vo2Max", "VO2 max", .activity, unit: "mL/kg/min")
        q("RunningPower", "runningPower", "Running power", .activity, unit: "W")
        q("RunningSpeed", "runningSpeed", "Running speed", .activity, unit: "m/s", factor: 1 / 3.6)

        // Heart and vital signs
        q("HeartRate", "heartRate", "Heart rate", .heartRate, unit: "/min", label: "beats/min", loinc: [l("8867-4", "Heart rate")])
        q("RestingHeartRate", "restingHeartRate", "Resting heart rate", .vitalSigns, unit: "/min", label: "beats/min")
        q("WalkingHeartRateAverage", "walkingHeartRateAverage", "Walking heart rate average", .vitalSigns, unit: "/min", label: "beats/min")
        q("HeartRateVariabilitySDNN", "heartRateVariabilitySDNN", "Heart rate variability SDNN", .vitalSigns, unit: "ms",
          loinc: [l("80404-7", "R-R interval.standard deviation (Heart rate variability)")])
        q("HeartRateRecoveryOneMinute", "heartRateRecoveryOneMinute", "Heart rate recovery one minute", .vitalSigns, unit: "/min", label: "beats/min")
        q("AtrialFibrillationBurden", "atrialFibrillationBurden", "Atrial fibrillation burden", .vitalSigns, unit: "%")
        q("BloodPressureSystolic", "bloodPressureSystolic", "Blood pressure systolic", .vitalSigns, unit: "mm[Hg]", label: "mmHg",
          loinc: [l("8480-6", "Systolic blood pressure")])
        q("BloodPressureDiastolic", "bloodPressureDiastolic", "Blood pressure diastolic", .vitalSigns, unit: "mm[Hg]", label: "mmHg",
          loinc: [l("8462-4", "Diastolic blood pressure")])
        c("LowHeartRateEvent", "lowHeartRateEvent", "Low heart rate event", .cardiacFunction)
        c("HighHeartRateEvent", "highHeartRateEvent", "High heart rate event", .cardiacFunction)
        c("IrregularHeartRhythmEvent", "irregularHeartRhythmEvent", "Irregular heart rhythm event", .cardiacFunction)

        // Respiratory and other vitals
        q("OxygenSaturation", "oxygenSaturation", "Oxygen saturation", .oxygenSaturation, unit: "%",
          loinc: [l("2708-6", "Oxygen saturation in Arterial blood"), l("59408-5", "Oxygen saturation in Arterial blood by Pulse oximetry")])
        q("RespiratoryRate", "respiratoryRate", "Respiratory rate", .respiratoryRate, unit: "/min", label: "breaths/min",
          loinc: [l("9279-1", "Respiratory rate")])
        q("BodyTemperature", "bodyTemperature", "Body temperature", .bodyTemperature, unit: "Cel", label: "°C",
          loinc: [l("8310-5", "Body temperature")])
        q("AppleSleepingWristTemperature", "appleSleepingWristTemperature", "Apple sleeping wrist temperature", .vitalSigns, unit: "Cel", label: "°C")
        q("BloodGlucose", "bloodGlucose", "Blood glucose", .bloodGlucose, unit: "mmol/L", factor: 1 / 18.0182,
          loinc: [l("2339-0", "Glucose [Mass/volume] in Blood")])
        q("PeripheralPerfusionIndex", "peripheralPerfusionIndex", "Peripheral perfusion index", .testResult, unit: "%")

        // Body measurements
        q("BodyMass", "bodyMass", "Body mass", .bodyWeight, unit: "kg", loinc: [l("29463-7", "Body weight")])
        q("BodyMassIndex", "bodyMassIndex", "Body mass index", .bmi, unit: "kg/m2", loinc: [l("39156-5", "Body mass index (BMI) [Ratio]")])
        q("BodyFatPercentage", "bodyFatPercentage", "Body fat percentage", .bodyMeasurement, unit: "%",
          loinc: [l("41982-0", "Percentage of body fat Measured")])
        q("LeanBodyMass", "leanBodyMass", "Lean body mass", .bodyMeasurement, unit: "kg", loinc: [l("91557-9", "Lean body weight")])
        q("Height", "height", "Height", .bodyHeight, unit: "cm", loinc: [l("8302-2", "Body height")])
        q("WaistCircumference", "waistCircumference", "Waist circumference", .bodyMeasurement, unit: "cm")

        // Sleep
        c("SleepAnalysis", "sleepAnalysis", "Sleep analysis", .sleep)

        // Mobility
        q("WalkingSpeed", "walkingSpeed", "Walking speed", .mobility, unit: "m/s", factor: 1 / 3.6)
        q("WalkingStepLength", "walkingStepLength", "Walking step length", .mobility, unit: "m", factor: 0.01)
        q("WalkingAsymmetryPercentage", "walkingAsymmetryPercentage", "Walking asymmetry percentage", .mobility, unit: "%")
        q("WalkingDoubleSupportPercentage", "walkingDoubleSupportPercentage", "Walking double support percentage", .mobility, unit: "%")
        q("SixMinuteWalkTestDistance", "sixMinuteWalkTestDistance", "Six minute walk test distance", .mobility, unit: "m", loinc: [l("64098-7")])
        q("StairAscentSpeed", "stairAscentSpeed", "Stair ascent speed", .mobility, unit: "m/s")
        q("StairDescentSpeed", "stairDescentSpeed", "Stair descent speed", .mobility, unit: "m/s")
        q("AppleWalkingSteadiness", "appleWalkingSteadiness", "Apple walking steadiness", .mobility, unit: "%")

        // Hearing
        q("EnvironmentalAudioExposure", "environmentalAudioExposure", "Environmental audio exposure", .hearing, unit: "dB", label: "dB(A) SPL")
        q("HeadphoneAudioExposure", "headphoneAudioExposure", "Headphone audio exposure", .hearing, unit: "dB", label: "dB(A) SPL")

        // Nutrition
        q("DietaryEnergyConsumed", "dietaryEnergyConsumed", "Energy consumed", .nutrition, unit: "kcal", loinc: [l("9052-2")])
        q("DietaryWater", "dietaryWater", "Water", .nutrition, unit: "L", factor: 0.001)
        q("DietaryCaffeine", "dietaryCaffeine", "Caffeine", .nutrition, unit: "mg")
        q("DietaryProtein", "dietaryProtein", "Protein", .nutrition, unit: "g", loinc: [l("9079-5")])
        q("DietaryCarbohydrates", "dietaryCarbohydrates", "Carbohydrates", .nutrition, unit: "g", loinc: [l("9059-7")])
        q("DietaryFatTotal", "dietaryFatTotal", "Fat total", .nutrition, unit: "g", loinc: [l("9066-2")])
        q("DietaryFiber", "dietaryFiber", "Fiber", .nutrition, unit: "g")
        q("DietarySugar", "dietarySugar", "Sugar", .nutrition, unit: "g")

        // Mindfulness and reproductive health
        c("MindfulSession", "mindfulSession", "Mindful session", .mindfulness)
        c("MenstrualFlow", "menstrualFlow", "Menstrual flow", .reproductiveHealth)
        return t
    }()

    /// Workout activity codes in the PGHD code system. HealthKit's activity names are the codes.
    public static let workoutActivityCodes: Set<String> = [
        "americanFootball", "archery", "australianFootball", "badminton", "barre", "baseball", "basketball", "bowling", "boxing",
        "cardioDance", "climbing", "cooldown", "coreTraining", "cricket", "crossCountrySkiing", "crossTraining", "curling", "cycling",
        "dance", "danceInspiredTraining", "discSports", "downhillSkiing", "elliptical", "equestrianSports", "fencing", "fishing",
        "fitnessGaming", "flexibility", "functionalStrengthTraining", "golf", "gymnastics", "handball", "handCycling",
        "highIntensityIntervalTraining", "hiking", "hockey", "hunting", "jumpRope", "kickboxing", "lacrosse", "martialArts",
        "mindAndBody", "mixedCardio", "mixedMetabolicCardioTraining", "other", "paddleSports", "pickleball", "pilates", "play",
        "preparationAndRecovery", "racquetball", "rowing", "rugby", "running", "sailing", "skatingSports", "snowboarding", "snowSports",
        "soccer", "socialDance", "softball", "squash", "stairClimbing", "stairs", "stepTraining", "surfingSports", "swimBikeRun",
        "swimming", "tableTennis", "taiChi", "tennis", "trackAndField", "traditionalStrengthTraining", "transition", "underwaterDiving",
        "volleyball", "walking", "waterFitness", "waterPolo", "waterSports", "wheelchairRunPace", "wheelchairWalkPace", "wrestling", "yoga",
    ]

    /// Sleep stage → sleep-analysis code. The IG uses HealthKit's names.
    public static func sleepCode(for stage: SleepStage) -> FHIRCoding {
        let display: String
        switch stage {
        case .inBed: display = "In bed"
        case .asleepUnspecified: display = "Asleep unspecified"
        case .awake: display = "Awake"
        case .asleepREM: display = "Asleep REM"
        case .asleepCore: display = "Asleep core"
        case .asleepDeep: display = "Asleep deep"
        }
        return FHIRCoding(PHRIG.sleepAnalysisCodeSystem, stage.rawValue, display)
    }

    /// Distance code for a workout's total distance, by the sport.
    public static func workoutDistanceType(for activity: String) -> String {
        switch activity {
        case "cycling", "handCycling": return "HKQuantityTypeIdentifierDistanceCycling"
        case "swimming", "swimBikeRun", "waterFitness", "waterPolo", "waterSports": return "HKQuantityTypeIdentifierDistanceSwimming"
        default: return "HKQuantityTypeIdentifierDistanceWalkingRunning"
        }
    }
}
