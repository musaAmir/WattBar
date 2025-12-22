//
//  SMC.swift
//  WattBar
//
//  Original by Serhiy Mytrovtsiy at github.com/exelban/stats
//  Modified from WattSec implementation
//

import Foundation
import IOKit
import IOKit.ps

internal enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readKeyInfo = 9
}

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)
    
    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    
    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

internal struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    
    init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        
        self = str.utf8.reduce(0) { sum, character in
            return sum << 8 | UInt32(character)
        }
    }
    
    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

extension Float {
    init?(_ bytes: [UInt8]) {
        self = bytes.withUnsafeBytes {
            return $0.load(fromByteOffset: 0, as: Self.self)
        }
    }
    
    var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}

/// Complete power data from various sources
public struct SMCPowerData {
    let systemWatts: Double
    let batteryWatts: Double
    let isCharging: Bool
    let batteryPercent: Int
}

public class SMC {
    public static let shared = SMC()
    private var conn: io_connect_t = 0
    private let lock = NSLock()

    public init() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0
        let device: io_object_t
        
        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if result != kIOReturnSuccess {
            print("Error IOServiceGetMatchingServices(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if device == 0 {
            print("Error IOIteratorNext(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if result != kIOReturnSuccess {
            print("Error IOServiceOpen(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
    }
    
    deinit {
        let result = self.close()
        if result != kIOReturnSuccess {
            print("error close smc connection: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
    }
    
    public func close() -> kern_return_t {
        return IOServiceClose(conn)
    }
    
    public func getValue(_ key: String) -> Double? {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)

        result = read(&val)
        if result != kIOReturnSuccess {
            print("Error read(\(key)): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return nil
        }

        if val.dataType == "flt " {
            return Float(val.bytes).map { Double($0) }
        }

        return nil
    }
    
    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        
        input.key = FourCharCode(fromString: value.pointee.key)
        input.data8 = SMCKeys.readKeyInfo.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        
        value.pointee.dataSize = UInt32(output.keyInfo.dataSize)
        value.pointee.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        
        memcpy(&value.pointee.bytes, &output.bytes, Int(value.pointee.dataSize))
        
        return kIOReturnSuccess
    }
    
    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride

        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }

    // MARK: - Comprehensive Power Data

    /// Read all power data including battery percentage and charging state
    public func readPowerData() -> SMCPowerData {
        lock.lock()
        defer { lock.unlock() }

        // 1. Check charging state via IOPS (fastest method for plug/unplug detection)
        let isCharging = checkIOPSChargingState()

        // 2. Get battery percentage from registry
        let batteryInfo = readBatteryInfo()

        // 3. Read power values from SMC
        var systemWatts = getValue("PSTR") ?? 0.0
        var batteryWatts = getValue("PPBR") ?? 0.0

        // 4. Fallback to IOPS power calculation if SMC values are zero
        if systemWatts == 0 || batteryWatts == 0 {
            if let iopsWatts = readIOPSPowerData() {
                if batteryWatts == 0 { batteryWatts = iopsWatts }
                if systemWatts == 0 { systemWatts = iopsWatts }
            }
        }

        // 5. Fallback to registry calculation
        if systemWatts == 0 || batteryWatts == 0 {
            if let volts = batteryInfo.voltage, let amps = batteryInfo.amperage, volts > 0, amps != 0 {
                let calculatedWatts = (Double(abs(volts)) * Double(abs(amps))) / 1_000_000.0
                if batteryWatts == 0 { batteryWatts = calculatedWatts }
                if systemWatts == 0 && !isCharging { systemWatts = calculatedWatts }
            }
        }

        // Use battery watts as system watts if nothing else worked
        if systemWatts == 0 && batteryWatts > 0 {
            systemWatts = batteryWatts
        }

        return SMCPowerData(
            systemWatts: systemWatts,
            batteryWatts: batteryWatts,
            isCharging: isCharging,
            batteryPercent: batteryInfo.percent
        )
    }

    // MARK: - IOPS (IOPowerSources) Methods

    /// Check charging state via IOPowerSources - responds instantly to plug/unplug
    public func checkIOPSChargingState() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return false }

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                // Primary check: Is external power connected? (AC Power vs Battery Power)
                // This updates INSTANTLY when you plug/unplug
                if let powerSourceState = description[kIOPSPowerSourceStateKey] as? String {
                    let isOnACPower = (powerSourceState == kIOPSACPowerValue)
                    let isChargingFlag = description[kIOPSIsChargingKey] as? Bool ?? false

                    // Show charging icon if AC power connected OR actively charging
                    return isOnACPower || isChargingFlag
                }

                // Fallback to just checking IsCharging
                if let isChargingFlag = description[kIOPSIsChargingKey] as? Bool {
                    return isChargingFlag
                }
            }
        }
        return false
    }

    /// Read power data from IOPS (voltage * current)
    private func readIOPSPowerData() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                let current = description[kIOPSCurrentKey] as? Int
                let voltage = description[kIOPSVoltageKey] as? Int

                if let v = voltage, let c = current, v > 0, c != 0 {
                    return (Double(abs(v)) * Double(abs(c))) / 1_000_000.0
                }
            }
        }
        return nil
    }

    // MARK: - Registry Methods (AppleSmartBattery)

    private struct BatteryInfo {
        let isCharging: Bool
        let percent: Int
        let voltage: Int?
        let amperage: Int?
    }

    /// Read battery info from AppleSmartBattery registry
    private func readBatteryInfo() -> BatteryInfo {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return BatteryInfo(isCharging: false, percent: 0, voltage: nil, amperage: nil)
        }
        defer { IOObjectRelease(service) }

        let isCharging = getBoolProperty(service, "IsCharging")
        let curCap = getIntProperty(service, "CurrentCapacity")
        let maxCap = getIntProperty(service, "MaxCapacity")
        let percent = maxCap > 0 ? (curCap * 100) / maxCap : 0

        var amps = getIntProperty(service, "InstantAmperage")
        if amps == 0 { amps = getIntProperty(service, "Amperage") }
        let volts = getIntProperty(service, "Voltage")

        return BatteryInfo(
            isCharging: isCharging,
            percent: percent,
            voltage: volts == 0 ? nil : volts,
            amperage: amps
        )
    }

    private func getIntProperty(_ service: io_service_t, _ key: String) -> Int {
        if let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) {
            return prop.takeRetainedValue() as? Int ?? 0
        }
        return 0
    }

    private func getBoolProperty(_ service: io_service_t, _ key: String) -> Bool {
        if let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) {
            return prop.takeRetainedValue() as? Bool ?? false
        }
        return false
    }
}

