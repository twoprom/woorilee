// Menu-backed settings for Hanja conversion preferences.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation

@MainActor
final class HanjaSettingsStore {
    static let shared = HanjaSettingsStore()

    private enum Keys {
        static let useRealtimeHanjaConversion = "useRealtimeHanjaConversion"
        static let useContextHanjaRanking = "useContextHanjaRanking"
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var useRealtimeHanjaConversion: Bool {
        bool(forKey: Keys.useRealtimeHanjaConversion, default: false)
    }

    func setUseRealtimeHanjaConversion(_ enabled: Bool) {
        guard useRealtimeHanjaConversion != enabled else {
            return
        }

        defaults.set(enabled, forKey: Keys.useRealtimeHanjaConversion)
    }

    func toggleUseRealtimeHanjaConversion() {
        setUseRealtimeHanjaConversion(!useRealtimeHanjaConversion)
    }

    var useContextHanjaRanking: Bool {
        bool(forKey: Keys.useContextHanjaRanking, default: true)
    }

    func setUseContextHanjaRanking(_ enabled: Bool) {
        guard useContextHanjaRanking != enabled else {
            return
        }

        defaults.set(enabled, forKey: Keys.useContextHanjaRanking)
    }

    func toggleUseContextHanjaRanking() {
        setUseContextHanjaRanking(!useContextHanjaRanking)
    }

    private func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return defaults.bool(forKey: key)
    }
}
