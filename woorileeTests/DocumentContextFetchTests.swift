// Tests for step R1b: cursor-adjacent committed-document-text fetch.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/hanja-context-scaling-plan.md §6 (R1b). Six groups per the R1b implementation
// spec §4: (1) documentContextWindow pure truncation, (2) FakeIMKTextInput fetch + snapshot union,
// (3) quiet failure fallback (identical to R1a's empty-session behavior), (4) once-per-composition
// guarantee, (5) real-Kiwi feature-space + end-to-end session-ranking effect, (6) eval/full-suite
// invariance — verified by the overall test run, not a dedicated method here.

import AppKit
import InputMethodKit
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class DocumentContextFetchTests: XCTestCase {
    // MARK: - Group 1: documentContextWindow pure truncation

    func testWindowWithNoBoundariesKeepsWholeText() {
        let text = "경계가전혀없는하나의긴조각텍스트"
        XCTAssertEqual(documentContextWindow(from: text), text)
    }

    func testWindowWithOneBoundaryKeepsWholeText() {
        let text = "첫문장이다.그다음미완조각"
        XCTAssertEqual(documentContextWindow(from: text), text)
    }

    func testWindowWithTwoBoundariesKeepsWholeText() {
        let text = "첫문장이다.둘째문장이다.그다음미완조각"
        XCTAssertEqual(documentContextWindow(from: text), text)
    }

    func testWindowWithThreeBoundariesCutsBeforeTheThirdFromLastBoundary() {
        // 3 boundaries -> cut before the boundary that starts the last TWO sentences (첫문장 is
        // dropped; 둘째문장/셋째문장 + the trailing fragment survive).
        let text = "첫문장이다.둘째문장이다.셋째문장이다.넷째미완조각"
        XCTAssertEqual(documentContextWindow(from: text), "둘째문장이다.셋째문장이다.넷째미완조각")
    }

    func testWindowWithFourBoundariesStillKeepsOnlyLastTwoSentencesPlusFragment() {
        let text = "A.B.C.D.마지막조각"
        // Boundaries after A, B, C, D. Keep from the boundary after B onward: "C.D.마지막조각".
        XCTAssertEqual(documentContextWindow(from: text), "C.D.마지막조각")
    }

    func testWindowWithEmptyStringReturnsEmpty() {
        XCTAssertEqual(documentContextWindow(from: ""), "")
    }

    func testWindowCapsAt200UTF16UnitsKeepingTheTrailingSlice() {
        let longText = String(repeating: "가", count: 250)
        let result = documentContextWindow(from: longText)
        XCTAssertEqual(result.utf16.count, 200)
        XCTAssertEqual(result, String(repeating: "가", count: 200))
    }

    /// Surrogate-boundary defense: constructs a 202-UTF16-unit string whose naive 200-cap cut
    /// point (index 2) falls INSIDE a surrogate pair (an emoji at indices [1, 3)). The cap must
    /// snap forward past the whole emoji rather than emit an invalid lone low-surrogate.
    func testWindowCapDoesNotSplitASurrogatePair() {
        let emoji = "😀"
        XCTAssertEqual(emoji.utf16.count, 2, "precondition: emoji must be a 2-unit surrogate pair")
        let text = "a" + emoji + String(repeating: "b", count: 199)
        XCTAssertEqual(text.utf16.count, 202)

        let result = documentContextWindow(from: text)

        XCTAssertFalse(result.contains(emoji), "the split emoji must be dropped, not truncated into an invalid half")
        XCTAssertEqual(result, String(repeating: "b", count: 199))
        XCTAssertLessThanOrEqual(result.utf16.count, 200)
        // Round-trips cleanly through UTF-16 (no isolated surrogate half survives).
        XCTAssertEqual(String(decoding: Array(result.utf16), as: UTF16.self), result)
    }

    // MARK: - Test harness (Groups 2-4)

    private func makeFetchHarness(
        documentText: String?,
        selectedRange overrideSelectedRange: NSRange? = nil,
        analyzeDocumentContext: @escaping (String) -> [String] = { _ in [] },
        scheduleImmediately: Bool = true
    ) -> (session: InputSession, engine: InputCompositionEngine, client: FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        if let documentText {
            client.attributedSubstringHandler = { range in
                guard let swiftRange = Range(range, in: documentText) else { return nil }
                return NSAttributedString(string: String(documentText[swiftRange]))
            }
            client.stubbedSelectedRange = overrideSelectedRange
                ?? NSRange(location: (documentText as NSString).length, length: 0)
        } else {
            client.stubbedSelectedRange = overrideSelectedRange ?? NSRange(location: 10, length: 0)
        }

        let session = InputSession()
        let engine = InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { _, _, _ in RealtimeClauseAnalysis(segments: [], clauseContentFeatures: []) },
            analyzeManualClause: { _, _ in [] },
            analyzeDocumentContext: analyzeDocumentContext,
            flushRealtimeUsageEvents: { _ in },
            updateComposition: {},
            debugLog: { _ in },
            scheduleDocumentContextAnalysis: scheduleImmediately ? { $0() } : { _ in }
        )
        return (session, engine, client)
    }

    // MARK: - Group 2: fetch + snapshot union

    func testFetchPopulatesDocumentContextFeaturesWithImmediateScheduling() throws {
        let harness = makeFetchHarness(
            documentText: "이미 확정된 문장입니다.",
            analyzeDocumentContext: { _ in ["확정/NNG", "문장/NNG"] }
        )
        harness.session.appendCommittedTextToRealtimeClause("가")

        harness.engine.fetchDocumentContextIfNeeded()

        XCTAssertTrue(harness.session.documentContextFetchAttempted)
        let scoring = try XCTUnwrap(harness.session.sessionScoringInputs)
        XCTAssertTrue(scoring.vocabularyFeatures.isSuperset(of: ["확정/NNG", "문장/NNG"]))
    }

    func testSessionScoringInputsUnionsSessionBufferAndDocumentContextFeatures() throws {
        let harness = makeFetchHarness(
            documentText: "이미 확정된 문장입니다.",
            analyzeDocumentContext: { _ in ["문서형태소/NNG"] }
        )

        // Seed hanjaSessionContext's vocabulary via the R1a commit hook directly (no real Kiwi
        // dependency needed for this test).
        harness.session.appendCommittedTextToRealtimeClause("한국")
        let candidate = HanjaCandidate(
            reading: "한국", value: "韓國", comment: "", source: .system, usageCount: 0, frequency: 0, baseRank: 0
        )
        let segment = HanjaSegment(
            sourceRange: NSRange(location: 0, length: 2), surface: "한국", normalizedLookupKey: "한국",
            tag: .nnp, isConvertible: true, previewCandidate: candidate
        )
        harness.session.updateRealtimeAnalysis(segments: [segment], clauseContentFeatures: ["세션형태소/NNG"])
        harness.session.recordRealtimeCommitToSessionContext()

        harness.engine.fetchDocumentContextIfNeeded()

        let scoring = try XCTUnwrap(harness.session.sessionScoringInputs)
        XCTAssertTrue(scoring.vocabularyFeatures.contains("세션형태소/NNG"), "must retain the session-buffer vocabulary")
        XCTAssertTrue(scoring.vocabularyFeatures.contains("문서형태소/NNG"), "must add the document-context vocabulary")
    }

    /// Confirms the client IPC (`attributedSubstring`) happens before `updateComposition` — the
    /// point where production sets marked text — so the fetch never reads a cursor position
    /// contaminated by this composition's own marked text.
    func testFetchRunsBeforeUpdateCompositionOnTheFirstDisplayUpdate() {
        var callOrder: [String] = []
        let client = FakeIMKTextInput()
        let documentText = "이전 텍스트"
        client.stubbedSelectedRange = NSRange(location: (documentText as NSString).length, length: 0)
        client.attributedSubstringHandler = { range in
            callOrder.append("attributedSubstring")
            guard let swiftRange = Range(range, in: documentText) else { return nil }
            return NSAttributedString(string: String(documentText[swiftRange]))
        }

        let session = InputSession()
        let engine = InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { _, _, _ in RealtimeClauseAnalysis(segments: [], clauseContentFeatures: []) },
            analyzeManualClause: { _, _ in [] },
            analyzeDocumentContext: { _ in [] },
            flushRealtimeUsageEvents: { _ in },
            updateComposition: { callOrder.append("updateComposition") },
            debugLog: { _ in },
            scheduleDocumentContextAnalysis: { $0() }
        )

        session.appendCommittedTextToRealtimeClause("가")
        engine.updateDisplay()

        XCTAssertEqual(callOrder.first, "attributedSubstring", "the fetch's IPC must run before updateComposition (setMarkedText)")
        XCTAssertTrue(session.documentContextFetchAttempted)
    }

    // MARK: - Group 3: quiet failure fallback (identical to R1a's empty-session behavior)

    func testFetchFailsQuietlyWhenAttributedSubstringReturnsNil() {
        let harness = makeFetchHarness(documentText: nil, selectedRange: NSRange(location: 10, length: 0))
        harness.session.appendCommittedTextToRealtimeClause("가")

        harness.engine.fetchDocumentContextIfNeeded()

        XCTAssertTrue(harness.session.documentContextFetchAttempted)
        XCTAssertNil(
            harness.session.sessionScoringInputs,
            "no session buffer and a failed document fetch => nil, exactly R1a's empty-session behavior"
        )
    }

    func testFetchFailsQuietlyWhenSelectedRangeIsNotFound() {
        let harness = makeFetchHarness(
            documentText: "본문 텍스트",
            selectedRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.session.appendCommittedTextToRealtimeClause("가")

        harness.engine.fetchDocumentContextIfNeeded()

        XCTAssertNil(harness.session.sessionScoringInputs)
    }

    func testFetchFailsQuietlyWhenCursorIsAtDocumentStart() {
        let harness = makeFetchHarness(
            documentText: "본문 텍스트",
            selectedRange: NSRange(location: 0, length: 0)
        )
        harness.session.appendCommittedTextToRealtimeClause("가")

        harness.engine.fetchDocumentContextIfNeeded()

        XCTAssertNil(harness.session.sessionScoringInputs)
    }

    // MARK: - Group 4: fetch happens at most once per composition

    func testFetchOnlyRunsOncePerCompositionAcrossRepeatedCalls() {
        var callCount = 0
        let harness = makeFetchHarness(
            documentText: "이미 확정된 문장입니다.",
            analyzeDocumentContext: { _ in
                callCount += 1
                return ["형태소/NNG"]
            }
        )
        harness.session.appendCommittedTextToRealtimeClause("가")

        harness.engine.fetchDocumentContextIfNeeded()
        harness.engine.fetchDocumentContextIfNeeded()
        harness.engine.fetchDocumentContextIfNeeded()

        XCTAssertEqual(callCount, 1, "repeated calls within the same composition must not re-fetch")
    }

    func testFetchOnlyRunsOnceAcrossMultipleUpdateDisplayCallsInOneComposition() {
        var fetchIPCCallCount = 0
        let client = FakeIMKTextInput()
        let documentText = "이전 텍스트"
        client.stubbedSelectedRange = NSRange(location: (documentText as NSString).length, length: 0)
        client.attributedSubstringHandler = { range in
            fetchIPCCallCount += 1
            guard let swiftRange = Range(range, in: documentText) else { return nil }
            return NSAttributedString(string: String(documentText[swiftRange]))
        }

        let session = InputSession()
        let engine = InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { _, _, _ in RealtimeClauseAnalysis(segments: [], clauseContentFeatures: []) },
            analyzeManualClause: { _, _ in [] },
            analyzeDocumentContext: { _ in [] },
            flushRealtimeUsageEvents: { _ in },
            updateComposition: {},
            debugLog: { _ in },
            scheduleDocumentContextAnalysis: { $0() }
        )

        session.appendCommittedTextToRealtimeClause("가")
        engine.updateDisplay()
        XCTAssertTrue(session.process("r"))
        engine.updateDisplay()
        XCTAssertTrue(session.process("k"))
        engine.updateDisplay()

        XCTAssertEqual(fetchIPCCallCount, 1, "multiple keystrokes within one composition must fetch only once")
    }

    func testFetchRefetchesAfterResetStartsANewComposition() {
        var callCount = 0
        let harness = makeFetchHarness(
            documentText: "이미 확정된 문장입니다.",
            analyzeDocumentContext: { _ in
                callCount += 1
                return ["형태소/NNG"]
            }
        )
        harness.session.appendCommittedTextToRealtimeClause("가")
        harness.engine.fetchDocumentContextIfNeeded()
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(harness.session.documentContextFetchAttempted)

        harness.session.reset() // simulates a commit ending the composition
        XCTAssertFalse(harness.session.documentContextFetchAttempted, "reset() must clear the fetch-attempted flag")
        XCTAssertNil(harness.session.sessionScoringInputs, "reset() must also drop the fetched features")

        harness.session.appendCommittedTextToRealtimeClause("나")
        harness.engine.fetchDocumentContextIfNeeded()

        XCTAssertEqual(callCount, 2, "a new composition after reset() must fetch again")
    }

    func testClearRealtimeClauseStateAlsoResetsDocumentContext() {
        let harness = makeFetchHarness(
            documentText: "이미 확정된 문장입니다.",
            analyzeDocumentContext: { _ in ["형태소/NNG"] }
        )
        harness.session.appendCommittedTextToRealtimeClause("가")
        harness.engine.fetchDocumentContextIfNeeded()
        XCTAssertNotNil(harness.session.sessionScoringInputs)

        harness.session.clearRealtimeClauseState()

        XCTAssertFalse(harness.session.documentContextFetchAttempted)
        XCTAssertNil(harness.session.sessionScoringInputs)
    }

    // MARK: - Group 5: real Kiwi integration (skips if the Kiwi model directory is missing)
    //
    // KiwiAnalysisService.contentFeatures(for:)'s instance state (`kiwi`) is only reachable
    // through the `.shared` singleton (private init), and no test in this suite drives that
    // singleton's real warm-up — every Kiwi-dependent test here instead builds a standalone
    // `Kiwi` via `KiwiBuilder(modelPath:)`, matching HanjaContextEvalV2Tests / sibling files. This
    // test therefore exercises the IDENTICAL feature-space contract `contentFeatures(for:)`
    // promises (same match options, topN: 1, `isContextContentMorphemeTag` filter, form/TAG
    // dedup) via that same standalone Kiwi, then feeds the result through the real
    // `sessionContextBoosts`/`rankWithContext` pipeline to confirm the end-to-end ranking effect.

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let modelDir = repoRoot().appendingPathComponent("woorilee/KiwiModels")
    private static let kiwiModelsAvailable = FileManager.default.fileExists(atPath: modelDir.path)
    private static let kiwi: Kiwi? = {
        guard kiwiModelsAvailable else { return nil }
        return try? KiwiBuilder(modelPath: modelDir.path).build()
    }()

    func testDocumentContextFeatureSpaceIncludesWaterPipeMorphemesAndFlipsSessionRanking() throws {
        guard Self.kiwiModelsAvailable, let kiwi = Self.kiwi else {
            print("Kiwi model directory not found, skipping real-Kiwi document-context integration test.")
            return
        }

        let documentSentence = "수도관이 얼었다."
        let results = try kiwi.analyze(documentSentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
        let winner = try XCTUnwrap(results.max(by: { $0.score < $1.score }))

        var seen = Set<String>()
        var features: [String] = []
        for token in winner.tokens where KiwiAnalysisService.isContextContentMorphemeTag(token.tag) {
            let feature = "\(token.form)/\(token.tag.description)"
            guard !seen.contains(feature) else { continue }
            seen.insert(feature)
            features.append(feature)
        }

        XCTAssertTrue(
            features.contains { $0.hasPrefix("수도관") || $0.hasPrefix("수도") },
            "expected a 수도관-related content morpheme in \(features)"
        )

        // End-to-end: fold the document-derived features into the session vocabulary axis and
        // confirm they can flip a same-reading ranking, mirroring HanjaContextRankerTests's
        // clause-axis flip test.
        let candidates = [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]
        let sessionInputs = HanjaSessionScoringInputs(vocabularyFeatures: Set(features), selectionPriors: [:], isEmpty: false)
        let lookup: (String, String) -> [String: Double]? = { reading, hanja in
            guard reading == "수도", hanja == "水道" else { return nil }
            return Dictionary(uniqueKeysWithValues: features.map { ($0, 40.0) })
        }
        let boosts = sessionContextBoosts(
            for: candidates, reading: "수도", session: sessionInputs, lookup: lookup, weights: .default
        )
        let ranked = rankWithContext(
            candidates: candidates, contextDominantHanja: [], weights: .default, sessionBoosts: boosts
        )

        XCTAssertEqual(ranked.first?.value, "水道", "document-context-derived session vocabulary must be able to flip the ranking")
    }

    /// Informational (no hard assertion beyond "a log line exists"): captures
    /// `fetchDocumentContextIfNeeded`'s own debugLog line — numbers-only, per its doc — to report
    /// the real fetch-IPC (FakeIMKTextInput) and Kiwi-analyze costs for one document-context fetch
    /// in this test environment.
    func testFetchAndAnalyzeLatencyIsReportedInDebugLog() throws {
        guard Self.kiwiModelsAvailable, let kiwi = Self.kiwi else {
            print("Kiwi model directory not found, skipping document-context fetch/analyze latency measurement.")
            return
        }

        let documentText = "정수 필터를 새로 달았더니 수도에서 나오는 물이 훨씬 깨끗해지고 냄새도 사라졌다."
        let client = FakeIMKTextInput()
        client.stubbedSelectedRange = NSRange(location: (documentText as NSString).length, length: 0)
        client.attributedSubstringHandler = { range in
            guard let swiftRange = Range(range, in: documentText) else { return nil }
            return NSAttributedString(string: String(documentText[swiftRange]))
        }

        var loggedLines: [String] = []
        let session = InputSession()
        let engine = InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { _, _, _ in RealtimeClauseAnalysis(segments: [], clauseContentFeatures: []) },
            analyzeManualClause: { _, _ in [] },
            analyzeDocumentContext: { text in
                guard let results = try? kiwi.analyze(text, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions),
                      let winner = results.max(by: { $0.score < $1.score })
                else {
                    return []
                }
                var seen = Set<String>()
                var features: [String] = []
                for token in winner.tokens where KiwiAnalysisService.isContextContentMorphemeTag(token.tag) {
                    let feature = "\(token.form)/\(token.tag.description)"
                    guard !seen.contains(feature) else { continue }
                    seen.insert(feature)
                    features.append(feature)
                }
                return features
            },
            flushRealtimeUsageEvents: { _ in },
            updateComposition: {},
            debugLog: { loggedLines.append($0) },
            scheduleDocumentContextAnalysis: { $0() }
        )

        session.appendCommittedTextToRealtimeClause("가")
        engine.fetchDocumentContextIfNeeded()

        let logLine = try XCTUnwrap(loggedLines.first { $0.hasPrefix("documentContext ") })
        print("R1B_LATENCY|\(logLine)")
        XCTAssertNotNil(session.sessionScoringInputs, "the real Kiwi analysis should find at least one content-morpheme feature")
    }
}
