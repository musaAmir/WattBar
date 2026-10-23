import Darwin
import Foundation

/// Call on a single background queue. No task ports, privileges, or helper tools.
/// These kernel counters cover CPU energy only, excluding GPU/display/network.
final class AppActivityMonitor {
    static let sampleInterval: TimeInterval = 5
    private(set) var supportsEnergy = false
    private var lastSampleDate: Date?
    private var accumulator = AppActivityDeltaAccumulator()
    private var supportsVersion6: Bool?
    private var processes: [pid_t: (start: UInt64, executable: UUID, identity: AppActivityIdentity)] = [:]
    private var identities: [String: AppActivityIdentity] = [:]
    private let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    func breakContinuity() {
        lastSampleDate = nil
        accumulator.breakContinuity()
    }

    /// nil means collecting a baseline, throttled, or a gap; it is not zero use.
    func sample(at date: Date = Date()) -> AppActivitySample? {
        if let lastSampleDate {
            let elapsed = date.timeIntervalSince(lastSampleDate)
            if elapsed >= 0 && elapsed < Self.sampleInterval { return nil }
        }
        lastSampleDate = date

        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else {
            accumulator.breakContinuity()
            return nil
        }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 128)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, capacity) }
        guard count > 0 else {
            accumulator.breakContinuity()
            return nil
        }

        var counters: [AppProcessCounter] = []
        var liveProcesses: [pid_t: (start: UInt64, executable: UUID, identity: AppActivityIdentity)] = [:]
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            guard let usage = readUsage(pid) else { continue }
            let identity: AppActivityIdentity
            if let cached = processes[pid], cached.start == usage.start,
               cached.executable == usage.executable {
                identity = cached.identity
            } else if let resolved = identityForProcess(pid) {
                identity = resolved
            } else {
                continue
            }
            liveProcesses[pid] = (usage.start, usage.executable, identity)
            if let energy = usage.energy, energy > 0 { supportsEnergy = true }
            counters.append(AppProcessCounter(pid: pid, startTime: usage.start, identity: identity,
                userTime: usage.user, systemTime: usage.system, energyNanojoules: usage.energy))
        }
        processes = liveProcesses
        guard !counters.isEmpty else {
            accumulator.breakContinuity()
            return nil
        }
        return accumulator.record(counters, at: date, secondsPerTick: secondsPerTick,
                                  supportsEnergy: supportsEnergy)
    }

    private struct Usage {
        let start: UInt64
        let executable: UUID
        let user: UInt64
        let system: UInt64
        let energy: UInt64?
    }

    private func readUsage(_ pid: pid_t) -> Usage? {
        // Probe our own process once: failure on another user's process does not
        // mean the OS lacks this flavor. Unsupported older OSes use CPU time.
        if supportsVersion6 == nil {
            var ownUsage = rusage_info_v6()
            supportsVersion6 = read(pid: getpid(), flavor: RUSAGE_INFO_V6, into: &ownUsage) == 0
        }
        if supportsVersion6 == true {
            var usage = rusage_info_v6()
            guard read(pid: pid, flavor: RUSAGE_INFO_V6, into: &usage) == 0 else { return nil }
            return Usage(start: usage.ri_proc_start_abstime, executable: UUID(uuid: usage.ri_uuid), user: usage.ri_user_time,
                         system: usage.ri_system_time, energy: usage.ri_energy_nj)
        }
        var usage = rusage_info_v0()
        guard read(pid: pid, flavor: RUSAGE_INFO_V0, into: &usage) == 0 else { return nil }
        return Usage(start: usage.ri_proc_start_abstime, executable: UUID(uuid: usage.ri_uuid), user: usage.ri_user_time,
                     system: usage.ri_system_time, energy: nil)
    }

    private func read<T>(pid: pid_t, flavor: Int32, into usage: inout T) -> Int32 {
        // libproc's historical pointer typedef is misleading: it writes the
        // complete struct into this buffer, not through an extra pointer.
        withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, flavor, $0)
            }
        }
    }

    private func identityForProcess(_ pid: pid_t) -> AppActivityIdentity? {
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN); Swift cannot import
        // that expression macro from sys/proc_info.h.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = UInt32(path.count)
        guard path.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, capacity) }) > 0 else {
            return nil
        }
        let executablePath = String(cString: path)
        let bundleURL = AppActivityIdentity.outermostAppURL(for: executablePath)
        let key = bundleURL?.path ?? executablePath
        if let cached = identities[key] { return cached }
        let identity: AppActivityIdentity
        if let bundleURL {
            let bundle = Bundle(url: bundleURL)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? bundleURL.deletingPathExtension().lastPathComponent
            identity = AppActivityIdentity(identifier: bundle?.bundleIdentifier ?? "app:\(key)",
                                           name: name, bundleURL: bundleURL)
        } else {
            identity = AppActivityIdentity(identifier: "process:\(key)",
                name: URL(fileURLWithPath: executablePath).lastPathComponent, bundleURL: nil)
        }
        // Avoid retaining an unbounded path cache during long-running sessions.
        if identities.count >= 2_048 { identities.removeAll(keepingCapacity: true) }
        identities[key] = identity
        return identity
    }
}
