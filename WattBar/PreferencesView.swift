//
//  PreferencesView.swift
//  WattBar
//
//  Preferences window UI
//

import SwiftUI
import ServiceManagement

struct PreferencesView: View {
    @ObservedObject var controller: PreferencesController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var requiresLoginApproval = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                card("Menu Bar") {
                    toggleRow("Show Power Usage", isOn: $controller.showPowerInMenuBar)
                    if controller.hasBattery {
                        toggleRow("Show Battery Icon", isOn: $controller.showBatteryIcon)
                        toggleRow("Show Battery Percentage", isOn: $controller.showBatteryPercent)
                    }
                }

                if controller.hasBattery {
                    card("Battery Icon") {
                        row("Style") {
                            Picker("Battery Icon Style", selection: $controller.batteryIconStyle) {
                                ForEach(BatteryIconStyle.allCases, id: \.self) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }
                }

                card("Power") {
                    if controller.hasBattery {
                        row("Display Mode") {
                            Picker("Display Mode", selection: $controller.displayMode) {
                                ForEach(DisplayMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }
                    row("Refresh Rate") {
                        Picker("Refresh Rate", selection: $controller.refreshInterval) {
                            ForEach(RefreshInterval.allCases, id: \.self) { interval in
                                Text(interval.label).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                card("General") {
                    toggleRow("Check for Updates Automatically", isOn: $controller.automaticUpdateChecks)
                    toggleRow("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                }

                if requiresLoginApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    Text("WattBar needs approval in System Settings to launch at login.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let loginError { Text(loginError).font(.caption).foregroundColor(.red) }

                card("Current Status") {
                    statusRow("System Power", value: PowerReading.watts(controller.currentPower))
                    if controller.hasBattery {
                        statusRow("Battery", value: controller.currentBatteryPercent.map { "\($0)%" } ?? "Unavailable")
                    }
                    Text("Sensor availability varies by Mac. A dash means no reading is available.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 380, height: 480)
        .onAppear { refreshLoginStatus() }
        .onChange(of: controlActiveState) { _ in refreshLoginStatus() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WattBar")
                    .font(.system(size: 20, weight: .semibold))
                Text("Preferences")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
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
