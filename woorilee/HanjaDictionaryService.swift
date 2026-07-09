// Loads and queries the bundled hanja dictionary.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import LibHangul

final class HanjaFrequencyTable {
    private let frequencies: [String: Int]

    static let empty = HanjaFrequencyTable(frequencies: [:])

    init(frequencies: [String: Int]) {
        self.frequencies = frequencies
    }

    // freq-hanja.txt (character frequency) stores a plain Int. freq-hanjaeo.txt (word frequency)
    // encodes 분류(1자리) + 하위값(6자리) into a 7-digit Int; only the decoded 하위값 (`value % 1_000_000`)
    // is comparable within a reading. Branch by source URL, not digit count. See
    // docs/plans/context-aware-hanja-conversion.md section 3 (단계 2 — 빈도 디코딩).
    convenience init(characterFrequencyURLs: [URL], wordFrequencyURLs: [URL]) {
        var merged: [String: Int] = [:]
        merged.reserveCapacity(256_000)
        func ingest(_ urls: [URL], decodeWordFrequency: Bool) {
            for url in urls {
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let separator = line.firstIndex(of: ":") else {
                        continue
                    }
                    let key = String(line[..<separator])
                    let valueSubstring = line[line.index(after: separator)...]
                    guard let parsed = Int(valueSubstring) else {
                        continue
                    }
                    let value = decodeWordFrequency ? parsed % 1_000_000 : parsed
                    if let existing = merged[key] {
                        if value > existing {
                            merged[key] = value
                        }
                    } else {
                        merged[key] = value
                    }
                }
            }
        }
        ingest(characterFrequencyURLs, decodeWordFrequency: false)
        ingest(wordFrequencyURLs, decodeWordFrequency: true)
        self.init(frequencies: merged)
    }

    var count: Int { frequencies.count }

    func frequency(for value: String) -> Int {
        frequencies[value] ?? 0
    }
}

@MainActor
final class HanjaDictionaryService {
    enum Status: Equatable {
        case uninitialized
        case loading
        case ready
        case unavailable(String)
    }

    static let shared = HanjaDictionaryService()

    private(set) var status: Status = .uninitialized
    private(set) var table: HanjaTable?
    private(set) var dictionaryURL: URL?
    private(set) var frequencyTable: HanjaFrequencyTable?
    private(set) var userHanjaStore: UserHanjaStore?
    private(set) var usageStore: HanjaUsageStore?
    /// 읽기 → 지배 한자 매핑 (step 4 — see docs/plans/context-aware-hanja-conversion.md §5).
    /// Built once at warm-up from the bundled dictionary + word frequency table; nil until warm-up
    /// resolves, and stays nil if the word frequency table didn't load (nothing to rank dominance by).
    private(set) var dominantHanjaMap: [String: String]?
    private var pendingWarmUpCompletions: [() -> Void] = []

    private init() {}

    var isAvailable: Bool {
        if case .ready = status {
            return true
        }

        return false
    }

    var isLoading: Bool {
        if case .loading = status {
            return true
        }

        return false
    }

