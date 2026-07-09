// Regression coverage for the composing-tail preview-flip bug: while a trailing syllable is
// still being composed (not yet committed to `rawClauseText`), it must not change an EARLIER,
// already-settled segment's preview. Fixed via KiwiAnalysisService.stableWinningTokens /
// analyzeClause(composingTailStart:), which excludes tokens overlapping the still-composing tail
// from the step-5c association context features.
//     Copyright (C) 2026 Seungjin Lee.
//
// Repro: typing "우리 집 수도가 고장났다" in realtime hanja mode. At "우리 집 수도가 고장" the 수도
// segment previews 水道 (correct, via association 집/NNG=37). Measured mechanism (see git history /
// task notes): appending a bare trailing jamo (e.g. "ㄴ") is harmless (Kiwi tags it SW, not a
// content-morpheme), but once the tail grows into a FULL syllable Kiwi's tokenizer recognizes as a
// content morpheme — "나" tokenizes as 나/VV — a NEW context feature appears that matches 修道's
// association-table row (나/VV=40 > 집/NNG=37), flipping the preview even though "나" is still
// mid-composition (a batchim could still attach, turning it into 낭/낚/났/... instead). This file
// pins that the fix keeps the preview stable while "나"/"났" are the STILL-COMPOSING tail, and
// documents (without asserting a specific value beyond what's needed) that once the tail commits
// to real text the shift is legitimate, not a bug.

