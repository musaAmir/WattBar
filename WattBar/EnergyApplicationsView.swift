import SwiftUI

private enum EnergyAppSort: String, CaseIterable {
    case energy = "CPU energy", cpu = "Average CPU", time = "CPU time"
}

struct EnergyApplicationsView: View {
    let activity: AppActivitySummary
    let window: EnergyWindow
    let palette: EnergyPalette
    @State private var search = ""
    @State private var sort: EnergyAppSort = .energy
    @AppStorage("energyShowBackgroundProcesses") private var showsProcesses = false
    @State private var selectedApp: AppActivityRecord?

    private var effectiveSort: EnergyAppSort { sort == .energy && !activity.supportsEnergy ? .time : sort }
    private var rows: [AppActivityRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return activity.apps.filter {
            (showsProcesses || $0.bundleURL != nil) &&
                (query.isEmpty || $0.name.localizedStandardContains(query) || $0.identifier.localizedStandardContains(query))
        }.sorted { a, b in
            let left: Double
            let right: Double
            switch effectiveSort {
            case .energy: left = a.cpuEnergyWh ?? -1; right = b.cpuEnergyWh ?? -1
            case .cpu: left = a.cpuPercent; right = b.cpuPercent
            case .time: left = a.cpuSeconds; right = b.cpuSeconds
            }
            return left == right ? a.name.localizedStandardCompare(b.name) == .orderedAscending : left > right
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Circle().fill(palette.accent).frame(width: 5, height: 5)
                Text(activity.supportsEnergy ? "CPU energy insights" : "CPU activity insights")
                    .font(.system(size: 11, weight: .medium))
                Text("·").foregroundStyle(palette.muted)
                Text("\(EnergyFormat.duration(activity.observedDuration)) observed").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(rows.count) \(showsProcesses ? (rows.count == 1 ? "app / process" : "apps & processes") : rows.count == 1 ? "application" : "applications")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search applications", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                        .onExitCommand { search = "" }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear application search")
                    }
                }.padding(.horizontal, 12).frame(height: 36)
                    .modifier(EnergySurface(palette: palette, radius: 9))
                Picker("Show", selection: $showsProcesses) {
                    Text("Apps only").tag(false)
                    Text("Apps & processes").tag(true)
                }.labelsHidden().frame(width: 145).help("Include background processes")
                Picker("Sort applications", selection: Binding(get: { effectiveSort }, set: { sort = $0 })) {
                    ForEach(EnergyAppSort.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option).disabled(option == .energy && !activity.supportsEnergy)
                    }
                }.labelsHidden().frame(width: 126)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("APPLICATION").frame(maxWidth: .infinity, alignment: .leading)
                    Text("AVG. CPU").frame(width: 86, alignment: .trailing)
                    Text(activity.supportsEnergy ? "CPU ENERGY" : "CPU TIME").frame(width: 105, alignment: .trailing)
                    Color.clear.frame(width: 12, height: 1)
                }.font(.system(size: 9, weight: .medium)).tracking(0.5).foregroundStyle(palette.muted)
                    .padding(.horizontal, 19).frame(height: 39)
                palette.border.frame(height: 1)
                if rows.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                                EnergyApplicationRow(record: record, rank: index + 1, usesEnergy: activity.supportsEnergy,
                                                     palette: palette) { selectedApp = record }
                                if index < rows.count - 1 { palette.border.frame(height: 1).padding(.leading, 65) }
                            }
                        }
                    }
                }
                palette.border.frame(height: 1)
                HStack {
                    Text("\(rows.count) \(rows.count == 1 ? "result" : "results")")
                    Spacer()
                    Text("Select an app for details").foregroundStyle(palette.muted)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 36)
            }.modifier(EnergySurface(palette: palette))
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle").padding(.top, 1)
                Text(activity.supportsEnergy
                     ? "CPU energy covers accessible processes. GPU and display power aren’t assigned to apps. CPU can exceed 100% across multiple cores."
                     : "CPU energy isn’t available for this period. CPU time and activity show the work each app performed. CPU can exceed 100% across multiple cores.")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10)).foregroundStyle(palette.muted).padding(.horizontal, 2)
        }.sheet(item: $selectedApp) { record in
            EnergyApplicationDetail(record: record, window: window, usesEnergy: activity.supportsEnergy,
                                    palette: palette) { selectedApp = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "app.dashed" : "magnifyingglass")
                .font(.system(size: 28, weight: .light)).foregroundStyle(palette.accent.opacity(0.65))
            Text(search.isEmpty ? "Waiting for app activity" : "No matching applications")
                .font(.system(size: 15, weight: .semibold))
            Text(search.isEmpty ? "Apps appear after a few readings. You can also include background processes."
                 : "Try a different name, or include background processes.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            if !search.isEmpty {
                Button("Clear search") { search = "" }.buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(30)
    }
}

private struct EnergyApplicationRow: View {
    let record: AppActivityRecord
    let rank: Int
    let usesEnergy: Bool
    let palette: EnergyPalette
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(String(rank)).font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.muted).frame(width: 17)
                EnergyAppIcon(url: record.bundleURL, size: 31)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(record.bundleURL == nil ? "Background process" : "Application")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(String(format: "%.1f%%", record.cpuPercent)).foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)
                Text(usesEnergy ? EnergyFormat.energy(record.cpuEnergyWh) : String(format: "%.1f s", record.cpuSeconds))
                    .fontWeight(.medium).frame(width: 105, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(palette.muted)
                    .frame(width: 12)
            }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 18).frame(height: 62)
                .background(hovered ? palette.accent.opacity(0.045) : Color.clear).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityElement(children: .combine).accessibilityHint("Open application energy details")
    }
}

private struct EnergyApplicationDetail: View {
    let record: AppActivityRecord
    let window: EnergyWindow
    let usesEnergy: Bool
    let palette: EnergyPalette
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 13) {
                EnergyAppIcon(url: record.bundleURL, size: 45)
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.name).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                    Text("\(window.label) · snapshot").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 17) {
                detail("CPU energy", value: EnergyFormat.energy(usesEnergy ? record.cpuEnergyWh : nil))
                detail("Average CPU power", value: cpuPower)
                detail("Average CPU activity", value: String(format: "%.1f%%", record.cpuPercent))
                detail("CPU time", value: String(format: "%.1f seconds", record.cpuSeconds))
            }.padding(18).modifier(EnergySurface(palette: palette))
            Text("CPU measurements cover observed activity in this period. A dash means energy data wasn’t fully available. Display, GPU and other device power aren’t attributed to this app.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let url = record.bundleURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.regular)
                }
                Spacer()
                Button("Done", action: onClose).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 420).background(palette.background).tint(palette.accent)
            .onExitCommand(perform: onClose)
    }
    private var cpuPower: String {
        guard usesEnergy, let power = record.averageCPUWatts else { return "— W" }
        return power > 0 && power < 1 ? String(format: "%.1f mW", power * 1000) : EnergyFormat.watts(power)
    }
    private func detail(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }
}
