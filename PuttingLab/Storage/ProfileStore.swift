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

    /// Loads the profile. Returns nil for genuinely-missing data AND for corrupted/old data
    /// (e.g. v0.1 profile with renamed fields). Treating decode failures as "needs recalibration"
    /// avoids upgrade-crashes that would otherwise lose the user mid-session.
    func load() throws -> CalibrationProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(CalibrationProfile.self, from: data)
        } catch is DecodingError {
            return nil
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
