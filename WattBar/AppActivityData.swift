import Foundation

/// CPU resources observed between two samples, never a share of system power.
struct AppActivitySample: Codable {
    let start: Date
    let end: Date
    let apps: [AppActivityMeasurement]
    let supportsEnergy: Bool
}

struct AppActivityMeasurement: Codable {
    let identifier: String
    let name: String
    let bundleURL: URL?
    let cpuSeconds: Double
    let cpuJoules: Double?
}

struct AppActivityIdentity: Equatable {
    let identifier: String
    let name: String
    let bundleURL: URL?

    /// Nested browser/Electron helper apps belong to the outer application.
    static func outermostAppURL(for executablePath: String) -> URL? {
        let components = URL(fileURLWithPath: executablePath).standardizedFileURL.pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])),
                   isDirectory: true)
    }
}

/// Own-process counters only: child counters would double-count helpers.
struct AppProcessCounter {
    let pid: Int32
    let startTime: UInt64
    let identity: AppActivityIdentity
    let userTime: UInt64
    let systemTime: UInt64
    let energyNanojoules: UInt64?
}

struct AppActivityDeltaAccumulator {
    // The app's slowest sensor refresh is 10 s with 50% timer tolerance.
    static let maximumInterval: TimeInterval = 30
    private var previousDate: Date?
    private var previousCounters: [Int32: AppProcessCounter] = [:]

    mutating func breakContinuity() {
        previousDate = nil
        previousCounters.removeAll(keepingCapacity: true)
    }

    mutating func record(_ counters: [AppProcessCounter], at date: Date,
                         secondsPerTick: Double, supportsEnergy: Bool) -> AppActivitySample? {
        let oldDate = previousDate
        let oldCounters = previousCounters
        previousDate = date
        previousCounters = Dictionary(counters.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        guard let oldDate, secondsPerTick.isFinite, secondsPerTick > 0 else { return nil }
        let elapsed = date.timeIntervalSince(oldDate)
        guard elapsed > 0, elapsed <= Self.maximumInterval else { return nil }

        var grouped: [String: AppActivityMeasurement] = [:]
        for current in counters {
            guard let previous = oldCounters[current.pid],
                  previous.startTime == current.startTime,
                  previous.identity.identifier == current.identity.identifier,
                  current.userTime >= previous.userTime,
                  current.systemTime >= previous.systemTime else { continue }

            let cpuSeconds = (Double(current.userTime - previous.userTime)
                              + Double(current.systemTime - previous.systemTime)) * secondsPerTick
            let joules: Double?
            if supportsEnergy, let now = current.energyNanojoules,
               let before = previous.energyNanojoules, now >= before {
                joules = Double(now - before) / 1_000_000_000
            } else {
                joules = nil
            }
            guard cpuSeconds > 0 || (joules ?? 0) > 0 else { continue }
            let identity = current.identity
            if let existing = grouped[identity.identifier] {
                let sumJoules: Double?
                if let old = existing.cpuJoules, let joules { sumJoules = old + joules }
                else { sumJoules = nil }
                grouped[identity.identifier] = AppActivityMeasurement(identifier: identity.identifier,
                    name: identity.name, bundleURL: identity.bundleURL,
                    cpuSeconds: existing.cpuSeconds + cpuSeconds, cpuJoules: sumJoules)
            } else {
                grouped[identity.identifier] = AppActivityMeasurement(identifier: identity.identifier,
                    name: identity.name, bundleURL: identity.bundleURL,
                    cpuSeconds: cpuSeconds, cpuJoules: joules)
            }
        }
        return AppActivitySample(start: oldDate, end: date,
                                 apps: grouped.values.sorted { $0.identifier < $1.identifier },
                                 supportsEnergy: supportsEnergy)
    }
}
