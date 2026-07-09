// Unit tests for KiwiAnalysisService.stableWinningTokens — the composing-tail stability filter
// used by analyzeClause(composingTailStart:) to keep still-composing (uncommitted) trailing text
// from perturbing context-association features for already-settled segments. Kiwi-free: exercises
// the pure token-filtering logic directly with hand-built Tokens, mirroring the pattern in
// RealtimeContextRankingTests.swift.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class KiwiStableWinningTokensTests: XCTestCase {
    private func token(_ form: String, tag: POSTag, position: Int, length: Int) -> Token {
        Token(form: form, tag: tag, position: position, length: length)
    }

    // Token isn't Equatable — compare by (form, tag, position, length) tuples instead.
    private func signatures(_ tokens: [Token]) -> [String] {
        tokens.map { "\($0.form)/\($0.tag.description)(pos=\($0.position),len=\($0.length))" }
    }

    func testNilComposingTailStartKeepsEveryToken() {
        let tokens = [
            token("고장", tag: .nng, position: 9, length: 2),
            token("나", tag: .vv, position: 11, length: 1),
        ]

        XCTAssertEqual(
            signatures(KiwiAnalysisService.stableWinningTokens(from: tokens, composingTailStart: nil)),
            signatures(tokens),
            "nil must be a full no-op, reproducing every call site that predates this fix"
        )
    }

    func testTokenEntirelyBeforeBoundaryIsKept() {
        // 고장/NNG spans [9, 11) — ends exactly at the boundary, not overlapping the tail.
        let stable = token("고장", tag: .nng, position: 9, length: 2)
        XCTAssertEqual(
            signatures(KiwiAnalysisService.stableWinningTokens(from: [stable], composingTailStart: 11)),
            signatures([stable])
        )
    }

    func testTokenStartingAtOrAfterBoundaryIsDropped() {
        // 나/VV spans [11, 12) — starts exactly at the boundary (still-composing tail).
        let composing = token("나", tag: .vv, position: 11, length: 1)
        XCTAssertEqual(
            KiwiAnalysisService.stableWinningTokens(from: [composing], composingTailStart: 11).count,
            0
        )
    }

    func testTokenStraddlingTheBoundaryIsDropped() {
        // A token that starts before the boundary but extends into the tail must still be
        // excluded (it isn't fully settled either) — same rule as the self-exclusion overlap
        // check elsewhere in this file, just anchored on "ends at/before" instead of "overlaps".
        let straddling = token("장ㄴ", tag: .nng, position: 10, length: 2)
        XCTAssertEqual(
            KiwiAnalysisService.stableWinningTokens(from: [straddling], composingTailStart: 11).count,
            0
        )
    }

    func testBoundaryAtFullClauseLengthKeepsEverything() {
        // composingTailStart == the end of every token (no composing tail at all) — the common
        // "clause has just been committed, nothing is composing" case.
        let tokens = [
            token("고장", tag: .nng, position: 9, length: 2),
            token("났", tag: .nng, position: 11, length: 1),
        ]
        XCTAssertEqual(
            signatures(KiwiAnalysisService.stableWinningTokens(from: tokens, composingTailStart: 12)),
            signatures(tokens)
        )
    }

    func testZeroLengthBoundaryDropsEveryToken() {
        // composingTailStart == 0 means the ENTIRE clause is still composing (e.g. the user has
        // typed only a single not-yet-committed syllable with nothing else before it).
        let tokens = [token("나", tag: .vv, position: 0, length: 1)]
        XCTAssertEqual(
            KiwiAnalysisService.stableWinningTokens(from: tokens, composingTailStart: 0).count,
            0
        )
    }

    func testEmptyTokensReturnsEmpty() {
        XCTAssertEqual(KiwiAnalysisService.stableWinningTokens(from: [], composingTailStart: 5).count, 0)
    }
}
