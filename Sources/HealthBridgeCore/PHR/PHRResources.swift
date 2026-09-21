import CryptoKit
import Foundation

/// Small FHIR R4 JSON helpers shared by the PHR resource builders.
enum FHIR {
    static func dateTime(_ date: Date) -> JSONValue { .string(ISO8601.string(from: date)) }

    static func period(_ start: Date, _ end: Date) -> JSONValue {
        ["start": dateTime(start), "end": dateTime(end)]
    }

    /// `effectiveDateTime` for an instant, `effectivePeriod` for a span.
    static func effective(_ start: Date, _ end: Date) -> (key: String, value: JSONValue) {
        end.timeIntervalSince(start) < 1 ? ("effectiveDateTime", dateTime(start)) : ("effectivePeriod", period(start, end))
    }

    static func quantity(_ value: Double, unit: String?, code: String?) -> JSONValue {
        var o: [String: JSONValue] = ["value": .number(rounded(value))]
        if let unit { o["unit"] = .string(unit) }
        if let code {
            o["system"] = .string(PHRIG.ucum)
            o["code"] = .string(code)
        }
        return .object(o)
    }

    static func concept(_ codings: [FHIRCoding], text: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if !codings.isEmpty { o["coding"] = .array(codings.map(\.json)) }
        if let text { o["text"] = .string(text) }
        return .object(o)
    }

    static func reference(_ ref: String, display: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["reference": .string(ref)]
        if let display { o["display"] = .string(display) }
        return .object(o)
    }

    static func category(_ profile: PGHDProfile) -> JSONValue {
        let c = profile.category
        return .array([concept([FHIRCoding(PHRIG.observationCategorySystem, c.code, c.display)])])
    }

    /// Strips floating-point noise (4.994999999 → 4.995) without losing sensor precision.
    static func rounded(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return (v * 1_000_000).rounded() / 1_000_000
    }

    /// A stable FHIR id (32 hex characters) from the parts that identify a record, so
    /// repeated exports of the same store produce the same ids and importers can merge.
    static func stableID(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Generated narrative from plain-text paragraphs.
    static func narrative(_ paragraphs: [String]) -> JSONValue {
        let body = paragraphs.map { "<p>\(escape($0))</p>" }.joined()
        return ["status": "generated", "div": .string("<div xmlns=\"http://www.w3.org/1999/xhtml\">\(body)</div>")]
    }
}

/// Builds the FHIR resources of a `.phr` file from the bridge's models.
struct PHRResourceBuilder {
    static let patientID = "me"
    static let compositionID = "cover"
    static let patientReference = "Patient/" + patientID

    let now: Date

    // MARK: Devices

    /// Identity of a data source: the app or device that wrote the samples.
    static func deviceKey(source: String?, device: String?) -> String? {
        let s = source?.trimmingCharacters(in: .whitespaces) ?? ""
        let d = device?.trimmingCharacters(in: .whitespaces) ?? ""
        if s.isEmpty, d.isEmpty { return nil }
        return s + "\u{1F}" + d
    }

    func device(source: String?, device model: String?) -> (id: String, resource: JSONValue)? {
        guard let key = Self.deviceKey(source: source, device: model) else { return nil }
        let id = "device-" + FHIR.stableID(["device", key])
        var names: [JSONValue] = []
        if let s = source, !s.isEmpty { names.append(["name": .string(s), "type": "user-friendly-name"]) }
        if let m = model, !m.isEmpty { names.append(["name": .string(m), "type": "model-name"]) }
        var o: [String: JSONValue] = [
            "resourceType": "Device",
            "id": .string(id),
            "meta": ["profile": [.string(PGHDProfile.device.url)]],
            "deviceName": .array(names),
            "patient": FHIR.reference(Self.patientReference),
        ]
        let haystack = ((source ?? "") + " " + (model ?? "")).lowercased()
        if ["apple", "iphone", "watch", "ipad", "airpods"].contains(where: { haystack.contains($0) }) {
            o["manufacturer"] = "Apple Inc."
        }
        return (id, .object(o))
    }

