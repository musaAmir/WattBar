import XCTest
@testable import WattBarCore

final class PowerTests: XCTestCase {
    func reading(system: Double? = nil, battery: Double? = nil, voltage: Double? = 12000,
                 current: Double? = -1000, percent: Double? = 50, charging: Bool = false,
                 external: Bool = false) -> PowerReading {
        .resolve(system: system, battery: battery, voltageMV: voltage, currentMA: current,
                 percent: percent, isCharging: charging, externalPower: external)
    }

    func testFloatAndFixedPointSensors() {
        XCTAssertEqual(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 72, 65]), 12.5)
        XCTAssertEqual(SMCValueDecoder.decode(type: "fpe2", bytes: [0, 50]), 12.5)
        XCTAssertEqual(SMCValueDecoder.decode(type: "sp78", bytes: [0xff, 0x80]), -0.5)
        XCTAssertEqual(SMCValueDecoder.decode(type: "ui16", bytes: [1, 0]), 256)
        XCTAssertEqual(SMCValueDecoder.decode(type: "ui32", bytes: [0, 1, 0, 0]), 65536)
        XCTAssertEqual(SMCValueDecoder.decode(type: "ui8 ", bytes: [42]), 42)
    }
    func testMalformedSensorPayloadsAreRejected() {
        for bytes: [UInt8] in [[], [1], [1, 2], [1, 2, 3], Array(repeating: 0, count: 32)] {
            XCTAssertNil(SMCValueDecoder.decode(type: "flt ", bytes: bytes))
        }
        XCTAssertNil(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 128, 127]))
        XCTAssertNil(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 192, 127]))
        XCTAssertNil(SMCValueDecoder.decode(type: "nope", bytes: [0, 1]))
        XCTAssertNil(SMCValueDecoder.decode(type: "spff", bytes: [0, 1]))
    }
    func testZeroIsARealSensorReading() {
        let result = reading(system: 0, battery: 0)
        XCTAssertEqual(result.systemTotal, 0)
        XCTAssertEqual(result.batteryRate, 0)
    }
    func testBatteryFallbackOnlyEstimatesSystemWhileDischarging() {
        XCTAssertEqual(reading().systemTotal, 12)
        XCTAssertNil(reading(external: true).systemTotal)
        XCTAssertNil(reading(charging: true).systemTotal)
        XCTAssertEqual(reading(system: 30, charging: true, external: true).systemTotal, 30)
    }
    func testSignedBatteryRateAndMissingSensors() {
        XCTAssertEqual(reading(battery: -2.5).batteryRate, 2.5)
        XCTAssertEqual(reading(voltage: 12000, current: 0).batteryRate, 0)
        XCTAssertNil(reading(voltage: nil).systemTotal)
        XCTAssertNil(reading(system: .nan, battery: .infinity, voltage: nil).systemTotal)
        XCTAssertNil(reading(system: -1, voltage: nil).systemTotal)
        XCTAssertEqual(PowerReading.watts(nil), "— W")
    }
    func testCapacityClampingAndUnavailablePercent() {
        XCTAssertEqual(reading(percent: 200).batteryPercent, 100)
        XCTAssertEqual(reading(percent: -1).batteryPercent, 0)
        XCTAssertNil(reading(percent: .nan).batteryPercent)
        XCTAssertNil(reading(percent: nil).batteryPercent)
    }
    func testDesktopRegistryStubIsNotAnInstalledBattery() {
        XCTAssertFalse(PowerReading.hasBattery(installed: false, maximumCapacity: 0))
        XCTAssertFalse(PowerReading.hasBattery(installed: nil, maximumCapacity: 0))
        XCTAssertTrue(PowerReading.hasBattery(installed: true, maximumCapacity: 0))
        XCTAssertTrue(PowerReading.hasBattery(installed: nil, maximumCapacity: 5000))
    }
    func testPluggedInDoesNotMeanCharging() {
        XCTAssertEqual(reading(external: true).batteryStatus, "Plugged In · Not Charging")
        XCTAssertEqual(reading(charging: true, external: true).batteryStatus, "Charging")
        XCTAssertEqual(reading().batteryStatus, "On Battery")
    }
}

