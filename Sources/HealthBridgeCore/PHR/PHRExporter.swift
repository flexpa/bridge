import Foundation

public enum PHRExportFormat: String, Sendable, CaseIterable {
    /// Newline-delimited JSON, one FHIR resource per line (`application/x-ndjson`).
    case phr
    /// A DEFLATE zip container holding the `.phr` file.
    case sphr

    public static func forURL(_ url: URL) -> PHRExportFormat {
        url.pathExtension.lowercased() == "sphr" ? .sphr : .phr
    }
}

public struct PHRExportOptions: Sendable, Equatable {
    /// Samples, workouts, sleep and (when set explicitly) clinical records inside this range.
    /// Nil exports everything the data source holds.
    public var range: DateInterval?
    public var includeClinicalRecords = true
    /// Write every sleep stage segment as its own Observation, in addition to one episode per night.
    public var includeSleepSegments = true
    /// HealthKit has no name; the PHR's Patient resource may carry one if the user gives it.
    public var patientName: String?

    public init(range: DateInterval? = nil, includeClinicalRecords: Bool = true, includeSleepSegments: Bool = true,
                patientName: String? = nil) {
        self.range = range
        self.includeClinicalRecords = includeClinicalRecords
        self.includeSleepSegments = includeSleepSegments
        self.patientName = patientName
    }
}

public struct PHRExportProgress: Sendable, Equatable {
    public var phase: String
    public var resources: Int
}

public struct PHRExportReport: Sendable, Equatable {
    public var url: URL
    public var format: PHRExportFormat
    public var resources: Int
    public var observations: Int
    public var sleepEpisodes: Int
    public var workouts: Int
    public var clinicalRecords: Int
    public var devices: Int
    /// Size of the uncompressed `.phr` content.
    public var bytes: Int
    public var range: DateInterval
    public var duration: TimeInterval
}

/// Writes the active data source as an HL7 Personal Health Record: a `.phr` file
/// (NDJSON of FHIR R4 resources using the IG's PGHD profiles) or a `.sphr` zip
/// around it. Streams, so a ten-year store never sits in memory at once.
/// https://build.fhir.org/ig/HL7/personal-health-record-format-ig/en/recordkeeping.html
public final class PHRExporter {
    private let provider: HealthDataProvider
    private let scratchRoot: URL
    private let now: Date
    private let progress: @Sendable (PHRExportProgress) -> Void
    private let builder: PHRResourceBuilder

    private var body: NDJSONWriter!
    private var devices: [String: (id: String, display: String?)] = [:]
    private var deviceCount = 0
    private var observations = 0
    private var sleepEpisodes = 0
    private var workouts = 0
    private var clinical = 0
    private var typeCounts: [(name: String, count: Int)] = []
    private var clinicalCounts: [String: Int] = [:]
    private var phase = "Preparing"
    private var sinceReport = 0

    /// `scratch` is a private folder for the intermediate files; it is removed when the export ends.
    public init(provider: HealthDataProvider, scratch: URL, now: Date = Date(),
                progress: @escaping @Sendable (PHRExportProgress) -> Void = { _ in }) {
        self.provider = provider
        self.scratchRoot = scratch
        self.now = now
        self.progress = progress
        self.builder = PHRResourceBuilder(now: now)
    }

