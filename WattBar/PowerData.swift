import Foundation

/// Missing sensors stay unavailable rather than becoming misleading zero readings.
struct PowerReading {
    let systemTotal: Float?
    let batteryRate: Float?
    let batteryPercent: Int?
    let isCharging: Bool
    let isOnExternalPower: Bool

    static let unavailable = PowerReading(systemTotal: nil, batteryRate: nil,
        batteryPercent: nil, isCharging: false, isOnExternalPower: false)

    static func resolve(system: Double?, battery: Double?, voltageMV: Double?, currentMA: Double?,
                        percent: Double?, isCharging: Bool, externalPower: Bool) -> PowerReading {
        func valid(_ value: Double?) -> Float? {
            guard let value, value.isFinite, value >= 0, value <= Double(Float.greatestFiniteMagnitude) else { return nil }
            return Float(value)
        }
        let calculated: Float?
        if let voltageMV, let currentMA, voltageMV.isFinite, voltageMV > 0, currentMA.isFinite {
            calculated = valid(voltageMV * abs(currentMA) / 1_000_000)
        } else { calculated = nil }
        let batteryRate = battery.flatMap { valid(abs($0)) } ?? calculated
        // Battery charge power is not total system power while an adapter is connected.
        let total = valid(system) ?? ((!externalPower && !isCharging) ? batteryRate : nil)
        let batteryPercent = percent.flatMap { $0.isFinite ? Int(min(100, max(0, $0))) : nil }
        return PowerReading(systemTotal: total, batteryRate: batteryRate, batteryPercent: batteryPercent,
                            isCharging: isCharging, isOnExternalPower: externalPower)
    }

    static func hasBattery(installed: Bool?, maximumCapacity: Double?) -> Bool {
        if let installed { return installed }
        return (maximumCapacity ?? 0) > 0
    }

    static func watts(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "— W" }
        return String(format: "%.1f W", value)
    }

    var batteryStatus: String {
        isCharging ? "Charging" : (isOnExternalPower ? "Plugged In · Not Charging" : "On Battery")
    }
}

/// SMC float values are little endian; integer and fixed-point values are big endian.
/// Decode bytes explicitly, without unaligned pointer loads or unchecked copies.
enum SMCValueDecoder {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch (type, bytes.count) {
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            value = Double(Float(bitPattern: bits))
        case ("ui8 ", 1): value = Double(bytes[0])
        case ("ui16", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            let chars = Array(type)
            guard bytes.count == 2, chars.count == 4,
                  chars[1] == "p", chars[0] == "s" || chars[0] == "f",
                  let integer = Int(String(chars[2]), radix: 16),
                  let fraction = Int(String(chars[3]), radix: 16),
                  integer + fraction == (chars[0] == "s" ? 15 : 16) else { return nil }
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let raw = chars[0] == "s" ? Double(Int16(bitPattern: bits)) : Double(bits)
            value = raw / pow(2, Double(fraction))
        }
        return value.isFinite ? value : nil
    }
}

enum DisplayMode: String, CaseIterable {
    case systemTotal = "system"
    case battery = "battery"
    var label: String { self == .systemTotal ? "System Total" : "Battery" }
}

enum BatteryIconStyle: String, CaseIterable {
    case dark = "dark"
    case light = "light"
    var label: String { self == .dark ? "Black Background" : "White Background" }
}

enum RefreshInterval: Double, CaseIterable {
    case oneSecond = 1, twoSeconds = 2, fiveSeconds = 5, tenSeconds = 10
    var label: String { "\(Int(rawValue)) \(self == .oneSecond ? "second" : "seconds")" }
}

/// A short, bounded history of actual readings. Missing values retain their place
/// in time so a graph can leave gaps instead of implying measured zero power.
struct PowerHistory {
    struct Sample {
        let date: Date
        let systemTotal: Float?
        let batteryRate: Float?
    }

    static let window: TimeInterval = 60
    private static let maximumSamples = 120
    private(set) var samples: [Sample] = []

    mutating func record(_ reading: PowerReading, at date: Date = Date()) {
        if let latest = samples.last, date < latest.date {
            samples.removeAll(keepingCapacity: true)
        }
        let cutoff = date.addingTimeInterval(-Self.window)
        samples.removeAll { $0.date < cutoff }

        func valid(_ value: Float?) -> Float? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        samples.append(Sample(date: date, systemTotal: valid(reading.systemTotal),
                              batteryRate: valid(reading.batteryRate)))
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    /// Valid measurements for statistics; use `samples` when drawing time gaps.
    func values(for mode: DisplayMode) -> [Float] {
        samples.compactMap { mode == .systemTotal ? $0.systemTotal : $0.batteryRate }
    }
}