    // MARK: Observations

    private func base(profile: PGHDProfile, id: String, code: JSONValue, start: Date, end: Date, uuid: String?,
                      deviceRef: (id: String, display: String?)?) -> [String: JSONValue] {
        var o: [String: JSONValue] = [
            "resourceType": "Observation",
            "id": .string(id),
            "meta": ["profile": [.string(profile.url)]],
            "status": "final",
            "category": FHIR.category(profile),
            "code": code,
            "subject": FHIR.reference(Self.patientReference),
            "performer": [FHIR.reference(Self.patientReference)],
        ]
        if let uuid {
            o["identifier"] = [["system": "urn:ietf:rfc:3986", "value": .string("urn:uuid:" + uuid.lowercased())]]
        }
        let eff = FHIR.effective(start, end)
        o[eff.key] = eff.value
        if let deviceRef { o["device"] = FHIR.reference("Device/" + deviceRef.id, display: deviceRef.display) }
        return o
    }

    static func sampleID(_ s: HealthSample) -> String {
        if let uuid = s.uuid, !uuid.isEmpty { return uuid.lowercased() }
        return FHIR.stableID(["sample", s.type, String(s.start.timeIntervalSince1970), String(s.end.timeIntervalSince1970),
                              String(s.value), s.categoryValue ?? "", s.source ?? "", s.device ?? ""])
    }

    /// One PGHD Observation for a quantity or category sample. Blood pressure halves are
    /// exported here only when they could not be paired; see `bloodPressure`.
    func observation(for s: HealthSample, mapping m: PGHDMapping, deviceRef: (id: String, display: String?)?) -> JSONValue {
        var codings = m.loinc
        codings.append(m.pghdCoding)
        // FHIR's vital-sign profiles want the LOINC code first; the PGHD code rides along.
        var o = base(profile: m.profile, id: Self.sampleID(s), code: FHIR.concept(codings), start: s.start, end: s.end,
                     uuid: s.uuid, deviceRef: deviceRef)

        switch s.type {
        case "HKCategoryTypeIdentifierSleepAnalysis":
            if let stage = SleepStage(rawCategoryValue: Int(s.value)) {
                o["valueCodeableConcept"] = FHIR.concept([PGHDCodeMap.sleepCode(for: stage)])
            }
        case "HKCategoryTypeIdentifierAppleStandHour":
            // HealthKit: 0 = stood, 1 = idle. Export the hour as 1 h stood or 0 h stood.
            o["valueQuantity"] = FHIR.quantity(s.value == 0 ? 1 : 0, unit: "h", code: "h")
        case "HKCategoryTypeIdentifierMenstrualFlow":
            // The profile allows only a Quantity. Intensity 0–3 with the HealthKit label as the unit.
            let label = s.categoryValue ?? Self.menstrualLabel(Int(s.value))
            if let intensity = Self.menstrualIntensity(label) {
                o["valueQuantity"] = FHIR.quantity(intensity, unit: label, code: nil)
            } else {
                o["dataAbsentReason"] = FHIR.concept([FHIRCoding("http://terminology.hl7.org/CodeSystem/data-absent-reason", "unknown", "Unknown")])
            }
        case "HKQuantityTypeIdentifierBloodGlucose":
            // The IG fixes mmol/L and carries mg/dL in a translation extension.
            var q = FHIR.quantity(s.value * m.factor, unit: m.unitDisplay, code: m.unitCode).objectValue ?? [:]
            q["extension"] = [[
                "url": .string(PHRIG.quantityTranslationExtension),
                "valueQuantity": FHIR.quantity(s.value, unit: "mg/dl", code: "mg/dl"),
            ]]
            o["valueQuantity"] = .object(q)
            o["issued"] = FHIR.dateTime(s.end)
        default:
            if m.unitCode != nil || s.type.hasPrefix("HKQuantityTypeIdentifier") {
                o["valueQuantity"] = FHIR.quantity(s.value * m.factor, unit: m.unitDisplay, code: m.unitCode)
            }
        }
        return .object(o)
    }

