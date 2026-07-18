// Step 7d — real-Kiwi integration coverage for the native-homograph promotion decision (docs/
// plans/context-aware-hanja-conversion.md §10). Mirrors HanjaContextComposingStabilityTests's
// pattern (real Kiwi + repo-path dictionaries/tables, static pipeline calls — no app warm-up
// singletons involved) but drives the FULL step-6 + step-7 gate/promotion pipeline end to end:
// Kiwi analyze -> bestRealtimeSegmentsWithWinningTokens(autoConvertGate:nativeHomographLookup:)
// -> applyContextReranking(autoConvertGate:). RealtimeNativeHomographGateTests already pins this
// logic with hand-built Token fixtures; this file instead pins it against REAL Kiwi tokenization
// and the REAL bundled hanja-context.txt / hanja-native-homograph.txt, so a corpus or tokenizer
// regression that a synthetic-token test can't see is still caught.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class HanjaContextNativeHomographIntegrationTests: XCTestCase {
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

    /// Real bundled step-7a/7b flagged-reading resource, loaded from its repo path (not the
    /// HanjaDictionaryService singleton — mirrors RealtimeNativeHomographGateTests's
    /// testBundledNativeHomographResourceContainsFlagshipReadings loading pattern).
    private static let flaggedReadings: Set<String> = {
        let root = repoRoot()
        guard let contents = try? String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-native-homograph.txt"), encoding: .utf8)
        else { return [] }
        return HanjaDictionaryService.parseNativeHomographReadings(contents: contents)
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

    /// Step 6 gate, wired the same way KiwiAnalysisService.analyzeClause wires it (real decoded
    /// freq-hanjaeo.txt 하위값 via HanjaFrequencyTable.wordFrequency, tag-aware for the NNP
    /// proper-noun evidence axis).
    private static let autoConvertGate: (HanjaCandidate, POSTag) -> Bool = { candidate, tag in
        KiwiAnalysisService.hasAutoConvertWordEvidence(
            candidate, tag: tag,
            wordFrequency: HanjaContextNativeHomographIntegrationTests.freqTable.wordFrequency(for:))
    }

    private static let nativeHomographLookup: (String) -> Bool = {
        HanjaContextNativeHomographIntegrationTests.flaggedReadings.contains($0)
    }

    /// Runs the full production realtime pipeline (Kiwi analyze -> bestRealtimeSegmentsWithWinning-
    /// Tokens -> applyContextReranking) exactly as KiwiAnalysisService.analyzeClause does, using
    /// the real bundled dictionaries/tables loaded directly from the repo (never the app's warm-up
    /// singletons, so this never depends on warm-up ordering).
    private func finalSegments(for clause: String) throws -> [HanjaSegment] {
        let kiwi = try XCTUnwrap(Self.kiwi)
        let results = try kiwi.analyze(
            clause, topN: 3, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
        let best = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
            from: results, in: clause, candidateLookup: Self.candidateLookup,
            hangulUsageLookup: { _ in 0 }, autoConvertGate: Self.autoConvertGate,
            nativeHomographLookup: Self.nativeHomographLookup
        )
        return KiwiAnalysisService.applyContextReranking(
            to: best.segments, clause: clause, dominantMap: Self.dominantMap,
            candidateLookup: Self.candidateLookup, winningTokens: best.winningTokens,
            associationFeatureLookup: { reading, hanja in Self.associationTable[reading]?[hanja] },
            autoConvertGate: Self.autoConvertGate
        )
    }

    private func segment(_ segments: [HanjaSegment], reading: String) -> HanjaSegment? {
        segments.first { $0.normalizedLookupKey == reading }
    }

    /// Same gating pattern as HanjaContextComposingStabilityTests / HanjaContextEvalV2Tests:
    /// self-skips (prints and returns `false`) when the Kiwi model directory is missing, rather
    /// than failing the suite in environments without the bundled models.
    private func requireInfra() -> Bool {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found, skipping.")
            return false
        }
        XCTAssertNotNil(Self.kiwi, "Kiwi failed to build")
        XCTAssertNotNil(Self.hanjaTable, "hanja.txt failed to load")
        XCTAssertFalse(Self.associationTable.isEmpty, "bundled hanja-context.txt must parse to a non-empty table")
        XCTAssertFalse(Self.flaggedReadings.isEmpty, "bundled hanja-native-homograph.txt must parse to a non-empty set")
        return true
    }

    /// Plan §10 scenario 1: "우리 집 수도가 고장났다" — 수도 previews 水道 (flagged, promoted via the
    /// 집/NNG containment/dominance evidence — already pinned by HanjaContextComposingStability-
    /// Tests, reconfirmed here through the full step-6+7 gate pipeline), 고장 previews 故障 (flagged,
    /// promoted via the step-7b collocation signal 나/VV=126 — the reported "고장이 한글로 남음"
    /// defect's fix), and 집 stays hangul (step-6 gate: 集's word evidence is principled-zero,
    /// freq-hanjaeo.txt has no 1-syllable rows).
    func testGojangSuduJipClauseFlagshipPromotions() throws {
        guard requireInfra() else { return }

        let clause = "우리 집 수도가 고장났다"
        let segments = try finalSegments(for: clause)

        let sudo = try XCTUnwrap(segment(segments, reading: "수도"))
        XCTAssertEqual(sudo.previewCandidate?.value, "水道", "수도 must preview 水道")

        let gojang = try XCTUnwrap(segment(segments, reading: "고장"))
        XCTAssertEqual(
            gojang.previewCandidate?.value, "故障",
            "고장 must be promoted to 故障 via the 나/VV collocation evidence (2026-07-11 defect fix)"
        )

        let jip = try XCTUnwrap(segment(segments, reading: "집"))
        XCTAssertNil(jip.previewCandidate, "집 must stay hangul — 集 has no step-6 word evidence")
    }

    /// Plan §10 scenario 2: "구두를 신는다" — no context evidence for 口頭 (신다/신발 context is about
    /// the native word, not the 口頭 candidate), so 구두 must await context evidence rather than
    /// auto-convert.
    func testGuduSindaClauseStaysHangul() throws {
        guard requireInfra() else { return }

        let clause = "구두를 신는다"
        let segments = try finalSegments(for: clause)

        let gudu = try XCTUnwrap(segment(segments, reading: "구두"))
        XCTAssertNil(gudu.previewCandidate, "구두 (shoes context) must not auto-convert to 口頭")
        XCTAssertTrue(gudu.awaitsContextEvidence, "구두 must be flagged as awaiting context evidence")
        XCTAssertTrue(gudu.isConvertible, "candidate panel access must stay available even while suppressed")
    }

    /// Plan §10 scenario 3: "구두로 계약을 전달했다" — the 계약/NNG=69 collocation feature under
    /// 구두:口頭 promotes the preview.
    func testGuduGyeyakClausePromotesToGuduSpokenForm() throws {
        guard requireInfra() else { return }

        let clause = "구두로 계약을 전달했다"
        let segments = try finalSegments(for: clause)

        let gudu = try XCTUnwrap(segment(segments, reading: "구두"))
        XCTAssertEqual(gudu.previewCandidate?.value, "口頭", "구두 must be promoted to 口頭 via the 계약 context")
    }

    /// 2026-07-11 defect: "한국의 수도는 서울이다" — 한국 stayed hangul because 국명·지명 decoded
    /// freq-hanjaeo 하위값 all sit in the ~100 band (韓國 104, 美國 104, 釜山 84), below the step-6
    /// threshold 500. The NNP proper-noun evidence axis (hasAutoConvertWordEvidence's `tag:`)
    /// accepts weak word evidence (하위값 > 0) or a hanja.txt comment for multi-syllable
    /// NNP-tagged segments. 미국·부산 rankings verified against the real dictionary before
    /// asserting (美國 104 > 尾局 74 > 米麴 63; 釜山 84 > 副産 81 > 傅山 80 — both top and both
    /// carrying NNP-axis evidence), so their hard assertions are safe.
    func testHangukSudoSeoulClauseAutoConvertsProperNouns() throws {
        guard requireInfra() else { return }

        let clause = "한국의 수도는 서울이다"
        let segments = try finalSegments(for: clause)

        let hanguk = try XCTUnwrap(segment(segments, reading: "한국"))
        XCTAssertEqual(
            hanguk.previewCandidate?.value, "韓國",
            "한국/NNP must auto-convert via the NNP evidence axis (韓國 하위값 104 < threshold 500)"
        )

        let sudo = try XCTUnwrap(segment(segments, reading: "수도"))
        XCTAssertEqual(sudo.previewCandidate?.value, "首都", "수도 must preview 首都 in the 서울 context")

        // 서울 is a native word with no hanja.txt entry: if the analyzer emits a segment for it at
        // all, it must be non-convertible with no preview.
        if let seoul = segment(segments, reading: "서울") {
            XCTAssertFalse(seoul.isConvertible, "서울 has no dictionary entry and must not be convertible")
            XCTAssertNil(seoul.previewCandidate)
        }

        // 미국·부산 through the same pipeline (separate clause so this stays one realistic
        // sentence each; both tagged NNP per the 2026-07-11 measurements).
        let travelSegments = try finalSegments(for: "미국과 부산을 오간다")
        let miguk = try XCTUnwrap(segment(travelSegments, reading: "미국"))
        XCTAssertEqual(miguk.previewCandidate?.value, "美國")
        let busan = try XCTUnwrap(segment(travelSegments, reading: "부산"))
        XCTAssertEqual(
            busan.previewCandidate?.value, "釜山",
            "부산 must convert via the weak-frequency alternative (釜山 has no hanja.txt comment)"
        )
    }

    /// Plan §10 scenario 4: "지금 뛴다" — 지금 is NOT a flagged native homograph (no non-hanja-origin
    /// stdict/opendict homograph headword), so step 6 alone governs and this is unchanged by step 7.
    func testJigeumClauseUnaffectedByStep7() throws {
        guard requireInfra() else { return }

        let clause = "지금 뛴다"
        let segments = try finalSegments(for: clause)

        let jigeum = try XCTUnwrap(segment(segments, reading: "지금"))
        XCTAssertEqual(jigeum.previewCandidate?.value, "只今", "지금 must auto-convert to 只今, unaffected by step 7")
        XCTAssertFalse(jigeum.awaitsContextEvidence, "지금 must never be flagged — it has no native-word homograph")
    }
}
