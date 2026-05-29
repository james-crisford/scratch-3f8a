import Foundation

enum ProfileStoreError: Error, Equatable {
    case suiteUnavailable
}

final class ProfileStore: @unchecked Sendable {
    static let defaultKey = "CalibrationProfile_v1"

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = ProfileStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    convenience init(suiteName: String, key: String = ProfileStore.defaultKey) throws {
        guard let d = UserDefaults(suiteName: suiteName) else {
            throw ProfileStoreError.suiteUnavailable
        }
        self.init(defaults: d, key: key)
    }

    func save(_ profile: CalibrationProfile) throws {
        let data = try JSONEncoder().encode(profile)
        defaults.set(data, forKey: key)
    }

    func load() throws -> CalibrationProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(CalibrationProfile.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
