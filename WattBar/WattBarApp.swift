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
import SwiftUI

// MARK: - Main App

@main
struct WattBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Properties

    private var powerStatusItem: NSStatusItem?
    private var batteryStatusItem: NSStatusItem?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var preferencesWindow: NSWindow?
    private var preferencesController: PreferencesController?

    private var currentReading: PowerReading = .zero {
        didSet {
            if oldValue.isCharging != currentReading.isCharging {
                DispatchQueue.main.async { [weak self] in
                    self?.updateDisplay()
                }
            }
        }
    }

    // User preferences
    private var showPowerInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showPowerInMenuBar, forKey: "showPowerInMenuBar")
            ensureAtLeastOneVisible(changed: .power)
            updateStatusItemVisibility()
            updateMenuCheckmarks()
            updateDisplay()
        }
    }

    private var showBatteryInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showBatteryInMenuBar, forKey: "showBatteryInMenuBar")
            ensureAtLeastOneVisible(changed: .battery)
            updateStatusItemVisibility()
            updateMenuCheckmarks()
            updateDisplay()
        }
    }

    private var batteryIconStyle: BatteryIconStyle {
        didSet {
            UserDefaults.standard.set(batteryIconStyle.rawValue, forKey: "batteryIconStyle")
            updateMenuCheckmarks()
            updateDisplay()
        }
    }

    private var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            updateMenuCheckmarks()
            updateDisplay()
        }
    }

    private var refreshInterval: RefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
            restartTimer()
            updateMenuCheckmarks()
        }
    }

    private enum StatusItemKind {
        case power
        case battery
    }

    // MARK: Initialization

    override init() {
        // Load saved preferences
        showPowerInMenuBar = UserDefaults.standard.object(forKey: "showPowerInMenuBar") as? Bool ?? true
        showBatteryInMenuBar = UserDefaults.standard.object(forKey: "showBatteryInMenuBar") as? Bool ?? false

        if let savedMode = UserDefaults.standard.string(forKey: "displayMode"),
           let mode = DisplayMode(rawValue: savedMode) {
            displayMode = mode
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
            refreshInterval = .oneSecond
        }

        super.init()
    }

    // MARK: Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItems()
        startActivity()
        startTimer()
        setupPowerSourceNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        timer?.invalidate()
    }

    // MARK: Status Items Setup

    private func setupStatusItems() {
        // Power status item
        powerStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = powerStatusItem?.button {
            button.title = "-- W"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.wantsLayer = false
        }
        buildPowerMenu()

        // Battery status item
        batteryStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = batteryStatusItem?.button {
            button.wantsLayer = false
        }
        updateBatteryStatusItem(percent: currentReading.batteryPercent, isCharging: currentReading.isCharging)
        buildBatteryMenu()

        updateStatusItemVisibility()
    }

    private func updateStatusItemVisibility() {
        powerStatusItem?.isVisible = showPowerInMenuBar
        batteryStatusItem?.isVisible = showBatteryInMenuBar
    }

    // MARK: Power Menu

    private func buildPowerMenu() {
        let menu = NSMenu()

        // Current reading display
        let readingItem = NSMenuItem(title: "Power: -- W", action: nil, keyEquivalent: "")
        readingItem.tag = 100
        menu.addItem(readingItem)

        menu.addItem(NSMenuItem.separator())

        // Display mode submenu
        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(displayModeSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode
            item.state = mode == displayMode ? .on : .off
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        displayItem.tag = 200
        menu.addItem(displayItem)

        // Refresh rate submenu
        let refreshMenu = NSMenu()
        for interval in RefreshInterval.allCases {
            let item = NSMenuItem(
                title: interval.label,
                action: #selector(refreshIntervalSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = interval
            item.state = interval == refreshInterval ? .on : .off
            refreshMenu.addItem(item)
        }
        let refreshItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        refreshItem.submenu = refreshMenu
        refreshItem.tag = 300
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle battery display
        let toggleBatteryItem = NSMenuItem(
            title: "Show Battery %",
            action: #selector(toggleBatteryDisplay),
            keyEquivalent: ""
        )
        toggleBatteryItem.target = self
        toggleBatteryItem.state = showBatteryInMenuBar ? .on : .off
        toggleBatteryItem.tag = 400
        menu.addItem(toggleBatteryItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit WattBar",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        powerStatusItem?.menu = menu
    }

    // MARK: Battery Menu

    private func buildBatteryMenu() {
        let menu = NSMenu()

        // Battery info
        let batteryItem = NSMenuItem(title: "Battery: --%", action: nil, keyEquivalent: "")
        batteryItem.tag = 100
        menu.addItem(batteryItem)

        let chargingItem = NSMenuItem(title: "Status: --", action: nil, keyEquivalent: "")
        chargingItem.tag = 101
        menu.addItem(chargingItem)

        menu.addItem(NSMenuItem.separator())

        // Icon style submenu
        let iconStyleMenu = NSMenu()
        for style in BatteryIconStyle.allCases {
            let item = NSMenuItem(
                title: style.label,
                action: #selector(batteryIconStyleSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style
            item.state = style == batteryIconStyle ? .on : .off
            iconStyleMenu.addItem(item)
        }
        let iconStyleItem = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        iconStyleItem.submenu = iconStyleMenu
        iconStyleItem.tag = 500
        menu.addItem(iconStyleItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle power display
        let togglePowerItem = NSMenuItem(
            title: "Show Power Usage",
            action: #selector(togglePowerDisplay),
            keyEquivalent: ""
        )
        togglePowerItem.target = self
        togglePowerItem.state = showPowerInMenuBar ? .on : .off
        togglePowerItem.tag = 400
        menu.addItem(togglePowerItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit WattBar",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        batteryStatusItem?.menu = menu
    }

    // MARK: Timer

    private func startTimer() {
        let interval = max(0.5, refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshReading()
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = 0.05
        timer.fireDate = Date()
        self.timer = timer
        refreshReading()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        startTimer()
    }

    private func refreshReading() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let data = SMC.shared.readPowerData()

            let reading = PowerReading(
                systemTotal: Float(data.systemWatts),
                batteryRate: Float(data.batteryWatts),
                deliveryRate: 0,
                batteryPercent: data.batteryPercent,
                isCharging: data.isCharging,
                timestamp: Date()
            )

            DispatchQueue.main.async {
                self?.currentReading = reading
                self?.updateDisplay()
            }
        }
    }

    private func startActivity() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                reason: "Real-time WattBar power monitoring"
            )
        }
    }

    private func setupPowerSourceNotifications() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.powerSourceChanged()
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
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
            let value: Float
            let prefix: String

            switch displayMode {
            case .systemTotal:
                value = currentReading.systemTotal
                prefix = ""
            case .battery:
                value = currentReading.batteryRate
                prefix = ""
            }

            let formattedValue = String(format: "%.1f", value)
            let newTitle = "\(prefix)\(formattedValue)W"

            if powerStatusItem?.button?.title != newTitle {
                powerStatusItem?.button?.title = newTitle
                powerStatusItem?.button?.needsDisplay = true
            }

            // Update power menu reading item
            if let menu = powerStatusItem?.menu,
               let readingItem = menu.item(withTag: 100) {
                readingItem.title = "System: \(String(format: "%.1f", currentReading.systemTotal))W | Battery: \(String(format: "%.1f", currentReading.batteryRate))W"
            }
        }

        // Update battery status item
        if showBatteryInMenuBar {
            let percent = currentReading.batteryPercent
            updateBatteryStatusItem(percent: percent, isCharging: currentReading.isCharging)

            // Update battery menu items
            if let menu = batteryStatusItem?.menu {
                if let batteryItem = menu.item(withTag: 100) {
                    batteryItem.title = "Battery: \(percent)%"
                }
                if let chargingItem = menu.item(withTag: 101) {
                    chargingItem.title = currentReading.isCharging ? "Status: Charging" : "Status: On Battery"
                }
            }
        }
    }

    private func ensureAtLeastOneVisible(changed: StatusItemKind) {
        guard !showPowerInMenuBar && !showBatteryInMenuBar else { return }

        switch changed {
        case .power:
            showBatteryInMenuBar = true
        case .battery:
            showPowerInMenuBar = true
        }
    }

    // MARK: Battery Icon

    private func updateBatteryStatusItem(percent: Int, isCharging: Bool) {
        guard let button = batteryStatusItem?.button else { return }
        let clampedPercent = max(0, min(percent, 100))
        button.imagePosition = .imageOnly
        button.title = ""

        let newImage = makeBatteryStatusImage(percent: clampedPercent, isCharging: isCharging, style: batteryIconStyle)
        newImage.cacheMode = .never
        button.image = newImage

        button.needsDisplay = true

        let statusText = isCharging ? "Charging" : "On Battery"
        button.toolTip = "Battery \(clampedPercent)% - \(statusText)"
        button.setAccessibilityLabel("Battery \(clampedPercent)% - \(statusText)")
    }

    private func makeBatteryStatusImage(percent: Int, isCharging: Bool, style: BatteryIconStyle) -> NSImage {
        let scale: CGFloat = 0.85
        let fontSize: CGFloat = 11.5 * scale
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)

        let text = "\(percent)"
        let textColor: NSColor = isCharging ? NSColor.white : (style == .dark ? NSColor.white : NSColor.black)
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
            // Charging mode: Green pill with lightning bolt
            let greenColor = NSColor(red: 0.35, green: 0.7, blue: 0.35, alpha: 0.6)
            greenColor.setFill()
            bodyPath.fill()

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
            // Non-charging mode: Use style-based colors
            let backgroundColor: NSColor
            let strokeColor: NSColor
            switch style {
            case .dark:
                backgroundColor = .black
                strokeColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
            case .light:
                backgroundColor = .white
                strokeColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
            }
            backgroundColor.setFill()
            bodyPath.fill()
            strokeColor.setStroke()
            bodyPath.lineWidth = strokeWidth
            bodyPath.stroke()

            // Draw cap
            let capPath = NSBezierPath(roundedRect: capRect, xRadius: 2.5, yRadius: 2.5)
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

            if let toggleItem = menu.item(withTag: 400) {
                toggleItem.state = showBatteryInMenuBar ? .on : .off
            }
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
            if let toggleItem = menu.item(withTag: 400) {
                toggleItem.state = showPowerInMenuBar ? .on : .off
            }
        }
    }

    // MARK: Menu Actions

    @objc private func displayModeSelected(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DisplayMode else { return }
        displayMode = mode
    }

    @objc private func refreshIntervalSelected(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? RefreshInterval else { return }
        refreshInterval = interval
    }

    @objc private func batteryIconStyleSelected(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? BatteryIconStyle else { return }
        batteryIconStyle = style
    }

    @objc private func togglePowerDisplay() {
        showPowerInMenuBar.toggle()
    }

    @objc private func toggleBatteryDisplay() {
        showBatteryInMenuBar.toggle()
    }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            let controller = PreferencesController(
                showPower: showPowerInMenuBar,
                showBattery: showBatteryInMenuBar,
                iconStyle: batteryIconStyle,
                displayMode: displayMode,
                refreshInterval: refreshInterval
            )
            controller.currentPower = currentReading.systemTotal
            controller.currentBatteryPercent = currentReading.batteryPercent

            controller.onUpdate = { [weak self] in
                guard let self = self, let ctrl = self.preferencesController else { return }
                self.showPowerInMenuBar = ctrl.showPowerInMenuBar
                self.showBatteryInMenuBar = ctrl.showBatteryInMenuBar
                self.batteryIconStyle = ctrl.batteryIconStyle
                self.displayMode = ctrl.displayMode
                self.refreshInterval = ctrl.refreshInterval
            }

            self.preferencesController = controller

            let prefsView = PreferencesView(controller: controller)
            let hostingController = NSHostingController(rootView: prefsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "WattBar Preferences"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 480))
            window.center()

            preferencesWindow = window
        } else {
            // Update controller values
            preferencesController?.showPowerInMenuBar = showPowerInMenuBar
            preferencesController?.showBatteryInMenuBar = showBatteryInMenuBar
            preferencesController?.batteryIconStyle = batteryIconStyle
            preferencesController?.displayMode = displayMode
            preferencesController?.refreshInterval = refreshInterval
            preferencesController?.currentPower = currentReading.systemTotal
            preferencesController?.currentBatteryPercent = currentReading.batteryPercent
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
