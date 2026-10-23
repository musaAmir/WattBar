import Foundation

/// Rolling windows, measured backwards from the time the menu is displayed.
enum EnergyWindow: String, CaseIterable, Identifiable {
    case minute, hour, day, week, month, threeMonths

    var id: String { rawValue }
    var duration: TimeInterval {
        switch self {
        case .minute: return 60
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .threeMonths: return 90 * 86_400
        }
    }
    var label: String {
        switch self {
        case .minute: return "Past Minute"
        case .hour: return "Past Hour"
        case .day: return "Past Day"
        case .week: return "Past Week"
        case .month: return "Past Month"
        case .threeMonths: return "Past 3 Months"
        }
    }
    var shortLabel: String {
        switch self {
        case .minute: return "1 min"
        case .hour: return "1 hour"
        case .day: return "24h"
        case .week: return "7 days"
        case .month: return "30 days"
        case .threeMonths: return "90 days"
        }
    }
    var chartDescription: String {
        switch self {
        case .minute: return "The last 60 seconds"
        case .hour: return "The last 60 minutes"
        case .day: return "The last 24 hours"
        case .week: return "The last 7 days"
        case .month: return "The last 30 days"
        case .threeMonths: return "The last 90 days"
        }
    }

}

struct EnergySummary {
    let averageWatts: Double?
    let wattHours: Double?
    let coveredSeconds: TimeInterval
    /// Fraction of the requested window that was actually measured, from zero to one.
    let coverage: Double
    let peakWatts: Double?
}

struct EnergyChartPoint {
    let start: Date
    let end: Date
    let averageWatts: Double?
    let coverage: Double
}

/// Integrates pairs of real readings. Neither an isolated reading nor a missing
/// sensor contributes measured time. The integration anchor is never persisted.
///
/// Ten-second buckets retain recent detail; after a day they compact into hourly
/// buckets for up to ninety days. Within each bucket, contiguous
/// measured intervals are combined into a span; gaps remain separate. Trapezoid
/// integration is exact when a complete span is included. At a window/chart
/// boundary, the span's average is used for its clipped portion (up to ten
/// seconds recently, or an hour in older history), so boundary energy and peaks
/// are approximate. Coverage remains exact and never extends before the first or after the last reading.
struct EnergyHistory: Codable {
    static let bucketDuration: TimeInterval = 10
    static let retention: TimeInterval = 90 * 86_400
    static let detailedRetention: TimeInterval = 86_400
    static let hourlyDuration: TimeInterval = 3_600
    static let maximumBucketCount = 8_641 + 2_161
    private static let maximumSpansPerSensor = 16
    private static let maximumHourlySpans = 2_048
    // Far beyond any supported Mac's consumption, and guards corrupt archives.
    private static let maximumWatts = 100_000.0

    private struct Span: Codable {
        let start: TimeInterval
        var end: TimeInterval
        var wattSeconds: Double
        var peakWatts: Double
    }

    private struct Bucket: Codable {
        let start: TimeInterval
        var system: [Span] = []
        var battery: [Span] = []
    }

    private struct Anchor {
        let date: TimeInterval
        let system: Double?
        let battery: Double?
    }

    private var buckets: [Bucket] = []
    private var hourlyBuckets: [Bucket] = []
    private var anchor: Anchor?
    private var latestObservation: TimeInterval?

    init() {}

    /// Exposed internally for retention diagnostics and tests, without raw samples.
    var bucketCount: Int { buckets.count + hourlyBuckets.count }

    mutating func record(_ reading: PowerReading, at date: Date = Date(),
                         maximumGap: TimeInterval = 15) {
        let now = date.timeIntervalSince1970
        guard Self.validTimestamp(now) else {
            interrupt()
            return
        }
        if let latestObservation, now < latestObservation {
            // A wall-clock correction must not integrate backwards or count the
            // same time twice. Completed older spans remain useful.
            removeFutureSpans(after: now)
            anchor = nil
        }
        latestObservation = now
        prune(at: now)

        let next = Anchor(date: now, system: Self.validWatts(reading.systemTotal),
                          battery: Self.validWatts(reading.batteryRate))
        defer { anchor = next }
        guard let previous = anchor else { return }
        let elapsed = now - previous.date
        guard maximumGap.isFinite, maximumGap > 0, elapsed > 0,
              elapsed <= min(maximumGap, Self.retention) else { return }

        // Split the linear interpolation at bucket boundaries before integrating.
        var cursor = max(previous.date, now - Self.retention)
        while cursor < now {
            let bucketStart = floor(cursor / Self.bucketDuration) * Self.bucketDuration
            let end = min(now, bucketStart + Self.bucketDuration)
            guard end > cursor else { break }
            if buckets.last?.start != bucketStart {
                buckets.append(Bucket(start: bucketStart))
            }
            let index = buckets.count - 1
            let fractionStart = (cursor - previous.date) / elapsed
            let fractionEnd = (end - previous.date) / elapsed
            if let from = previous.system, let to = next.system {
                Self.appendSpan(to: &buckets[index].system, start: cursor, end: end,
                                from: from + (to - from) * fractionStart,
                                to: from + (to - from) * fractionEnd)
            }
            if let from = previous.battery, let to = next.battery {
                Self.appendSpan(to: &buckets[index].battery, start: cursor, end: end,
                                from: from + (to - from) * fractionStart,
                                to: from + (to - from) * fractionEnd)
            }
            // Do not retain empty buckets during missing-sensor intervals.
            if buckets[index].system.isEmpty && buckets[index].battery.isEmpty {
                buckets.removeLast()
            }
            cursor = end
        }
        prune(at: now)
    }