    static func menstrualLabel(_ raw: Int) -> String {
        switch raw {
        case 1: return "unspecified"
        case 2: return "light"
        case 3: return "medium"
        case 4: return "heavy"
        case 5: return "none"
        default: return "unspecified"
        }
    }

    static func menstrualIntensity(_ label: String) -> Double? {
        switch label.lowercased() {
        case "none": return 0
        case "light": return 1
        case "medium": return 2
        case "heavy": return 3
        default: return nil
        }
    }

    /// A blood pressure panel (FHIR `bp` profile) from a systolic and a diastolic sample taken together.
    func bloodPressure(systolic: HealthSample, diastolic: HealthSample, deviceRef: (id: String, display: String?)?) -> JSONValue {
        let id = "bp-" + FHIR.stableID(["bp", Self.sampleID(systolic), Self.sampleID(diastolic)])
        let code = FHIR.concept([
            FHIRCoding(PHRIG.loinc, "85354-9", "Blood pressure panel with all children optional"),
            FHIRCoding(PHRIG.pghdCodeSystem, "bloodPressure", "Blood pressure"),
        ])
        var o = base(profile: .bloodPressure, id: id, code: code, start: systolic.start, end: systolic.end, uuid: nil, deviceRef: deviceRef)
        func component(_ s: HealthSample, _ loinc: FHIRCoding, _ pghd: String, _ display: String) -> JSONValue {
            ["code": FHIR.concept([loinc, FHIRCoding(PHRIG.pghdCodeSystem, pghd, display)]),
             "valueQuantity": FHIR.quantity(s.value, unit: "mmHg", code: "mm[Hg]")]
        }
        o["component"] = [
            component(systolic, FHIRCoding(PHRIG.loinc, "8480-6", "Systolic blood pressure"), "bloodPressureSystolic", "Blood pressure systolic"),
            component(diastolic, FHIRCoding(PHRIG.loinc, "8462-4", "Diastolic blood pressure"), "bloodPressureDiastolic", "Blood pressure diastolic"),
        ]
        if systolic.uuid != nil || diastolic.uuid != nil {
            o["identifier"] = .array([systolic.uuid, diastolic.uuid].compactMap { u in
                u.map { ["system": "urn:ietf:rfc:3986", "value": .string("urn:uuid:" + $0.lowercased())] }
            })
        }
        return .object(o)
    }

    // MARK: Sleep episodes

    static func sleepEpisodeID(_ night: SleepNight) -> String {
        "sleep-" + FHIR.stableID(["sleep-episode", String(night.bedtime.timeIntervalSince1970), String(night.wakeTime.timeIntervalSince1970)])
    }

