import SwiftUI

final class MenuDashboardModel: ObservableObject {
    @Published var reading: PowerReading = .unavailable
    @Published var history = PowerHistory()

    func record(_ reading: PowerReading, at date: Date) {
        history.record(reading, at: date)
        self.reading = reading
    }
}

struct MenuDashboardView: View {
    @ObservedObject var model: MenuDashboardModel
    let mode: DisplayMode
    let hasBattery: Bool
    let batteryFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.37, green: 0.86, blue: 0.74)
            : Color(red: 0.05, green: 0.43, blue: 0.36)
    }
    private var chartMode: DisplayMode { batteryFocused ? .battery : mode }
    private var power: Float? {
        chartMode == .systemTotal ? model.reading.systemTotal : model.reading.batteryRate
    }
    private var values: [Float] { model.history.values(for: chartMode) }
    private var average: Float? {
        values.isEmpty ? nil : Float(values.reduce(0.0) { $0 + Double($1) } / Double(values.count))
    }
    private var metricTitle: String {
        batteryFocused ? "BATTERY LEVEL" : (mode == .systemTotal ? "SYSTEM POWER" : "BATTERY POWER")
    }
    private var status: String {
        if batteryFocused {
            guard model.reading.batteryPercent != nil else { return "Battery reading unavailable" }
            return model.reading.batteryStatus
        }
        guard power != nil else { return "Power reading unavailable" }
        if !hasBattery { return "Current system draw" }
        if chartMode == .battery { return model.reading.isCharging ? "Charging battery" : model.reading.batteryStatus }
        return model.reading.isOnExternalPower ? "Connected to power" : "Running on battery"
    }
    private var batteryColor: Color {
        if let percent = model.reading.batteryPercent, percent < 20, !model.reading.isCharging {
            return .orange
        }
        return accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            reading
            trend
            if hasBattery { battery }
        }
        .padding(14)
        .frame(width: 308)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("WattBar").font(.system(size: 13, weight: .semibold))
                Text("Power at a glance").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(metricTitle)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(batteryFocused ? model.reading.batteryPercent.map { String($0) } ?? "—"
                    : power.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 38, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(batteryFocused ? "%" : "W")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(batteryFocused ? "Battery level" : metricTitle.lowercased())
            .accessibilityValue(batteryFocused
                ? model.reading.batteryPercent.map { "\($0) percent" } ?? "Unavailable"
                : power.map { String(format: "%.1f watts", $0) } ?? "Unavailable")
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(chartMode == .systemTotal ? "System draw" : "Battery power")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("LAST 60 SEC")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
            chart
            HStack {
                statistic("Average", value: average)
                Spacer()
                statistic("Peak", value: values.max())
            }
        }
        .padding(12)
        .background(accent.opacity(colorScheme == .dark ? 0.07 : 0.045),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var chart: some View {
        GeometryReader { geometry in
            let segments = chartSegments(in: geometry.size)
            let baseline = geometry.size.height - 4
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: baseline))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: baseline))
                }
                .stroke(accent.opacity(0.16), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                Path { path in
                    for segment in segments where segment.count > 1 {
                        guard let first = segment.first, let last = segment.last else { continue }
                        path.move(to: CGPoint(x: first.x, y: baseline))
                        for point in segment { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: last.x, y: baseline))
                        path.closeSubpath()
                    }
                }
                .fill(LinearGradient(colors: [accent.opacity(0.17), accent.opacity(0.01)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    for segment in segments {
                        if let first = segment.first {
                            path.move(to: first)
                            for point in segment.dropFirst() { path.addLine(to: point) }
                        }
                    }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                ForEach(segments.indices, id: \.self) { index in
                    if segments[index].count == 1, let point = segments[index].first {
                        Circle().fill(accent).frame(width: 3, height: 3).position(point)
                    }
                }
                if currentSampleHasPower, let last = segments.last?.last {
                    Circle().fill(accent).frame(width: 5, height: 5).position(last)
                }
                if values.isEmpty {
                    Text(model.history.samples.isEmpty ? "Collecting readings…" : "No power readings available")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Power history over the last 60 seconds")
        .accessibilityValue(values.isEmpty ? "No readings available"
            : "Average \(PowerReading.watts(average)), peak \(PowerReading.watts(values.max()))")
    }

    private func statistic(_ title: String, value: Float?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(PowerReading.watts(value)).monospacedDigit().fontWeight(.medium)
        }
        .font(.system(size: 10))
        .accessibilityElement(children: .combine)
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: model.reading.isCharging ? "bolt.fill" : "battery.100percent")
                    .foregroundStyle(batteryColor)
                    .accessibilityHidden(true)
                Text(batteryFocused ? "Battery power" : "Battery")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                Text(batteryFocused ? PowerReading.watts(model.reading.batteryRate)
                     : model.reading.batteryPercent.map { "\($0)%" } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        if let percent = model.reading.batteryPercent {
                            Capsule().fill(batteryColor)
                                .frame(width: geometry.size.width * CGFloat(min(100, max(0, percent))) / 100)
                        }
                    }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            if !batteryFocused {
                Text(model.reading.batteryPercent == nil ? "Battery reading unavailable" : model.reading.batteryStatus)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var currentSampleHasPower: Bool {
        guard let sample = model.history.samples.last else { return false }
        return (chartMode == .systemTotal ? sample.systemTotal : sample.batteryRate) != nil
    }

    private func chartSegments(in size: CGSize) -> [[CGPoint]] {
        guard let end = model.history.samples.last?.date else { return [] }
        let maximum = max(1, Double(values.max() ?? 0) * 1.15)
        let start = end.addingTimeInterval(-PowerHistory.window)
        var segments: [[CGPoint]] = []
        var points: [CGPoint] = []
        for sample in model.history.samples {
            guard let value = chartMode == .systemTotal ? sample.systemTotal : sample.batteryRate else {
                if !points.isEmpty { segments.append(points); points = [] }
                continue
            }
            let x = 3 + CGFloat(sample.date.timeIntervalSince(start) / PowerHistory.window) * (size.width - 6)
            let y = size.height - 4 - CGFloat(Double(value) / maximum) * (size.height - 8)
            points.append(CGPoint(x: x, y: y))
        }
        if !points.isEmpty { segments.append(points) }
        return segments
    }
}