    /// Call before sleep, after wake, and when acquisition is interrupted.
    mutating func interrupt() { anchor = nil }

    func summary(for window: EnergyWindow, mode: DisplayMode,
                 at date: Date = Date()) -> EnergySummary {
        aggregate(from: date.timeIntervalSince1970 - window.duration,
                  to: date.timeIntervalSince1970, mode: mode)
    }

    func chart(for window: EnergyWindow, mode: DisplayMode, at date: Date = Date(),
               pointCount: Int = 48) -> [EnergyChartPoint] {
        let count = min(240, max(1, pointCount))
        let end = date.timeIntervalSince1970
        guard Self.validTimestamp(end) else { return [] }
        let start = end - window.duration
        let step = window.duration / Double(count)
        return (0..<count).map { index in
            let lower = start + Double(index) * step
            let upper = start + Double(index + 1) * step
            let summary = aggregate(from: lower, to: upper, mode: mode)
            return EnergyChartPoint(start: Date(timeIntervalSince1970: lower),
                                    end: Date(timeIntervalSince1970: upper),
                                    averageWatts: summary.averageWatts, coverage: summary.coverage)
        }
    }

    /// Loading keeps only completed measurements, never an integration anchor.
    mutating func prepareAfterLoading(at date: Date) {
        anchor = nil
        latestObservation = date.timeIntervalSince1970
        removeFutureSpans(after: date.timeIntervalSince1970)
        prune(at: date.timeIntervalSince1970)
    }

    private func aggregate(from start: TimeInterval, to end: TimeInterval,
                           mode: DisplayMode) -> EnergySummary {
        guard Self.validTimestamp(start), Self.validTimestamp(end), end > start else {
            return EnergySummary(averageWatts: nil, wattHours: nil, coveredSeconds: 0,
                                 coverage: 0, peakWatts: nil)
        }
        var wattSeconds = 0.0
        var covered = 0.0
        var peak: Double?
        for (source, duration) in [(hourlyBuckets, Self.hourlyDuration), (buckets, Self.bucketDuration)] {
            for bucket in source {
                guard bucket.start < end, bucket.start + duration > start else { continue }
                for span in (mode == .systemTotal ? bucket.system : bucket.battery) {
                    let duration = min(end, span.end) - max(start, span.start)
                    guard duration > 0 else { continue }
                    wattSeconds += span.wattSeconds * (duration / (span.end - span.start))
                    covered += duration
                    peak = max(peak ?? 0, span.peakWatts)
                }
            }
        }
        return EnergySummary(averageWatts: covered > 0 ? wattSeconds / covered : nil,
                             wattHours: covered > 0 ? wattSeconds / 3_600 : nil,
                             coveredSeconds: covered,
                             coverage: min(1, max(0, covered / (end - start))), peakWatts: peak)
    }

    private static func appendSpan(to spans: inout [Span], start: TimeInterval,
                                   end: TimeInterval, from: Double, to: Double) {
        let energy = (from + to) * 0.5 * (end - start)
        if let last = spans.last, last.end == start {
            let index = spans.count - 1
            spans[index].end = end
            spans[index].wattSeconds += energy
            spans[index].peakWatts = max(last.peakWatts, from, to)
        } else if spans.count < maximumSpansPerSensor {
            spans.append(Span(start: start, end: end, wattSeconds: energy,
                              peakWatts: max(from, to)))
        }
        // More than sixteen disconnected spans in ten seconds cannot occur at
        // supported refresh rates. In pathological input, omit excess coverage
        // instead of inventing readings to bridge gaps or growing without bound.
    }

    private mutating func prune(at now: TimeInterval) {
        // Keep recent precision and compact older measurements without bridging gaps.
        let count = buckets.prefix { $0.start + Self.bucketDuration <= now - Self.detailedRetention }.count
        for bucket in buckets.prefix(count) {
            let start = floor(bucket.start / Self.hourlyDuration) * Self.hourlyDuration
            if hourlyBuckets.last?.start != start { hourlyBuckets.append(Bucket(start: start)) }
            let index = hourlyBuckets.count - 1
            for span in bucket.system { Self.merge(span, into: &hourlyBuckets[index].system) }
            for span in bucket.battery { Self.merge(span, into: &hourlyBuckets[index].battery) }
        }
        if count > 0 { buckets.removeFirst(count) }
        let expired = hourlyBuckets.prefix { $0.start + Self.hourlyDuration <= now - Self.retention }.count
        if expired > 0 { hourlyBuckets.removeFirst(expired) }
    }

