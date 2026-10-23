import XCTest
@testable import WattBarCore

final class AppActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let app = AppActivityIdentity(identifier: "example.app", name: "Example", bundleURL: nil)

    private func counter(pid: Int32 = 1, launched: UInt64 = 10, cpu: UInt64,
                         energy: UInt64? = nil, identity: AppActivityIdentity? = nil) -> AppProcessCounter {
        AppProcessCounter(pid: pid, startTime: launched, identity: identity ?? app,
                          userTime: cpu, systemTime: 0, energyNanojoules: energy)
    }

    func testHelpersAreGroupedAndMachTimeConverted() throws {
        var delta = AppActivityDeltaAccumulator()
        XCTAssertNil(delta.record([counter(cpu: 10, energy: 1_000_000_000),
                                   counter(pid: 2, cpu: 20, energy: 2_000_000_000)],
                                  at: start, secondsPerTick: 0.01, supportsEnergy: true))
        let sample = try XCTUnwrap(delta.record([counter(cpu: 110, energy: 4_000_000_000),
                                                counter(pid: 2, cpu: 220, energy: 6_000_000_000)],
            at: start.addingTimeInterval(5), secondsPerTick: 0.01, supportsEnergy: true))
        XCTAssertEqual(sample.apps.count, 1)
        XCTAssertEqual(sample.apps[0].cpuSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(sample.apps[0].cpuJoules), 7, accuracy: 0.0001)
    }

    func testNewAndReusedPIDsNeverImportLifetimeUsage() throws {
        var delta = AppActivityDeltaAccumulator()
        _ = delta.record([counter(cpu: 50, energy: 500)], at: start,
                         secondsPerTick: 1, supportsEnergy: true)
        let sample = try XCTUnwrap(delta.record([counter(launched: 11, cpu: 1_000, energy: 100_000),
                                                counter(pid: 2, cpu: 5_000, energy: 500_000)],
            at: start.addingTimeInterval(5), secondsPerTick: 1, supportsEnergy: true))
        XCTAssertTrue(sample.apps.isEmpty)
    }

    func testUnavailableCPUOnlyAndMixedHelperEnergyIsNotInvented() throws {
        var delta = AppActivityDeltaAccumulator()
        _ = delta.record([counter(cpu: 10, energy: 100), counter(pid: 2, cpu: 10)],
                         at: start, secondsPerTick: 0.1, supportsEnergy: true)
        let sample = try XCTUnwrap(delta.record([counter(cpu: 20, energy: 200), counter(pid: 2, cpu: 20)],
            at: start.addingTimeInterval(5), secondsPerTick: 0.1, supportsEnergy: true))
        XCTAssertEqual(sample.apps[0].cpuSeconds, 2, accuracy: 0.0001)
        XCTAssertNil(sample.apps[0].cpuJoules)
    }

    func testCounterRollbackAndEnergyRollbackDoNotUnderflow() throws {
        var delta = AppActivityDeltaAccumulator()
        _ = delta.record([counter(cpu: 100, energy: 100)], at: start,
                         secondsPerTick: 1, supportsEnergy: true)
        let sample = try XCTUnwrap(delta.record([counter(cpu: 90, energy: 90)],
            at: start.addingTimeInterval(5), secondsPerTick: 1, supportsEnergy: true))
        XCTAssertTrue(sample.apps.isEmpty)
        let next = try XCTUnwrap(delta.record([counter(cpu: 91, energy: 80)],
            at: start.addingTimeInterval(10), secondsPerTick: 1, supportsEnergy: true))
        XCTAssertEqual(next.apps[0].cpuSeconds, 1)
        XCTAssertNil(next.apps[0].cpuJoules)
    }

    func testLongGapsClockChangesAndSleepBreakContinuity() {
        var delta = AppActivityDeltaAccumulator()
        _ = delta.record([counter(cpu: 1)], at: start, secondsPerTick: 1, supportsEnergy: false)
        XCTAssertNil(delta.record([counter(cpu: 50)], at: start.addingTimeInterval(60),
                                  secondsPerTick: 1, supportsEnergy: false))
        XCTAssertNil(delta.record([counter(cpu: 60)], at: start.addingTimeInterval(30),
                                  secondsPerTick: 1, supportsEnergy: false))
        delta.breakContinuity()
        XCTAssertNil(delta.record([counter(cpu: 65)], at: start.addingTimeInterval(35),
                                  secondsPerTick: 1, supportsEnergy: false))
    }

    func testHelpersUseOutermostAppPath() {
        XCTAssertEqual(AppActivityIdentity.outermostAppURL(for:
            "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")?.path,
            "/Applications/Browser.app")
        XCTAssertEqual(AppActivityIdentity.outermostAppURL(for:
            "/Applications/Example.app/Contents/MacOS/Example")?.path, "/Applications/Example.app")
        XCTAssertNil(AppActivityIdentity.outermostAppURL(for: "/usr/bin/python3"))
    }
}
