//
//  HanjaSettingsStore.swift
//  woorilee
//
//  Created by Codex on 4/22/26.
//

import Foundation

@MainActor
final class HanjaSettingsStore {
    static let shared = HanjaSettingsStore()

    private enum Keys {
        static let useRealtimeHanjaConversion = "useRealtimeHanjaConversion"
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

    private func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return defaults.bool(forKey: key)
    }
}
