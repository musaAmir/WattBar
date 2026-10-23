import SwiftUI
import ServiceManagement

enum PreferencesPane: String, CaseIterable {
    case general, menuBar, monitoring, updates

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .monitoring: return "Monitoring"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .monitoring: return "waveform.path.ecg"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

/// AppKit supplies standard keyboard navigation, selection, and toolbar appearance.
final class PreferencesToolbarController: NSObject, NSToolbarDelegate {
    private let controller: PreferencesController
    let toolbar = NSToolbar(identifier: "WattBarPreferences")

    init(controller: PreferencesController) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(controller.pane.rawValue)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesPane.allCases.map { .init($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = PreferencesPane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = PreferencesPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        controller.pane = pane
        toolbar.selectedItemIdentifier = sender.itemIdentifier
    }
}

struct PreferencesView: View {
    @ObservedObject var controller: PreferencesController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var requiresLoginApproval = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }

    private var visibleItemCount: Int {
        [controller.showPowerInMenuBar,
         controller.hasBattery && controller.showBatteryIcon,
         controller.hasBattery && controller.showBatteryPercent].filter { $0 }.count
    }

    var body: some View {
        Form {
            switch controller.pane {
            case .general: general
            case .menuBar: menuBar
            case .monitoring: monitoring
            case .updates: updates
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .tint(Color.accentColor)
        .frame(width: 590, height: 440)
        .onAppear { refreshLoginStatus() }
        .onChange(of: controlActiveState) { _ in refreshLoginStatus() }
    }

    private var general: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: WattBarBrand.appIcon)
                        .resizable().interpolation(.high).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WattBar").font(.title2.weight(.semibold))
                        Text("A little insight into your Mac’s energy.").foregroundStyle(.secondary)
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    settingLabel("Launch at login", detail: "Start monitoring when you sign in to your Mac.")
                }
                .accessibilityLabel("Launch at login")
                .accessibilityValue(launchAtLogin ? "On" : "Off")
                if requiresLoginApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    Text("Approve WattBar in System Settings to finish enabling launch at login.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section {
                LabeledContent {
                    Button("Open Dashboard") { controller.onOpenDashboard?() }
                } label: {
                    settingLabel("Energy & applications", detail: "Explore trends and see which apps use CPU energy.")
                }
            } footer: {
                Text("Your energy history stays on this Mac. No account required.")
            }
        }
    }

    private var menuBar: some View {
        let preview = controller.menuBarPreview?()
        return Group {
            Section {
                HStack {
                    Label("Preview", systemImage: "menubar.rectangle").foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 9) {
                        if controller.showPowerInMenuBar {
                            Text(preview?.power ?? PowerReading.watts(controller.currentPower)).monospacedDigit()
                        }
                        if controller.hasBattery && (controller.showBatteryIcon || controller.showBatteryPercent) {
                            if let image = preview?.batteryImage {
                                Image(nsImage: image)
                                    .accessibilityLabel(controller.currentBatteryPercent.map { "Battery \($0)%" } ?? "Battery unavailable")
                            } else {
                                Text(preview?.batteryText ?? "—%").monospacedDigit()
                            }
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Section {
                Toggle("Show power usage", isOn: $controller.showPowerInMenuBar)
                    .disabled(controller.showPowerInMenuBar && visibleItemCount == 1)
                if controller.hasBattery {
                    Toggle("Show battery icon", isOn: $controller.showBatteryIcon)
                        .disabled(controller.showBatteryIcon && visibleItemCount == 1)
                    Toggle("Show battery percentage", isOn: $controller.showBatteryPercent)
                        .disabled(controller.showBatteryPercent && visibleItemCount == 1)
                }
            } footer: {
                Text("Keep at least one item visible so WattBar is always within reach.")
            }
            if controller.hasBattery {
                Section {
                    Picker("Power reading", selection: $controller.displayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Battery icon", selection: $controller.batteryIconStyle) {
                        ForEach(BatteryIconStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
        }
    }

    private var monitoring: some View {
        Group {
            Section {
                Picker("Refresh interval", selection: $controller.refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Longer intervals reduce background work. Application activity is sampled at most every five seconds.")
            }
            Section {
                LabeledContent("Retained on this Mac", value: "90 days")
                LabeledContent("Recent detail", value: "24 hours")
                LabeledContent("Older history", value: "Hourly summaries")
            } header: { Text("Energy history") } footer: {
                Text("History builds as WattBar runs. Averages use observed time; sleep and missing readings stay as gaps.")
            }
            Section {
                LabeledContent("System power", value: PowerReading.watts(controller.currentPower))
                if controller.hasBattery {
                    LabeledContent("Battery", value: controller.currentBatteryPercent.map { "\($0)%" } ?? "Unavailable")
                }
            } header: { Text("Live sensors") } footer: {
                Text("Sensor availability varies by Mac. A dash means a reading is unavailable.")
            }
        }
    }

    private var updates: some View {
        Group {
            Section {
                Toggle(isOn: $controller.automaticUpdateChecks) {
                    settingLabel("Check for updates automatically", detail: "Let WattBar check for new releases in the background.")
                }
                .accessibilityLabel("Check for updates automatically")
                LabeledContent("Check now") {
                    Button("Check for Updates…") { controller.onCheckForUpdates?() }
                }
            }
            Section {
                LabeledContent("Installed version", value: version)
            } footer: {
                Text("Available updates are shown before installation.")
            }
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { loginError = "Couldn’t change Launch at Login: \(error.localizedDescription)" }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        requiresLoginApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

// MARK: - Preferences Controller

class PreferencesController: ObservableObject {
    @Published var pane: PreferencesPane = .general
    var menuBarPreview: (() -> (power: String, batteryImage: NSImage?, batteryText: String))?
    var onOpenDashboard: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    @Published var showPowerInMenuBar: Bool {
        didSet { onUpdate?() }
    }
    @Published var showBatteryIcon: Bool {
        didSet { onUpdate?() }
    }
    @Published var showBatteryPercent: Bool {
        didSet { onUpdate?() }
    }
    @Published var batteryIconStyle: BatteryIconStyle {
        didSet { onUpdate?() }
    }
    @Published var displayMode: DisplayMode {
        didSet { onUpdate?() }
    }
    @Published var refreshInterval: RefreshInterval {
        didSet { onUpdate?() }
    }
    @Published var automaticUpdateChecks = true {
        didSet { onUpdate?() }
    }
    @Published var currentPower: Float?
    @Published var currentBatteryPercent: Int?
    var hasBattery = true

    var onUpdate: (() -> Void)?

    init(
        showPower: Bool,
        showBatteryIcon: Bool,
        showBatteryPercent: Bool,
        iconStyle: BatteryIconStyle,
        displayMode: DisplayMode,
        refreshInterval: RefreshInterval
    ) {
        self.showPowerInMenuBar = showPower
        self.showBatteryIcon = showBatteryIcon
        self.showBatteryPercent = showBatteryPercent
        self.batteryIconStyle = iconStyle
        self.displayMode = displayMode
        self.refreshInterval = refreshInterval
    }
}
