import XCTest
@testable import WattBarCore

final class AppActivityHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func sample(_ offset: Double, duration: Double = 5, cpu: Double = 2,
                        joules: Double? = 18, supported: Bool = true) -> AppActivitySample {
        AppActivitySample(start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + duration),
            apps: [AppActivityMeasurement(identifier: "example", name: "Example", bundleURL: nil,
                                           cpuSeconds: cpu, cpuJoules: joules)], supportsEnergy: supported)
    }
    func testJoulesCPUPercentAndMissingEnergy() throws {
        var history = AppActivityHistory()
        history.record(sample(0))
        history.record(sample(10, joules: nil))
        let result = history.summary(for: .minute, at: start.addingTimeInterval(20))
        XCTAssertEqual(result.observedDuration, 10)
        XCTAssertEqual(result.apps.first?.cpuPercent, 40)
        XCTAssertNil(result.apps.first?.cpuEnergyWh)
        var measured = AppActivityHistory()
        measured.record(sample(0))
        let app = try XCTUnwrap(measured.summary(for: .minute, at: start.addingTimeInterval(5)).apps.first)
        XCTAssertEqual(try XCTUnwrap(app.cpuEnergyWh), 0.005, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(app.averageCPUWatts), 3.6, accuracy: 0.000001)
    }
    func testClippingOverlapsAndGapsNeverAddUnobservedTime() throws {
        var history = AppActivityHistory()
        history.record(sample(0))
        history.record(sample(3)) // overlap rejected
        history.record(sample(30))
        let result = history.summary(for: .minute, at: start.addingTimeInterval(62))
        XCTAssertEqual(result.observedDuration, 8)
        XCTAssertEqual(result.apps.first?.cpuSeconds, 3.2)
        XCTAssertNil(history.summary(for: .minute, at: start.addingTimeInterval(100)).apps.first)
    }
    func testCompactionRoundTripKeepsExitedAppsAndRollingWindows() throws {
        var history = AppActivityHistory()
        for offset in stride(from: 0.0, through: 600, by: 5) { history.record(sample(offset)) }
        let restored = try JSONDecoder().decode(AppActivityHistory.self, from: JSONEncoder().encode(history))
        let minute = restored.summary(for: .minute, at: start.addingTimeInterval(605))
        XCTAssertEqual(minute.observedDuration, 60)
        XCTAssertEqual(minute.apps.first?.cpuSeconds, 24)
        let hour = restored.summary(for: .hour, at: start.addingTimeInterval(605))
        XCTAssertEqual(hour.observedDuration, 605)
        XCTAssertEqual(hour.apps.first?.cpuSeconds, 242)
        XCTAssertEqual(restored.summary(for: .day, at: start.addingTimeInterval(90_000)).observedDuration, 0)
    }
    func testZeroUnsupportedAndClockRollback() throws {
        var history = AppActivityHistory()
        history.record(sample(0, cpu: 0, joules: 0))
        XCTAssertEqual(history.summary(for: .minute, at: start.addingTimeInterval(5)).apps.first?.cpuEnergyWh, 0)
        history.record(sample(10, joules: nil, supported: false))
        XCTAssertNil(history.summary(for: .minute, at: start.addingTimeInterval(15)).apps.first?.cpuEnergyWh)
        history.record(sample(4))
        let result = history.summary(for: .minute, at: start.addingTimeInterval(9))
        XCTAssertEqual(result.observedDuration, 5)
        XCTAssertEqual(result.apps.first?.cpuSeconds, 2)
    }
    func testCompactionOverflowPreservesTotalsAndExpiredDataDrops() throws {
        var history = AppActivityHistory()
        let apps = (0..<180).map {
            AppActivityMeasurement(identifier: "app-\($0)", name: "App \($0)", bundleURL: nil,
                                   cpuSeconds: 1, cpuJoules: 2)
        }
        history.record(AppActivitySample(start: start, end: start.addingTimeInterval(5), apps: apps, supportsEnergy: true))
        history.record(sample(200)) // compact the older sample
        let result = history.summary(for: .day, at: start.addingTimeInterval(205))
        XCTAssertTrue(result.apps.contains { $0.name == "Other processes" })
        XCTAssertEqual(result.apps.reduce(0) { $0 + ($1.cpuEnergyWh ?? 0) }, 378 / 3600, accuracy: 0.000001)
        let data = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode(AppActivityHistory.self, from: data)
        XCTAssertEqual(restored.summary(for: .day, at: start.addingTimeInterval(205)).observedDuration, 10)
        XCTAssertTrue(restored.summary(for: .day, at: start.addingTimeInterval(90_000)).apps.isEmpty)
    }

    func testLongWindowsCompactionAndRestartPreservePerAppEnergy() throws {
        var history = AppActivityHistory()
        for day in 0..<91 { history.record(sample(Double(day) * 86_400)) }
        let now = start.addingTimeInterval(90 * 86_400 + 5)
        history.prepareAfterLoading(at: now)
        let data = try JSONEncoder().encode(history)
        var restored = try JSONDecoder().decode(AppActivityHistory.self, from: data)
        for (window, days) in [(EnergyWindow.week, 7.0), (.month, 30.0), (.threeMonths, 90.0)] {
            let result = restored.summary(for: window, at: now)
            XCTAssertEqual(result.observedDuration, days * 5)
            let app = try XCTUnwrap(result.apps.first)
            XCTAssertEqual(app.cpuSeconds, days * 2)
            XCTAssertEqual(try XCTUnwrap(app.cpuEnergyWh), days * 0.005, accuracy: 0.000001)
        }
        XCTAssertLessThan(data.count, 25_000)
        restored.prepareAfterLoading(at: now.addingTimeInterval(91 * 86_400))
        XCTAssertTrue(restored.summary(for: .threeMonths, at: now.addingTimeInterval(91 * 86_400)).apps.isEmpty)
    }

    func testHourlyCompactionPreservesGapsAndUnknownEnergy() throws {
        var history = AppActivityHistory()
        history.record(sample(0))
        history.record(sample(20, joules: nil))
        history.record(sample(2 * 86_400))
        let data = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode(AppActivityHistory.self, from: data)
        let result = restored.summary(for: .week, at: start.addingTimeInterval(2 * 86_400 + 5))
        XCTAssertEqual(result.observedDuration, 15)
        XCTAssertEqual(result.apps.first?.cpuSeconds, 6)
        XCTAssertNil(result.apps.first?.cpuEnergyWh)
        XCTAssertEqual(restored.summary(for: .minute, at: start.addingTimeInterval(85)).observedDuration, 0)
    }

    func testPreviousIdentityTableArchiveMigratesIntoHourlyHistory() throws {
        var history = AppActivityHistory()
        history.record(sample(0))
        history.record(sample(200))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        json["version"] = 2
        json.removeValue(forKey: "hourlyBuckets")
        var restored = try JSONDecoder().decode(AppActivityHistory.self, from: JSONSerialization.data(withJSONObject: json))
        restored.prepareAfterLoading(at: start.addingTimeInterval(2 * 86_400))
        let result = restored.summary(for: .month, at: start.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(result.observedDuration, 10)
        XCTAssertEqual(try XCTUnwrap(result.apps.first?.cpuEnergyWh), 0.01, accuracy: 0.000001)
    }

    func testStoreRestartAndCorruption() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let store = AppActivityHistoryStore(url: url)
        XCTAssertTrue(try store.load(now: start).summary(for: .day, at: start).apps.isEmpty)
        var history = AppActivityHistory()
        history.record(sample(0))
        store.save(history)
        try store.flush().get()
        let restored = try store.load(now: start.addingTimeInterval(10))
        XCTAssertEqual(restored.summary(for: .minute, at: start.addingTimeInterval(10)).observedDuration, 5)
        try Data("not valid".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertNotNil(store.lastError)
    }
}
