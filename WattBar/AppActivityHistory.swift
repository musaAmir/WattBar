import Foundation

struct AppActivityRecord: Identifiable {
    let identifier: String
    let name: String
    let bundleURL: URL?
    let cpuSeconds: Double
    let cpuPercent: Double
    let cpuEnergyWh: Double?
    let averageCPUWatts: Double?
    var id: String { identifier }
}

struct AppActivitySummary {
    let apps: [AppActivityRecord]
    let observedDuration: TimeInterval
    let supportsEnergy: Bool
}

/// Keeps recent intervals for minute precision, then minute buckets for a day
/// and hourly buckets for the remainder of the ninety-day retention window.
/// At a clipped older bucket, resource totals are proportional to its observed
/// time. Coverage remains exact; resource attribution at that boundary is approximate.
struct AppActivityHistory: Codable {
    private struct Span: Codable { var start: Date; var end: Date }
    private struct Totals: Codable {
        let identifier: String
        var name: String
        var bundleURL: URL?
        var cpuSeconds: Double
        var cpuJoules: Double?
    }
    private struct Bucket: Codable {
        let start: Date
        var spans: [Span] = []
        var apps: [String: Totals] = [:]
        var supportsEnergy = true
        var duration: Double { spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
    }
    private var buckets: [Bucket] = []
    private var hourlyBuckets: [Bucket] = []
    private var recent: [AppActivitySample] = []
    private var latestEnd: Date?
    static let retention: Double = 90 * 86_400
    private static let detailedRetention: Double = 86_400
    private static let maximumApps = 100
    private static let otherID = "wattbar.other-processes"

    init() {}

    mutating func record(_ sample: AppActivitySample) {
        guard Self.valid(sample) else { return }
        if let latestEnd, sample.end < latestEnd {
            // Do not overlap old observations after a wall-clock correction.
            recent.removeAll { $0.end > sample.start }
            buckets.removeAll { $0.start.addingTimeInterval(60) > sample.start }
            hourlyBuckets.removeAll { $0.start.addingTimeInterval(3_600) > sample.start }
            self.latestEnd = nil
        }
        if let latestEnd, sample.start < latestEnd { return }
        latestEnd = sample.end
        recent.append(sample)
        let compactBefore = sample.end.addingTimeInterval(-120)
        while let first = recent.first, first.end <= compactBefore {
            recent.removeFirst()
            compact(first)
        }
        prepareAfterLoading(at: sample.end)
    }

    func summary(for window: EnergyWindow, at date: Date = Date()) -> AppActivitySummary {
        let start = date.addingTimeInterval(-window.duration)
        var totals: [String: Totals] = [:]
        var observed = 0.0
        var energyAvailable = false
        var allEnergyAvailable = true
        for bucket in hourlyBuckets + buckets {
            guard bucket.start < date, (bucket.spans.last?.end ?? .distantPast) > start else { continue }
            let covered = bucket.spans.reduce(0.0) { $0 + Self.overlap($1.start, $1.end, start, date) }
            guard covered > 0, bucket.duration > 0 else { continue }
            observed += covered
            energyAvailable = energyAvailable || bucket.supportsEnergy
            allEnergyAvailable = allEnergyAvailable && bucket.supportsEnergy
            for value in bucket.apps.values { Self.add(value, scale: covered / bucket.duration, to: &totals) }
        }
        for sample in recent {
            let covered = Self.overlap(sample.start, sample.end, start, date)
            guard covered > 0 else { continue }
            observed += covered
            energyAvailable = energyAvailable || sample.supportsEnergy
            allEnergyAvailable = allEnergyAvailable && sample.supportsEnergy
            let scale = covered / sample.end.timeIntervalSince(sample.start)
            for app in sample.apps {
                Self.add(Totals(identifier: app.identifier, name: app.name, bundleURL: app.bundleURL,
                                cpuSeconds: app.cpuSeconds, cpuJoules: app.cpuJoules), scale: scale, to: &totals)
            }
        }
        let apps = totals.values.map { value -> AppActivityRecord in
            let joules = allEnergyAvailable ? value.cpuJoules : nil
            return AppActivityRecord(identifier: value.identifier, name: value.name, bundleURL: value.bundleURL,
                cpuSeconds: value.cpuSeconds, cpuPercent: observed > 0 ? value.cpuSeconds / observed * 100 : 0,
                cpuEnergyWh: joules.map { $0 / 3_600 }, averageCPUWatts: joules.map { observed > 0 ? $0 / observed : 0 })
        }.sorted {
            if energyAvailable, ($0.cpuEnergyWh ?? -1) != ($1.cpuEnergyWh ?? -1) {
                return ($0.cpuEnergyWh ?? -1) > ($1.cpuEnergyWh ?? -1)
            }
            if $0.cpuSeconds != $1.cpuSeconds { return $0.cpuSeconds > $1.cpuSeconds }
            return $0.identifier < $1.identifier
        }
        return AppActivitySummary(apps: apps, observedDuration: min(window.duration, observed), supportsEnergy: energyAvailable)
    }

