import Foundation

final class StrokeHistoryStore: @unchecked Sendable {
    static let defaultKey = "StrokeHistory_v1"
    static let defaultCap = 50

    let defaults: UserDefaults
    let key: String
    let cap: Int

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
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([StrokeRecord].self, from: data)
    }

    func append(_ record: StrokeRecord) throws {
        var current = try load()
        current.append(record)
        if current.count > cap {
            current.removeFirst(current.count - cap)
        }
        try save(current)
    }

    func save(_ records: [StrokeRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
