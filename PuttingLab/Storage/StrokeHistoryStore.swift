import Foundation

final class StrokeHistoryStore: @unchecked Sendable {
    static let defaultKey = "StrokeHistory_v1"
    static let defaultCap = 50

    let defaults: UserDefaults
    let key: String
    let cap: Int

    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = StrokeHistoryStore.defaultKey,
        cap: Int = StrokeHistoryStore.defaultCap
    ) {
        self.defaults = defaults
        self.key = key
        self.cap = max(1, cap)
    }

    func load() throws -> [StrokeRecord] {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked()
    }

    private func loadLocked() throws -> [StrokeRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([StrokeRecord].self, from: data)
        } catch is DecodingError {
            // Self-heal: a malformed blob (e.g. from a schema change in a future
            // version) used to brick this store — append() does load+save, so a
            // single un-decodable blob meant no new stroke could EVER be saved.
            // Mirror ProfileStore behaviour: treat decode failure as 'empty' and
            // let the next save overwrite the bad blob.
            return []
        }
    }

    /// Atomic load-mutate-save under an internal lock. Spec §8 calls for FIFO eviction
    /// at `cap`. Concurrent appends from multiple actors would lose records without this lock.
    func append(_ record: StrokeRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var current = try loadLocked()
        current.append(record)
        if current.count > cap {
            current.removeFirst(current.count - cap)
        }
        try saveLocked(current)
    }

    func save(_ records: [StrokeRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try saveLocked(records)
    }

    private func saveLocked(_ records: [StrokeRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: key)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