    /// One `pghd-sleep-episode` per night, summarizing the stage segments the night is made of.
    func sleepEpisode(_ night: SleepNight, isMainSleep: Bool, memberIDs: [String]) -> JSONValue {
        let code = FHIR.concept([FHIRCoding(PHRIG.pghdCodeSystem, "sleepEpisode", "Sleep episode")])
        var o = base(profile: .sleepEpisode, id: Self.sleepEpisodeID(night), code: code, start: night.bedtime,
                     end: max(night.wakeTime, night.bedtime.addingTimeInterval(1)), uuid: nil, deviceRef: nil)
        var components: [JSONValue] = []
        func minutes(_ code: String, _ display: String, _ value: Double) {
            components.append(["code": FHIR.concept([FHIRCoding(PHRIG.sleepEpisodeCodeSystem, code, display)]),
                               "valueQuantity": FHIR.quantity(value, unit: "min", code: "min")])
        }
        func percent(_ code: String, _ display: String, _ value: Double) {
            components.append(["code": FHIR.concept([FHIRCoding(PHRIG.sleepEpisodeCodeSystem, code, display)]),
                               "valueQuantity": FHIR.quantity(value, unit: "%", code: "%")])
        }
        let segments = night.segments ?? []
        let asleep = segments.filter { $0.stage.isAsleep }
        if !asleep.isEmpty, let firstAsleep = asleep.map(\.start).min(), let lastAsleep = asleep.map(\.end).max() {
            minutes("latencyToSleepOnset", "Latency to sleep onset", max(0, firstAsleep.timeIntervalSince(night.bedtime) / 60))
            minutes("latencyToArising", "Latency to arising", max(0, night.wakeTime.timeIntervalSince(lastAsleep) / 60))
        }
        minutes("totalSleepTime", "Total sleep time", night.asleepMinutes)
        if night.coreMinutes > 0 { minutes("coreSleepDuration", "Core sleep duration", night.coreMinutes) }
        if night.deepMinutes > 0 { minutes("deepSleepDuration", "Deep sleep duration", night.deepMinutes) }
        if night.remMinutes > 0 { minutes("remSleepDuration", "REM sleep duration", night.remMinutes) }
        if night.asleepMinutes > 0 {
            if night.coreMinutes > 0 { percent("coreSleepPercentage", "Core sleep percentage", night.coreMinutes / night.asleepMinutes * 100) }
            if night.deepMinutes > 0 { percent("deepSleepPercentage", "Deep sleep percentage", night.deepMinutes / night.asleepMinutes * 100) }
            if night.remMinutes > 0 { percent("remSleepPercentage", "REM sleep percentage", night.remMinutes / night.asleepMinutes * 100) }
        }
        minutes("wakeAfterSleepOnset", "Wake after sleep onset", night.awakeMinutes)
        components.append(["code": FHIR.concept([FHIRCoding(PHRIG.sleepEpisodeCodeSystem, "numberOfAwakenings", "Number of awakenings")]),
                           "valueInteger": .number(Double(segments.filter { $0.stage == .awake }.count))])
        if night.inBedMinutes > 0 {
            percent("sleepEfficiencyPercentage", "Sleep efficiency percentage", min(100, night.asleepMinutes / night.inBedMinutes * 100))
        }
        components.append(["code": FHIR.concept([FHIRCoding(PHRIG.sleepEpisodeCodeSystem, "isMainSleep", "Is main sleep")]),
                           "valueBoolean": .bool(isMainSleep)])
        o["component"] = .array(components)
        if !memberIDs.isEmpty { o["hasMember"] = .array(memberIDs.map { FHIR.reference("Observation/" + $0) }) }
        return .object(o)
    }

    // MARK: Workouts

    static func workoutID(_ w: Workout) -> String {
        if let uuid = w.uuid, !uuid.isEmpty { return uuid.lowercased() }
        return "workout-" + FHIR.stableID(["workout", w.activityType, String(w.start.timeIntervalSince1970), String(w.end.timeIntervalSince1970), w.source ?? ""])
    }

    /// The workout plus its energy and distance totals as member observations (as the IG's walking example does).
    func workout(_ w: Workout, deviceRef: (id: String, display: String?)?) -> [JSONValue] {
        let id = Self.workoutID(w)
        let known = PGHDCodeMap.workoutActivityCodes.contains(w.activityType)
        let activityCode = known ? w.activityType : "other"
        let display = Self.titleCase(w.activityType)
        let code = FHIR.concept([FHIRCoding(PHRIG.pghdCodeSystem, activityCode, known ? display : "Other")], text: known ? nil : display)
        var main = base(profile: .workout, id: id, code: code, start: w.start, end: max(w.end, w.start.addingTimeInterval(1)),
                        uuid: w.uuid, deviceRef: deviceRef)

        var members: [JSONValue] = []
        var refs: [JSONValue] = []
        func child(_ typeID: String, value: Double, suffix: String) {
            guard let m = PGHDCodeMap.mapping(for: typeID) else { return }
            let childID = id + "-" + suffix
            var o = base(profile: m.profile, id: childID, code: FHIR.concept(m.loinc + [m.pghdCoding]), start: w.start,
                         end: max(w.end, w.start.addingTimeInterval(1)), uuid: nil, deviceRef: deviceRef)
            o["valueQuantity"] = FHIR.quantity(value * m.factor, unit: m.unitDisplay, code: m.unitCode)
            o["derivedFrom"] = [FHIR.reference("Observation/" + id)]
            members.append(.object(o))
            refs.append(FHIR.reference("Observation/" + childID))
        }
        if let kcal = w.totalEnergyKcal { child("HKQuantityTypeIdentifierActiveEnergyBurned", value: kcal, suffix: "energy") }
        if let km = w.totalDistanceKm { child(PGHDCodeMap.workoutDistanceType(for: w.activityType), value: km, suffix: "distance") }
        if !refs.isEmpty { main["hasMember"] = .array(refs) }

        var components: [JSONValue] = [
            ["code": FHIR.concept([], text: "Duration"), "valueQuantity": FHIR.quantity(w.durationMinutes, unit: "min", code: "min")],
        ]
        if let avg = w.averageHeartRate {
            components.append(["code": FHIR.concept([FHIRCoding(PHRIG.pghdCodeSystem, "heartRate", "Heart rate")], text: "Average heart rate"),
                               "valueQuantity": FHIR.quantity(avg, unit: "beats/min", code: "/min")])
        }
        if let mx = w.maxHeartRate {
            components.append(["code": FHIR.concept([FHIRCoding(PHRIG.pghdCodeSystem, "heartRate", "Heart rate")], text: "Maximum heart rate"),
                               "valueQuantity": FHIR.quantity(mx, unit: "beats/min", code: "/min")])
        }
        main["component"] = .array(components)
        return [.object(main)] + members
    }

