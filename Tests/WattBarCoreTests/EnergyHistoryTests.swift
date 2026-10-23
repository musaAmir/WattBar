import XCTest
@testable import WattBarCore

final class EnergyHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func reading(_ watts: Float?, battery: Float? = nil) -> PowerReading {
        PowerReading(systemTotal: watts, batteryRate: battery, batteryPercent: nil,
                     isCharging: false, isOnExternalPower: false)
    }

    private func record(_ watts: Float?, at seconds: Double, in history: inout EnergyHistory,
                        battery: Float? = nil, gap: TimeInterval = 15) {
        history.record(reading(watts, battery: battery), at: start.addingTimeInterval(seconds),
                       maximumGap: gap)
    }

    private func summary(_ history: EnergyHistory, at seconds: Double,
                         window: EnergyWindow = .minute, mode: DisplayMode = .systemTotal) -> EnergySummary {
        history.summary(for: window, mode: mode, at: start.addingTimeInterval(seconds))
    }

    func testKnownTrapezoidIntegralAndIndependentBatteryEnergy() throws {
        var history = EnergyHistory()
        record(100, at: 0, in: &history, battery: 0)
        record(200, at: 10, in: &history, battery: 10)
        record(100, at: 20, in: &history, battery: 20)
        let system = summary(history, at: 20)
        XCTAssertEqual(try XCTUnwrap(system.averageWatts), 150, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(system.wattHours), 3_000 / 3_600, accuracy: 0.000_001)
        XCTAssertEqual(system.coveredSeconds, 20)
        XCTAssertEqual(system.coverage, 1 / 3, accuracy: 0.000_001)
        XCTAssertEqual(system.peakWatts, 200)
        let battery = summary(history, at: 20, mode: .battery)
        XCTAssertEqual(battery.averageWatts, 10)
        XCTAssertEqual(try XCTUnwrap(battery.wattHours), 200 / 3_600, accuracy: 0.000_001)
    }

    func testIrregularIntervalsAreTimeWeightedRatherThanSampleAveraged() throws {
        var history = EnergyHistory()
        record(0, at: 0, in: &history)
        record(100, at: 1, in: &history)
        record(100, at: 10, in: &history)
        let result = summary(history, at: 10)
        XCTAssertEqual(result.averageWatts, 95) // (50 Ws + 900 Ws) / 10 s
        XCTAssertEqual(try XCTUnwrap(result.wattHours), 950 / 3_600, accuracy: 0.000_001)
        XCTAssertEqual(result.coveredSeconds, 10)
    }

    func testFirstSampleDoesNotBackfillAndWindowDoesNotExtrapolate() {
        var history = EnergyHistory()
        record(50, at: 3, in: &history)
        XCTAssertNil(summary(history, at: 3).averageWatts)
        record(50, at: 8, in: &history)
        XCTAssertEqual(summary(history, at: 60).coveredSeconds, 5)
        XCTAssertEqual(summary(history, at: 60).averageWatts, 50)
        XCTAssertEqual(summary(history, at: 64).coveredSeconds, 4)
        XCTAssertNil(summary(history, at: 68).averageWatts)
    }

    func testMinuteHourAndDaySelectTheirOwnRollingWindows() throws {
        var history = EnergyHistory()
        for offset in stride(from: 0, through: 3_600, by: 10) {
            record(36, at: Double(offset), in: &history)
        }
        let minute = summary(history, at: 3_600)
        let hour = summary(history, at: 3_600, window: .hour)
        let day = summary(history, at: 3_600, window: .day)
        XCTAssertEqual(minute.averageWatts, 36)
        XCTAssertEqual(try XCTUnwrap(minute.wattHours), 0.6, accuracy: 0.000_001)
        XCTAssertEqual(minute.coverage, 1)
        XCTAssertEqual(hour.averageWatts, 36)
        XCTAssertEqual(try XCTUnwrap(hour.wattHours), 36, accuracy: 0.000_001)
        XCTAssertEqual(hour.coverage, 1)
        XCTAssertEqual(day.averageWatts, 36)
        XCTAssertEqual(try XCTUnwrap(day.wattHours), 36, accuracy: 0.000_001)
        XCTAssertEqual(day.coverage, 1 / 24, accuracy: 0.000_001)
    }

    func testPartialBoundaryUsesSpanAverageWithExactMeasuredCoverage() throws {
        var history = EnergyHistory()
        record(0, at: 0, in: &history)
        record(100, at: 10, in: &history)
        record(100, at: 20, in: &history)
        // The last minute starts five seconds into the first ten-second span.
        let result = summary(history, at: 65)
        XCTAssertEqual(result.coveredSeconds, 15)
        XCTAssertEqual(try XCTUnwrap(result.wattHours), 1_250 / 3_600, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.averageWatts), 1_250 / 15, accuracy: 0.000_001)
    }

    func testZeroIsMeasuredButMissingAndInvalidSensorsAreNot() {
        var history = EnergyHistory()
        record(0, at: 0, in: &history, battery: 5)
        record(0, at: 2, in: &history, battery: nil)
        record(nil, at: 4, in: &history, battery: 5)
        record(.nan, at: 6, in: &history, battery: 5)
        record(-1, at: 8, in: &history, battery: .infinity)
        record(.infinity, at: 10, in: &history)
        let system = summary(history, at: 10)
        XCTAssertEqual(system.averageWatts, 0)
        XCTAssertEqual(system.wattHours, 0)
        XCTAssertEqual(system.coveredSeconds, 2)
        let battery = summary(history, at: 10, mode: .battery)
        XCTAssertEqual(battery.averageWatts, 5)
        XCTAssertEqual(battery.coveredSeconds, 2)
    }

    func testLongGapsAndSleepInterruptionsDoNotAccumulateEnergy() {
        var history = EnergyHistory()
        record(100, at: 0, in: &history)
        record(100, at: 5, in: &history)
        record(100, at: 50, in: &history)
        record(100, at: 55, in: &history)
        history.interrupt()
        record(100, at: 56, in: &history)
        record(100, at: 60, in: &history)
        XCTAssertEqual(summary(history, at: 60).coveredSeconds, 14)
        XCTAssertEqual(summary(history, at: 60).averageWatts, 100)
    }

    func testRefreshToleranceAllowsConfiguredLongerIntervals() {
        var history = EnergyHistory()
        record(25, at: 0, in: &history, gap: 25)
        record(25, at: 20, in: &history, gap: 25)
        record(25, at: 46, in: &history, gap: 25)
        XCTAssertEqual(summary(history, at: 46).coveredSeconds, 20)
        XCTAssertEqual(summary(history, at: 46).averageWatts, 25)
    }

    func testMissingIntervalsInsideOneBucketStayGapsInCharts() {
        var history = EnergyHistory()
        record(10, at: 0, in: &history)
        record(10, at: 2, in: &history)
        record(nil, at: 3, in: &history)
        record(20, at: 7, in: &history)
        record(20, at: 9, in: &history)
        let chart = history.chart(for: .minute, mode: .systemTotal,
                                  at: start.addingTimeInterval(60), pointCount: 60)
        XCTAssertEqual(chart.count, 60)
        XCTAssertEqual(chart[0].averageWatts, 10)
        XCTAssertEqual(chart[1].coverage, 1)
        XCTAssertNil(chart[2].averageWatts)
        XCTAssertNil(chart[6].averageWatts)
        XCTAssertEqual(chart[7].averageWatts, 20)
        XCTAssertNil(chart[9].averageWatts)
        XCTAssertEqual(summary(history, at: 60).coveredSeconds, 4)
    }

    func testClockReversalDropsFutureMeasurementsAndNeverDoubleCounts() {
        var history = EnergyHistory()
        for offset in [0.0, 10, 20, 30] { record(10, at: offset, in: &history) }
        record(50, at: 15, in: &history)
        XCTAssertEqual(summary(history, at: 15).coveredSeconds, 10)
        record(50, at: 20, in: &history)
        let result = summary(history, at: 20)
        XCTAssertEqual(result.coveredSeconds, 15)
        XCTAssertEqual(result.averageWatts, 350 / 15)
    }

    func testDuplicateTimestampsDoNotAddCoverage() {
        var history = EnergyHistory()
        record(10, at: 0, in: &history)
        record(20, at: 0, in: &history)
        record(20, at: 10, in: &history)
        XCTAssertEqual(summary(history, at: 10).coveredSeconds, 10)
        XCTAssertEqual(summary(history, at: 10).averageWatts, 20)
    }

    func testHistoryStaysBoundedAndDayExcludesOlderReadings() throws {
        var history = EnergyHistory()
        // Deliberately offset from bucket boundaries to exercise both edge buckets.
        for offset in stride(from: 3, through: 172_803, by: 10) {
            record(10, at: Double(offset), in: &history)
        }
        XCTAssertLessThanOrEqual(history.bucketCount, EnergyHistory.maximumBucketCount)
        let day = summary(history, at: 172_803, window: .day)
        XCTAssertEqual(day.coveredSeconds, 86_400)
        XCTAssertEqual(day.coverage, 1)
        XCTAssertEqual(try XCTUnwrap(day.wattHours), 240, accuracy: 0.000_001)
        record(nil, at: 259_214, in: &history)
        XCTAssertEqual(history.bucketCount, 0)
    }

    func testDecodingNeverRestoresIntegrationAnchor() throws {
        var history = EnergyHistory()
        record(10, at: 0, in: &history)
        record(10, at: 5, in: &history)
        var restored = try JSONDecoder().decode(EnergyHistory.self, from: JSONEncoder().encode(history))
        record(10, at: 8, in: &restored)
        XCTAssertEqual(summary(restored, at: 8).coveredSeconds, 5)
        record(10, at: 10, in: &restored)
        XCTAssertEqual(summary(restored, at: 10).coveredSeconds, 7)
    }

    func testPathologicalHighFrequencyGapsDoNotGrowStorageWithoutBound() throws {
        var history = EnergyHistory()
        for offset in stride(from: 0.0, through: 9.9, by: 0.1) {
            record(10, at: offset, in: &history)
            record(10, at: offset + 0.02, in: &history)
            record(nil, at: offset + 0.04, in: &history)
        }
        let data = try JSONEncoder().encode(history)
        XCTAssertLessThan(data.count, 2_000)
        XCTAssertLessThanOrEqual(summary(history, at: 10).coveredSeconds, 0.321)
        XCTAssertNoThrow(try JSONDecoder().decode(EnergyHistory.self, from: data))
    }
}
