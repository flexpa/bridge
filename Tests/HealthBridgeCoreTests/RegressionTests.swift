import XCTest
@testable import HealthBridgeCore

/// One test per defect found in adversarial review. Each fails against the code as it was.
final class RegressionTests: XCTestCase {
    let cal = Calendar.current

    private func at(_ iso: String) -> Date { ISO8601.date(from: iso)! }

    // MARK: Sleep

    /// A watch and a ring both logging the same night used to be summed, reporting roughly
    /// double. Measured on real data: a night of 6h18m was reported as 12h15m.
    func testOverlappingSourcesAreUnionedNotSummed() {
        let segments = [
            SleepSegment(start: at("2026-04-01T23:00:00"), end: at("2026-04-02T06:00:00"), stage: .asleepCore, source: "Apple Watch"),
            SleepSegment(start: at("2026-04-01T23:00:00"), end: at("2026-04-02T06:00:00"), stage: .asleepCore, source: "Oura"),
        ]
        let nights = HealthMath.nights(from: segments, includeSegments: false)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].asleepMinutes, 420, "two sources covering one 7h night must report 7h, not 14h")
        XCTAssertEqual(nights[0].coreMinutes, 420)
    }

    /// Partial overlap unions to the covered span rather than either the sum or one source.
    func testPartiallyOverlappingSourcesUnionToTheCoveredSpan() {
        let segments = [
            SleepSegment(start: at("2026-04-01T23:00:00"), end: at("2026-04-02T03:00:00"), stage: .asleepREM, source: "A"),
            SleepSegment(start: at("2026-04-02T02:00:00"), end: at("2026-04-02T06:00:00"), stage: .asleepREM, source: "B"),
        ]
        XCTAssertEqual(HealthMath.nights(from: segments, includeSegments: false)[0].remMinutes, 420)
    }

    func testDisjointSegmentsStillAddUp() {
        let segments = [
            SleepSegment(start: at("2026-04-01T23:00:00"), end: at("2026-04-02T00:00:00"), stage: .asleepCore),
            SleepSegment(start: at("2026-04-02T01:00:00"), end: at("2026-04-02T02:00:00"), stage: .asleepCore),
        ]
        XCTAssertEqual(HealthMath.nights(from: segments, includeSegments: false)[0].coreMinutes, 120)
    }

    /// Grouping compared against the most recently appended segment, so a short segment inside a
    /// long envelope made the night look finished and split it in two.
    func testNightIsNotSplitByAnOutOfOrderSegmentEnd() {
        let segments = [
            SleepSegment(start: at("2026-04-01T22:00:00"), end: at("2026-04-02T08:00:00"), stage: .inBed),
            SleepSegment(start: at("2026-04-01T22:00:00"), end: at("2026-04-01T23:00:00"), stage: .asleepCore),
            SleepSegment(start: at("2026-04-02T04:00:00"), end: at("2026-04-02T08:00:00"), stage: .asleepCore),
        ]
        let nights = HealthMath.nights(from: segments, includeSegments: false)
        XCTAssertEqual(nights.count, 1, "a gap inside the inBed envelope is one night, not two")
        XCTAssertEqual(nights[0].coreMinutes, 300)
        XCTAssertEqual(nights[0].inBedMinutes, 600)
    }

    /// A twenty-minute nap keyed to the same day used to overwrite the night in the daily summary.
    func testNapDoesNotReplaceTheNightInTheDailySummary() async throws {
        let segments = [
            SleepSegment(start: at("2026-04-01T23:00:00"), end: at("2026-04-02T07:00:00"), stage: .asleepCore),
            SleepSegment(start: at("2026-04-02T14:00:00"), end: at("2026-04-02T14:20:00"), stage: .asleepCore),
        ]
        let provider = StubSleepProvider(segments: segments)
        let result = try await HealthTools.getDailySummary.handler(ToolArgs(["date": "2026-04-02"]), provider, BridgeSettings())
        XCTAssertEqual(result["days"]?[0]?["sleepAsleepMinutes"]?.doubleValue, 480, "the night must win over the nap")
    }

    // MARK: Bucketing

    /// The cumulative path was rewritten from a per-sample scan of every bucket to a bounded
    /// sweep. Prove the two agree, including samples spanning boundaries and zero-length ones.
    func testBoundedSweepMatchesTheNaiveBucketing() {
        let steps = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierStepCount"]!
        let start = at("2026-03-01T00:00:00")
        var samples: [HealthSample] = []
        var rng = SeededGenerator(seed: 7)
        for i in 0..<400 {
            let s = start.addingTimeInterval(Double(rng.next(in: 0...(30 * 86400))))
            let span = Double(rng.next(in: 0...(3 * 86400)))   // some cross several day boundaries
            samples.append(HealthSample(type: steps.identifier, start: s, end: s.addingTimeInterval(span),
                                        value: Double(rng.next(in: 1...500)), unit: "count"))
            if i % 40 == 0 {
                samples.append(HealthSample(type: steps.identifier, start: s, end: s, value: 10, unit: "count"))
            }
        }
        let range = DateInterval(start: start, end: start.addingTimeInterval(30 * 86400))
        let fast = HealthMath.buckets(for: samples.sorted { $0.start < $1.start }, type: steps, range: range, interval: .day)
        let naive = Self.naiveBuckets(samples: samples, type: steps, range: range, interval: .day)
        XCTAssertEqual(fast.count, naive.count)
        for (f, n) in zip(fast, naive) {
            XCTAssertEqual(f.sum ?? 0, n, accuracy: 0.0001, "bucket starting \(ISO8601.string(from: f.start))")
        }
        XCTAssertEqual(fast.reduce(0) { $0 + ($1.sum ?? 0) }, naive.reduce(0, +), accuracy: 0.0001)
    }

    /// The original implementation, kept here only as an oracle.
    private static func naiveBuckets(samples: [HealthSample], type: HealthDataType, range: DateInterval,
                                     interval: StatisticsInterval) -> [Double] {
        var boundaries: [Date] = []
        var cursor = HealthMath.alignedStart(of: range.start, interval: interval, calendar: .current)
        while cursor < range.end {
            boundaries.append(cursor)
            cursor = Calendar.current.date(byAdding: interval.dateComponents, to: cursor)!
        }
        boundaries.append(cursor)
        var sums = [Double](repeating: 0, count: boundaries.count - 1)
        for s in samples {
            let total = max(s.end.timeIntervalSince(s.start), 0)
            for i in 0..<(boundaries.count - 1) {
                let bStart = boundaries[i], bEnd = boundaries[i + 1]
                if total == 0 {
                    if s.start >= bStart && s.start < bEnd { sums[i] += s.value }
                } else {
                    let o1 = max(bStart, s.start), o2 = min(bEnd, s.end)
                    if o2 > o1 { sums[i] += s.value * (o2.timeIntervalSince(o1) / total) }
                }
            }
        }
        return sums
    }

    // MARK: Server hardening

    /// `hasPrefix("127.")` accepted any registrable domain starting with those characters,
    /// which is the DNS-rebinding vector the Host and Origin checks exist to stop.
    func testLoopbackMatchingIsExact() {
        for good in ["127.0.0.1", "127.1.2.3", "localhost", "::1", "[::1]", "::ffff:127.0.0.1", "::1%lo0"] {
            XCTAssertTrue(HTTPServer.isLoopback(good), "\(good) should be loopback")
        }
        for bad in ["127.evil.com", "127.0.0.1.evil.com", "evil.com", "127.1", "0177.0.0.1",
                    "127.0.0.1x", "1270.0.0.1", "example.127.0.0.1.nip.io", "", "127.0.0.256"] {
            XCTAssertFalse(HTTPServer.isLoopback(bad), "\(bad) must not be treated as loopback")
        }
    }

    /// A chunk-size line with no terminator used to grow the receive buffer without bound,
    /// before any authentication ran.
    func testUnterminatedChunkSizeLineIsRejected() {
        var parser = HTTPRequestParser()
        _ = try? parser.feed(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        XCTAssertThrowsError(try parser.feed(Data(String(repeating: "f", count: 2048).utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .badChunk)
        }
    }

    func testOversizedRawBufferIsRejected() {
        var parser = HTTPRequestParser()
        parser.maxBodySize = 1024
        parser.maxHeadSize = 1024
        _ = try? parser.feed(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        XCTAssertThrowsError(try parser.feed(Data(repeating: 0x41, count: 4096)))
    }

    /// `end` is exclusive, so a bare YYYY-MM-DD used to drop that whole day.
    func testBareEndDateIncludesThatDay() throws {
        let args = ToolArgs(["start": "2026-09-01", "end": "2026-09-02"])
        let range = try args.range(defaultDays: 7)
        XCTAssertEqual(range.start, at("2026-09-01T00:00:00"))
        XCTAssertEqual(range.end, at("2026-09-03T00:00:00"), "asking through the 2nd must include the 2nd")
        // A full timestamp is still honoured exactly.
        let exact = try ToolArgs(["start": "2026-09-01T00:00:00", "end": "2026-09-02T12:00:00"]).range(defaultDays: 7)
        XCTAssertEqual(exact.end, at("2026-09-02T12:00:00"))
    }

    // MARK: Import hardening

    /// `resourceFilePath` comes from a file the user was handed. Traversal let a crafted export
    /// read arbitrary JSON — this app's pairings file, other agents' configs — and serve it back
    /// as a clinical record.
    func testExportResourcePathCannotEscapeTheExportDirectory() {
        let root = URL(fileURLWithPath: "/tmp/apple_health_export")
        XCTAssertNotNil(HealthExportImporter.resourceURL("/clinical-records/a.json", under: root))
        XCTAssertNotNil(HealthExportImporter.resourceURL("clinical-records/a.json", under: root))
        for escape in ["../../../etc/passwd",
                       "/../../Users/x/Library/Application Support/HealthBridge/pairings.json",
                       "clinical-records/../../../../.claude.json",
                       "..",
                       ""] {
            XCTAssertNil(HealthExportImporter.resourceURL(escape, under: root), "must reject: \(escape)")
        }
        // A leading slash is stripped rather than honoured, so an absolute path is contained
        // inside the export directory rather than escaping to it.
        let absolute = HealthExportImporter.resourceURL("/tmp/apple_health_export_evil/x.json", under: root)
        XCTAssertEqual(absolute?.path, "/tmp/apple_health_export/tmp/apple_health_export_evil/x.json")
    }
}

/// Serves only sleep, so the daily-summary keying can be tested in isolation.
private final class StubSleepProvider: HealthDataProvider, @unchecked Sendable {
    let kind = "stub"
    private let segments: [SleepSegment]
    init(segments: [SleepSegment]) { self.segments = segments }

    func status() async -> ProviderStatus {
        ProviderStatus(kind: kind, description: "stub", available: true, authorization: .notApplicable)
    }
    func availableTypes() async -> [HealthDataType] { [] }
    func requestAuthorization() async throws {}
    func samples(of type: HealthDataType, in range: DateInterval?, limit: Int, ascending: Bool) async throws -> [HealthSample] { [] }
    func statistics(of type: HealthDataType, in range: DateInterval, interval: StatisticsInterval) async throws -> [StatisticsBucket] {
        HealthMath.buckets(for: [], type: type, range: range, interval: interval)
    }
    func latestSample(of type: HealthDataType) async throws -> HealthSample? { nil }
    func sleepSegments(in range: DateInterval) async throws -> [SleepSegment] {
        segments.filter { $0.end >= range.start && $0.start < range.end }
    }
    func workouts(in range: DateInterval?, activityType: String?, limit: Int) async throws -> [Workout] { [] }
    func characteristics() async throws -> Characteristics { Characteristics() }
    func clinicalRecords(kind: ClinicalRecordKind?, since: Date?, limit: Int) async throws -> [ClinicalRecord] { [] }
}
