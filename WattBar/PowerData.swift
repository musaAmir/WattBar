//
//  PowerData.swift
//  WattBar
//
//  Data structures and enums for power monitoring
//

import Foundation

/// Power reading data from SMC
struct PowerReading {
    let systemTotal: Float    // Total system power in watts
    let batteryRate: Float    // Battery discharge/charge rate in watts
    let deliveryRate: Float   // Power from adapter in watts
    let batteryPercent: Int   // Battery percentage (0-100)
    let isCharging: Bool      // Whether battery is charging
    let timestamp: Date

    var displayValue: Float {
        systemTotal
    }

    var batteryDisplayValue: Float {
        batteryRate
    }

    static let zero = PowerReading(
        systemTotal: 0,
        batteryRate: 0,
        deliveryRate: 0,
        batteryPercent: 0,
        isCharging: false,
        timestamp: Date()
    )
}

/// User preference for what to display
enum DisplayMode: String, CaseIterable {
    case systemTotal = "system"
    case battery = "battery"

    var label: String {
        switch self {
        case .systemTotal: return "System Total"
        case .battery: return "Battery"
        }
    }
}

/// Battery icon style options
enum BatteryIconStyle: String, CaseIterable {
    case dark = "dark"
    case light = "light"

    var label: String {
        switch self {
        case .dark: return "Black Background"
        case .light: return "White Background"
        }
    }
}

/// Available refresh intervals
enum RefreshInterval: Double, CaseIterable {
    case oneSecond = 1.0
    case twoSeconds = 2.0
    case fiveSeconds = 5.0
    case tenSeconds = 10.0

    var label: String {
        switch self {
        case .oneSecond: return "1 second"
        case .twoSeconds: return "2 seconds"
        case .fiveSeconds: return "5 seconds"
        case .tenSeconds: return "10 seconds"
        }
    }
}
