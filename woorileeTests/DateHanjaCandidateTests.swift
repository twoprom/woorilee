// Tests for relative-date candidates and their manual/realtime integration.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class DateHanjaCandidateTests: XCTestCase {
    private let aliases: [([String], Int, String, String)] = [
        (["오늘", "금일"], 16, "十六", "一六"),
        (["내일", "명일"], 17, "十七", "一七"),
        (["모레", "내일모레", "낼모레", "명후일", "재명일"], 18, "十八", "一八"),
        (["글피", "삼명일"], 19, "十九", "一九"),
        (["그글피"], 20, "二十", "二〇"),
        (["어제", "어저께", "작일"], 15, "十五", "一五"),
        (["그제", "그저께", "거거일", "재작", "재작일"], 14, "十四", "一四"),
        (["그끄저께", "그끄제", "삼작일", "재재작일"], 13, "十三", "一三"),
    ]

    func testAllRequestedAliasesProduceNineOrderedNotationsAndLabels() {
        let weekdays = [13: ("금", "金"), 14: ("토", "土"), 15: ("일", "日"), 16: ("월", "月"),
                        17: ("화", "火"), 18: ("수", "水"), 19: ("목", "木"), 20: ("금", "金")]
        for (words, day, quantity, digits) in aliases {
            for word in words {
                let candidates = candidates(for: word)
                let weekday = weekdays[day]!
                XCTAssertEqual(candidates.map(\.value), [
                    "11/\(day)", "2026/11/\(day)", "2026/11/\(day)(\(weekday.0))", "2026/11/\(day)(\(weekday.1))",
                    "2026년 11월 \(day)일", "2026年 11月 \(day)日",
                    "二千二十六年十一月\(quantity)日", "二〇二六年一一月\(digits)日",
                    "大韓民國108年11月\(day)日",
                ], word)
                XCTAssertEqual(candidates.map(\.comment), [
                    "날짜", "날짜", "날짜", "日字", "날짜", "日字", "日字", "日字", "大韓民國年號",
                ], word)
                XCTAssertEqual(candidates.map(\.reading), Array(repeating: word, count: 9), word)
                XCTAssertEqual(candidates.map(\.baseRank), Array(0..<9), word)
            }
        }
    }

    func testUnrecognizedOrPartialExpressionsDoNotGenerateDates() {
        for word in ["", "오늘날", "재작년", "금일봉", "내", "오늘 ", "어제오늘", "2026-11-16"] {
            XCTAssertFalse(DateHanjaCandidateGenerator.isDateCandidateSource(word), word)
            XCTAssertTrue(candidates(for: word).isEmpty, word)
        }
    }

    func testCalendarCrossesMonthsYearsAndLeapDays() {
        for (reference, word, expected) in [
            ("2026-12-31T12:00:00Z", "내일", "2027년 1월 1일"),
            ("2026-01-01T12:00:00Z", "그끄제", "2025년 12월 29일"),
            ("2026-01-30T12:00:00Z", "그글피", "2026년 2월 3일"),
            ("2028-02-28T12:00:00Z", "내일", "2028년 2월 29일"),
            ("2028-03-01T12:00:00Z", "어제", "2028년 2월 29일"),
            ("2026-02-28T12:00:00Z", "내일", "2026년 3월 1일"),
        ] {
            XCTAssertEqual(candidates(for: word, reference: reference)[4].value, expected, reference)
        }
        XCTAssertEqual(candidates(for: "내일", reference: "2026-12-31T12:00:00Z").map(\.value), [
            "1/1", "2027/1/1", "2027/1/1(금)", "2027/1/1(金)",
            "2027년 1월 1일", "2027年 1月 1日", "二千二十七年一月一日", "二〇二七年一月一日",
            "大韓民國109年1月1日",
        ])
    }

    func testEraYearsFollowRelativeDateAcrossPreviousYearAndLeapDay() {
        XCTAssertEqual(candidates(for: "어제", reference: "2026-01-01T12:00:00Z").last?.value,
                       "大韓民國107年12月31日")
        XCTAssertEqual(candidates(for: "내일", reference: "2028-02-28T12:00:00Z").last?.value,
                       "大韓民國110年2月29日")
    }

    func testAllDateCandidatesFitOnOnePanelPage() {
        var state = HanjaCandidatePanelState(
            mode: .manual(sourceText: "오늘", replacementRange: NSRange(location: 0, length: 2)),
            anchorRange: NSRange(location: 2, length: 0), candidates: candidates(for: "오늘")
        )
        XCTAssertEqual(state.pageCount, 1)
        XCTAssertEqual(state.visibleCandidateRange, 0..<9)
        XCTAssertEqual(state.candidateForPageNumberIndex(8)?.value, "大韓民國108年11月16日")
        XCTAssertEqual(state.candidateForPageNumberIndex(8)?.comment, "大韓民國年號")
        state.movePage(by: 1)
        XCTAssertEqual(state.page, 0)
    }

    func testCurrentDayUsesRequestedTimeZoneAndFreshReferenceDate() {
        let reference = "2026-11-16T00:30:00Z"
        XCTAssertEqual(candidates(for: "오늘", reference: reference)[4].value, "2026년 11월 16일")
        XCTAssertEqual(
            candidates(for: "오늘", reference: reference, zone: "America/Los_Angeles")[4].value,
            "2026년 11월 15일"
        )
        XCTAssertEqual(
            candidates(for: "오늘", reference: "2026-11-17T00:30:00Z")[4].value,
            "2026년 11월 17일"
        )
        XCTAssertEqual(candidates(for: "오늘", reference: reference)[2].value, "2026/11/16(월)")
        XCTAssertEqual(
            candidates(for: "오늘", reference: reference, zone: "America/Los_Angeles")[3].value,
            "2026/11/15(日)"
        )
    }

    func testRelativeDaysUseCalendarArithmeticAcrossDaylightSavingChanges() {
        XCTAssertEqual(
            candidates(for: "내일", reference: "2026-03-28T23:30:00Z")[4].value,
            "2026년 3월 29일"
        )
        XCTAssertEqual(
            candidates(for: "내일", reference: "2026-10-24T23:30:00Z")[4].value,
            "2026년 10월 26일"
        )
    }

    func testEveryAliasFormsOneSelectableSegmentEvenWithoutKiwiTokens() throws {
        for (words, _, _, _) in aliases {
            for word in words {
                let segments = segments(in: word)
                XCTAssertEqual(segments.count, 1, word)
                let segment = try XCTUnwrap(segments.first)
                XCTAssertEqual(segment.surface, word)
                XCTAssertEqual(segment.sourceRange, NSRange(location: 0, length: word.utf16.count))
                XCTAssertTrue(segment.isConvertible)
                XCTAssertNil(segment.previewCandidate)
                XCTAssertFalse(segment.awaitsContextEvidence)
                XCTAssertTrue(HanjaCandidatePanelState.realtimeDefaultHighlightedIsHangul(segment: segment))
            }
        }
    }

    func testSplitCompoundWithParticleIsOneDateSegmentAndPreservesUTF16Ranges() throws {
        let text = "😀 내일모레에"
        let tokens = [
            Token(form: "내일", tag: .nng, position: 3, length: 2),
            Token(form: "모레", tag: .nng, position: 5, length: 2),
            Token(form: "에", tag: .jkb, position: 7, length: 1),
        ]
        let segments = segments(in: text, tokens: tokens)
        XCTAssertEqual(segments.map(\.surface), ["내일모레"])
        XCTAssertEqual(segments.first?.sourceRange, NSRange(location: 3, length: 4))

        var state = RealtimeClauseState()
        state.rawClauseText = text
        state.updateAnalysis(segments: segments)
        XCTAssertEqual(state.previewClauseText, text)
        XCTAssertTrue(state.applyCandidateSelection(try XCTUnwrap(candidates(for: "내일모레").first)))
        XCTAssertEqual(state.previewClauseText, "😀 11/18에")
        state.updateAnalysis(segments: segments)
        XCTAssertEqual(state.previewClauseText, "😀 11/18에")
        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())
        XCTAssertEqual(state.previewClauseText, text)
    }

    func testDatePrefixesInUnrelatedWordsDoNotOfferDates() {
        for (text, word) in [("오늘날", "오늘"), ("재작년", "재작"), ("금일봉", "금일")] {
            let tokens = [Token(form: word, tag: .nng, position: 0, length: word.utf16.count)]
            XCTAssertTrue(segments(in: text, tokens: tokens).isEmpty, text)
        }
    }

    func testContextRerankingAndManualBoundariesKeepDateSourceUntilSelected() {
        let text = "금일"
        let segments = segments(in: text, tokens: [Token(form: text, tag: .nng, position: 0, length: 2)])
        let ranked = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: text, dominantMap: [text: "今日"], candidateLookup: { self.candidates(for: $0) },
            autoConvertGate: { _, _ in true }
        )
        XCTAssertEqual(ranked.count, 1)
        XCTAssertNil(ranked.first?.previewCandidate)
        let manual = KiwiAnalysisService.makeManualSegments(
            boundaries: [], in: text, candidateLookup: { self.candidates(for: $0) }
        )
        XCTAssertTrue(manual.first?.isConvertible == true)
        XCTAssertNil(manual.first?.previewCandidate)
    }

    func testCoordinatorExposesDateCandidatesInBothPanelsWithOriginalReplacementRange() {
        let target = ManualHanjaTarget(
            sourceText: "그끄저께", replacementRange: NSRange(location: 12, length: 4),
            anchorRange: NSRange(location: 16, length: 0)
        )
        let coordinator = HanjaServiceCoordinator.shared
        let lookup = coordinator.manualLookup(for: target)
        XCTAssertEqual(lookup.lookupKey, target.sourceText)
        XCTAssertEqual(lookup.state.mode, .manual(sourceText: target.sourceText, replacementRange: target.replacementRange))
        XCTAssertEqual(lookup.state.anchorRange, target.anchorRange)
        XCTAssertEqual(lookup.state.candidates.map(\.comment), [
            "날짜", "날짜", "날짜", "日字", "날짜", "日字", "日字", "日字", "大韓民國年號",
        ])
        let segment = HanjaSegment(
            sourceRange: NSRange(location: 0, length: 4), surface: target.sourceText,
            normalizedLookupKey: target.sourceText, tag: .nng, isConvertible: true, previewCandidate: nil
        )
        XCTAssertEqual(coordinator.realtimeCandidates(for: segment).map(\.comment), [
            "날짜", "날짜", "날짜", "日字", "날짜", "日字", "日字", "日字", "大韓民國年號",
        ])
    }

    func testActualKiwiPipelineRecognizesEveryAliasWithAndWithoutParticle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let kiwi = try KiwiBuilder(modelPath: root.appendingPathComponent("woorilee/KiwiModels").path).build()
        for (words, _, _, _) in aliases {
            for word in words {
                let finalSyllable = word.unicodeScalars.last!.value
                let particle = (finalSyllable - 0xAC00) % 28 == 0 ? "는" : "은"
                for suffix in ["", particle] {
                    let clause = word + suffix
                    let analysis = KiwiAnalysisService.analyzeClause(
                        clause, kiwi: kiwi, candidateLookup: { self.candidates(for: $0) },
                        hangulUsageLookup: { _ in 0 }, dominantMap: [:], autoConvertGate: { _, _ in true }
                    )
                    let dates = analysis.segments.filter { $0.isConvertible }
                    XCTAssertEqual(dates.map(\.surface), [word], clause)
                    XCTAssertTrue(dates.allSatisfy { $0.previewCandidate == nil }, clause)
                }
            }
        }
    }

    private func candidates(
        for word: String, reference: String = "2026-11-16T12:00:00Z", zone: String = "Europe/London"
    ) -> [HanjaCandidate] {
        DateHanjaCandidateGenerator.candidates(
            for: word, referenceDate: ISO8601DateFormatter().date(from: reference)!,
            timeZone: TimeZone(identifier: zone)!
        )
    }

    private func segments(in text: String, tokens: [Token] = []) -> [HanjaSegment] {
        KiwiAnalysisService.makeRealtimeSegments(
            from: tokens, in: text, candidateLookup: { self.candidates(for: $0) },
            autoConvertGate: { _, _ in true }, nativeHomographLookup: { _ in true }
        )
    }
}
