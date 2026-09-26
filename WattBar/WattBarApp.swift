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
    private var preferencesWindow: NSWindow?
    private var preferencesController: PreferencesController?

    // Battery image cache to avoid regenerating on every update
    private var cachedBatteryImage: NSImage?
    private var cachedBatteryPercent: Int = -1
    private var cachedBatteryIsCharging: Bool = false
    private var cachedBatteryIconStyle: BatteryIconStyle = .dark

    // Cache for last displayed power value to skip unnecessary string formatting
    private var lastDisplayedPowerValue: Float = -1

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
            // Default to 2 seconds for better energy efficiency
            refreshInterval = .twoSeconds
        }

        super.init()
    }

    // MARK: Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItems()
        startTimer()
        setupPowerSourceNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            title: "Show Battery Icon",
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

        let toggleBatteryItem = NSMenuItem(
            title: "Show Battery Icon",
            action: #selector(toggleBatteryDisplay),
            keyEquivalent: ""
        )
        toggleBatteryItem.target = self
        toggleBatteryItem.state = showBatteryInMenuBar ? .on : .off
        toggleBatteryItem.tag = 401
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

        batteryStatusItem?.menu = menu
    }

    // MARK: Timer

    private func startTimer() {
        let interval = max(1.0, refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshReading()
        }
        // Use .default mode instead of .common to allow better power management
        // The timer doesn't need to fire during modal dialogs or scrolling
        RunLoop.main.add(timer, forMode: .default)
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
        // Use .utility QoS for energy efficiency - this is background monitoring work,
        // not user-initiated interactive work that needs immediate response
        DispatchQueue.global(qos: .utility).async { [weak self] in
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

        // Only regenerate image if battery state has changed (saves CPU/GPU work)
        let needsNewImage = cachedBatteryImage == nil
            || cachedBatteryPercent != clampedPercent
            || cachedBatteryIsCharging != isCharging
            || cachedBatteryIconStyle != batteryIconStyle

        if needsNewImage {
            let newImage = makeBatteryStatusImage(percent: clampedPercent, isCharging: isCharging, style: batteryIconStyle)
            cachedBatteryImage = newImage
            cachedBatteryPercent = clampedPercent
            cachedBatteryIsCharging = isCharging
            cachedBatteryIconStyle = batteryIconStyle
            button.image = newImage
            button.needsDisplay = true
        }

        let statusText = isCharging ? "Charging" : "On Battery"
        button.toolTip = "Battery \(clampedPercent)% - \(statusText)"
        button.setAccessibilityLabel("Battery \(clampedPercent)% - \(statusText)")
    }

    private func makeBatteryStatusImage(percent: Int, isCharging: Bool, style: BatteryIconStyle) -> NSImage {
        let scale: CGFloat = 0.85
        let fontSize: CGFloat = 11.5 * scale
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)

        let text = "\(percent)"

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
            if let toggleItem = menu.item(withTag: 401) {
                toggleItem.state = showBatteryInMenuBar ? .on : .off
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
        syncPreferencesController()
    }

    @objc private func toggleBatteryDisplay() {
        showBatteryInMenuBar.toggle()
        syncPreferencesController()
    }

    private func syncPreferencesController() {
        guard let controller = preferencesController else { return }
        let onUpdate = controller.onUpdate
        controller.onUpdate = nil
        controller.showPowerInMenuBar = showPowerInMenuBar
        controller.showBatteryInMenuBar = showBatteryInMenuBar
        controller.batteryIconStyle = batteryIconStyle
        controller.displayMode = displayMode
        controller.refreshInterval = refreshInterval
        controller.currentPower = currentReading.systemTotal
        controller.currentBatteryPercent = currentReading.batteryPercent
        controller.onUpdate = onUpdate
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
                if self.showPowerInMenuBar != ctrl.showPowerInMenuBar {
                    self.showPowerInMenuBar = ctrl.showPowerInMenuBar
                } else if self.showBatteryInMenuBar != ctrl.showBatteryInMenuBar {
                    self.showBatteryInMenuBar = ctrl.showBatteryInMenuBar
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
            window.setContentSize(NSSize(width: 380, height: 480))
            window.center()

            preferencesWindow = window
        } else {
            // Update controller values
            syncPreferencesController()
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
