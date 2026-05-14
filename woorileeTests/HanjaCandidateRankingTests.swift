// Tests for Hanja candidate ranking logic.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import LibHangul
import XCTest
@testable import woorilee

final class HanjaCandidateRankingTests: XCTestCase {
    private let zeroFrequency: (String) -> Int = { _ in 0 }

    func testUserDefinedEntryReplacesSystemDuplicate() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let userEntries = [
            UserHanjaEntry(
                id: UUID(),
                reading: "한자",
                value: "漢字",
                comment: "user-comment",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        ]
        let systemCandidates = [
            HanjaCandidateSeed(
                reading: "한자",
                value: "漢字",
                comment: "system-comment",
                source: .system,
                baseRank: 0
            ),
            HanjaCandidateSeed(
                reading: "한자",
                value: "漢子",
                comment: "second",
                source: .system,
                baseRank: 1
            )
        ]
        let usageCounts = [
            HanjaCandidateKey(reading: "한자", value: "漢字"): 5,
            HanjaCandidateKey(reading: "한자", value: "漢子"): 5,
        ]

        let merged = mergeHanjaCandidates(
            userEntries: userEntries,
            systemCandidates: systemCandidates,
            usageCounts: usageCounts,
            frequencyLookup: zeroFrequency
        )

        let userOverridden = merged.first { $0.value == "漢字" }
        XCTAssertEqual(userOverridden?.source, .userDefined)
        XCTAssertEqual(userOverridden?.comment, "user-comment")
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeSortsByUsageThenBaseRankThenValueWhenNoFrequency() {
        let systemCandidates = [
            HanjaCandidateSeed(reading: "key", value: "Beta", comment: "", source: .system, baseRank: 2),
            HanjaCandidateSeed(reading: "key", value: "Alpha", comment: "", source: .system, baseRank: 0),
            HanjaCandidateSeed(reading: "key", value: "Zulu", comment: "", source: .system, baseRank: 4),
            HanjaCandidateSeed(reading: "key", value: "Able", comment: "", source: .system, baseRank: 4),
        ]
        let usageCounts = [
            HanjaCandidateKey(reading: "key", value: "Alpha"): 5,
            HanjaCandidateKey(reading: "key", value: "Beta"): 5,
        ]

        let merged = mergeHanjaCandidates(
            userEntries: [],
            systemCandidates: systemCandidates,
            usageCounts: usageCounts,
            frequencyLookup: zeroFrequency
        )

        XCTAssertEqual(merged.map(\.value), ["Alpha", "Beta", "Able", "Zulu"])
    }

    func testUserDefinedCandidatesSortBeforeSystemCandidates() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let userEntries = [
            UserHanjaEntry(
                id: UUID(),
                reading: "key",
                value: "User",
                comment: "",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        ]
        let systemCandidates = [
            HanjaCandidateSeed(reading: "key", value: "System", comment: "", source: .system, baseRank: 0),
        ]
        let usageCounts = [
            HanjaCandidateKey(reading: "key", value: "System"): 99,
        ]

        let merged = mergeHanjaCandidates(
            userEntries: userEntries,
            systemCandidates: systemCandidates,
            usageCounts: usageCounts,
            frequencyLookup: zeroFrequency
        )

        XCTAssertEqual(merged.map(\.value), ["User", "System"])
    }

    func testFrequencyDescendingBreaksTiesAfterUsage() {
        let systemCandidates = [
            HanjaCandidateSeed(reading: "한자", value: "韓子", comment: "", source: .system, baseRank: 2),
            HanjaCandidateSeed(reading: "한자", value: "漢字", comment: "", source: .system, baseRank: 0),
            HanjaCandidateSeed(reading: "한자", value: "漢子", comment: "", source: .system, baseRank: 1),
        ]
        let frequencies: [String: Int] = [
            "漢字": 6_009_096,
            "漢子": 5_000_099,
            "韓子": 2_000_107,
        ]

        let merged = mergeHanjaCandidates(
            userEntries: [],
            systemCandidates: systemCandidates,
            usageCounts: [:],
            frequencyLookup: { frequencies[$0] ?? 0 }
        )

        XCTAssertEqual(merged.map(\.value), ["漢字", "漢子", "韓子"])
    }

    func testUsageCountOutranksFrequency() {
        let systemCandidates = [
            HanjaCandidateSeed(reading: "한자", value: "漢字", comment: "", source: .system, baseRank: 0),
            HanjaCandidateSeed(reading: "한자", value: "漢子", comment: "", source: .system, baseRank: 1),
        ]
        let frequencies: [String: Int] = [
            "漢字": 6_009_096,
            "漢子": 5_000_099,
        ]
        let usageCounts = [
            HanjaCandidateKey(reading: "한자", value: "漢子"): 1,
        ]

        let merged = mergeHanjaCandidates(
            userEntries: [],
            systemCandidates: systemCandidates,
            usageCounts: usageCounts,
            frequencyLookup: { frequencies[$0] ?? 0 }
        )

        XCTAssertEqual(merged.map(\.value), ["漢子", "漢字"])
    }

    func testExactHanjaSearchDoesNotIncludeShorterPrefixReading() throws {
        let dictionaryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("woorilee/data/hanja/hanja.txt")
        let table = try XCTUnwrap(LibHangul.loadHanjaTable(filename: dictionaryURL.path))
        let exactList = try XCTUnwrap(LibHangul.searchHanja(table: table, key: "한국"))
        let prefixList = try XCTUnwrap(LibHangul.searchHanjaPrefix(table: table, key: "한국"))

        let exactReadings = readings(in: exactList)
        XCTAssertGreaterThan(exactReadings.count, 0)
        XCTAssertTrue(exactReadings.allSatisfy { $0 == "한국" })
        XCTAssertFalse(exactReadings.contains("한"))
        XCTAssertTrue(readings(in: prefixList).contains("한"))
    }

    private func readings(in list: HanjaList) -> [String] {
        (0..<list.getSize()).compactMap { list.getNthKey($0) }
    }
}
