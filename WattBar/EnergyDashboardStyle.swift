import Charts
import SwiftUI

struct EnergyPalette {
    let dark: Bool
    var background: Color { dark ? Color(red: 0.065, green: 0.077, blue: 0.086) : Color(red: 0.956, green: 0.964, blue: 0.971) }
    var sidebar: Color { dark ? Color(red: 0.083, green: 0.096, blue: 0.106) : Color(red: 0.927, green: 0.939, blue: 0.949) }
    var surface: Color { dark ? Color(red: 0.101, green: 0.117, blue: 0.129) : .white }
    var accent: Color { dark ? Color(red: 0.39, green: 0.87, blue: 0.74) : Color(red: 0.04, green: 0.43, blue: 0.35) }
    var border: Color { Color.primary.opacity(dark ? 0.075 : 0.055) }
    var muted: Color { Color.primary.opacity(dark ? 0.47 : 0.45) }
}

struct EnergySurface: ViewModifier {
    let palette: EnergyPalette
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content.background(palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
    }
}

struct EnergyPeriodControl: View {
    @Binding var selection: EnergyWindow
    let palette: EnergyPalette
    var body: some View {
        HStack(spacing: 3) {
            ForEach(EnergyWindow.allCases) { period in
                Button { selection = period } label: {
                    Text(period == .minute ? "1 min" : period == .hour ? "1 hour" : "24 hours")
                        .font(.system(size: 12, weight: selection == period ? .semibold : .medium))
                        .foregroundStyle(selection == period ? Color.primary : .secondary)
                        .padding(.horizontal, 15).frame(height: 30)
                        .background {
                            if selection == period {
                                RoundedRectangle(cornerRadius: 7).fill(palette.surface)
                                    .shadow(color: .black.opacity(palette.dark ? 0.12 : 0.06), radius: 2, y: 1)
                            }
                        }
                }.buttonStyle(.plain).accessibilityLabel(period.label)
                    .accessibilityValue(selection == period ? "Selected" : "")
            }
        }.padding(3).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel("History period")
    }
}

struct EnergyMetricCard: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let prominent: Bool
    let palette: EnergyPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(prominent ? palette.accent : palette.muted).accessibilityHidden(true)
            }
            Text(value).font(.system(size: 31, weight: .semibold, design: .rounded)).tracking(-0.7)
                .monospacedDigit().foregroundStyle(prominent ? palette.accent : .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(EnergySurface(palette: palette))
            .accessibilityElement(children: .combine)
    }
}