    /// `functionalStrengthTraining` → `Functional strength training`, the code system's display style.
    static func titleCase(_ camel: String) -> String {
        var out = ""
        for (i, ch) in camel.enumerated() {
            if ch.isUppercase, i > 0 {
                out.append(" ")
                out.append(Character(ch.lowercased()))
            } else {
                out.append(i == 0 ? Character(ch.uppercased()) : ch)
            }
        }
        return out
    }

    // MARK: Patient, cover page, provenance, clinical records

    func patient(_ c: Characteristics, name: String?) -> JSONValue {
        var o: [String: JSONValue] = [
            "resourceType": "Patient",
            "id": .string(Self.patientID),
            "meta": ["lastUpdated": FHIR.dateTime(now)],
        ]
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            o["name"] = [["use": "official", "text": .string(name)]]
        }
        if let dob = c.dateOfBirth, !dob.isEmpty { o["birthDate"] = .string(String(dob.prefix(10))) }
        switch c.biologicalSex {
        case "male", "female", "other": o["gender"] = .string(c.biologicalSex!)
        default: break
        }
        return .object(o)
    }

    struct CoverPage {
        var title: String
        var sourceDescription: String
        var sourceDetail: String?
        var range: DateInterval
        var typeCounts: [(name: String, count: Int)]
        var sleepEpisodes: Int
        var workouts: Int
        var clinicalCounts: [(kind: String, count: Int)]
        var devices: Int
        var resources: Int
    }

