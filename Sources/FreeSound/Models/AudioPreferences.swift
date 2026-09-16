import Foundation

struct AppAudioSettings: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var balance: Float = 0
    var outputUID: String?
    var favorite = false
    var boost = false

    var needsProcessing: Bool {
        muted || abs(volume - 1) > 0.001 || abs(balance) > 0.001 || outputUID != nil
    }

    mutating func normalize() {
        volume = volume.isFinite ? min(max(volume, 0), boost ? 2 : 1) : 1
        balance = balance.isFinite ? min(max(balance, -1), 1) : 0
    }
}

struct AudioPreferences: Codable {
    var apps: [String: AppAudioSettings] = [:]
    var controlsEnabled = false
    var pinned = false
    var onlyFavorites = false

    static let storageKey = "FreeSound.preferences.v1"

    static func load(from defaults: UserDefaults = .standard) -> AudioPreferences {
        guard let data = defaults.data(forKey: storageKey),
              var preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        for key in preferences.apps.keys { preferences.apps[key]?.normalize() }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