struct EnergyTrendCard: View {
    let points: [EnergyChartPoint]
    let window: EnergyWindow
    let summary: EnergySummary
    let mode: DisplayMode
    let palette: EnergyPalette
    var height: CGFloat = 145
    @State private var hoveredDate: Date?

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let watts: Double
        let segment: Int
    }
    private var plot: [Point] {
        var segment = 0
        return points.enumerated().compactMap { index, point in
            guard let watts = point.averageWatts else { segment += 1; return nil }
            return Point(id: index, date: point.start.addingTimeInterval(point.end.timeIntervalSince(point.start) / 2),
                         watts: watts, segment: segment)
        }
    }
    private var hovered: Point? {
        guard let hoveredDate else { return nil }
        guard let nearest = plot.min(by: { abs($0.date.timeIntervalSince(hoveredDate)) < abs($1.date.timeIntervalSince(hoveredDate)) }),
              abs(nearest.date.timeIntervalSince(hoveredDate)) <= window.duration / Double(max(1, points.count)) / 2 else { return nil }
        return nearest
    }
    private var ceiling: Double {
        let peak = max(5, plot.map(\.watts).max() ?? 5)
        let step = peak < 25 ? 5.0 : peak < 100 ? 10 : 25
        return ceil(peak * 1.12 / step) * step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode == .systemTotal ? "Power over time" : "Battery transfer over time")
                        .font(.system(size: 14, weight: .semibold))
                    Text(window == .minute ? "The last 60 seconds" : window == .hour ? "The last 60 minutes" : "The last 24 hours")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let hovered {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(EnergyFormat.watts(hovered.watts)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        Text(hovered.date, format: window == .minute ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(palette.accent).frame(width: 5, height: 5)
                        Text("Recorded power").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.top, 3)
                }
            }.frame(height: 35, alignment: .top)
            chart.frame(height: height)
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 10))
                Text("\(EnergyFormat.duration(summary.coveredSeconds)) recorded")
                Spacer()
                Text("\(EnergyFormat.coverage(summary.coverage)) of this period")
                GeometryReader { geometry in
                    Capsule().fill(palette.border)
                        .overlay(alignment: .leading) {
                            Capsule().fill(palette.accent.opacity(0.7))
                                .frame(width: geometry.size.width * min(1, max(0, summary.coverage)))
                        }
                }.frame(width: 56, height: 4).accessibilityHidden(true)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(19).modifier(EnergySurface(palette: palette))
    }

    private var chart: some View {
        let isolated = Set(Dictionary(grouping: plot, by: \.segment).filter { $0.value.count == 1 }.keys)
        return Chart {
            ForEach(plot) { point in
                AreaMark(x: .value("Time", point.date), yStart: .value("Baseline", 0),
                         yEnd: .value("Power", point.watts), series: .value("Segment", point.segment))
                    .foregroundStyle(LinearGradient(colors: [palette.accent.opacity(0.19), palette.accent.opacity(0.015)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("Power", point.watts), series: .value("Segment", point.segment))
                    .foregroundStyle(palette.accent).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if isolated.contains(point.segment) {
                    PointMark(x: .value("Time", point.date), y: .value("Power", point.watts))
                        .foregroundStyle(palette.accent).symbolSize(24)
                }
            }
            if let hovered {
                RuleMark(x: .value("Selected time", hovered.date)).foregroundStyle(palette.accent.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Time", hovered.date), y: .value("Power", hovered.watts))
                    .foregroundStyle(palette.accent).symbolSize(35)
            }
        }
        .chartXScale(domain: (points.first?.start ?? Date().addingTimeInterval(-window.duration))...(points.last?.end ?? Date()))
        .chartYScale(domain: 0...ceiling)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(palette.border)
                AxisValueLabel(anchor: .leading) {
                    if let watts = value.as(Double.self) {
                        Text("\(Int(watts)) W").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(date, format: window == .minute ? .dateTime.minute().second() : .dateTime.hour().minute())
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let location): inspect(location, proxy: proxy, geometry: geometry)
                    case .ended: hoveredDate = nil
                    }
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    inspect(value.location, proxy: proxy, geometry: geometry)
                })
            }
        }
        .overlay {
            if plot.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "waveform.path").font(.system(size: 22)).foregroundStyle(palette.accent.opacity(0.6))
                    Text("Building your energy history").font(.system(size: 12, weight: .medium))
                    Text("Recorded readings will appear here.").font(.system(size: 10)).foregroundStyle(.secondary)
                }.allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Recorded power over \(window.label.lowercased())")
    }
    private func inspect(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let frame: CGRect
        if #available(macOS 14, *) {
            guard let plotFrame = proxy.plotFrame else { hoveredDate = nil; return }
            frame = geometry[plotFrame]
        } else {
            frame = geometry[proxy.plotAreaFrame]
        }
        guard frame.contains(location) else { hoveredDate = nil; return }
        hoveredDate = proxy.value(atX: location.x - frame.minX, as: Date.self)
    }

}

struct EnergyAppIcon: View {
    let url: URL?
    var size: CGFloat = 30
    var body: some View {
        Group {
            if let url { Image(nsImage: EnergyAppIconCache.shared.icon(for: url)).resizable() }
            else {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.055))
                    .overlay(Image(systemName: "terminal").font(.system(size: size * 0.45)).foregroundStyle(.secondary))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private final class EnergyAppIconCache {
    static let shared = EnergyAppIconCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 128 }
    func icon(for url: URL) -> NSImage {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
