import Foundation

/// Owns persistence on a serial background queue. Checkpointing is throttled,
/// while flush writes the most recent snapshot and waits for the atomic write.
final class AppActivityHistoryStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WattBar", isDirectory: true)
            .appendingPathComponent("app-activity.json")
    }

    private let url: URL
    private let queue = DispatchQueue(label: "com.wattbar.app-activity", qos: .utility)
    private var pendingHistory: AppActivityHistory?
    private var lastCheckpoint: Date?
    private let errorLock = NSLock()
    private var errorMessage: String?
    private var failure: Error? {
        didSet {
            errorLock.lock()
            errorMessage = failure?.localizedDescription
            errorLock.unlock()
        }
    }
    private static let maximumFileBytes = 32 * 1_024 * 1_024

    init(url: URL = AppActivityHistoryStore.defaultURL) { self.url = url }

    /// Safe to read from the main thread. Errors clear after a successful write.
    var lastError: String? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return errorMessage
    }

    /// A missing file is a new history; invalid/unreadable files are errors.
    func load(now: Date = Date()) throws -> AppActivityHistory {
        try queue.sync {
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    failure = nil
                    return AppActivityHistory()
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumFileBytes else {
                    throw StoreError.fileTooLarge
                }
                let data = try Data(contentsOf: url)
                var history = try JSONDecoder().decode(AppActivityHistory.self, from: data)
                history.prepareAfterLoading(at: now)
                failure = nil
                return history
            } catch {
                failure = error
                throw error
            }
        }
    }

    /// Always retains the newest snapshot; ordinary disk writes occur once a minute.
    func save(_ history: AppActivityHistory, at date: Date = Date(), force: Bool = false) {
        queue.async { [self] in
            pendingHistory = history
            if force || lastCheckpoint == nil || date.timeIntervalSince(lastCheckpoint!) >= 60 || date < lastCheckpoint! {
                writePending(at: date)
            }
        }
    }

    /// Use on sleep and quit after saving the current history. Failed writes leave
    /// the pending snapshot available for retry and return their error to the UI.
    @discardableResult
    func flush(at date: Date = Date()) -> Result<Void, Error> {
        queue.sync {
            writePending(at: date)
            if let failure { return .failure(failure) }
            return .success(())
        }
    }

    private func writePending(at date: Date) {
        guard let history = pendingHistory else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            let data = try encoder.encode(history)
            try data.write(to: url, options: .atomic)
            pendingHistory = nil
            lastCheckpoint = date
            failure = nil
        } catch {
            lastCheckpoint = date // avoid retrying on every sensor tick
            failure = error
        }
    }

    private enum StoreError: LocalizedError {
        case fileTooLarge
        var errorDescription: String? { "The saved app activity is too large to read safely." }
    }
}
