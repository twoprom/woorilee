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

    // Regression for the 단계 2 (빈도 디코딩) fix: freq-hanjaeo.txt encodes 분류(1자리) + 하위값(6자리)
    // into a 7-digit Int, so raw values corrupt within-reading order. Decoding via `% 1_000_000`
    // must make the common word 水道 outrank the rarer 囚徒/水稻 for reading 수도.
    // See docs/plans/context-aware-hanja-conversion.md section 3.
    func testWordFrequencyDecodingFixesWithinReadingOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let freq = HanjaFrequencyTable(
            characterFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanja.txt")],
            wordFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanjaeo.txt")]
        )

        XCTAssertEqual(freq.frequency(for: "水道"), 2106, "raw value 4002106 must decode to 하위값 via % 1_000_000")
        XCTAssertEqual(freq.frequency(for: "囚徒"), 1072)
        XCTAssertEqual(freq.frequency(for: "水稻"), 84)
        XCTAssertGreaterThan(freq.frequency(for: "水道"), freq.frequency(for: "囚徒"))
        XCTAssertGreaterThan(freq.frequency(for: "水道"), freq.frequency(for: "水稻"))

        let dictionaryURL = root.appendingPathComponent("woorilee/data/hanja/hanja.txt")
        let table = try XCTUnwrap(LibHangul.loadHanjaTable(filename: dictionaryURL.path))
        let list = try XCTUnwrap(LibHangul.searchHanja(table: table, key: "수도"))
        let seeds: [HanjaCandidateSeed] = (0..<list.getSize()).compactMap { i in
            guard let value = list.getNthValue(i) else { return nil }
            return HanjaCandidateSeed(reading: list.getNthKey(i) ?? "수도", value: value,
                                      comment: list.getNthComment(i) ?? "", source: .system, baseRank: i)
        }
        let merged = mergeHanjaCandidates(userEntries: [], systemCandidates: seeds,
                                          usageCounts: [:], frequencyLookup: freq.frequency(for:))
        let values = merged.map(\.value)
        let waterPipeRank = try XCTUnwrap(values.firstIndex(of: "水道"))
        let prisonerRank = try XCTUnwrap(values.firstIndex(of: "囚徒"))
        let riceRank = try XCTUnwrap(values.firstIndex(of: "水稻"))
        XCTAssertLessThan(waterPipeRank, prisonerRank, "水道 must rank ahead of the rarer 囚徒 after decoding")
        XCTAssertLessThan(waterPipeRank, riceRank, "水道 must rank ahead of the rarer 水稻 after decoding")
    }
}
