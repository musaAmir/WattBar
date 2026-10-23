import XCTest
@testable import WattBarCore

final class EnergyHistoryStoreTests: XCTestCase {
    private var folder: URL!
    private let start = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func history() -> EnergyHistory {
        var history = EnergyHistory()
        let reading = PowerReading(systemTotal: 50, batteryRate: 0, batteryPercent: nil,
                                   isCharging: false, isOnExternalPower: false)
        history.record(reading, at: start)
        history.record(reading, at: start.addingTimeInterval(10))
        return history
    }

    func testMissingArchiveStartsEmptyAndFlushRestoresMeasurements() throws {
        let url = folder.appendingPathComponent("nested/history.json")
        let store = EnergyHistoryStore(url: url)
        XCTAssertEqual(try store.load(now: start).bucketCount, 0)
        store.save(history(), at: start)
        try store.flush().get()
        XCTAssertNil(store.lastError)
        let restored = try EnergyHistoryStore(url: url).load(now: start.addingTimeInterval(20))
        let result = restored.summary(for: .minute, mode: .systemTotal, at: start.addingTimeInterval(20))
        XCTAssertEqual(result.averageWatts, 50)
        XCTAssertEqual(result.coveredSeconds, 10)
        XCTAssertEqual(restored.summary(for: .minute, mode: .battery,
                                        at: start.addingTimeInterval(20)).averageWatts, 0)
    }

    func testFlushWritesNewestSnapshotEvenInsideCheckpointThrottle() throws {
        let url = folder.appendingPathComponent("history.json")
        let store = EnergyHistoryStore(url: url)
        store.save(EnergyHistory(), at: start)
        try store.flush(at: start).get()
        XCTAssertNil(store.lastError)
        store.save(history(), at: start.addingTimeInterval(1))
        XCTAssertNil(store.lastError)
        let old = try EnergyHistoryStore(url: url).load(now: start.addingTimeInterval(20))
        XCTAssertEqual(old.bucketCount, 0)
        try store.flush().get()
        let newest = try EnergyHistoryStore(url: url).load(now: start.addingTimeInterval(20))
        XCTAssertEqual(newest.bucketCount, 1)
    }

    func testReloadDoesNotBridgeQuitGapAndPrunesExpiredData() throws {
        let url = folder.appendingPathComponent("history.json")
        let store = EnergyHistoryStore(url: url)
        store.save(history())
        try store.flush().get()
        var restored = try EnergyHistoryStore(url: url).load(now: start.addingTimeInterval(12))
        let reading = PowerReading(systemTotal: 50, batteryRate: nil, batteryPercent: nil,
                                   isCharging: false, isOnExternalPower: false)
        restored.record(reading, at: start.addingTimeInterval(13))
        XCTAssertEqual(restored.summary(for: .minute, mode: .systemTotal,
                                        at: start.addingTimeInterval(13)).coveredSeconds, 10)
        let expired = try EnergyHistoryStore(url: url).load(now: start.addingTimeInterval(90_000))
        XCTAssertEqual(expired.bucketCount, 0)
    }

    func testReloadAfterClockReversalDropsFutureSpans() throws {
        let url = folder.appendingPathComponent("history.json")
        let store = EnergyHistoryStore(url: url)
        store.save(history())
        try store.flush().get()
        let restored = try EnergyHistoryStore(url: url).load(now: start.addingTimeInterval(5))
        XCTAssertNil(restored.summary(for: .minute, mode: .systemTotal,
                                       at: start.addingTimeInterval(5)).averageWatts)
    }

    func testCorruptUnsupportedAndImpossibleArchivesSurfaceErrors() throws {
        let url = folder.appendingPathComponent("history.json")
        let store = EnergyHistoryStore(url: url)
        let invalidJSON = [
            "not json",
            #"{"version":2,"bucketSeconds":10,"buckets":[]}"#,
            #"{"version":1,"bucketSeconds":20,"buckets":[]}"#,
            #"{"version":1,"bucketSeconds":10,"buckets":[{"start":1000,"system":[{"start":1000,"end":1011,"wattSeconds":1,"peakWatts":1}],"battery":[]}]}"#,
            #"{"version":1,"bucketSeconds":10,"buckets":[{"start":1000,"system":[{"start":1000,"end":1010,"wattSeconds":-1,"peakWatts":1}],"battery":[]}]}"#,
            #"{"version":1,"bucketSeconds":10,"buckets":[{"start":1000,"system":[{"start":1000,"end":1010,"wattSeconds":100,"peakWatts":1}],"battery":[]}]}"#,
            #"{"version":1,"bucketSeconds":10,"buckets":[{"start":1000,"system":[{"start":1000,"end":1000,"wattSeconds":0,"peakWatts":0}],"battery":[]}]}"#,
            #"{"version":1,"bucketSeconds":10,"buckets":[{"start":1000,"system":[{"start":1000,"end":1010,"wattSeconds":1,"peakWatts":1},{"start":1005,"end":1010,"wattSeconds":1,"peakWatts":1}],"battery":[]}]}"#
        ]
        for source in invalidJSON {
            try Data(source.utf8).write(to: url)
            XCTAssertThrowsError(try store.load(now: start.addingTimeInterval(20)))
            XCTAssertNotNil(store.lastError)
        }
    }

    func testWriteFailureIsReturnedAndSuccessfulRetryClearsIt() throws {
        let obstruction = folder.appendingPathComponent("blocked")
        try Data("file blocks a directory".utf8).write(to: obstruction)
        let store = EnergyHistoryStore(url: obstruction.appendingPathComponent("history.json"))
        store.save(history())
        XCTAssertThrowsError(try store.flush().get())
        XCTAssertNotNil(store.lastError)
        try FileManager.default.removeItem(at: obstruction)
        try store.flush().get()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(try store.load(now: start.addingTimeInterval(20)).bucketCount, 1)
    }
}
