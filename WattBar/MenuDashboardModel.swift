import SwiftUI

/// Shared by the compact menu and the history window. Only sensor reads advance energy.
final class MenuDashboardModel: ObservableObject {
    @Published var reading: PowerReading = .unavailable
    @Published var history = PowerHistory()
    @Published var energyHistory = EnergyHistory()
    @Published var activityHistory = AppActivityHistory()
    @Published var lastUpdated = Date()
    @Published private(set) var storageMessages: [String] = []

    private let energyStore: EnergyHistoryStore?
    private let activityStore: AppActivityHistoryStore?
    private var loadMessages: [String] = []

    init(energyStore: EnergyHistoryStore? = EnergyHistoryStore(),
         activityStore: AppActivityHistoryStore? = AppActivityHistoryStore()) {
        self.energyStore = energyStore
        self.activityStore = activityStore
        do { if let energyStore { energyHistory = try energyStore.load(now: lastUpdated) } }
        catch { loadMessages.append("Previous power history couldn’t be restored. New readings are being recorded.") }
        do { if let activityStore { activityHistory = try activityStore.load(now: lastUpdated) } }
        catch { loadMessages.append("Previous app activity couldn’t be restored. New activity is being recorded.") }
        updateStorageMessages()
    }

    func record(_ reading: PowerReading, at date: Date, maximumGap: TimeInterval = 30) {
        history.record(reading, at: date)
        energyHistory.record(reading, at: date, maximumGap: maximumGap)
        self.reading = reading
        lastUpdated = date
        energyStore?.save(energyHistory, at: date)
        updateStorageMessages()
    }

    func recordActivity(_ sample: AppActivitySample) {
        activityHistory.record(sample)
        activityStore?.save(activityHistory, at: sample.end)
        updateStorageMessages()
    }

    func interrupt() {
        energyHistory.interrupt()
        history = PowerHistory()
        reading = .unavailable
        checkpoint()
    }

    func refreshSummaries(at date: Date = Date()) {
        lastUpdated = date
        updateStorageMessages()
    }

    func checkpoint() {
        energyStore?.save(energyHistory, force: true)
        activityStore?.save(activityHistory, force: true)
        _ = energyStore?.flush()
        _ = activityStore?.flush()
        updateStorageMessages()
    }

    private func updateStorageMessages() {
        var messages = loadMessages
        if energyStore?.lastError != nil { messages.append("Power history couldn’t be saved. Check available disk space and folder permissions.") }
        if activityStore?.lastError != nil { messages.append("App activity couldn’t be saved. Check available disk space and folder permissions.") }
        if storageMessages != messages { storageMessages = messages }
    }
}

/// Use energy units for accumulated use and power units for rates.
enum EnergyFormat {
    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "— W" }
        return String(format: "%.1f W", value)
    }

    static func energy(_ wattHours: Double?) -> String {
        guard let wattHours, wattHours.isFinite else { return "—" }
        if wattHours == 0 { return "0 Wh" }
        if wattHours >= 1000 { return String(format: "%.2f kWh", wattHours / 1000) }
        if wattHours < 1 { return String(format: "%.1f mWh", wattHours * 1000) }
        return String(format: "%.2f Wh", wattHours)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds >= 86_400 { return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    static func coverage(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<1%" }
        return "\(min(100, max(0, Int(value * 100))))%"
    }
}
