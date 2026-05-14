//
//  UserHanjaStore.swift
//  woorilee
//

import Foundation

final class UserHanjaStore {
    private let storageURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) var entries: [UserHanjaEntry] = []
    private var exactIndex: [String: [UserHanjaEntry]] = [:]

    init(storageURL: URL, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadFromDisk() {
        ensureParentDirectoryExistsIfPossible()

        guard fileManager.fileExists(atPath: storageURL.path) else {
            replaceEntries([])
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let envelope = try decoder.decode(VersionedEntriesEnvelope<UserHanjaEntry>.self, from: data)
            replaceEntries(envelope.entries)
        } catch {
            replaceEntries([])
        }
    }

    @discardableResult
    func save(_ entry: UserHanjaEntry) throws -> UserHanjaEntry {
        let storedEntry: UserHanjaEntry

        if let index = entries.firstIndex(where: { $0.candidateKey == entry.candidateKey }) {
            let existingEntry = entries[index]
            storedEntry = UserHanjaEntry(
                id: existingEntry.id,
                reading: entry.reading,
                value: entry.value,
                comment: entry.comment,
                createdAt: existingEntry.createdAt,
                updatedAt: entry.updatedAt
            )
            entries[index] = storedEntry
        } else {
            storedEntry = entry
            entries.append(storedEntry)
        }

        rebuildIndex()
        try persist()
        return storedEntry
    }

    func delete(candidateKey: HanjaCandidateKey) throws {
        guard let index = entries.firstIndex(where: { $0.candidateKey == candidateKey }) else {
            return
        }

        entries.remove(at: index)
        rebuildIndex()
        try persist()
    }

    func exactEntries(for reading: String) -> [UserHanjaEntry] {
        exactIndex[reading] ?? []
    }

    private func replaceEntries(_ newEntries: [UserHanjaEntry]) {
        entries = newEntries
        rebuildIndex()
    }

    private func rebuildIndex() {
        exactIndex = Dictionary(grouping: entries, by: \.reading)
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

        let envelope = VersionedEntriesEnvelope(
            version: HanjaPersonalizationStorage.currentVersion,
            entries: entries
        )
        let data = try encoder.encode(envelope)
        try data.write(to: storageURL, options: .atomic)
    }
}
