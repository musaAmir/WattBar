//
//  WattBarApp.swift
//  WattBar
//
//  Clean rebuild based on WattSec implementation
//  With battery indicator and customization from original WattBar
//

import Cocoa
import Combine
import CoreText
import Foundation
import IOKit.ps
import Sparkle
import SwiftUI

// MARK: - Main App

@main
enum WattBarApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // SwiftUI is created only while a menu or Preferences is open.
        withExtendedLifetime(delegate) { app.run() }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {

    // MARK: Properties

    private var powerStatusItem: NSStatusItem?
    private var batteryStatusItem: NSStatusItem?
    private var timer: Timer?
    private var energyWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var preferencesController: PreferencesController?
    private var preferencesToolbar: PreferencesToolbarController?

    // Sparkle checks the appcast in Info.plist (SUFeedURL) once a day and offers to install new versions
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Battery image cache to avoid regenerating on every update
    private var cachedBatteryImage: NSImage?
    private var cachedBatteryPercent: Int = -1
    private var cachedBatteryIsCharging: Bool = false
    private var cachedBatteryIconStyle: BatteryIconStyle = .dark
    private var cachedBatteryShowsPercent: Bool = true

    private lazy var dashboardModel = MenuDashboardModel()
    private var currentReading: PowerReading = .unavailable
    private let sensorQueue = DispatchQueue(label: "com.wattbar.sensors", qos: .utility)
    private let activityMonitor = AppActivityMonitor()
    private var acquisitionGeneration = 0
    private var readInFlight = false
    private var isSleeping = false
    private var isTerminating = false
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []

    // User preferences
    private var showPowerInMenuBar: Bool {
        didSet {
            // Refuse to hide the last visible item, otherwise the app becomes unreachable
            if !anyMenuBarItemEnabled { showPowerInMenuBar = true }
            UserDefaults.standard.set(showPowerInMenuBar, forKey: "showPowerInMenuBar")
            menuBarItemsChanged()
        }
    }

    private var showBatteryIcon: Bool {
        didSet {
            if !anyMenuBarItemEnabled { showBatteryIcon = true }
            UserDefaults.standard.set(showBatteryIcon, forKey: "showBatteryIcon")
            menuBarItemsChanged()
        }
    }

    private var showBatteryPercent: Bool {
        didSet {
            if !anyMenuBarItemEnabled { showBatteryPercent = true }
            UserDefaults.standard.set(showBatteryPercent, forKey: "showBatteryPercent")
            menuBarItemsChanged()
        }
    }

    /// Desktop Macs (Mac mini, iMac, Studio) have no battery, so battery options are hidden there
    private static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let installed = IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        let capacity = IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        return PowerReading.hasBattery(installed: installed, maximumCapacity: capacity?.doubleValue)
    }()

    private var showBatteryInMenuBar: Bool {
        AppDelegate.hasBattery && (showBatteryIcon || showBatteryPercent)
    }

    private var anyMenuBarItemEnabled: Bool {
        showPowerInMenuBar || showBatteryInMenuBar
    }

    private var batteryIconStyle: BatteryIconStyle {
        didSet {
            guard oldValue != batteryIconStyle else { return }
            UserDefaults.standard.set(batteryIconStyle.rawValue, forKey: "batteryIconStyle")
            updateMenuCheckmarks()
            updateDisplay()
        }
    }

    private var displayMode: DisplayMode {
        didSet {
            guard oldValue != displayMode else { return }
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            updateMenuCheckmarks()
            updateDisplay()
        }
    }

    private var refreshInterval: RefreshInterval {
        didSet {
            guard oldValue != refreshInterval else { return }
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
            restartTimer()
            updateMenuCheckmarks()
        }
    }

    // MARK: Initialization

    override init() {
        // Load saved preferences
        let defaults = UserDefaults.standard
        // Older versions had a single "showBatteryInMenuBar" toggle; use it as the default for both new ones
        let legacyShowBattery = defaults.object(forKey: "showBatteryInMenuBar") as? Bool ?? false
        let showIcon = defaults.object(forKey: "showBatteryIcon") as? Bool ?? legacyShowBattery
        let showPercent = defaults.object(forKey: "showBatteryPercent") as? Bool ?? legacyShowBattery
        let showPower = defaults.object(forKey: "showPowerInMenuBar") as? Bool ?? true
        showBatteryIcon = showIcon
        showBatteryPercent = showPercent
        showPowerInMenuBar = showPower || !(AppDelegate.hasBattery && (showIcon || showPercent))

        if let savedMode = UserDefaults.standard.string(forKey: "displayMode"),
           let mode = DisplayMode(rawValue: savedMode) {
            displayMode = AppDelegate.hasBattery ? mode : .systemTotal
        } else {
            displayMode = .systemTotal
        }

        if let savedStyle = UserDefaults.standard.string(forKey: "batteryIconStyle"),
           let style = BatteryIconStyle(rawValue: savedStyle) {
            batteryIconStyle = style
        } else {
            batteryIconStyle = .dark
        }

        if let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval") as Double?,
           savedInterval > 0,
           let interval = RefreshInterval(rawValue: savedInterval) {
            refreshInterval = interval
        } else {
            // Default to 2 seconds for better energy efficiency
            refreshInterval = .twoSeconds
        }

        super.init()
    }

    // MARK: Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherRunningInstances()
        updateStatusItemVisibility()
        startTimer()
        setupPowerSourceNotifications()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.isSleeping = true
                self?.acquisitionGeneration += 1
                self?.dashboardModel.interrupt()
                self?.sensorQueue.async { [weak self] in self?.activityMonitor.breakContinuity() }
                self?.timer?.invalidate()
                self?.timer = nil
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isSleeping = false
                self.dashboardModel.refreshSummaries()
                self.sensorQueue.async {
                    SMC.shared.close()
                    self.activityMonitor.breakContinuity()
                }
                self.startTimer()
            }
        ]
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showEnergyHistory()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        acquisitionGeneration += 1
        dashboardModel.checkpoint()
        timer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let source = powerSourceRunLoopSource { CFRunLoopSourceInvalidate(source) }
        powerSourceRunLoopSource = nil
        sensorQueue.async { SMC.shared.close() }
    }

    /// Two copies running at once (e.g. a login item plus an Xcode build) means two sets of menu bar icons.
    /// The newest launch wins so rebuilding from Xcode replaces the old copy.
    private func quitOtherRunningInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        others.forEach { $0.terminate() }
        // Let the previous instance checkpoint before lazily loading its history.
        let deadline = Date().addingTimeInterval(2)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: Status Items Setup

    private func menuBarItemsChanged() {
        updateStatusItemVisibility()
        updateMenuCheckmarks()
        updateDisplay()
    }

    /// Creates or removes status items to match the preferences.
    /// Items are removed rather than hidden with `isVisible`, because macOS 26+ also uses that flag
    /// for items the user hid in System Settings > Menu Bar, and the two fight each other.
    private func updateStatusItemVisibility() {
        if showPowerInMenuBar, powerStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // A stable name lets macOS remember this item (position, visibility) across launches
            // instead of tracking anonymous "Item-0"/"Item-1" entries that pile up as duplicates
            item.autosaveName = "WattBarPower"
            if let button = item.button {
                button.title = "— W"
                button.image = menuSymbol("bolt.fill")
                button.imagePosition = .imageLeading
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            }
            powerStatusItem = item
            buildPowerMenu()
        } else if !showPowerInMenuBar, let item = powerStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            powerStatusItem = nil
        }

        if showBatteryInMenuBar, batteryStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "WattBarBattery"
            batteryStatusItem = item
            cachedBatteryImage = nil
            buildBatteryMenu()
            updateBatteryStatusItem(percent: currentReading.batteryPercent, isCharging: currentReading.isCharging)
        } else if !showBatteryInMenuBar, let item = batteryStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            batteryStatusItem = nil
        }
    }

    // MARK: Menus

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let dashboard = NSMenuItem(title: "WattBar", action: nil, keyEquivalent: "")
        dashboard.tag = 100
        dashboard.isEnabled = false
        menu.addItem(dashboard)
        menu.addItem(.separator())
        return menu
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        image?.isTemplate = true
        return image
    }

    private func buildPowerMenu() {
        let menu = makeMenu()
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(displayModeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = mode != .battery || AppDelegate.hasBattery
            item.representedObject = mode
            item.state = mode == displayMode ? .on : .off
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "Power Reading", action: nil, keyEquivalent: "")
        displayItem.image = menuSymbol("bolt.circle")
        displayItem.submenu = displayMenu
        displayItem.tag = 200
        displayItem.isHidden = !AppDelegate.hasBattery
        menu.addItem(displayItem)

        let refreshMenu = NSMenu()
        for interval in RefreshInterval.allCases {
            let item = NSMenuItem(title: interval.label, action: #selector(refreshIntervalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = interval == refreshInterval ? .on : .off
            refreshMenu.addItem(item)
        }
        let refreshItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        refreshItem.image = menuSymbol("clock")
        refreshItem.submenu = refreshMenu
        refreshItem.tag = 300
        menu.addItem(refreshItem)
        addMenuBarToggles(to: menu)
        addCommonMenuActions(to: menu)
        powerStatusItem?.menu = menu
    }

    private func buildBatteryMenu() {
        let menu = makeMenu()
        let iconStyleMenu = NSMenu()
        for style in BatteryIconStyle.allCases {
            let item = NSMenuItem(title: style.label, action: #selector(batteryIconStyleSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            item.state = style == batteryIconStyle ? .on : .off
            iconStyleMenu.addItem(item)
        }
        let iconStyleItem = NSMenuItem(title: "Battery Icon Style", action: nil, keyEquivalent: "")
        iconStyleItem.image = menuSymbol("battery.100percent")
        iconStyleItem.submenu = iconStyleMenu
        iconStyleItem.tag = 500
        menu.addItem(iconStyleItem)
        addMenuBarToggles(to: menu)
        addCommonMenuActions(to: menu)
        batteryStatusItem?.menu = menu
    }

    private func addCommonMenuActions(to menu: NSMenu) {
        menu.addItem(.separator())
        for (title, symbol, action, key) in [
            ("Energy & Apps…", "chart.xyaxis.line", #selector(showEnergyHistory), "e"),
            ("Preferences…", "slider.horizontal.3", #selector(showPreferences), ","),
            ("Check for Updates…", "arrow.triangle.2.circlepath", #selector(checkForUpdates), ""),
            ("Quit WattBar", "power", #selector(quitApp), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.image = menuSymbol(symbol)
            item.target = self
            menu.addItem(item)
        }
    }

    // Keep the standard macOS menu for keyboard navigation and native submenus.
    // The dashboard is created on demand and released as soon as its menu closes.
    func menuWillOpen(_ menu: NSMenu) {
        guard let item = menu.item(withTag: 100) else { return }
        dashboardModel.refreshSummaries()
        let batteryFocused = menu === batteryStatusItem?.menu
        let view = NSHostingView(rootView: MenuDashboardView(
            model: dashboardModel,
            mode: batteryFocused ? .battery : displayMode,
            hasBattery: AppDelegate.hasBattery,
            batteryFocused: batteryFocused
        ))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        item.view = view
        refreshReading()
    }

    func menuDidClose(_ menu: NSMenu) {
        menu.item(withTag: 100)?.view = nil
    }

    // MARK: Menu Bar Toggles

    private func addMenuBarToggles(to menu: NSMenu) {
        let submenu = NSMenu()
        let toggles: [(String, Selector, Int)] = [
            ("Power Usage", #selector(togglePowerDisplay), 400),
            ("Battery Icon", #selector(toggleBatteryIcon), 401),
            ("Battery Percentage", #selector(toggleBatteryPercent), 402)
        ]
        for (title, action, tag) in toggles {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isHidden = tag != 400 && !AppDelegate.hasBattery
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Menu Bar Items", action: nil, keyEquivalent: "")
        item.image = menuSymbol("menubar.rectangle")
        item.tag = 410
        item.submenu = submenu
        menu.addItem(item)
        updateMenuBarToggleCheckmarks(in: menu)
    }

    private func updateMenuBarToggleCheckmarks(in menu: NSMenu) {
        guard let submenu = menu.item(withTag: 410)?.submenu else { return }
        submenu.item(withTag: 400)?.state = showPowerInMenuBar ? .on : .off
        submenu.item(withTag: 401)?.state = showBatteryIcon ? .on : .off
        submenu.item(withTag: 402)?.state = showBatteryPercent ? .on : .off
    }

    // MARK: Timer

    private func startTimer() {
        guard !isSleeping, !isTerminating else { return }
        let interval = max(1.0, refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshReading()
        }
        // Reuse this timer while menus track so the dashboard stays live.
        // Tolerance and the single-read guard still bound sensor work.
        RunLoop.main.add(timer, forMode: .common)
        // Set tolerance to 50% of interval to allow aggressive timer coalescing
        // This lets macOS batch timer fires and keep CPU in low-power states longer
        timer.tolerance = interval * 0.5
        self.timer = timer
        // Only call refreshReading once (timer will fire on its own schedule)
        refreshReading()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        startTimer()
    }

    private func refreshReading() {
        // A notification and timer can coincide. Keep at most one sensor read queued.
        guard !readInFlight, !isSleeping, !isTerminating else { return }
        readInFlight = true
        let generation = acquisitionGeneration
        let maximumGap = max(15, refreshInterval.rawValue * 2.5)
        sensorQueue.async { [weak self] in
            let reading = SMC.shared.readPowerData()
            let observedAt = Date()
            let activity = self?.activityMonitor.sample(at: observedAt)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                guard !self.isSleeping, !self.isTerminating, generation == self.acquisitionGeneration else { return }
                self.currentReading = reading
                self.dashboardModel.record(reading, at: observedAt, maximumGap: maximumGap)
                if let activity { self.dashboardModel.recordActivity(activity) }
                self.updateDisplay()
            }
        }
    }

    private func setupPowerSourceNotifications() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.powerSourceChanged()
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
    }

    @objc private func powerSourceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshReading()
        }
    }

    // MARK: Display Update

    private func updateDisplay() {
        // Update preferences controller if open
        preferencesController?.currentPower = currentReading.systemTotal
        preferencesController?.currentBatteryPercent = currentReading.batteryPercent

        // Update power status item
        if showPowerInMenuBar {
            let value = displayMode == .systemTotal ? currentReading.systemTotal : currentReading.batteryRate
            let newTitle = PowerReading.watts(value)
            powerStatusItem?.button?.setAccessibilityLabel("\(displayMode.label): \(newTitle)")
            powerStatusItem?.button?.toolTip = value == nil ? "This power sensor is unavailable on this Mac." : displayMode.label

            if powerStatusItem?.button?.title != newTitle {
                powerStatusItem?.button?.title = newTitle
                powerStatusItem?.button?.needsDisplay = true
            }
        }

        // Update battery status item
        if showBatteryInMenuBar {
            let percent = currentReading.batteryPercent
            updateBatteryStatusItem(percent: percent, isCharging: currentReading.isCharging)
        }
    }

    // MARK: Battery Icon

    private func updateBatteryStatusItem(percent: Int?, isCharging: Bool) {
        guard let button = batteryStatusItem?.button else { return }
        guard let percent else {
            button.image = nil
            button.imagePosition = .noImage
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.toolTip = "Battery percentage unavailable"
            button.title = "—%"
            button.setAccessibilityLabel("Battery percentage unavailable")
            cachedBatteryImage = nil
            return
        }
        let clampedPercent = max(0, min(percent, 100))

        if !showBatteryIcon {
            // Percentage only: plain text, like the power reading
            cachedBatteryImage = nil
            button.image = nil
            button.imagePosition = .noImage
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let newTitle = isCharging ? "\(clampedPercent)% ⚡︎" : "\(clampedPercent)%"
            if button.title != newTitle {
                button.title = newTitle
            }
        } else {
            button.imagePosition = .imageOnly
            button.title = ""

            // Only regenerate image if battery state has changed (saves CPU/GPU work)
            let needsNewImage = cachedBatteryImage == nil
                || cachedBatteryPercent != clampedPercent
                || cachedBatteryIsCharging != isCharging
                || cachedBatteryIconStyle != batteryIconStyle
                || cachedBatteryShowsPercent != showBatteryPercent

            if needsNewImage {
                let newImage = makeBatteryStatusImage(
                    percent: clampedPercent,
                    isCharging: isCharging,
                    style: batteryIconStyle,
                    showPercent: showBatteryPercent
                )
                cachedBatteryImage = newImage
                cachedBatteryPercent = clampedPercent
                cachedBatteryIsCharging = isCharging
                cachedBatteryIconStyle = batteryIconStyle
                cachedBatteryShowsPercent = showBatteryPercent
                button.image = newImage
                button.needsDisplay = true
            }
        }

        let statusText = currentReading.batteryStatus
        button.toolTip = "Battery \(clampedPercent)% - \(statusText)"
        button.setAccessibilityLabel("Battery \(clampedPercent)% - \(statusText)")
    }

    private func makeBatteryStatusImage(percent: Int, isCharging: Bool, style: BatteryIconStyle, showPercent: Bool) -> NSImage {
        let scale: CGFloat = 0.85
        let fontSize: CGFloat = 11.5 * scale
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)

        let text = showPercent ? "\(percent)" : ""

        // Determine fill level using discrete steps matching actual percentage
        let discreteFillPercent: CGFloat
        if percent >= 90 {
            discreteFillPercent = 1.0      // 90-100% → full
        } else if percent >= 80 {
            discreteFillPercent = 0.85     // 80-89% → 85% fill
        } else if percent >= 70 {
            discreteFillPercent = 0.75     // 70-79% → 75% fill
        } else if percent >= 60 {
            discreteFillPercent = 0.65     // 60-69% → 65% fill
        } else if percent >= 50 {
            discreteFillPercent = 0.55     // 50-59% → 55% fill
        } else if percent >= 40 {
            discreteFillPercent = 0.45     // 40-49% → 45% fill
        } else if percent >= 30 {
            discreteFillPercent = 0.35     // 30-39% → 35% fill
        } else if percent >= 20 {
            discreteFillPercent = 0.25     // 20-29% → 25% fill
        } else if percent >= 10 {
            discreteFillPercent = 0.15     // 10-19% → 15% fill
        } else if percent >= 5 {
            discreteFillPercent = 0.08     // 5-9% → 8% fill
        } else {
            discreteFillPercent = 0.03     // 0-4% → almost empty
        }

        // Determine if low battery (below 20%) - will turn red
        let isLowBattery = percent < 20 && !isCharging

        // Text color: contrast with fill color
        let textColor: NSColor
        if isCharging {
            textColor = NSColor.white
        } else if isLowBattery {
            textColor = NSColor.white
        } else {
            // Text needs to contrast with fill (fill is white on dark, black on light)
            textColor = style == .dark ? NSColor.black : NSColor.white
        }

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesFontLeading],
            attributes: textAttributes
        )
        let textWidth = ceil(textBounds.width)

        let strokeWidth: CGFloat = 1
        let bodyHeight: CGFloat = 16 * scale
        let minBodyWidth: CGFloat = 24 * scale
        let paddingX: CGFloat = 6 * scale
        let capWidth: CGFloat = 3 * scale
        let cornerRadius: CGFloat = 5 * scale

        let baseBodyWidth = max(minBodyWidth, ceil(textWidth + paddingX * 2))
        let bodyWidth = ceil(baseBodyWidth * 1.08)
        let imageSize = NSSize(width: bodyWidth + capWidth + strokeWidth, height: bodyHeight)
        let image = NSImage(size: imageSize)

        image.lockFocus()

        let bodyRect = NSRect(
            x: strokeWidth / 2,
            y: strokeWidth / 2,
            width: bodyWidth,
            height: bodyHeight - strokeWidth
        )
        let capHeight = bodyRect.height * 0.55
        let capRect = NSRect(
            x: bodyRect.maxX + (strokeWidth / 2),
            y: bodyRect.midY - capHeight / 2,
            width: capWidth,
            height: capHeight
        )

        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)

        if isCharging {
            // Charging mode: Green fill with lightning bolt
            // Draw empty battery background first
            let emptyColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)
            emptyColor.setFill()
            bodyPath.fill()

            // Draw green fill level
            let fillWidth = (bodyRect.width - strokeWidth) * discreteFillPercent
            let fillRect = NSRect(
                x: bodyRect.minX + strokeWidth / 2,
                y: bodyRect.minY + strokeWidth / 2,
                width: fillWidth,
                height: bodyRect.height - strokeWidth
            )
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
            // Clip to body shape
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            let greenColor = NSColor(red: 0.35, green: 0.78, blue: 0.35, alpha: 1.0)
            greenColor.setFill()
            fillPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            let strokeColor = NSColor(red: 0.4, green: 0.75, blue: 0.4, alpha: 0.8)
            strokeColor.setStroke()
            bodyPath.lineWidth = strokeWidth
            bodyPath.stroke()

            // Draw cap
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: 2.5, yRadius: 2.5)
            capPath.lineWidth = strokeWidth
            strokeColor.setStroke()
            capPath.stroke()
        } else {
            // Non-charging mode: Show fill level with style-based or red colors
            let backgroundColor: NSColor
            let fillColor: NSColor
            let strokeColor: NSColor

            if isLowBattery {
                // Low battery: red fill on dark background
                backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
                // Gradient from orange to red as battery decreases
                let redIntensity = 1.0 - (CGFloat(percent) / 20.0) * 0.3
                fillColor = NSColor(red: 0.9, green: 0.25 * (1.0 - redIntensity), blue: 0.2 * (1.0 - redIntensity), alpha: 1.0)
                strokeColor = NSColor(red: 0.8, green: 0.3, blue: 0.3, alpha: 0.9)
            } else {
                switch style {
                case .dark:
                    // Light background - closer to white but still distinct from fill
                    backgroundColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
                    fillColor = NSColor.white
                    strokeColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
                case .light:
                    // Darker background for contrast with black fill
                    backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
                    fillColor = NSColor.black
                    strokeColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
                }
            }

            // Draw empty battery background
            backgroundColor.setFill()
            bodyPath.fill()

            // Draw fill level
            let fillWidth = (bodyRect.width - strokeWidth) * discreteFillPercent
            let fillRect = NSRect(
                x: bodyRect.minX + strokeWidth / 2,
                y: bodyRect.minY + strokeWidth / 2,
                width: fillWidth,
                height: bodyRect.height - strokeWidth
            )

            // Clip fill to body shape and draw
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            let fillPath = NSBezierPath(rect: fillRect)
            fillColor.setFill()
            fillPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Draw stroke
            strokeColor.setStroke()
            bodyPath.lineWidth = strokeWidth
            bodyPath.stroke()

            // Draw cap with fill based on battery level
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: 2.5, yRadius: 2.5)
            if discreteFillPercent >= 1.0 {
                // Full battery (90%+): fill the cap too
                fillColor.setFill()
                capPath.fill()
            }
            capPath.lineWidth = strokeWidth
            strokeColor.setStroke()
            capPath.stroke()
        }

        // Draw percentage text and lightning bolt (centered together)
        let verticalOffset: CGFloat = 3.2 * scale
        let horizontalOffset: CGFloat = 0.6 * scale

        if isCharging {
            // Draw custom white lightning bolt
            let boltWidth: CGFloat = 5.0
            let boltHeight: CGFloat = 7.5

            let boltSpacing: CGFloat = 1.5
            let totalWidth = textBounds.width + boltSpacing + boltWidth

            let combinedX = bodyRect.midX - totalWidth / 2 + 1.5

            let textOrigin = NSPoint(
                x: floor(combinedX - textBounds.minX),
                y: floor(bodyRect.midY - (textBounds.height / 2 + textBounds.minY) - verticalOffset)
            )
            (text as NSString).draw(at: textOrigin, withAttributes: textAttributes)

            // Draw white lightning bolt shape
            let boltX = textOrigin.x + textBounds.width + boltSpacing
            let boltY = bodyRect.midY - boltHeight / 2

            let boltPath = NSBezierPath()
            boltPath.move(to: NSPoint(x: boltX + boltWidth * 0.5, y: boltY + boltHeight))
            boltPath.line(to: NSPoint(x: boltX, y: boltY + boltHeight * 0.45))
            boltPath.line(to: NSPoint(x: boltX + boltWidth * 0.35, y: boltY + boltHeight * 0.45))
            boltPath.line(to: NSPoint(x: boltX + boltWidth * 0.15, y: boltY))
            boltPath.line(to: NSPoint(x: boltX + boltWidth, y: boltY + boltHeight * 0.55))
            boltPath.line(to: NSPoint(x: boltX + boltWidth * 0.6, y: boltY + boltHeight * 0.55))
            boltPath.close()

            NSColor.white.setFill()
            boltPath.fill()
        } else {
            // Non-charging: center text normally
            let textOrigin = NSPoint(
                x: floor(bodyRect.midX - (textBounds.width / 2 + textBounds.minX) + horizontalOffset),
                y: floor(bodyRect.midY - (textBounds.height / 2 + textBounds.minY) - verticalOffset)
            )
            (text as NSString).draw(at: textOrigin, withAttributes: textAttributes)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: Menu Checkmarks

    private func updateMenuCheckmarks() {
        // Update power menu checkmarks
        if let menu = powerStatusItem?.menu {
            if let displayItem = menu.item(withTag: 200),
               let displayMenu = displayItem.submenu {
                for item in displayMenu.items {
                    if let mode = item.representedObject as? DisplayMode {
                        item.state = mode == displayMode ? .on : .off
                    }
                }
            }

            if let refreshItem = menu.item(withTag: 300),
               let refreshMenu = refreshItem.submenu {
                for item in refreshMenu.items {
                    if let interval = item.representedObject as? RefreshInterval {
                        item.state = interval == refreshInterval ? .on : .off
                    }
                }
            }

            updateMenuBarToggleCheckmarks(in: menu)
        }

        // Update battery menu checkmarks
        if let menu = batteryStatusItem?.menu {
            if let iconItem = menu.item(withTag: 500),
               let iconMenu = iconItem.submenu {
                for item in iconMenu.items {
                    if let style = item.representedObject as? BatteryIconStyle {
                        item.state = style == batteryIconStyle ? .on : .off
                    }
                }
            }
            updateMenuBarToggleCheckmarks(in: menu)
        }
    }

    // MARK: Menu Actions

    @objc private func displayModeSelected(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DisplayMode else { return }
        displayMode = mode
        syncPreferencesController()
    }

    @objc private func refreshIntervalSelected(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? RefreshInterval else { return }
        refreshInterval = interval
        syncPreferencesController()
    }

    @objc private func batteryIconStyleSelected(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? BatteryIconStyle else { return }
        batteryIconStyle = style
        syncPreferencesController()
    }

    @objc private func togglePowerDisplay() {
        showPowerInMenuBar.toggle()
        syncPreferencesController()
    }

    @objc private func toggleBatteryIcon() {
        showBatteryIcon.toggle()
        syncPreferencesController()
    }

    @objc private func toggleBatteryPercent() {
        showBatteryPercent.toggle()
        syncPreferencesController()
    }

    private func syncPreferencesController() {
        guard let controller = preferencesController else { return }
        let onUpdate = controller.onUpdate
        controller.onUpdate = nil
        controller.showPowerInMenuBar = showPowerInMenuBar
        controller.showBatteryIcon = showBatteryIcon
        controller.showBatteryPercent = showBatteryPercent
        controller.batteryIconStyle = batteryIconStyle
        controller.displayMode = displayMode
        controller.refreshInterval = refreshInterval
        controller.automaticUpdateChecks = updaterController.updater.automaticallyChecksForUpdates
        controller.currentPower = currentReading.systemTotal
        controller.currentBatteryPercent = currentReading.batteryPercent
        controller.onUpdate = onUpdate
    }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            let controller = PreferencesController(
                showPower: showPowerInMenuBar,
                showBatteryIcon: showBatteryIcon,
                showBatteryPercent: showBatteryPercent,
                iconStyle: batteryIconStyle,
                displayMode: displayMode,
                refreshInterval: refreshInterval
            )
            controller.automaticUpdateChecks = updaterController.updater.automaticallyChecksForUpdates
            controller.hasBattery = AppDelegate.hasBattery
            controller.currentPower = currentReading.systemTotal
            controller.currentBatteryPercent = currentReading.batteryPercent

            controller.menuBarPreview = { [weak self] in
                (self?.powerStatusItem?.button?.title ?? "— W",
                 self?.batteryStatusItem?.button?.image,
                 self?.batteryStatusItem?.button?.title ?? "—%")
            }
            controller.onOpenDashboard = { [weak self] in self?.showEnergyHistory() }
            controller.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
            controller.onUpdate = { [weak self] in
                guard let self = self, let ctrl = self.preferencesController else { return }
                // Only assign the toggle that changed, so the "keep one item visible" rule applies to it
                if self.showPowerInMenuBar != ctrl.showPowerInMenuBar {
                    self.showPowerInMenuBar = ctrl.showPowerInMenuBar
                } else if self.showBatteryIcon != ctrl.showBatteryIcon {
                    self.showBatteryIcon = ctrl.showBatteryIcon
                } else if self.showBatteryPercent != ctrl.showBatteryPercent {
                    self.showBatteryPercent = ctrl.showBatteryPercent
                }
                if self.updaterController.updater.automaticallyChecksForUpdates != ctrl.automaticUpdateChecks {
                    self.updaterController.updater.automaticallyChecksForUpdates = ctrl.automaticUpdateChecks
                }
                self.batteryIconStyle = ctrl.batteryIconStyle
                self.displayMode = ctrl.displayMode
                self.refreshInterval = ctrl.refreshInterval
                self.syncPreferencesController()
            }

            self.preferencesController = controller

            let prefsView = PreferencesView(controller: controller)
            let hostingController = NSHostingController(rootView: prefsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "WattBar Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            let toolbarController = PreferencesToolbarController(controller: controller)
            preferencesToolbar = toolbarController
            window.toolbar = toolbarController.toolbar
            window.toolbarStyle = .preference
            window.setContentSize(NSSize(width: 590, height: 440))
            window.center()

            preferencesWindow = window
        } else {
            // Update controller values
            syncPreferencesController()
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showEnergyHistory() {
        if energyWindow == nil {
            let view = EnergyDetailView(model: dashboardModel, hasBattery: AppDelegate.hasBattery,
                                        onOpenPreferences: { [weak self] in self?.showPreferences() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "WattBar — Energy & Apps"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1060, height: 790))
            window.contentMinSize = NSSize(width: 920, height: 640)
            window.center()
            energyWindow = window
        }
        dashboardModel.refreshSummaries()
        energyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === energyWindow {
            energyWindow = nil
            return
        }
        guard notification.object as? NSWindow === preferencesWindow else { return }
        preferencesWindow = nil
        preferencesController = nil
        preferencesToolbar = nil
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