    mutating func prepareAfterLoading(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        buckets.removeAll { $0.spans.contains(where: { $0.end > date }) }
        hourlyBuckets.removeAll { $0.start.addingTimeInterval(3_600) <= cutoff || $0.spans.contains(where: { $0.end > date }) }
        recent.removeAll { $0.end <= cutoff || $0.end > date }
        let count = buckets.prefix { $0.start.addingTimeInterval(60) <= date.addingTimeInterval(-Self.detailedRetention) }.count
        for bucket in buckets.prefix(count) { compactOlder(bucket) }
        if count > 0 { buckets.removeFirst(count) }
        hourlyBuckets.removeAll { $0.start.addingTimeInterval(3_600) <= cutoff }
        latestEnd = [hourlyBuckets.last?.spans.last?.end, buckets.last?.spans.last?.end, recent.last?.end].compactMap { $0 }.max()
    }

    private mutating func compactOlder(_ bucket: Bucket) {
        let start = Date(timeIntervalSince1970: floor(bucket.start.timeIntervalSince1970 / 3_600) * 3_600)
        if hourlyBuckets.last?.start != start { hourlyBuckets.append(Bucket(start: start)) }
        let index = hourlyBuckets.count - 1
        for span in bucket.spans {
            if hourlyBuckets[index].spans.last?.end == span.start {
                hourlyBuckets[index].spans[hourlyBuckets[index].spans.count - 1].end = span.end
            } else { hourlyBuckets[index].spans.append(span) }
        }
        hourlyBuckets[index].supportsEnergy = hourlyBuckets[index].supportsEnergy && bucket.supportsEnergy
        for value in bucket.apps.values { Self.add(value, scale: 1, to: &hourlyBuckets[index].apps) }
        Self.boundApps(&hourlyBuckets[index].apps)
    }

    private mutating func compact(_ sample: AppActivitySample) {
        let totalDuration = sample.end.timeIntervalSince(sample.start)
        var cursor = sample.start
        while cursor < sample.end {
            let start = Date(timeIntervalSince1970: floor(cursor.timeIntervalSince1970 / 60) * 60)
            let end = min(sample.end, start.addingTimeInterval(60))
            if buckets.last?.start != start { buckets.append(Bucket(start: start)) }
            let index = buckets.count - 1
            if buckets[index].spans.last?.end == cursor {
                buckets[index].spans[buckets[index].spans.count - 1].end = end
            } else { buckets[index].spans.append(Span(start: cursor, end: end)) }
            buckets[index].supportsEnergy = buckets[index].supportsEnergy && sample.supportsEnergy
            for app in sample.apps {
                Self.add(Totals(identifier: app.identifier, name: app.name, bundleURL: app.bundleURL,
                    cpuSeconds: app.cpuSeconds, cpuJoules: app.cpuJoules),
                    scale: end.timeIntervalSince(cursor) / totalDuration, to: &buckets[index].apps)
            }
            Self.boundApps(&buckets[index].apps)
            cursor = end
        }
    }

    private static func add(_ value: Totals, scale: Double, to totals: inout [String: Totals]) {
        if var old = totals[value.identifier] {
            old.cpuSeconds += value.cpuSeconds * scale
            old.cpuJoules = old.cpuJoules.flatMap { old in value.cpuJoules.map { old + $0 * scale } }
            totals[value.identifier] = old
        } else {
            totals[value.identifier] = Totals(identifier: value.identifier, name: value.name, bundleURL: value.bundleURL,
                                             cpuSeconds: value.cpuSeconds * scale, cpuJoules: value.cpuJoules.map { $0 * scale })
        }
    }

    private static func boundApps(_ apps: inout [String: Totals]) {
        guard apps.count > maximumApps else { return }
        let keep = Set(apps.values.filter { $0.identifier != otherID }.sorted {
            ($0.cpuJoules ?? $0.cpuSeconds) > ($1.cpuJoules ?? $1.cpuSeconds)
        }.prefix(maximumApps - 1).map(\.identifier))
        var result = apps.filter { keep.contains($0.key) }
        for value in apps.values where !keep.contains(value.identifier) {
            add(Totals(identifier: otherID, name: "Other processes", bundleURL: nil,
                       cpuSeconds: value.cpuSeconds, cpuJoules: value.cpuJoules), scale: 1, to: &result)
        }
        apps = result
    }

    private static func overlap(_ a: Date, _ b: Date, _ start: Date, _ end: Date) -> Double {
        max(0, min(b, end).timeIntervalSince(max(a, start)))
    }
    private static func valid(_ sample: AppActivitySample) -> Bool {
        let duration = sample.end.timeIntervalSince(sample.start)
        return sample.start.timeIntervalSince1970.isFinite && sample.end.timeIntervalSince1970.isFinite
            && duration > 0 && duration <= 30 && sample.apps.count <= 8_192
            && Set(sample.apps.map(\.identifier)).count == sample.apps.count
            && sample.apps.allSatisfy {
                !$0.identifier.isEmpty && $0.identifier.count <= 4_096 && $0.name.count <= 2_048
                && $0.cpuSeconds.isFinite && $0.cpuSeconds >= 0 && $0.cpuSeconds <= duration * 32_768
                && ($0.cpuJoules.map { $0.isFinite && $0 >= 0 && $0 <= duration * 1_000_000 } ?? true)
            }
    }

