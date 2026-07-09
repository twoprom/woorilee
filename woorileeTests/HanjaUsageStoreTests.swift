// Tests for Hanja usage store persistence.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import XCTest
@testable import woorilee

final class HanjaUsageStoreTests: XCTestCase {
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

    func testRecordSelectionUpdatesCountLastSelectedAtAndReloadsAfterFlush() {
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)
        var dates = [firstDate, secondDate]
        let storeURL = makeStoreURL()
        let store = HanjaUsageStore(
            storageURL: storeURL,
            debounceInterval: 60,
            dateProvider: { dates.removeFirst() }
        )
        store.loadFromDisk()

        store.recordSelection(lookupKey: "한자", value: "漢字")
        store.recordSelection(lookupKey: "한자", value: "漢字")

        let key = HanjaCandidateKey(reading: "한자", value: "漢字")
        XCTAssertEqual(store.usageCount(for: key), 2)
        XCTAssertEqual(store.usageRecord(for: key)?.lastSelectedAt, secondDate)

        store.flushNow()

        let reloadedStore = HanjaUsageStore(storageURL: storeURL, debounceInterval: 60)
        reloadedStore.loadFromDisk()
        XCTAssertEqual(reloadedStore.usageCount(for: key), 2)
        XCTAssertEqual(reloadedStore.usageRecord(for: key)?.lastSelectedAt, secondDate)
    }

    func testLoadCreatesParentDirectoryWhenStoreIsMissing() {
        let storeURL = makeStoreURL()
        let parentDirectoryURL = storeURL.deletingLastPathComponent()
        let store = HanjaUsageStore(storageURL: storeURL, debounceInterval: 60)

        XCTAssertFalse(FileManager.default.fileExists(atPath: parentDirectoryURL.path))

        store.loadFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: parentDirectoryURL.path))
        XCTAssertTrue(store.usageCountsByKey.isEmpty)
    }

    func testMalformedJSONRecoversAsEmptyStore() throws {
        let storeURL = makeStoreURL()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("not-json".utf8).write(to: storeURL, options: .atomic)

        let store = HanjaUsageStore(storageURL: storeURL, debounceInterval: 60)
        store.loadFromDisk()

        XCTAssertTrue(store.usageCountsByKey.isEmpty)
        XCTAssertNil(store.usageRecord(for: HanjaCandidateKey(reading: "한자", value: "漢字")))
    }

    func testRemoveAllClearsCountsAndPersistsAfterReload() {
        let storeURL = makeStoreURL()
        let store = HanjaUsageStore(storageURL: storeURL, debounceInterval: 60)
        store.loadFromDisk()

        store.recordSelection(lookupKey: "한자", value: "漢字")
        store.recordHangulSelection(lookupKey: "한글")

        XCTAssertFalse(store.usageCountsByKey.isEmpty)
        XCTAssertEqual(store.hangulUsageCount(for: "한글"), 1)

        store.removeAll()

        XCTAssertTrue(store.usageCountsByKey.isEmpty)
        XCTAssertEqual(store.hangulUsageCount(for: "한글"), 0)

        let reloadedStore = HanjaUsageStore(storageURL: storeURL, debounceInterval: 60)
        reloadedStore.loadFromDisk()
        XCTAssertTrue(reloadedStore.usageCountsByKey.isEmpty)
        XCTAssertEqual(reloadedStore.hangulUsageCount(for: "한글"), 0)
    }

    private func makeStoreURL() -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("woorilee", isDirectory: true)
            .appendingPathComponent("Hanja", isDirectory: true)
            .appendingPathComponent("usage-counts.json", isDirectory: false)
    }
}
