import SwiftUI

private enum EnergyPage: String, CaseIterable {
    case overview = "Overview", applications = "Applications", history = "History"
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .applications: return "square.stack"
        case .history: return "clock.arrow.circlepath"
        }
    }
    var shortcut: KeyEquivalent {
        switch self { case .overview: return "1"; case .applications: return "2"; case .history: return "3" }
    }
}

struct EnergyDetailView: View {
    @ObservedObject var model: MenuDashboardModel
    let hasBattery: Bool
    let onOpenPreferences: () -> Void
    @AppStorage("energyHistoryWindow") private var window: EnergyWindow = .hour
    @State private var page: EnergyPage = .overview
    @State private var mode: DisplayMode = .systemTotal
    @State private var showsTrackingInfo = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: EnergyPalette { EnergyPalette(dark: colorScheme == .dark) }

    var body: some View {
        let summary = model.energyHistory.summary(for: window, mode: mode, at: model.lastUpdated)
        let activity = model.activityHistory.summary(for: window, at: model.lastUpdated)
        HStack(spacing: 0) {
            sidebar
            palette.border.frame(width: 1)
            VStack(spacing: 0) {
                header
                if page == .applications {
                    EnergyApplicationsView(activity: activity, window: window, palette: palette)
                        .padding(.horizontal, 28).padding(.bottom, 22)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if page == .overview { overview(summary, activity: activity) }
                            else { history(summary) }
                            notices
                        }.padding(.horizontal, 28).padding(.bottom, 24)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.background).tint(palette.accent)
        .frame(minWidth: 920, idealWidth: 1060, minHeight: 640, idealHeight: 790)
        .onAppear { model.refreshSummaries() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: WattBarBrand.appIcon).resizable().interpolation(.high)
                    .frame(width: 36, height: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WattBar").font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                    Text("Energy monitor").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 34)
            Text("WORKSPACE").font(.system(size: 8, weight: .semibold)).tracking(1.5)
                .foregroundStyle(palette.muted).padding(.horizontal, 22).padding(.bottom, 10)
            ForEach(EnergyPage.allCases, id: \.self) { destination in
                Button { page = destination } label: {
                    HStack(spacing: 10) {
                        Image(systemName: destination.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                        Text(destination.rawValue).font(.system(size: 12, weight: page == destination ? .semibold : .medium))
                        Spacer()
                        if page == destination { Capsule().fill(palette.accent).frame(width: 3, height: 14) }
                    }.foregroundStyle(page == destination ? palette.accent : Color.primary.opacity(0.65))
                        .padding(.horizontal, 12).frame(height: 39)
                        .background(page == destination ? palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).keyboardShortcut(destination.shortcut, modifiers: .command)
                    .accessibilityValue(page == destination ? "Selected" : "")
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 6) {
                    Circle().fill(model.reading.systemTotal == nil ? palette.muted : palette.accent).frame(width: 5, height: 5)
                    Text(model.reading.systemTotal == nil ? "Waiting for readings" : "Monitoring this Mac")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(PowerReading.watts(model.reading.systemTotal)).font(.system(size: 24, weight: .medium, design: .rounded))
                        .monospacedDigit().tracking(-0.6)
                }
                Text("Current system draw").font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12).padding(.bottom, 18)
            Button(action: onOpenPreferences) {
                Label("Preferences", systemImage: "slider.horizontal.3").font(.system(size: 12))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 9))
                Text("Stored on this Mac").font(.system(size: 9))
            }.foregroundStyle(palette.muted).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 21)
        }.frame(width: 184).background(palette.sidebar)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page == .overview ? "Energy overview" : page.rawValue)
                    .font(.system(size: 23, weight: .semibold)).tracking(-0.6).lineLimit(1)
                Text(page == .applications ? "Understand the work behind your energy use."
                     : page == .history ? "Your recorded usage, over time." : "A clear view of what your Mac is using.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            EnergyPeriodControl(selection: $window, palette: palette)
            Button { showsTrackingInfo.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 25, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).help("About energy measurements").accessibilityLabel("About energy measurements")
                .popover(isPresented: $showsTrackingInfo) { trackingInfo }
        }.padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 23)
    }

    @ViewBuilder private func overview(_ summary: EnergySummary, activity: AppActivitySummary) -> some View {
        if hasBattery { sourceControl }
        HStack(spacing: 12) {
            EnergyMetricCard(title: mode == .systemTotal ? "Energy used" : "Energy transferred",
                             value: EnergyFormat.energy(summary.wattHours), caption: "During recorded time",
                             symbol: "bolt.fill", prominent: true, palette: palette)
            EnergyMetricCard(title: "Average draw", value: EnergyFormat.watts(summary.averageWatts),
                             caption: window.label, symbol: "waveform.path", prominent: false, palette: palette)
            EnergyMetricCard(title: "Peak draw", value: EnergyFormat.watts(summary.peakWatts),
                             caption: "Highest recorded reading", symbol: "arrow.up.right", prominent: false, palette: palette)
        }
        trend(summary)
        topApps(activity)
    }

    private var sourceControl: some View {
        HStack {
            Text("POWER SOURCE").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
            Spacer()
            Picker("Power source", selection: $mode) {
                Text("Whole Mac").tag(DisplayMode.systemTotal)
                Text("Battery transfer").tag(DisplayMode.battery)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
        }
    }

    private func trend(_ summary: EnergySummary, height: CGFloat = 145) -> some View {
        EnergyTrendCard(points: model.energyHistory.chart(for: window, mode: mode, at: model.lastUpdated),
                        window: window, summary: summary, mode: mode, palette: palette, height: height)
    }

    private func topApps(_ activity: AppActivitySummary) -> some View {
        let applications = activity.apps.filter { $0.bundleURL != nil }
        let rows = Array((applications.isEmpty ? activity.apps : applications).prefix(3))
        let maximum = rows.map { activity.supportsEnergy ? $0.cpuEnergyWh ?? 0 : $0.cpuSeconds }.max() ?? 0
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top applications").font(.system(size: 14, weight: .semibold))
                    Text(activity.supportsEnergy ? "CPU energy · \(window.label.lowercased())" : "CPU activity · \(window.label.lowercased())")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { page = .applications } label: {
                    HStack(spacing: 5) { Text("View all"); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
                }.buttonStyle(.plain)
            }
            if rows.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed").foregroundStyle(palette.accent)
                    Text("App insights will appear after a few readings.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
            } else {
                ForEach(rows) { app in
                    HStack(spacing: 10) {
                        EnergyAppIcon(url: app.bundleURL, size: 28)
                        Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 10)
                        let value = activity.supportsEnergy ? app.cpuEnergyWh ?? 0 : app.cpuSeconds
                        GeometryReader { geometry in
                            Capsule().fill(palette.accent.opacity(0.06)).overlay(alignment: .leading) {
                                Capsule().fill(palette.accent.opacity(0.65))
                                    .frame(width: maximum > 0 ? geometry.size.width * min(1, value / maximum) : 0)
                            }
                        }.frame(width: 100, height: 4).accessibilityHidden(true)
                        Text(activity.supportsEnergy ? EnergyFormat.energy(app.cpuEnergyWh) : String(format: "%.1f s", app.cpuSeconds))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 94, alignment: .trailing)
                    }.frame(height: 35).accessibilityElement(children: .combine)
                }
            }
        }.padding(19).modifier(EnergySurface(palette: palette))
    }

    @ViewBuilder private func history(_ summary: EnergySummary) -> some View {
        if hasBattery { sourceControl }
        trend(summary, height: 200)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Usage summary").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Rolling windows").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Text("PERIOD").frame(maxWidth: .infinity, alignment: .leading)
                Text("ENERGY").frame(width: 110, alignment: .trailing)
                Text("AVERAGE").frame(width: 95, alignment: .trailing)
                Text("RECORDED").frame(width: 115, alignment: .trailing)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(palette.muted)
            ForEach(EnergyWindow.allCases) { period in
                let result = model.energyHistory.summary(for: period, mode: mode, at: model.lastUpdated)
                Button { window = period } label: {
                    HStack {
                        HStack(spacing: 8) {
                            Circle().fill(window == period ? palette.accent : palette.border).frame(width: 5, height: 5)
                            Text(period.label).font(.system(size: 12, weight: .medium))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(EnergyFormat.energy(result.wattHours)).foregroundStyle(palette.accent)
                            .frame(width: 110, alignment: .trailing)
                        Text(EnergyFormat.watts(result.averageWatts)).frame(width: 95, alignment: .trailing)
                        Text(EnergyFormat.duration(result.coveredSeconds)).foregroundStyle(.secondary)
                            .frame(width: 115, alignment: .trailing)
                    }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(window == period ? "Selected" : "")
                if period != .day { palette.border.frame(height: 1) }
            }
        }.padding(19).modifier(EnergySurface(palette: palette))
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "clock.badge.checkmark").foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("Your history builds while WattBar runs").font(.system(size: 12, weight: .medium))
                Text("Averages use recorded time. Sleep and missing readings leave gaps. Your last 90 days are saved automatically on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18)
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.storageMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if page == .overview {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 9))
                    Text(mode == .systemTotal ? "Whole-Mac power and per-app CPU energy are measured separately."
                         : "Battery transfer includes both charging and discharging.")
                        .font(.system(size: 10))
                }.foregroundStyle(palette.muted).padding(.horizontal, 2)
            }
        }
    }

    private var trackingInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About your measurements").font(.system(size: 15, weight: .semibold))
            Text("Watts show power at a moment in time. Watt-hours show energy used over recorded time.")
            Text("Whole-Mac readings come from your Mac’s sensors. App insights cover CPU energy where supported; display, GPU and other device power aren’t assigned to apps.")
            Text("Sleep, missing readings and time before tracking are excluded. Recorded coverage shows how much of each period was measured.")
            Text("Your history stays on this Mac and rolls off after 90 days.").foregroundStyle(.secondary)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(22).frame(width: 340)
    }
}
