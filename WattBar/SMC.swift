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

/// Read-only, serialized access to AppleSMC and the built-in battery registry.
final class SMC {
    static let shared = SMC()
    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var keyInfo: [String: SMCKeyData_t.keyInfo_t] = [:]

    init() { openConnection() }
    deinit { close() }

    private func openConnection() {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return }
        defer { IOObjectRelease(device) }
        if IOServiceOpen(device, mach_task_self_, 0, &conn) != kIOReturnSuccess { conn = 0 }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if conn != 0 { IOServiceClose(conn); conn = 0 }
        keyInfo.removeAll(keepingCapacity: true)
    }

    private func getValue(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: key)
        let info: SMCKeyData_t.keyInfo_t
        if let cached = keyInfo[key] {
            info = cached
        } else {
            input.data8 = SMCKeys.readKeyInfo.rawValue
            guard call(input: &input, output: &output), (1...32).contains(Int(output.keyInfo.dataSize)) else { return nil }
            info = output.keyInfo
            keyInfo[key] = info
        }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCKeys.readBytes.rawValue
        guard call(input: &input, output: &output) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCValueDecoder.decode(type: info.dataType.toString(), bytes: bytes)
    }

    private func call(input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> Bool {
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        let result = IOConnectCallStructMethod(conn, UInt32(SMCKeys.kernelIndex.rawValue), &input,
                                               MemoryLayout<SMCKeyData_t>.stride, &output, &outputSize)
        return result == kIOReturnSuccess && outputSize == MemoryLayout<SMCKeyData_t>.stride && output.result == 0
    }

    func readPowerData() -> PowerReading {
        lock.lock()
        defer { lock.unlock() }
        if conn == 0 { openConnection() }
        let info = readBatteryInfo()
        let current = (info["InstantAmperage"] as? NSNumber) ?? (info["Amperage"] as? NSNumber)
        // Registry negative amperage may be encoded as an unsigned two's-complement NSNumber.
        let currentMA = current.map { Double($0.int64Value) }
        let capacity = (info["CurrentCapacity"] as? NSNumber)?.doubleValue
        let maximum = (info["MaxCapacity"] as? NSNumber)?.doubleValue
        let percent: Double?
        if let capacity, let maximum, maximum > 0 { percent = capacity / maximum * 100 }
        else { percent = nil }
        return PowerReading.resolve(system: getValue("PSTR"), battery: getValue("PPBR"),
            voltageMV: (info["Voltage"] as? NSNumber)?.doubleValue, currentMA: currentMA,
            percent: percent, isCharging: info["IsCharging"] as? Bool ?? false,
            externalPower: info["ExternalConnected"] as? Bool ?? false)
    }

    private func readBatteryInfo() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let properties else { return [:] }
        return properties.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
    }
}