    func warmUp(completion: (() -> Void)? = nil) {
        if let completion {
            pendingWarmUpCompletions.append(completion)
        }

        switch status {
        case .ready, .unavailable:
            drainPendingWarmUpCompletions()
            return
        case .loading:
            return
        case .uninitialized:
            break
        }

        status = .loading
        let bundle = Bundle.main

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loadedDictionaryURL = bundle.url(
                forResource: AppRuntimePaths.hanjaResourceName,
                withExtension: AppRuntimePaths.hanjaResourceExtension,
                subdirectory: AppRuntimePaths.hanjaResourceSubdirectory
            )
            let loadedTable = loadedDictionaryURL.flatMap { dictionaryURL in
                LibHangul.loadHanjaTable(filename: dictionaryURL.path)
            }
            let characterFrequencyURLs: [URL] = [AppRuntimePaths.hanjaFrequencyCharacterResourceName].compactMap { name in
                bundle.url(
                    forResource: name,
                    withExtension: AppRuntimePaths.hanjaResourceExtension,
                    subdirectory: AppRuntimePaths.hanjaResourceSubdirectory
                )
            }
            let wordFrequencyURLs: [URL] = [AppRuntimePaths.hanjaFrequencyWordResourceName].compactMap { name in
                bundle.url(
                    forResource: name,
                    withExtension: AppRuntimePaths.hanjaResourceExtension,
                    subdirectory: AppRuntimePaths.hanjaResourceSubdirectory
                )
            }
            let loadedFrequencyTable = HanjaFrequencyTable(
                characterFrequencyURLs: characterFrequencyURLs,
                wordFrequencyURLs: wordFrequencyURLs
            )
            var loadedDominantHanjaMap: [String: String]?
            if !wordFrequencyURLs.isEmpty, let loadedDictionaryURL,
               let dictionaryContents = try? String(contentsOf: loadedDictionaryURL, encoding: .utf8) {
                loadedDominantHanjaMap = buildDominantHanjaMap(
                    dictionaryLines: dictionaryContents.split(separator: "\n", omittingEmptySubsequences: true),
                    frequency: loadedFrequencyTable.frequency(for:)
                )
            }
            let resolvedStatus: Status
            if let loadedDictionaryURL {
                if loadedTable != nil {
                    resolvedStatus = .ready
                } else {
                    resolvedStatus = .unavailable("Failed to load hanja dictionary from \(loadedDictionaryURL.path)")
                }
            } else {
                resolvedStatus = .unavailable("Bundled hanja dictionary was not found at \(AppRuntimePaths.hanjaResourceSubdirectory)/\(AppRuntimePaths.hanjaResourceName).\(AppRuntimePaths.hanjaResourceExtension)")
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    let loadedUserStore = Self.loadUserHanjaStore()
                    let loadedUsageStore = Self.loadUsageStore()
                    self.dictionaryURL = loadedDictionaryURL
                    self.table = loadedTable
                    self.frequencyTable = loadedFrequencyTable
                    self.userHanjaStore = loadedUserStore
                    self.usageStore = loadedUsageStore
                    self.dominantHanjaMap = loadedDominantHanjaMap
                    self.status = resolvedStatus
                    self.drainPendingWarmUpCompletions()
                }
            }
        }
    }

    func exactCandidates(for key: String) -> [HanjaCandidate] {
        candidates(for: key) { table in
            LibHangul.searchHanja(table: table, key: key)
        }
    }

    func prefixCandidates(for key: String) -> [HanjaCandidate] {
        candidates(for: key) { table in
            LibHangul.searchHanjaPrefix(table: table, key: key)
        }
    }

    func manualLookup(for target: ManualHanjaTarget) -> ManualHanjaLookupResult {
        let candidates = exactCandidates(for: target.sourceText)
        let hangulUsage = hangulUsageCount(for: target.sourceText)
        let topHanjaUsage = candidates.first?.usageCount ?? 0
        let highlightedIsHangul = hangulUsage > 0 && hangulUsage >= topHanjaUsage
        return ManualHanjaLookupResult(
            state: HanjaCandidatePanelState(
                mode: .manual(sourceText: target.sourceText, replacementRange: target.replacementRange),
                anchorRange: target.anchorRange,
                candidates: candidates,
                highlightedIsHangul: highlightedIsHangul
            ),
            lookupKey: target.sourceText
        )
    }

    func recordSelection(lookupKey: String, value: String) {
        usageStore?.recordSelection(lookupKey: lookupKey, value: value)
    }

    func recordHangulSelection(lookupKey: String) {
        usageStore?.recordHangulSelection(lookupKey: lookupKey)
    }

    func hangulUsageCount(for lookupKey: String) -> Int {
        usageStore?.hangulUsageCount(for: lookupKey) ?? 0
    }

    func flushUsageWrites() {
        usageStore?.flushNow()
    }

    func resetUsageData() {
        usageStore?.removeAll()
    }

    private func candidates(
        for key: String,
        search: (HanjaTable) -> HanjaList?
    ) -> [HanjaCandidate] {
        guard !key.isEmpty, let table else {
            return []
        }

        let userEntries = userHanjaStore?.exactEntries(for: key) ?? []
        let systemCandidates = makeSystemCandidates(from: search(table), defaultReading: key)
        let usageCounts = usageStore?.usageCountsByKey ?? [:]
        let frequencyTable = self.frequencyTable ?? .empty
        let merged = mergeHanjaCandidates(
            userEntries: userEntries,
            systemCandidates: systemCandidates,
            usageCounts: usageCounts,
            frequencyLookup: frequencyTable.frequency(for:)
        )
        return merged.filter { $0.value != $0.reading }
    }

    private func makeSystemCandidates(
        from list: HanjaList?,
        defaultReading: String
    ) -> [HanjaCandidateSeed] {
        guard let list else {
            return []
        }

        return (0..<list.getSize()).compactMap { index in
            guard let value = list.getNthValue(index) else {
                return nil
            }

            return HanjaCandidateSeed(
                reading: list.getNthKey(index) ?? defaultReading,
                value: value,
                comment: list.getNthComment(index) ?? "",
                source: .system,
                baseRank: index
            )
        }
    }

    private static func loadUserHanjaStore(fileManager: FileManager = .default) -> UserHanjaStore? {
        guard let storageURL = try? AppRuntimePaths.userHanjaStoreURL(fileManager: fileManager) else {
            return nil
        }

        let store = UserHanjaStore(storageURL: storageURL, fileManager: fileManager)
        store.loadFromDisk()
        return store
    }

    private static func loadUsageStore(fileManager: FileManager = .default) -> HanjaUsageStore? {
        guard let storageURL = try? AppRuntimePaths.usageCountsStoreURL(fileManager: fileManager) else {
            return nil
        }

        let store = HanjaUsageStore(storageURL: storageURL, fileManager: fileManager)
        store.loadFromDisk()
        return store
    }

    private func drainPendingWarmUpCompletions() {
        guard !pendingWarmUpCompletions.isEmpty else {
            return
        }

        let completions = pendingWarmUpCompletions
        pendingWarmUpCompletions.removeAll()
        for completion in completions {
            completion()
        }
    }
}
