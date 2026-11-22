import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class HanjaRecommendationPipelineTests: XCTestCase {
    private func candidate(_ value: String, reading: String = "수도", rank: Int = 0) -> HanjaCandidate {
        HanjaCandidate(reading: reading, value: value, comment: "", source: .system,
                       usageCount: 0, frequency: 1000 - rank, baseRank: rank)
    }

    func testSharedAnalysisKeepsPanelLeaderSeparateFromGatedPreview() throws {
        let modelDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("woorilee/KiwiModels")
        let kiwi = try KiwiBuilder(modelPath: modelDir.path).build()
        let good = candidate("故障", reading: "고장")
        let rare = candidate("姑藏", reading: "고장", rank: 1)
        var lookupCounts: [String: Int] = [:]
        let lookup: (String) -> [HanjaCandidate] = {
            lookupCounts[$0, default: 0] += 1
            return $0 == "고장" ? [good, rare] : []
        }
        let association: (String, String) -> [String: Double]? = { reading, value in
            guard reading == "고장" else { return nil }
            return ["자동차/NNG": value == "姑藏" ? 100 : 10]
        }
        let analysis = KiwiAnalysisService.analyzeClause(
            "자동차가 고장 났다", kiwi: kiwi, candidateLookup: lookup,
            hangulUsageLookup: { _ in 0 }, dominantMap: ["자동차": "自動車"],
            associationFeatureLookup: association,
            autoConvertGate: { candidate, _ in candidate.value == "故障" },
            nativeHomographLookup: { $0 == "고장" })
        let segment = try XCTUnwrap(analysis.segments.first { $0.surface == "고장" })
        XCTAssertEqual(lookupCounts["고장"], 1, "top-3 segmentation and reranking must share one dictionary lookup")
        XCTAssertEqual(segment.previewCandidate?.value, "故障")
        XCTAssertEqual(rankSegmentCandidates(lookup("고장"), for: segment,
            associationLookup: association).first?.candidate.value, "姑藏")
        XCTAssertTrue(analysis.clauseContentFeatures.contains("자동차/NNG"))
    }

    func testBrowsingPreservesCandidateAcrossPagesAfterReorder() {
        let candidates = (0..<12).map { candidate("候補\($0)", rank: $0) }
        let segment = HanjaSegment(sourceRange: NSRange(location: 0, length: 2), surface: "수도",
            normalizedLookupKey: "수도", tag: .nng, isConvertible: true, previewCandidate: candidates[0])
        var previous = HanjaCandidatePanelState.realtimeState(segment: segment, index: 0,
            anchorRange: .init(location: 0, length: 2), candidates: candidates, previous: nil)
        previous.moveHighlight(by: 1)
        let reordered = candidates.filter { $0 != candidates[1] } + [candidates[1]]
        let state = HanjaCandidatePanelState.realtimeState(segment: segment, index: 0,
            anchorRange: .init(location: 0, length: 2), candidates: reordered, previous: previous)
        XCTAssertEqual(state.highlightedCandidate?.candidateKey, candidates[1].candidateKey)
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.highlightedIndex, 11)
    }

    func testPanelFollowsPreviewUntilUserBrowsesAndFallsBackWhenCandidateDisappears() {
        let first = candidate("首都"), second = candidate("水道", rank: 1)
        let segment = HanjaSegment(sourceRange: NSRange(location: 0, length: 2), surface: "수도",
            normalizedLookupKey: "수도", tag: .nng, isConvertible: true, previewCandidate: first)
        var previous = HanjaCandidatePanelState.realtimeState(segment: segment, index: 0,
            anchorRange: .init(location: 0, length: 2), candidates: [first, second], previous: nil)
        let changed = segment.replacingPreviewCandidate(second)
        let state = HanjaCandidatePanelState.realtimeState(segment: changed, index: 0,
            anchorRange: previous.anchorRange, candidates: [first, second], previous: previous)
        XCTAssertEqual(state.highlightedCandidate?.value, "水道")
        previous.moveHighlight(by: 1)
        let missing = HanjaCandidatePanelState.realtimeState(segment: segment, index: 0,
            anchorRange: previous.anchorRange, candidates: [first], previous: previous)
        XCTAssertEqual(missing.highlightedCandidate?.value, "首都")
        previous.moveHighlight(by: 1) // second -> Hangul
        let hangul = HanjaCandidatePanelState.realtimeState(segment: segment, index: 0,
            anchorRange: previous.anchorRange, candidates: [second, first], previous: previous)
        XCTAssertTrue(hangul.highlightedIsHangul)
    }

    func testManualMergeExcludesBothOriginalSpansAndUsesSurroundingEvidence() throws {
        let first = candidate("首都"), water = candidate("水道", rank: 1)
        let old = [
            HanjaSegment(sourceRange: .init(location: 0, length: 1), surface: "수", normalizedLookupKey: "수",
                tag: .nng, isConvertible: false, previewCandidate: nil,
                contextFeatures: ["도/NNG", "누수/NNG"]),
            HanjaSegment(sourceRange: .init(location: 1, length: 1), surface: "도", normalizedLookupKey: "도",
                tag: .nng, isConvertible: false, previewCandidate: nil,
                contextFeatures: ["수/NNG", "누수/NNG"])]
        let manual = KiwiAnalysisService.makeManualSegments(boundaries: [], in: "수도",
            candidateLookup: { _ in [first, water] })
        let ranked = rankManualSegments(manual, previousSegments: old,
            candidateLookup: { _ in [first, water] },
            associationLookup: { _, value in ["누수/NNG": value == "水道" ? 100 : 0] })
        let result = try XCTUnwrap(ranked.first)
        XCTAssertEqual(result.sourceRange, .init(location: 0, length: 2))
        XCTAssertEqual(result.contextFeatures, ["누수/NNG"])
        XCTAssertEqual(result.previewCandidate?.value, "水道")
        XCTAssertEqual(rankSegmentCandidates([first, water], for: result,
            associationLookup: { _, value in ["누수/NNG": value == "水道" ? 100 : 0] }).first?.candidate.value, "水道")
    }

    func testManualContextExcludesTargetEvenWhenHostReturnsWholeDocument() {
        let text = "누수 수도 공사"
        let context = manualHanjaSurroundingContext(targetRange: .init(location: 3, length: 2)) { _ in
            (text, .init(location: 0, length: text.utf16.count))
        }
        XCTAssertFalse(context.contains("수도"))
        XCTAssertTrue(context.contains("누수"))
        XCTAssertTrue(context.contains("공사"))
    }

    func testManualContextBoundsRequestsAndQuietlyHandlesFailure() {
        var requests: [NSRange] = []
        let context = manualHanjaSurroundingContext(targetRange: .init(location: 9000, length: 1000)) { range in
            requests.append(range)
            return nil
        }
        XCTAssertEqual(context, "")
        XCTAssertEqual(requests, [.init(location: 8800, length: 200), .init(location: 10000, length: 200)])
        XCTAssertEqual(manualHanjaSurroundingContext(targetRange: .init(location: NSNotFound, length: 0)) { _ in
            XCTFail("invalid ranges must not reach the host")
            return nil
        }, "")
    }
    func testDictionaryAdditionsAreSearchableWithoutChangingDominantMapOrAutoGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("woorilee/data/hanja")
        let dictionaryURL = dir.appendingPathComponent("hanja.txt")
        let table = try XCTUnwrap(LibHangul.loadHanjaTable(filename: dictionaryURL.path))
        let additions = [("유약", "釉藥"), ("음사", "音寫"), ("비선", "秘線"), ("천도", "遷道")]
        for (reading, value) in additions {
            let list = try XCTUnwrap(LibHangul.searchHanja(table: table, key: reading))
            XCTAssertTrue((0..<list.getSize()).contains { list.getNthValue($0) == value })
            let added = candidate(value, reading: reading)
            XCTAssertFalse(KiwiAnalysisService.hasAutoConvertWordEvidence(added, tag: .nng,
                wordFrequency: { _ in 0 }))
        }
        let frequency = HanjaFrequencyTable(characterFrequencyURLs: [dir.appendingPathComponent("freq-hanja.txt")],
            wordFrequencyURLs: [dir.appendingPathComponent("freq-hanjaeo.txt")])
        for (_, value) in additions {
            XCTAssertEqual(frequency.wordFrequency(for: value), 0)
        }
        let lines = try String(contentsOf: dictionaryURL, encoding: .utf8).split(separator: "\n")
        let addedLines = Set(additions.map { "\($0.0):\($0.1):" })
        let oldLines = lines.filter { !addedLines.contains(String($0)) }
        XCTAssertEqual(buildDominantHanjaMap(dictionaryLines: lines, frequency: frequency.frequency(for:)),
            buildDominantHanjaMap(dictionaryLines: oldLines, frequency: frequency.frequency(for:)))
    }

}
