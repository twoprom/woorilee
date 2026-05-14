// Tests for user-defined Hanja dictionary persistence.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import XCTest
@testable import woorilee

final class UserHanjaStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        let baseURL = FileManager.default.temporaryDirectory
        temporaryDirectoryURL = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func testLoadCreatesParentDirectoryWhenStoreIsMissing() {
        let storeURL = makeStoreURL()
        let parentDirectoryURL = storeURL.deletingLastPathComponent()
        let store = UserHanjaStore(storageURL: storeURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: parentDirectoryURL.path))

        store.loadFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: parentDirectoryURL.path))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSaveUpdateDeleteAndReloadRoundTrip() throws {
        let storeURL = makeStoreURL()
        let store = UserHanjaStore(storageURL: storeURL)
        store.loadFromDisk()

        let createdAt = Date(timeIntervalSince1970: 1_000)
        let firstEntry = UserHanjaEntry(
            id: UUID(),
            reading: "한자",
            value: "漢字",
            comment: "first",
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let savedEntry = try store.save(firstEntry)
        XCTAssertEqual(store.exactEntries(for: "한자"), [savedEntry])

        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let updatedEntry = UserHanjaEntry(
            id: UUID(),
            reading: "한자",
            value: "漢字",
            comment: "updated",
            createdAt: updatedAt,
            updatedAt: updatedAt
        )

        let persistedEntry = try store.save(updatedEntry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(persistedEntry.id, savedEntry.id)
        XCTAssertEqual(persistedEntry.createdAt, savedEntry.createdAt)
        XCTAssertEqual(persistedEntry.updatedAt, updatedAt)
        XCTAssertEqual(store.exactEntries(for: "한자").first?.comment, "updated")

        let reloadedStore = UserHanjaStore(storageURL: storeURL)
        reloadedStore.loadFromDisk()
        XCTAssertEqual(reloadedStore.exactEntries(for: "한자"), [persistedEntry])

        try reloadedStore.delete(candidateKey: HanjaCandidateKey(reading: "한자", value: "漢字"))
        XCTAssertTrue(reloadedStore.entries.isEmpty)

        let deletedReloadStore = UserHanjaStore(storageURL: storeURL)
        deletedReloadStore.loadFromDisk()
        XCTAssertTrue(deletedReloadStore.entries.isEmpty)
    }

    func testMalformedJSONRecoversAsEmptyStore() throws {
        let storeURL = makeStoreURL()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("not-json".utf8).write(to: storeURL, options: .atomic)

        let store = UserHanjaStore(storageURL: storeURL)
        store.loadFromDisk()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.exactEntries(for: "한자").isEmpty)
    }

    private func makeStoreURL() -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("woorilee", isDirectory: true)
            .appendingPathComponent("Hanja", isDirectory: true)
            .appendingPathComponent("user-hanja.json", isDirectory: false)
    }
}