final class PowerHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func reading(system: Float?, battery: Float?) -> PowerReading {
        PowerReading(systemTotal: system, batteryRate: battery, batteryPercent: nil,
                     isCharging: false, isOnExternalPower: false)
    }

    func testWindowPreservesBoundaryAndRemovesOlderReadings() {
        var history = PowerHistory()
        for offset in [0.0, 30.0, 60.0] {
            history.record(reading(system: Float(offset), battery: nil),
                           at: start.addingTimeInterval(offset))
        }
        XCTAssertEqual(history.values(for: .systemTotal), [0, 30, 60])

        history.record(.unavailable, at: start.addingTimeInterval(60.001))
        XCTAssertEqual(history.values(for: .systemTotal), [30, 60])
        XCTAssertEqual(history.samples.count, 3)

        history.record(reading(system: 7, battery: nil), at: start.addingTimeInterval(121))
        XCTAssertEqual(history.values(for: .systemTotal), [7])
        XCTAssertEqual(history.samples.count, 1)
    }

    func testRapidReadingsKeepMemoryBoundedAndRetainNewestSamples() {
        var history = PowerHistory()
        for index in 0..<200 {
            history.record(reading(system: Float(index), battery: nil),
                           at: start.addingTimeInterval(Double(index) / 10))
        }
        XCTAssertEqual(history.samples.count, 120)
        XCTAssertEqual(history.samples.first?.date, start.addingTimeInterval(8))
        XCTAssertEqual(history.samples.first?.systemTotal, 80)
        XCTAssertEqual(history.samples.last?.systemTotal, 199)
    }

    func testRealZeroAndMissingValuesRemainDistinct() {
        var history = PowerHistory()
        history.record(reading(system: 0, battery: 0), at: start)
        history.record(.unavailable, at: start.addingTimeInterval(1))
        history.record(reading(system: .nan, battery: .infinity), at: start.addingTimeInterval(2))
        history.record(reading(system: -1, battery: -.infinity), at: start.addingTimeInterval(3))
        history.record(reading(system: .infinity, battery: -1), at: start.addingTimeInterval(4))

        XCTAssertEqual(history.samples.count, 5)
        XCTAssertEqual(history.samples.first?.systemTotal, 0)
        XCTAssertEqual(history.samples.first?.batteryRate, 0)
        XCTAssertTrue(history.samples.dropFirst().allSatisfy { $0.systemTotal == nil && $0.batteryRate == nil })
        XCTAssertEqual(history.values(for: .systemTotal), [0])
        XCTAssertEqual(history.values(for: .battery), [0])
    }

    func testDisplayModesKeepIndependentMeasurements() {
        var history = PowerHistory()
        history.record(reading(system: 25, battery: 10), at: start)
        history.record(reading(system: nil, battery: 12), at: start.addingTimeInterval(1))
        history.record(reading(system: 30, battery: nil), at: start.addingTimeInterval(2))

        XCTAssertEqual(history.values(for: .systemTotal), [25, 30])
        XCTAssertEqual(history.values(for: .battery), [10, 12])
        XCTAssertNil(history.samples[1].systemTotal)
        XCTAssertNil(history.samples[2].batteryRate)
    }

    func testClockReversalStartsANewHistory() {
        var history = PowerHistory()
        history.record(reading(system: 25, battery: 10), at: start)
        history.record(reading(system: 30, battery: 12), at: start.addingTimeInterval(5))
        history.record(reading(system: 20, battery: 8), at: start.addingTimeInterval(4))

        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.date, start.addingTimeInterval(4))
        XCTAssertEqual(history.values(for: .systemTotal), [20])
        XCTAssertEqual(history.values(for: .battery), [8])
    }
}