import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class HanjaContextComposingStabilityTests: XCTestCase {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let modelDir = repoRoot().appendingPathComponent("woorilee/KiwiModels")
    private static let kiwiModelsAvailable = FileManager.default.fileExists(atPath: modelDir.path)

    private static let kiwi: Kiwi? = {
        guard kiwiModelsAvailable else { return nil }
        return try? KiwiBuilder(modelPath: modelDir.path).build()
    }()

    private static let hanjaTable: HanjaTable? = {
        LibHangul.loadHanjaTable(filename: repoRoot().appendingPathComponent("woorilee/data/hanja/hanja.txt").path)
    }()

    private static let freqTable: HanjaFrequencyTable = {
        let root = repoRoot()
        return HanjaFrequencyTable(
            characterFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanja.txt")],
            wordFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanjaeo.txt")]
        )
    }()

    private static let dominantMap: [String: String] = {
        let root = repoRoot()
        guard let text = try? String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja.txt"), encoding: .utf8)
        else { return [:] }
        return buildDominantHanjaMap(
            dictionaryLines: text.split(separator: "\n", omittingEmptySubsequences: true),
            frequency: freqTable.frequency(for:)
        )
    }()

    private static let associationTable: [String: [String: [String: UInt8]]] = {
        let root = repoRoot()
        guard let contents = try? String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.txt"), encoding: .utf8)
        else { return [:] }
        return HanjaContextAssociationStore.parse(contents: contents)
    }()

    private static func candidateLookup(_ key: String) -> [HanjaCandidate] {
        let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
        if !numericCandidates.isEmpty { return numericCandidates }

        guard let table = hanjaTable, let list = LibHangul.searchHanja(table: table, key: key) else { return [] }
        let seeds: [HanjaCandidateSeed] = (0..<list.getSize()).compactMap { i in
            guard let value = list.getNthValue(i) else { return nil }
            return HanjaCandidateSeed(reading: list.getNthKey(i) ?? key, value: value,
                                      comment: list.getNthComment(i) ?? "", source: .system, baseRank: i)
        }
        let merged = mergeHanjaCandidates(userEntries: [], systemCandidates: seeds,
                                          usageCounts: [:], frequencyLookup: freqTable.frequency(for:))
        return merged.filter { $0.value != $0.reading }
    }

    /// Mirrors KiwiAnalysisService.analyzeClause's body exactly (Kiwi analyze -> bestRealtime-
    /// SegmentsWithWinningTokens -> stableWinningTokens(composingTailStart:) -> applyContext-
    /// Reranking), using the real bundled dominant map + association table by default (pass an
    /// explicit `associationLookup` to override the table — used by the stubbed-lookup plumbing
    /// test), but via the static pipeline directly (like HanjaContextEvalV2Tests) since
    /// KiwiAnalysisService itself is a singleton with a private initializer.
    private func sudoPreview(
        clause: String,
        composingTailStart: Int?,
        associationLookup: ((String, String) -> [String: UInt8]?)? = nil
    ) throws -> String? {
        let kiwi = try XCTUnwrap(Self.kiwi)
        let results = try kiwi.analyze(clause, topN: 3, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
        let best = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
            from: results, in: clause, candidateLookup: Self.candidateLookup, hangulUsageLookup: { _ in 0 }
        )
        let stableTokens = KiwiAnalysisService.stableWinningTokens(
            from: best.winningTokens, composingTailStart: composingTailStart
        )
        let lookup: (String, String) -> [String: UInt8]? = associationLookup ?? { reading, hanja in
            Self.associationTable[reading]?[hanja]
        }
        let reranked = KiwiAnalysisService.applyContextReranking(
            to: best.segments, clause: clause, dominantMap: Self.dominantMap,
            candidateLookup: Self.candidateLookup, winningTokens: stableTokens,
            associationFeatureLookup: lookup
        )
        return reranked.first(where: { $0.normalizedLookupKey == "수도" })?.previewCandidate?.value
    }

    /// The class of instability: while a trailing syllable is STILL COMPOSING (not yet committed
    /// — i.e. it's `tailPreedit`, positioned at/after `composingTailStart`), the 수도 segment's
    /// preview must stay 水道 regardless of how far the composing syllable has progressed (bare
    /// consonant, full open syllable, syllable + batchim).
    func testComposingTailNeverFlipsEarlierSegmentPreview() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found, skipping.")
            return
        }
        XCTAssertNotNil(Self.kiwi, "Kiwi failed to build")
        XCTAssertNotNil(Self.hanjaTable, "hanja.txt failed to load")
        XCTAssertFalse(Self.associationTable.isEmpty)

        let rawClauseText = "우리 집 수도가 고장"
        let composingTailStart = inputUTF16Length(of: rawClauseText)

        // Every one of these is rawClauseText + a still-composing tail (never committed) at the
        // real composingTailStart boundary. All must preview 水道 — this is the flagship
        // regression: "나"/"났" alone (before the fix) flipped the preview to 修道.
        let composingTails = ["", "ㄴ", "나", "났"]
        for tail in composingTails {
            let clause = rawClauseText + tail
            let preview = try sudoPreview(clause: clause, composingTailStart: composingTailStart)
            XCTAssertEqual(
                preview, "水道",
                "composing tail \"\(tail)\" (clause=\"\(clause)\") must not flip the settled 수도 preview"
            )
        }
    }

    /// Regression coverage for the data-quality fix (hanja-context.txt ubiquity filter,
    /// scripts/hanja-context/build_association_table.py): bare 나/VV was a corpus-domain-biased
    /// association feature under 수도:修道 (weighted=40, alongside 오/VV=20, 보/VV=20) — it survived
    /// the within-reading contrast only because 修道-anchor sentences happen to skew narrative
    /// prose while 水道-anchor sentences skew technical prose, not because 나/VV means anything
    /// about monasteries. That let a fully COMMITTED clause (no composing tail at all — the
    /// composing-tail-stability fix above does not apply here, since there is no tail) flip the
    /// 수도 preview to 修道 on real settled text. The table now excludes 나/VV (and its "ilk" —
    /// bare generic VV/VA morphemes above a corpus-wide ubiquity threshold) globally, so this
    /// exact sentence — the reported repro — previews 水道, matching what a human reader means by
    /// "우리 집 수도가 고장났다" (our house's water line broke).
    func testCommittedNaVerbNoLongerFlipsPreviewNowThatItIsAUbiquitousFeature() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found, skipping.")
            return
        }

        let clause = "우리 집 수도가 고장났다"

        let preview = try sudoPreview(clause: clause, composingTailStart: nil)
        XCTAssertEqual(
            preview, "水道",
            "fully committed \"우리 집 수도가 고장났다\" (no composing tail) must preview 水道 — "
                + "나/VV is a banned ubiquitous feature now, not a legitimate 修道 signal"
        )
    }

    /// Sanity check that the composingTailStart plumbing IS the mechanism preventing the flip —
    /// not a coincidence of the shipped table's contents. The bundled hanja-context.txt no longer
    /// carries 나/VV under 수도:修道 (banned by the build script's ubiquity filter, data-quality
    /// fix), so the historical repro can't be driven through the real table anymore. Instead this
    /// injects a STUBBED associationFeatureLookup into the production path (applyContextReranking
    /// takes the lookup as a parameter — no store/singleton involved) that recreates exactly the
    /// historical defect data: 나/VV=40 under 修道 vs 집/NNG=37 under 水道. Real Kiwi analysis of
    /// the same clause then proves both directions: with composingTailStart at the rawClauseText/
    /// tailPreedit boundary the composing 나 cannot vote (preview stays 水道); with nil (pre-fix
    /// behavior) it does vote and flips the preview to 修道. Independent of hanja-context.txt
    /// forever.
    func testComposingTailStartIsWhatPreventsTheFlip_stubbedLookup() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found, skipping.")
            return
        }

        // Synthetic association data mirroring the historical defect (pre-ubiquity-filter table):
        // 나/VV=40 under 修道 out-voted 집/NNG=37 under 水道.
        let stubbedLookup: (String, String) -> [String: UInt8]? = { reading, hanja in
            guard reading == "수도" else { return nil }
            switch hanja {
            case "修道": return ["나/VV": 40]
            case "水道": return ["집/NNG": 37]
            default: return nil
            }
        }

        let rawClauseText = "우리 집 수도가 고장"
        let composingTailStart = inputUTF16Length(of: rawClauseText)
        let clause = rawClauseText + "나"

        // With the boundary: the still-composing 나 is stripped before it can vote — stable.
        let stablePreview = try sudoPreview(
            clause: clause, composingTailStart: composingTailStart, associationLookup: stubbedLookup
        )
        XCTAssertEqual(
            stablePreview, "水道",
            "with composingTailStart at the rawClauseText boundary, the composing 나 must not vote"
        )

        // Without it (nil, pre-fix behavior): 나/VV votes and flips the preview — the plumbing,
        // not the data, is what prevents the flip.
        let flippedPreview = try sudoPreview(
            clause: clause, composingTailStart: nil, associationLookup: stubbedLookup
        )
        XCTAssertEqual(
            flippedPreview, "修道",
            "with composingTailStart nil (pre-fix behavior), the stubbed 나/VV=40 must flip the preview"
        )
    }
}
