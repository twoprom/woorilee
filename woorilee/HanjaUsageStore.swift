//
//  HanjaUsageStore.swift
//  woorilee
//

import Foundation

final class HanjaUsageStore {
    private let storageURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let debounceInterval: TimeInterval
    private let scheduler: DispatchQueue
    private let dateProvider: () -> Date

    private var recordsByKey: [HanjaCandidateKey: HanjaUsageRecord] = [:]
    private var pendingWriteWorkItem: DispatchWorkItem?
    private var hasPendingChanges = false

    init(
        storageURL: URL,
        fileManager: FileManager = .default,
        debounceInterval: TimeInterval = 0.25,
        scheduler: DispatchQueue = .main,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        self.debounceInterval = debounceInterval
        self.scheduler = scheduler
        self.dateProvider = dateProvider

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    deinit {
        pendingWriteWorkItem?.cancel()
    }

    var usageCountsByKey: [HanjaCandidateKey: Int] {
        recordsByKey.reduce(into: [:]) { partialResult, element in
            partialResult[element.key] = element.value.count
        }
    }

    func loadFromDisk() {
        ensureParentDirectoryExistsIfPossible()

        guard fileManager.fileExists(atPath: storageURL.path) else {
            recordsByKey = [:]
            hasPendingChanges = false
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let envelope = try decoder.decode(VersionedEntriesEnvelope<HanjaUsageRecord>.self, from: data)
            recordsByKey = Dictionary(uniqueKeysWithValues: envelope.entries.map { ($0.candidateKey, $0) })
            hasPendingChanges = false
        } catch {
            recordsByKey = [:]
            hasPendingChanges = false
        }
    }

    func recordHangulSelection(lookupKey: String) {
        recordSelection(lookupKey: lookupKey, value: lookupKey)
    }

    func hangulUsageCount(for lookupKey: String) -> Int {
        usageCount(for: HanjaCandidateKey(reading: lookupKey, value: lookupKey))
    }

    func recordSelection(lookupKey: String, value: String) {
        guard !lookupKey.isEmpty, !value.isEmpty else {
            return
        }

        let candidateKey = HanjaCandidateKey(reading: lookupKey, value: value)
        let now = dateProvider()

        if var existingRecord = recordsByKey[candidateKey] {
            existingRecord.count += 1
            existingRecord.lastSelectedAt = now
            recordsByKey[candidateKey] = existingRecord
        } else {
            recordsByKey[candidateKey] = HanjaUsageRecord(
                lookupKey: lookupKey,
                value: value,
                count: 1,
                lastSelectedAt: now
            )
        }

        hasPendingChanges = true
        scheduleWrite()
    }

    func usageCount(for candidateKey: HanjaCandidateKey) -> Int {
        recordsByKey[candidateKey]?.count ?? 0
    }

    func usageRecord(for candidateKey: HanjaCandidateKey) -> HanjaUsageRecord? {
        recordsByKey[candidateKey]
    }

    func flushNow() {
        pendingWriteWorkItem?.cancel()
        pendingWriteWorkItem = nil

        guard hasPendingChanges else {
            return
        }

        do {
            try persist()
            hasPendingChanges = false
        } catch {
            hasPendingChanges = true
        }
    }

    private func scheduleWrite() {
        pendingWriteWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        pendingWriteWorkItem = workItem
        scheduler.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func ensureParentDirectoryExistsIfPossible() {
        try? fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let entries = recordsByKey.values.sorted {
            if $0.lookupKey != $1.lookupKey {
                return $0.lookupKey < $1.lookupKey
            }

            return $0.value < $1.value
        }
        let envelope = VersionedEntriesEnvelope(
            version: HanjaPersonalizationStorage.currentVersion,
            entries: entries
        )
        let data = try encoder.encode(envelope)
        try data.write(to: storageURL, options: .atomic)
    }
}