    public func run(to destination: URL, options: PHRExportOptions) async throws -> PHRExportReport {
        let started = Date()
        let format = PHRExportFormat.forURL(destination)
        report("Preparing")

        let status = await provider.status()
        guard status.available else {
            throw HealthDataError.unavailable("Nothing to export: \(status.description).")
        }
        // Ranges are half-open like the tools' `end`, so a store's own range is widened by a second
        // to keep the last instant sample, whose start equals the store's maximum end.
        var range = options.range
            ?? status.dataRange.map { DateInterval(start: $0.start, end: $0.end.addingTimeInterval(1)) }
            ?? DateInterval(start: Calendar.current.date(byAdding: .year, value: -10, to: now) ?? now, end: now)
        // Never walk month windows across years that hold no data.
        if let first = status.dataRange?.start, first > range.start, first < range.end {
            range = DateInterval(start: first, end: range.end)
        }
        if range.duration <= 0 { range = DateInterval(start: range.start, end: range.start.addingTimeInterval(1)) }

        let fm = FileManager.default
        try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratchRoot) }

        let bodyURL = scratchRoot.appendingPathComponent("body.ndjson")
        body = try NDJSONWriter(url: bodyURL)
        try await writeSamples(range: range)
        try await writeSleep(range: range, includeSegments: options.includeSleepSegments)
        // The store's own range is measured over samples; without a requested range, take every workout.
        try await writeWorkouts(range: options.range)
        if options.includeClinicalRecords { try await writeClinical(range: options.range) }
        try body.close()

        report("Finishing")
        let characteristics = (try? await provider.characteristics()) ?? Characteristics()
        let resources = body.lines + 3
        let name = options.patientName?.trimmingCharacters(in: .whitespaces)
        let page = PHRResourceBuilder.CoverPage(
            title: "Personal Health Record" + ((name?.isEmpty == false) ? " for \(name!)" : ""),
            sourceDescription: status.description, sourceDetail: status.detail, range: range, typeCounts: typeCounts,
            sleepEpisodes: sleepEpisodes, workouts: workouts,
            clinicalCounts: clinicalCounts.keys.sorted().map { ($0, clinicalCounts[$0]!) },
            devices: deviceCount, resources: resources)
        let header: [JSONValue] = [
            builder.patient(characteristics, name: name),
            builder.composition(page),
            builder.provenance(range: range, sourceDescription: status.description, sourceDetail: status.detail),
        ]

        let baseName = destination.deletingPathExtension().lastPathComponent
        let phrName = baseName + ".phr"
        let container = scratchRoot.appendingPathComponent(baseName, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let phrURL = container.appendingPathComponent(phrName)
        try assemble(header: header, body: bodyURL, to: phrURL)
        try? fm.removeItem(at: bodyURL)
        let bytes = (try? fm.attributesOfItem(atPath: phrURL.path)[.size] as? Int) ?? 0

        let product: URL
        switch format {
        case .phr:
            product = phrURL
        case .sphr:
            report("Compressing")
            product = scratchRoot.appendingPathComponent(baseName + ".sphr")
            try Self.zip(container, to: product)
        }
        try install(product, at: destination)

        return PHRExportReport(url: destination, format: format, resources: resources, observations: observations,
                               sleepEpisodes: sleepEpisodes, workouts: workouts, clinicalRecords: clinical, devices: deviceCount,
                               bytes: bytes, range: range, duration: Date().timeIntervalSince(started))
    }

    // MARK: Samples

    private static let systolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
    private static let diastolic = "HKQuantityTypeIdentifierBloodPressureDiastolic"
    private static let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"

    private func writeSamples(range: DateInterval) async throws {
        let available = Set(await provider.availableTypes().map(\.identifier))
        var bloodPressureDone = false
        for type in HealthTypeCatalog.all where available.contains(type.identifier) && type.identifier != Self.sleepType {
            guard let mapping = PGHDCodeMap.mapping(for: type.identifier) else { continue }
            if type.identifier == Self.systolic || type.identifier == Self.diastolic {
                guard !bloodPressureDone else { continue }
                bloodPressureDone = true
                report("Writing blood pressure")
                let count = try await writeBloodPressure(range: range)
                typeCounts.append(("Blood pressure", count))
                continue
            }
            report("Writing \(type.name.lowercased())")
            var count = 0
            for (i, window) in Self.windows(range).enumerated() {
                let samples = try await provider.samples(of: type, in: window, limit: Int.max, ascending: true)
                // A sample that started in an earlier window was written there; the first window keeps
                // everything that overlaps the range.
                for s in samples where i == 0 || s.start >= window.start {
                    let device = try deviceRef(source: s.source, model: s.device)
                    try write(builder.observation(for: s, mapping: mapping, deviceRef: device))
                    observations += 1
                    count += 1
                }
            }
            typeCounts.append((type.name, count))
        }
    }

    /// Systolic and diastolic samples recorded together become one blood pressure panel.
    private func writeBloodPressure(range: DateInterval) async throws -> Int {
        guard let sType = HealthTypeCatalog.byIdentifier[Self.systolic], let dType = HealthTypeCatalog.byIdentifier[Self.diastolic],
              let sMap = PGHDCodeMap.mapping(for: Self.systolic), let dMap = PGHDCodeMap.mapping(for: Self.diastolic) else { return 0 }
        func key(_ s: HealthSample) -> String {
            "\(s.start.timeIntervalSince1970)|\(s.end.timeIntervalSince1970)|\(s.source ?? "")"
        }
        var count = 0
        for (i, window) in Self.windows(range).enumerated() {
            let sys = try await provider.samples(of: sType, in: window, limit: Int.max, ascending: true).filter { i == 0 || $0.start >= window.start }
            let dia = try await provider.samples(of: dType, in: window, limit: Int.max, ascending: true).filter { i == 0 || $0.start >= window.start }
            var pending: [String: [HealthSample]] = [:]
            for d in dia { pending[key(d), default: []].append(d) }
            for s in sys {
                let device = try deviceRef(source: s.source, model: s.device)
                if var list = pending[key(s)], !list.isEmpty {
                    let d = list.removeFirst()
                    pending[key(s)] = list
                    try write(builder.bloodPressure(systolic: s, diastolic: d, deviceRef: device))
                } else {
                    try write(builder.observation(for: s, mapping: sMap, deviceRef: device))
                }
                observations += 1
                count += 1
            }
            for d in pending.values.flatMap({ $0 }).sorted(by: { $0.start < $1.start }) {
                let device = try deviceRef(source: d.source, model: d.device)
                try write(builder.observation(for: d, mapping: dMap, deviceRef: device))
                observations += 1
                count += 1
            }
        }
        return count
    }

    // MARK: Sleep

    /// Sleep is exported by night, like `get_sleep`: the query is padded so a night that
    /// straddles the range boundary is complete, and a night belongs to the export when it
    /// ends inside the range. Segment observations are written per kept night.
    private func writeSleep(range: DateInterval, includeSegments: Bool) async throws {
        guard let type = HealthTypeCatalog.byIdentifier[Self.sleepType], let mapping = PGHDCodeMap.mapping(for: Self.sleepType) else { return }
        report("Writing sleep")
        let padding: TimeInterval = 18 * 3600
        let padded = DateInterval(start: range.start.addingTimeInterval(-padding), end: range.end.addingTimeInterval(padding))
        let samples = try await provider.samples(of: type, in: padded, limit: Int.max, ascending: true)
        guard !samples.isEmpty else { return }

        func segmentKey(_ start: Date, _ end: Date, _ stage: SleepStage, _ source: String?) -> String {
            "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(stage.rawValue)|\(source ?? "")"
        }
        var segments: [SleepSegment] = []
        var samplesBySegment: [String: HealthSample] = [:]
        for s in samples {
            guard let stage = SleepStage(rawCategoryValue: Int(s.value)) else { continue }
            segments.append(SleepSegment(start: s.start, end: s.end, stage: stage, source: s.source))
            samplesBySegment[segmentKey(s.start, s.end, stage, s.source)] = s
        }

        let nights = HealthMath.nights(from: segments, includeSegments: true)
            .filter { $0.wakeTime >= range.start && $0.wakeTime <= range.end }
        var longestByDay: [String: Double] = [:]
        for n in nights { longestByDay[n.date] = max(longestByDay[n.date] ?? 0, n.asleepMinutes) }
        var written = 0
        var writtenIDs = Set<String>()
        for n in nights {
            var members: [String] = []
            for seg in n.segments ?? [] {
                guard let s = samplesBySegment[segmentKey(seg.start, seg.end, seg.stage, seg.source)] else { continue }
                let id = PHRResourceBuilder.sampleID(s)
                members.append(id)
                guard includeSegments, !writtenIDs.contains(id) else { continue }
                writtenIDs.insert(id)
                let device = try deviceRef(source: s.source, model: s.device)
                try write(builder.observation(for: s, mapping: mapping, deviceRef: device))
                observations += 1
                written += 1
            }
            let isMain = n.asleepMinutes > 0 && n.asleepMinutes >= (longestByDay[n.date] ?? 0)
            try write(builder.sleepEpisode(n, isMainSleep: isMain, memberIDs: includeSegments ? members : []))
            sleepEpisodes += 1
        }
        if includeSegments { typeCounts.append(("Sleep stages", written)) }
    }

    // MARK: Workouts and clinical records

    private func writeWorkouts(range: DateInterval?) async throws {
        report("Writing workouts")
        let list = try await provider.workouts(in: range, activityType: nil, limit: Int.max)
        for w in list.sorted(by: { $0.start < $1.start }) {
            let device = try deviceRef(source: w.source, model: nil)
            for resource in builder.workout(w, deviceRef: device) { try write(resource) }
            workouts += 1
        }
    }

    private func writeClinical(range: DateInterval?) async throws {
        report("Writing clinical records")
        let records = try await provider.clinicalRecords(kind: nil, since: nil, limit: Int.max)
        for r in records {
            if let range, let date = r.date, !(date >= range.start && date < range.end) { continue }
            guard let resource = builder.clinical(r) else { continue }
            try write(resource)
            clinical += 1
            clinicalCounts[r.kind.rawValue, default: 0] += 1
        }
    }

    // MARK: Plumbing

    /// Writes the Device resource for a source the first time it is seen, before the first
    /// observation that references it.
    private func deviceRef(source: String?, model: String?) throws -> (id: String, display: String?)? {
        guard let key = PHRResourceBuilder.deviceKey(source: source, device: model) else { return nil }
        if let existing = devices[key] { return existing }
        guard let made = builder.device(source: source, device: model) else { return nil }
        try body.write(made.resource)
        deviceCount += 1
        let ref = (id: made.id, display: source ?? model)
        devices[key] = ref
        return ref
    }

    private func write(_ resource: JSONValue) throws {
        try body.write(resource)
        sinceReport += 1
        if sinceReport >= 5000 {
            sinceReport = 0
            progress(PHRExportProgress(phase: phase, resources: body.lines))
        }
    }

    private func report(_ phase: String) {
        self.phase = phase
        progress(PHRExportProgress(phase: phase, resources: body?.lines ?? 0))
    }

    /// Month-sized query windows so a large type never loads at once.
    static func windows(_ range: DateInterval) -> [DateInterval] {
        var out: [DateInterval] = []
        var cursor = range.start
        let cal = Calendar.current
        while cursor < range.end {
            let next = min(cal.date(byAdding: .month, value: 1, to: cursor) ?? range.end, range.end)
            guard next > cursor else { break }
            out.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return out
    }

    /// Patient, cover page and provenance first, then the streamed body.
    private func assemble(header: [JSONValue], body bodyURL: URL, to url: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HealthDataError.internalError("cannot create \(url.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        for resource in header {
            var line = JSON.data(resource)
            line.append(0x0A)
            try out.write(contentsOf: line)
        }
        let input = try FileHandle(forReadingFrom: bodyURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }

    static func zip(_ folder: URL, to url: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--norsrc", folder.path, url.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw HealthDataError.internalError("could not compress \(url.lastPathComponent)") }
    }

    private func install(_ file: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: file)
        } else {
            try fm.moveItem(at: file, to: destination)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

/// Buffered newline-delimited JSON writer.
final class NDJSONWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var lines = 0
    private(set) var bytes = 0

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HealthDataError.internalError("cannot create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(2 << 20)
    }

    func write(_ resource: JSONValue) throws {
        buffer.append(JSON.data(resource))
        buffer.append(0x0A)
        lines += 1
        if buffer.count >= 1 << 20 { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        bytes += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        try flush()
        try handle.close()
    }
}
