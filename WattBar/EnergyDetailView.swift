import SwiftUI

struct EnergyDetailView: View {
    @ObservedObject var model: MenuDashboardModel
    let hasBattery: Bool
    @AppStorage("energyHistoryWindow") private var window: EnergyWindow = .hour
    @State private var mode: DisplayMode = .systemTotal
    @State private var showAllApps = false
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { colorScheme == .dark ? Color(red: 0.37, green: 0.86, blue: 0.74) : Color(red: 0.05, green: 0.43, blue: 0.36) }

    var body: some View {
        let summary = model.energyHistory.summary(for: window, mode: mode, at: model.lastUpdated)
        let activity = model.activityHistory.summary(for: window, at: model.lastUpdated)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                        .frame(width: 48, height: 48).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Energy & Apps").font(.system(size: 24, weight: .semibold))
                        Text("See where your Mac’s energy goes.").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Picker("History period", selection: $window) {
                    ForEach(EnergyWindow.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                if hasBattery {
                    Picker("Power source", selection: $mode) {
                        Text("Whole Mac").tag(DisplayMode.systemTotal)
                        Text("Battery transfer").tag(DisplayMode.battery)
                    }.pickerStyle(.segmented).frame(maxWidth: 320)
                }
                HStack(spacing: 12) {
                    metric("Energy recorded", value: EnergyFormat.energy(summary.wattHours), symbol: "bolt.fill")
                    metric("Average draw", value: EnergyFormat.watts(summary.averageWatts), symbol: "waveform.path")
                    metric("Peak draw", value: EnergyFormat.watts(summary.peakWatts), symbol: "arrow.up.right")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(mode == .systemTotal ? "Whole-Mac power" : "Battery power transfer").font(.headline)
                        Spacer()
                        Text("\(EnergyFormat.duration(summary.coveredSeconds)) recorded · \(EnergyFormat.coverage(summary.coverage))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    EnergyHistoryChart(points: model.energyHistory.chart(for: window, mode: mode, at: model.lastUpdated), accent: accent)
                        .frame(height: 105)
                    HStack {
                        Text(window == .minute ? "60 seconds ago" : window == .hour ? "1 hour ago" : "24 hours ago")
                        Spacer()
                        Text("Now")
                    }.font(.caption2).foregroundStyle(.secondary)
                    Text(mode == .systemTotal
                         ? "Estimates from recorded sensor readings. Sleep, missing readings and time before tracking are excluded."
                         : "Battery transfer includes energy charging and discharging the battery. It is separate from whole-Mac consumption.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
                appSection(activity)
                ForEach(model.storageMessages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("History stays on this Mac and rolls off after 24 hours. Keep WattBar running to build your history.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 620, idealWidth: 660, minHeight: 560, idealHeight: 700)
        .onAppear { model.refreshSummaries() }
    }

    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }

    private func appSection(_ activity: AppActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(activity.supportsEnergy ? "CPU energy by app" : "CPU activity by app").font(.headline)
                Spacer()
                Text("\(EnergyFormat.duration(activity.observedDuration)) observed").font(.caption).foregroundStyle(.secondary)
            }
            Text(activity.supportsEnergy
                 ? "CPU counters for accessible apps and processes. GPU, display and other device power aren’t attributed here."
                 : "CPU energy counters aren’t available for this period. CPU time shows which apps were active.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if activity.apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed").font(.system(size: 25)).foregroundStyle(accent)
                    Text("Collecting app activity…").font(.callout)
                    Text("The first readings take a few seconds. No activity may have been recorded in this period.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                HStack {
                    Text("APP / PROCESS")
                    Spacer()
                    Text("AVG. CPU").frame(width: 75, alignment: .trailing)
                    Text(activity.supportsEnergy ? "CPU ENERGY" : "CPU TIME").frame(width: 100, alignment: .trailing)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                let rows = showAllApps ? activity.apps : Array(activity.apps.prefix(10))
                ForEach(rows) { record in
                    HStack(spacing: 9) {
                        appIcon(record.bundleURL)
                        Text(record.name).lineLimit(1).truncationMode(.middle)
                            .help(record.bundleURL?.path ?? record.name)
                        Spacer(minLength: 4)
                        Text(String(format: "%.1f%%", record.cpuPercent)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 75, alignment: .trailing)
                        Text(activity.supportsEnergy ? EnergyFormat.energy(record.cpuEnergyWh) : String(format: "%.1f s", record.cpuSeconds))
                            .monospacedDigit().frame(width: 100, alignment: .trailing)
                    }.font(.system(size: 12)).padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                }
                if activity.apps.count > 10 {
                    Button(showAllApps ? "Show top 10" : "Show all \(activity.apps.count) apps and processes") { showAllApps.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                Text("CPU percentages can exceed 100% when an app uses multiple cores. A dash means its CPU energy wasn’t fully observed.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private func appIcon(_ url: URL?) -> some View {
        if let url {
            Image(nsImage: AppIconCache.shared.icon(for: url)).resizable().frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "terminal").font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).accessibilityHidden(true)
        }
    }
}

private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 128 }
    func icon(for url: URL) -> NSImage {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

private struct EnergyHistoryChart: View {
    let points: [EnergyChartPoint]
    let accent: Color
    var body: some View {
        GeometryReader { geometry in
            let maximum = max(1, (points.compactMap(\.averageWatts).max() ?? 1) * 1.15)
            ZStack {
                ForEach(0..<3) { row in
                    Path { path in
                        let y = CGFloat(row) * (geometry.size.height - 8) / 2 + 4
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }.stroke(accent.opacity(0.13), style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                }
                Path { path in
                    var connected = false
                    for (index, point) in points.enumerated() {
                        guard let watts = point.averageWatts else { connected = false; continue }
                        let p = CGPoint(x: CGFloat(index) / CGFloat(max(1, points.count - 1)) * geometry.size.width,
                                        y: geometry.size.height - 4 - CGFloat(watts / maximum) * (geometry.size.height - 8))
                        if connected { path.addLine(to: p) } else { path.move(to: p) }
                        connected = true
                    }
                }.stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(points.indices, id: \.self) { index in
                    if let watts = points[index].averageWatts {
                        Circle().fill(accent).frame(width: 3, height: 3)
                            .position(x: CGFloat(index) / CGFloat(max(1, points.count - 1)) * geometry.size.width,
                                      y: geometry.size.height - 4 - CGFloat(watts / maximum) * (geometry.size.height - 8))
                    }
                }
                if points.allSatisfy({ $0.averageWatts == nil }) {
                    Text("Your energy history will appear here as readings arrive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Recorded power history")
    }
}