    func composition(_ page: CoverPage) -> JSONValue {
        let day: (Date) -> String = { ISO8601.dayString($0) }
        let about = [
            "Personal health record exported by \(BridgeInfo.displayName) \(BridgeInfo.version) on \(day(now)).",
            "Source: \(page.sourceDescription)." + (page.sourceDetail.map { " " + $0 } ?? ""),
            "Covers \(day(page.range.start)) to \(day(page.range.end)). \(page.resources) resources in total.",
            "Format: HL7 FHIR R4 Personal Health Record (.phr, newline-delimited JSON), Patient Generated Health Data profiles from hl7.fhir.uv.phr \(PHRIG.version).",
        ]
        var pghd = page.typeCounts.map { "\($0.name): \($0.count)" }
        if page.sleepEpisodes > 0 { pghd.append("Sleep episodes (nights): \(page.sleepEpisodes)") }
        if page.workouts > 0 { pghd.append("Workouts: \(page.workouts)") }
        if page.devices > 0 { pghd.append("Data sources (Device resources): \(page.devices)") }
        var sections: [JSONValue] = [
            ["title": "About this record", "text": FHIR.narrative(about)],
            ["title": "Patient-generated health data",
             "code": FHIR.concept([FHIRCoding(PHRIG.observationCategorySystem, "vital-signs", "Vital Signs"),
                                   FHIRCoding(PHRIG.observationCategorySystem, "activity", "Activity")]),
             "text": FHIR.narrative(pghd.isEmpty ? ["No samples in the selected range."] : pghd)],
        ]
        if !page.clinicalCounts.isEmpty {
            sections.append(["title": "Clinical records from connected providers",
                             "text": FHIR.narrative(page.clinicalCounts.map { "\($0.kind): \($0.count)" })])
        }
        return [
            "resourceType": "Composition",
            "id": .string(Self.compositionID),
            "meta": ["lastUpdated": FHIR.dateTime(now)],
            "status": "final",
            "type": FHIR.concept([FHIRCoding(PHRIG.loinc, "11503-0", "Medical records")]),
            "subject": FHIR.reference(Self.patientReference),
            "date": FHIR.dateTime(now),
            "author": [FHIR.reference(Self.patientReference), ["display": .string("\(BridgeInfo.displayName) \(BridgeInfo.version)")]],
            "title": .string(page.title),
            "section": .array(sections),
        ]
    }

    func provenance(range: DateInterval, sourceDescription: String, sourceDetail: String?) -> JSONValue {
        let id = "export-" + FHIR.stableID(["export", String(now.timeIntervalSince1970)])
        var source = sourceDescription
        if let d = sourceDetail, !d.isEmpty { source += ". " + d }
        return [
            "resourceType": "Provenance",
            "id": .string(id),
            "target": [FHIR.reference("Composition/" + Self.compositionID), FHIR.reference(Self.patientReference)],
            "occurredPeriod": FHIR.period(range.start, range.end),
            "recorded": FHIR.dateTime(now),
            "activity": FHIR.concept([FHIRCoding("http://terminology.hl7.org/CodeSystem/v3-DataOperation", "CREATE", "create")]),
            "agent": [
                ["type": FHIR.concept([FHIRCoding(PHRIG.provenanceParticipantSystem, "author", "Author")]),
                 "who": FHIR.reference(Self.patientReference)],
                ["type": FHIR.concept([FHIRCoding(PHRIG.provenanceParticipantSystem, "assembler", "Assembler")]),
                 "who": ["display": .string("\(BridgeInfo.displayName) \(BridgeInfo.version)")]],
            ],
            "entity": [["role": "source", "what": ["display": .string(source)]]],
        ]
    }

    /// Which element points at the patient, per resource type (R4).
    static func subjectElement(for resourceType: String) -> String? {
        switch resourceType {
        case "AllergyIntolerance", "Immunization": return "patient"
        case "Coverage": return "beneficiary"
        case "Observation", "Condition", "Procedure", "MedicationRequest", "MedicationStatement", "MedicationDispense", "MedicationOrder",
             "DiagnosticReport", "DocumentReference", "Encounter", "CarePlan", "Goal", "ServiceRequest", "Specimen", "ImagingStudy":
            return "subject"
        default: return nil
        }
    }

    /// A clinical record as Health stored it, with `meta.source` naming the provider it came from
    /// and the patient filled in when the provider's copy left it out.
    func clinical(_ r: ClinicalRecord) -> JSONValue? {
        guard var o = r.resource.objectValue, let resourceType = o["resourceType"]?.stringValue else { return nil }
        if o["id"]?.stringValue == nil {
            o["id"] = .string("clinical-" + FHIR.stableID(["clinical", r.fhirResourceType, r.identifier ?? "", r.sourceURL ?? "", JSON.string(r.resource)]))
        }
        var meta = o["meta"]?.objectValue ?? [:]
        if let url = r.sourceURL, !url.isEmpty, meta["source"] == nil { meta["source"] = .string(url) }
        if !meta.isEmpty { o["meta"] = .object(meta) }
        if let element = Self.subjectElement(for: resourceType), o[element] == nil {
            o[element] = FHIR.reference(Self.patientReference)
        }
        return .object(o)
    }
}