    private struct Identity: Codable { let name: String; let bundleURL: URL? }
    private struct ArchivedUsage: Codable { let cpuSeconds: Double; let cpuJoules: Double? }
    private struct ArchivedBucket: Codable {
        let start: Date
        let spans: [Span]
        let apps: [String: ArchivedUsage]
        let supportsEnergy: Bool
    }
    private enum CodingKeys: String, CodingKey { case version, buckets, hourlyBuckets, recent, identities }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // App names and paths are stored once, rather than in every minute bucket.
        var identities: [String: Identity] = [:]
        func archive(_ source: [Bucket]) -> [ArchivedBucket] {
            source.map { bucket in
                for app in bucket.apps.values { identities[app.identifier] = Identity(name: app.name, bundleURL: app.bundleURL) }
                return ArchivedBucket(start: bucket.start, spans: bucket.spans,
                    apps: bucket.apps.mapValues { ArchivedUsage(cpuSeconds: $0.cpuSeconds, cpuJoules: $0.cpuJoules) },
                    supportsEnergy: bucket.supportsEnergy)
            }
        }
        let archived = archive(buckets)
        let hourly = archive(hourlyBuckets)
        try c.encode(3, forKey: .version)
        try c.encode(identities, forKey: .identities)
        try c.encode(archived, forKey: .buckets)
        try c.encode(hourly, forKey: .hourlyBuckets)
        try c.encode(recent, forKey: .recent)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard (1...3).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported app history format")
        }
        if version == 1 { buckets = try c.decode([Bucket].self, forKey: .buckets) }
        else {
            let identities = try c.decode([String: Identity].self, forKey: .identities)
            func restore(_ archived: [ArchivedBucket]) throws -> [Bucket] {
                try archived.map { bucket in
                    let apps = try bucket.apps.map { key, value -> (String, Totals) in
                        guard let identity = identities[key] else {
                            throw DecodingError.dataCorruptedError(forKey: .identities, in: c, debugDescription: "Missing app identity")
                        }
                        return (key, Totals(identifier: key, name: identity.name, bundleURL: identity.bundleURL,
                                             cpuSeconds: value.cpuSeconds, cpuJoules: value.cpuJoules))
                    }
                    return Bucket(start: bucket.start, spans: bucket.spans,
                                  apps: Dictionary(uniqueKeysWithValues: apps), supportsEnergy: bucket.supportsEnergy)
                }
            }
            buckets = try restore(c.decode([ArchivedBucket].self, forKey: .buckets))
            hourlyBuckets = try restore(c.decodeIfPresent([ArchivedBucket].self, forKey: .hourlyBuckets) ?? [])
        }
        recent = try c.decode([AppActivitySample].self, forKey: .recent)
        var previous = Date.distantPast
        var valid = buckets.count <= 1_441 && hourlyBuckets.count <= 2_161 && recent.count <= 1_000
        for (tier, duration, spanLimit) in [(hourlyBuckets, 3_600.0, 1_024), (buckets, 60.0, 60)] {
            previous = .distantPast
            for bucket in tier {
                valid = valid && bucket.start.timeIntervalSince1970.isFinite && bucket.start >= previous
                    && bucket.apps.count <= Self.maximumApps && bucket.spans.count <= spanLimit && !bucket.spans.isEmpty
                var end = bucket.start
                for span in bucket.spans {
                    valid = valid && span.start >= end && span.end > span.start && span.end <= bucket.start.addingTimeInterval(duration)
                    end = span.end
                }
                for (key, app) in bucket.apps {
                    valid = valid && key == app.identifier && !key.isEmpty && key.count <= 4_096 && app.name.count <= 2_048
                        && app.cpuSeconds.isFinite && app.cpuSeconds >= 0 && app.cpuSeconds <= bucket.duration * 32_768
                        && (app.cpuJoules.map { $0.isFinite && $0 >= 0 && $0 <= bucket.duration * 1_000_000 } ?? true)
                }
                previous = bucket.start.addingTimeInterval(duration)
            }
        }
        if let oldEnd = hourlyBuckets.last?.spans.last?.end, let newStart = buckets.first?.spans.first?.start {
            valid = valid && oldEnd <= newStart
        }
        previous = buckets.last?.spans.last?.end ?? hourlyBuckets.last?.spans.last?.end ?? .distantPast
        for sample in recent {
            valid = valid && Self.valid(sample) && sample.start >= previous
            previous = sample.end
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(forKey: .buckets, in: c, debugDescription: "Invalid app history measurements")
        }
        latestEnd = previous == .distantPast ? nil : previous
    }
}
