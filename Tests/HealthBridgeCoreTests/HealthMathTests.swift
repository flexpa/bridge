import XCTest
@testable import HealthBridgeCore

final class HealthMathTests: XCTestCase {
    let steps = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierStepCount"]!
    let hr = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierHeartRate"]!
    let cal = Calendar.current

    func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let base = cal.startOfDay(for: ISO8601.date(from: "2026-09-01")!)
        return cal.date(byAdding: DateComponents(day: offset, hour: hour, minute: minute), to: base)!
    }

    func testCumulativeSumsPerDayAndSplitsSpanningSamples() {
        let samples = [
            HealthSample(type: steps.identifier, start: day(0, hour: 8), end: day(0, hour: 9), value: 1000, unit: "count"),
            HealthSample(type: steps.identifier, start: day(0, hour: 23), end: day(1, hour: 1), value: 400, unit: "count"),  // 50/50 split
            HealthSample(type: steps.identifier, start: day(1, hour: 10), end: day(1, hour: 10, minute: 30), value: 300, unit: "count"),
        ]
        let buckets = HealthMath.buckets(for: samples, type: steps, range: DateInterval(start: day(0), end: day(2)), interval: .day)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].sum!, 1200, accuracy: 0.01)
        XCTAssertEqual(buckets[1].sum!, 500, accuracy: 0.01)
        XCTAssertEqual(buckets[0].count, 2)
    }

    func testDiscreteAverageMinMax() {
        let samples = [
            HealthSample(type: hr.identifier, start: day(0, hour: 8), end: day(0, hour: 8), value: 60, unit: "count/min"),
            HealthSample(type: hr.identifier, start: day(0, hour: 9), end: day(0, hour: 9), value: 80, unit: "count/min"),
            HealthSample(type: hr.identifier, start: day(1, hour: 9), end: day(1, hour: 9), value: 100, unit: "count/min"),
        ]
        let buckets = HealthMath.buckets(for: samples, type: hr, range: DateInterval(start: day(0), end: day(2)), interval: .day)
        XCTAssertEqual(buckets[0].average, 70)
        XCTAssertEqual(buckets[0].min, 60)
        XCTAssertEqual(buckets[0].max, 80)
        XCTAssertEqual(buckets[1].average, 100)
        XCTAssertEqual(buckets[1].count, 1)
    }

    func testEmptyBucketsAreReported() {
        let buckets = HealthMath.buckets(for: [], type: steps, range: DateInterval(start: day(0), end: day(3)), interval: .day)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets.map { $0.sum ?? -1 }, [0, 0, 0])
    }

    func testHourlyBucketsAlignToTheHour() {
        let range = DateInterval(start: day(0, hour: 7, minute: 30), end: day(0, hour: 10))
        let buckets = HealthMath.buckets(for: [], type: steps, range: range, interval: .hour)
        XCTAssertEqual(buckets.first?.start, day(0, hour: 7))
        XCTAssertEqual(buckets.count, 3)
    }

    func testNightsGroupingAndStageMinutes() {
        let segments = [
            SleepSegment(start: day(0, hour: 23), end: day(1, hour: 7), stage: .inBed),
            SleepSegment(start: day(0, hour: 23, minute: 15), end: day(1, hour: 1), stage: .asleepCore),
            SleepSegment(start: day(1, hour: 1), end: day(1, hour: 2), stage: .asleepDeep),
            SleepSegment(start: day(1, hour: 2), end: day(1, hour: 2, minute: 10), stage: .awake),
            SleepSegment(start: day(1, hour: 2, minute: 10), end: day(1, hour: 6, minute: 50), stage: .asleepREM),
            // Next night
            SleepSegment(start: day(1, hour: 23), end: day(2, hour: 6), stage: .asleepUnspecified),
        ]
        let nights = HealthMath.nights(from: segments, includeSegments: true)
        XCTAssertEqual(nights.count, 2)
        let first = nights[0]
        XCTAssertEqual(first.date, ISO8601.dayString(day(1)))
        XCTAssertEqual(first.inBedMinutes, 480)
        XCTAssertEqual(first.coreMinutes, 105)
        XCTAssertEqual(first.deepMinutes, 60)
        XCTAssertEqual(first.awakeMinutes, 10)
        XCTAssertEqual(first.remMinutes, 280)
        XCTAssertEqual(first.asleepMinutes, 445)
        XCTAssertEqual(first.segments?.count, 5)
        XCTAssertEqual(nights[1].asleepMinutes, 420)
        XCTAssertEqual(nights[1].inBedMinutes, 420)  // inferred from envelope
    }

    func testTypeResolution() {
        XCTAssertEqual(HealthTypeCatalog.resolve("stepCount")?.identifier, steps.identifier)
        XCTAssertEqual(HealthTypeCatalog.resolve("step_count")?.identifier, steps.identifier)
        XCTAssertEqual(HealthTypeCatalog.resolve("Steps")?.identifier, steps.identifier)
        XCTAssertEqual(HealthTypeCatalog.resolve("HKQuantityTypeIdentifierHeartRate")?.identifier, hr.identifier)
        XCTAssertEqual(HealthTypeCatalog.resolve("heart rate")?.identifier, hr.identifier)
        XCTAssertNil(HealthTypeCatalog.resolve("bogus"))
    }

    func testUnitConversion() {
        let mass = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierBodyMass"]!
        let (kg, unit) = UnitConversion.canonicalize(value: 176.37, unit: "lb", type: mass)
        XCTAssertEqual(kg, 80.0, accuracy: 0.01)
        XCTAssertEqual(unit, "kg")
        let temp = HealthTypeCatalog.byIdentifier["HKQuantityTypeIdentifierBodyTemperature"]!
        XCTAssertEqual(UnitConversion.canonicalize(value: 98.6, unit: "degF", type: temp).0, 37, accuracy: 0.01)
        let (same, sameUnit) = UnitConversion.canonicalize(value: 5, unit: "furlong", type: mass)
        XCTAssertEqual(same, 5)
        XCTAssertEqual(sameUnit, "furlong")
    }

    func testISO8601Parsing() {
        XCTAssertNotNil(ISO8601.date(from: "2026-09-14T08:00:00-04:00"))
        XCTAssertNotNil(ISO8601.date(from: "2026-09-14T08:00:00.123Z"))
        let dateOnly = ISO8601.date(from: "2026-09-14")!
        XCTAssertEqual(dateOnly, cal.startOfDay(for: dateOnly))
        XCTAssertEqual(cal.component(.day, from: dateOnly), 14)
        XCTAssertNotNil(ISO8601.date(from: "today"))
        XCTAssertNil(ISO8601.date(from: "not a date"))
        XCTAssertNotNil(ISO8601.exportDate(from: "2026-09-10 09:15:00 -0400"))
    }

    func testEncodableZeroAndOneStayNumbers() throws {
        struct Row: Encodable { var a: Double? = 1; var b: Double? = 0; var c: Bool = true; var d: Int = 0 }
        let v = try JSON.value(Row())
        XCTAssertEqual(v["a"], .number(1))
        XCTAssertEqual(v["b"], .number(0))
        XCTAssertEqual(v["c"], .bool(true))
        XCTAssertEqual(v["d"], .number(0))
        XCTAssertEqual(JSONValue(any: 1), .number(1))
        XCTAssertEqual(JSONValue(any: true), .bool(true))
        XCTAssertEqual(JSONValue(any: 0), .number(0))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("[0, 1, true, false, 2.5]".utf8))
        XCTAssertEqual(decoded, [0, 1, true, false, 2.5])
    }

    func testJSONValueIntegersSurviveRoundTrip() throws {
        let value: JSONValue = ["a": 5, "b": 2.5, "c": [1, 2], "d": .null, "e": true]
        let text = JSON.string(value)
        XCTAssertTrue(text.contains("\"a\":5"))
        XCTAssertTrue(text.contains("\"b\":2.5"))
        let back = try JSON.parse(text)
        XCTAssertEqual(back["a"]?.intValue, 5)
        XCTAssertEqual(back["e"]?.boolValue, true)
        XCTAssertEqual(back["c"]?[1]?.intValue, 2)
    }
}