    private static func merge(_ span: Span, into spans: inout [Span]) {
        if let last = spans.last, last.end == span.start {
            spans[spans.count - 1].end = span.end
            spans[spans.count - 1].wattSeconds += span.wattSeconds
            spans[spans.count - 1].peakWatts = max(last.peakWatts, span.peakWatts)
        } else if spans.count < maximumHourlySpans { spans.append(span) }
    }

    private mutating func removeFutureSpans(after now: TimeInterval) {
        for index in buckets.indices {
            buckets[index].system.removeAll { $0.end > now }
            buckets[index].battery.removeAll { $0.end > now }
        }
        for index in hourlyBuckets.indices {
            hourlyBuckets[index].system.removeAll { $0.end > now }
            hourlyBuckets[index].battery.removeAll { $0.end > now }
        }
        buckets.removeAll { $0.system.isEmpty && $0.battery.isEmpty }
        hourlyBuckets.removeAll { $0.system.isEmpty && $0.battery.isEmpty }
    }

    private static func validWatts(_ value: Float?) -> Double? {
        guard let value, value.isFinite, value >= 0, Double(value) <= maximumWatts else { return nil }
        return Double(value)
    }

    private static func validTimestamp(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= -62_135_596_800 && value <= 253_402_300_799
    }

    private enum CodingKeys: String, CodingKey { case version, bucketSeconds, buckets, hourlyBuckets }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(Self.bucketDuration, forKey: .bucketSeconds)
        try container.encode(buckets, forKey: .buckets)
        try container.encode(hourlyBuckets, forKey: .hourlyBuckets)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard (1...2).contains(version),
              try container.decode(TimeInterval.self, forKey: .bucketSeconds) == Self.bucketDuration else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                   debugDescription: "Unsupported energy history format.")
        }
        buckets = try container.decode([Bucket].self, forKey: .buckets)
        hourlyBuckets = try container.decodeIfPresent([Bucket].self, forKey: .hourlyBuckets) ?? []
        guard buckets.count <= 8_641, hourlyBuckets.count <= 2_161 else {
            throw DecodingError.dataCorruptedError(forKey: .buckets, in: container,
                                                   debugDescription: "Energy history exceeds its retention limit.")
        }
        for (tier, bucketLength, spanLimit) in [(hourlyBuckets, Self.hourlyDuration, Self.maximumHourlySpans), (buckets, Self.bucketDuration, Self.maximumSpansPerSensor)] {
            var lastBucketStart: TimeInterval?
            for bucket in tier {
                guard Self.validTimestamp(bucket.start),
                      bucket.start == floor(bucket.start / bucketLength) * bucketLength,
                      lastBucketStart.map({ bucket.start > $0 }) ?? true,
                      !bucket.system.isEmpty || !bucket.battery.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .buckets, in: container,
                                                           debugDescription: "Invalid energy history bucket.")
                }
                for spans in [bucket.system, bucket.battery] {
                    var lastEnd = bucket.start
                    guard spans.count <= spanLimit else {
                        throw DecodingError.dataCorruptedError(forKey: .buckets, in: container,
                                                               debugDescription: "Too many energy history spans.")
                    }
                    for span in spans {
                        let duration = span.end - span.start
                        guard Self.validTimestamp(span.start), Self.validTimestamp(span.end),
                              span.start >= lastEnd, duration > 0,
                              span.end <= bucket.start + bucketLength,
                              span.wattSeconds.isFinite, span.wattSeconds >= 0,
                              span.peakWatts.isFinite, span.peakWatts >= 0,
                              span.peakWatts <= Self.maximumWatts,
                              span.wattSeconds <= span.peakWatts * duration + 0.000_001 else {
                            throw DecodingError.dataCorruptedError(forKey: .buckets, in: container,
                                                                   debugDescription: "Invalid energy history measurement.")
                        }
                        lastEnd = span.end
                    }
                }
                lastBucketStart = bucket.start
            }
        }
        if let oldEnd = hourlyBuckets.last.flatMap({ ($0.system + $0.battery).map(\.end).max() }),
           let recentStart = buckets.first.flatMap({ ($0.system + $0.battery).map(\.start).min() }), oldEnd > recentStart {
            throw DecodingError.dataCorruptedError(forKey: .buckets, in: container, debugDescription: "Overlapping history tiers.")
        }
        // anchor and latestObservation deliberately stay unset on decoding.
    }
}
