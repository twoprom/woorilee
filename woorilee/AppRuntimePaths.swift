// Centralized on-disk paths for Application Support and bundled resources.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation

enum AppRuntimePaths {
    static let hanjaResourceName = "hanja"
    static let hanjaResourceExtension = "txt"
    static let hanjaResourceSubdirectory = "data/hanja"
    static let hanjaFrequencyCharacterResourceName = "freq-hanja"
    static let hanjaFrequencyWordResourceName = "freq-hanjaeo"
    static let kiwiModelDirectory = "KiwiModels"
    static let applicationSupportDirectoryName = "woorilee"
    static let hanjaSupportDirectoryName = "Hanja"
    static let userHanjaStoreFilename = "user-hanja.json"
    static let usageCountsStoreFilename = "usage-counts.json"

    static func applicationSupportDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func hanjaSupportDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(hanjaSupportDirectoryName, isDirectory: true)
    }

    static func userHanjaStoreURL(fileManager: FileManager = .default) throws -> URL {
        try hanjaSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(userHanjaStoreFilename, isDirectory: false)
    }

    static func usageCountsStoreURL(fileManager: FileManager = .default) throws -> URL {
        try hanjaSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(usageCountsStoreFilename, isDirectory: false)
    }
}
