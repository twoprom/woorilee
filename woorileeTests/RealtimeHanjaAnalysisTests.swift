import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeHanjaAnalysisTests: XCTestCase {
    func testNumericHanjaCandidatesForSmallNumber() {
        XCTAssertEqual(
            NumericHanjaCandidateGenerator.candidates(for: "123").map(\.value),
            ["百二十三", "一二三", "백이십삼"]
        )
    }

    func testNumericHanjaCandidatesIncludeZeroDigitVariants() {
        XCTAssertEqual(
            NumericHanjaCandidateGenerator.candidates(for: "3015").map(\.value),
            ["三千十五", "三零一五", "三〇一五", "삼천십오"]
        )
    }

    func testNumericHanjaCandidatesForLargeNumber() {
        XCTAssertEqual(
            NumericHanjaCandidateGenerator.candidates(for: "123456789").map(\.value),
            ["一二三四五六七八九", "一億二千三百四十五萬六千七百八十九", "1억2345만6789", "일억이천삼백사십오만육천칠백팔십구"]
        )
    }

    func testNumericHanjaCandidatesIgnoreCommasForValue() {
        XCTAssertEqual(
            NumericHanjaCandidateGenerator.candidates(for: "123,456,789").map(\.value),
            ["一二三四五六七八九", "一億二千三百四十五萬六千七百八十九", "1억2345만6789", "일억이천삼백사십오만육천칠백팔십구"]
        )
    }

    func testNumericHanjaCandidatesForLeadingZeroUseDigitReadingsOnly() {
        XCTAssertEqual(
            NumericHanjaCandidateGenerator.candidates(for: "0012").map(\.value),
            ["零零一二", "〇〇一二", "영영일이"]
        )
    }

    func testRealtimeNumericSegmentIsSelectableAndConvertible() {
        let tokens = [
            Token(form: "123", tag: .sn, position: 0, length: 3),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "123",
            candidateLookup: NumericHanjaCandidateGenerator.candidates(for:)
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "123"
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.normalizedLookupKey, "123")
        XCTAssertTrue(segments.first?.isConvertible == true)
        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertEqual(state.previewClauseText, "123")

        let panelState = HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: 0, segmentSurface: "123"),
            anchorRange: NSRange(location: 0, length: 3),
            candidates: NumericHanjaCandidateGenerator.candidates(for: segments[0].normalizedLookupKey)
        )
        XCTAssertFalse(panelState.candidates.isEmpty)
        XCTAssertEqual(panelState.candidates.first?.value, "百二十三")
    }

    func testRealtimeNumericCandidatePanelDefaultsHighlightToArabicNumber() {
        let tokens = [
            Token(form: "123", tag: .sn, position: 0, length: 3),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "123",
            candidateLookup: NumericHanjaCandidateGenerator.candidates(for:)
        )
        guard let segment = segments.first else {
            return XCTFail("expected numeric segment")
        }

        let candidates = NumericHanjaCandidateGenerator.candidates(for: segment.normalizedLookupKey)
        let panelState = HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: 0, segmentSurface: segment.surface),
            anchorRange: NSRange(location: 0, length: 3),
            candidates: candidates,
            highlightedIsHangul: HanjaCandidatePanelState.realtimeDefaultHighlightedIsHangul(
                segment: segment,
                candidates: candidates,
                hangulUsage: 0
            )
        )

        XCTAssertTrue(panelState.hasHangulRow)
        XCTAssertTrue(panelState.highlightedIsHangul)
    }

    func testRealtimeNumericSegmentMergesWithHangulSegments() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "123", tag: .sn, position: 2, length: 3),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국123",
            candidateLookup: { key in
                if let normalized = NumericHanjaCandidateGenerator.normalizedDigits(from: key) {
                    return NumericHanjaCandidateGenerator.candidates(for: normalized)
                }

                return key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국123"
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(segments.map(\.surface), ["한국", "123"])
        XCTAssertEqual(state.previewClauseText, "韓國123")
        XCTAssertEqual(state.selectedSegment?.surface, "한국")
        XCTAssertTrue(state.moveSelectedSegment(by: 1))
        XCTAssertEqual(state.selectedSegment?.surface, "123")
    }

    func testRealtimeSegmentsUseEligibleTagsOnly() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "은", tag: .jx, position: 2, length: 1),
            Token(form: "abc", tag: .sl, position: 3, length: 3),
        ]

        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국은abc",
            candidateLookup: { key in
                key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.surface, "한국")
        XCTAssertEqual(segments.first?.tag, .nnp)
        XCTAssertTrue(segments.first?.isConvertible == true)
        XCTAssertEqual(segments.first?.previewCandidate?.value, "韓國")
    }

    func testRealtimeAnalysisChoosesLowerRankedTokenizationWhenItPreservesExactCandidates() {
        let sourceText = "동해물과 백두산이"
        let results = [
            TokenResult(
                score: -36.1,
                tokens: [
                    Token(form: sourceText, tag: .nnp, position: 0, length: 9),
                ]
            ),
            TokenResult(
                score: -39.4,
                tokens: [
                    Token(form: "동해", tag: .nnp, position: 0, length: 2),
                    Token(form: "물", tag: .nng, position: 2, length: 1),
                    Token(form: "과", tag: .jc, position: 3, length: 1),
                    Token(form: "백두산", tag: .nnp, position: 5, length: 3),
                    Token(form: "이", tag: .jks, position: 8, length: 1),
                ]
            ),
        ]

        let segments = KiwiAnalysisService.bestRealtimeSegments(
            from: results,
            in: sourceText,
            candidateLookup: { key in
                switch key {
                case "동해": return [candidate(reading: key, value: "東海")]
                case "백두산": return [candidate(reading: key, value: "白頭山")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = sourceText
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(segments.map(\.surface), ["동해", "물", "백두산"])
        XCTAssertEqual(state.previewClauseText, "東海물과 白頭山이")
        XCTAssertEqual(state.selectedSegment?.surface, "동해")
        XCTAssertTrue(state.moveSelectedSegment(by: 1))
        XCTAssertEqual(state.selectedSegment?.surface, "백두산")
    }

    func testRealtimeAnalysisKeepsTopTokenizationWhenItHasBetterExactCandidateCoverage() {
        let sourceText = "동해물과 백두산이"
        let wholeCandidate = candidate(reading: sourceText, value: "東海물과白頭山이")
        let results = [
            TokenResult(
                score: -36.1,
                tokens: [
                    Token(form: sourceText, tag: .nnp, position: 0, length: 9),
                ]
            ),
            TokenResult(
                score: -39.4,
                tokens: [
                    Token(form: "동해", tag: .nnp, position: 0, length: 2),
                    Token(form: "백두산", tag: .nnp, position: 5, length: 3),
                ]
            ),
        ]

        let segments = KiwiAnalysisService.bestRealtimeSegments(
            from: results,
            in: sourceText,
            candidateLookup: { key in
                switch key {
                case sourceText: return [wholeCandidate]
                case "동해": return [candidate(reading: key, value: "東海")]
                case "백두산": return [candidate(reading: key, value: "白頭山")]
                default: return []
                }
            }
        )

        XCTAssertEqual(segments.map(\.surface), [sourceText])
        XCTAssertEqual(segments.first?.previewCandidate, wholeCandidate)
    }

    func testRealtimePreviewUsesExactCandidateForSegment() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국은",
            candidateLookup: { key in
                key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국은"

        state.updateAnalysis(segments: segments)

        XCTAssertEqual(state.previewClauseText, "韓國은")
        XCTAssertEqual(state.selectedSegmentIndex, 0)
    }

    func testRealtimePreviewKeepsCandidateFreeTokensAndTailPreeditRaw() {
        let sourceText = "한국 없는ㄱ"
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "없는", tag: .va, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: { key in
                key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국 없는"
        state.tailPreedit = "ㄱ"

        state.updateAnalysis(segments: segments)

        XCTAssertEqual(state.previewClauseText, "韓國 없는ㄱ")
        XCTAssertEqual(segments.map(\.surface), ["한국", "없는"])
        XCTAssertEqual(segments.last?.isConvertible, false)
        XCTAssertNil(segments.last?.previewCandidate)
    }

    func testRealtimeMarkedStringHighlightsSelectedConvertibleSegment() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국은",
            candidateLookup: { key in
                key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국은"
        state.updateAnalysis(segments: segments)

        let markedText = inputRealtimeMarkedAttributedString(state)

        XCTAssertEqual(markedText.string, "韓國은")
        XCTAssertEqual(
            markedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.thick.rawValue
        )
        XCTAssertNotNil(markedText.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            markedText.attribute(.underlineStyle, at: 2, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testRealtimeCandidateSelectionLocksPreviewAcrossReanalysis() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
        ]
        let defaultCandidate = candidate(reading: "한국", value: "韓國")
        let selectedCandidate = candidate(reading: "한국", value: "漢國")
        let initialSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국은",
            candidateLookup: { key in
                key == "한국" ? [defaultCandidate, selectedCandidate] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국은"
        state.updateAnalysis(segments: initialSegments)

        XCTAssertTrue(state.applyCandidateSelection(selectedCandidate))
        XCTAssertEqual(state.previewClauseText, "漢國은")
        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["漢國"])

        let reanalyzedSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국은",
            candidateLookup: { key in
                key == "한국" ? [defaultCandidate, selectedCandidate] : []
            }
        )
        state.updateAnalysis(segments: reanalyzedSegments)

        XCTAssertEqual(state.previewClauseText, "漢國은")
        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["漢國"])
    }

    func testRealtimePreviewDropsSegmentWhenAnalyzerOmitsIt() {
        let sourceText = "한국 역사"
        let initialSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: [
                Token(form: "한국", tag: .nnp, position: 0, length: 2),
                Token(form: "역사", tag: .nng, position: 3, length: 2),
            ],
            in: sourceText,
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = sourceText
        state.updateAnalysis(segments: initialSegments)

        let tailOnlySegments = KiwiAnalysisService.makeRealtimeSegments(
            from: [
                Token(form: "역사", tag: .nng, position: 3, length: 2),
            ],
            in: sourceText,
            candidateLookup: { key in
                key == "역사" ? [candidate(reading: key, value: "歷史")] : []
            }
        )
        state.updateAnalysis(segments: tailOnlySegments)

        XCTAssertEqual(state.segments.map(\.surface), ["역사"])
        XCTAssertEqual(state.previewClauseText, "한국 歷史")
    }

    func testRealtimePreviewAcceptsMergedSegmentFromAnalyzer() {
        let sourceText = "한국역사"
        let initialSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: [
                Token(form: "한국", tag: .nnp, position: 0, length: 2),
                Token(form: "역사", tag: .nng, position: 2, length: 2),
            ],
            in: sourceText,
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = sourceText
        state.updateAnalysis(segments: initialSegments)

        let mergedCandidateFreeSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: [
                Token(form: "한국역사", tag: .nng, position: 0, length: 4),
            ],
            in: sourceText,
            candidateLookup: { _ in [] }
        )
        state.updateAnalysis(segments: mergedCandidateFreeSegments)

        XCTAssertEqual(state.segments.map(\.surface), ["한국역사"])
        XCTAssertEqual(state.previewClauseText, "한국역사")
        XCTAssertEqual(state.segments.first?.isConvertible, false)
        XCTAssertNil(state.selectedSegmentIndex)
    }

    func testRealtimeHangulFallbackLocksSelectedSegmentAcrossReanalysis() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "역사", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국 역사",
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국 역사"
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(state.previewClauseText, "韓國 歷史")
        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())
        XCTAssertEqual(state.previewClauseText, "한국 歷史")

        let reanalyzedSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국 역사",
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        state.updateAnalysis(segments: reanalyzedSegments)

        XCTAssertEqual(state.previewClauseText, "한국 歷史")
        XCTAssertNil(state.segments[0].previewCandidate)
        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertTrue(state.moveSelectedSegment(by: 1))
        XCTAssertEqual(state.selectedSegmentIndex, 1)
    }

    func testRealtimeHangulFallbackRemovesCandidateLockAndPendingUsage() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
        ]
        let defaultCandidate = candidate(reading: "한국", value: "韓國")
        let selectedCandidate = candidate(reading: "한국", value: "漢國")
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국",
            candidateLookup: { key in
                key == "한국" ? [defaultCandidate, selectedCandidate] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국"
        state.updateAnalysis(segments: segments)

        XCTAssertTrue(state.applyCandidateSelection(selectedCandidate))
        XCTAssertEqual(state.previewClauseText, "漢國")
        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["漢國"])
        XCTAssertFalse(state.lockedCandidates.isEmpty)

        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())

        XCTAssertEqual(state.previewClauseText, "한국")
        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["한국"])
        XCTAssertEqual(state.pendingUsageEvents.map(\.lookupKey), ["한국"])
        XCTAssertTrue(state.lockedCandidates.isEmpty)
        XCTAssertFalse(state.hangulLockedSegments.isEmpty)
    }

    func testRealtimeHangulFallbackCanAdvanceToNextConvertibleSegment() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "역사", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국 역사",
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국 역사"
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())
        XCTAssertTrue(state.moveSelectedSegment(by: 1))
        XCTAssertEqual(state.selectedSegmentIndex, 1)
        XCTAssertEqual(state.selectedSegment?.surface, "역사")
    }

    func testRealtimeSegmentSelectionCanWrapForManualNavigation() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "역사", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국 역사",
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국 역사"
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertTrue(state.moveSelectedSegment(by: -1, wraps: true))
        XCTAssertEqual(state.selectedSegmentIndex, 1)
        XCTAssertTrue(state.moveSelectedSegment(by: 1, wraps: true))
        XCTAssertEqual(state.selectedSegmentIndex, 0)
    }

    func testRealtimeCandidateSelectionStopsAtLastConvertibleSegment() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "역사", tag: .nng, position: 3, length: 2),
        ]
        let selectedCandidate = candidate(reading: "역사", value: "歷史別")
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국 역사",
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史"), selectedCandidate]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국 역사"
        state.updateAnalysis(segments: segments)
        XCTAssertTrue(state.moveSelectedSegment(by: 1))

        XCTAssertTrue(state.applyCandidateSelection(selectedCandidate))
        XCTAssertFalse(state.moveSelectedSegment(by: 1))

        XCTAssertEqual(state.previewClauseText, "韓國 歷史別")
        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["歷史別"])
        XCTAssertEqual(state.selectedSegmentIndex, 1)
    }

    func testRealtimeHangulFallbackStopsAtLastConvertibleSegment() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
            Token(form: "역사", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국 역사",
            candidateLookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "한국 역사"
        state.updateAnalysis(segments: segments)
        XCTAssertTrue(state.moveSelectedSegment(by: 1))

        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())
        XCTAssertFalse(state.moveSelectedSegment(by: 1))

        XCTAssertEqual(state.previewClauseText, "韓國 역사")
        XCTAssertEqual(state.pendingUsageEvents.count, 1)
        XCTAssertEqual(state.pendingUsageEvents.first?.lookupKey, "역사")
        XCTAssertEqual(state.pendingUsageEvents.first?.value, "역사")
        XCTAssertEqual(state.selectedSegmentIndex, 1)
    }

    func testRealtimeCandidateStatePagesHighlightAndNumericLookup() {
        let candidates = (0..<12).map { index in
            candidate(reading: "한", value: "漢\(index)")
        }
        var state = HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: 0, segmentSurface: "한"),
            anchorRange: NSRange(location: 0, length: 1),
            candidates: candidates
        )

        XCTAssertFalse(state.mode.allowsNumberedSelection)
        XCTAssertEqual(state.pageCount, 2)
        XCTAssertEqual(state.visibleCandidateRange, 0..<9)
        XCTAssertEqual(state.candidateForPageNumberIndex(8)?.value, "漢8")
        XCTAssertNil(state.candidateForPageNumberIndex(9))

        state.moveHighlight(by: 9)

        XCTAssertEqual(state.highlightedIndex, 9)
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.visibleCandidateRange, 9..<12)

        state.movePage(by: 1)

        XCTAssertEqual(state.page, 0)
        XCTAssertEqual(state.highlightedIndex, 0)
    }

    func testRealtimePreviewPrefersHangulWhenUsageDominates() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국",
            candidateLookup: { key in
                key == "한국"
                    ? [candidate(reading: key, value: "韓國", usageCount: 1)]
                    : []
            },
            hangulUsageLookup: { key in
                key == "한국" ? 2 : 0
            }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertTrue(segments.first?.isConvertible == true)
    }

    func testRealtimePreviewKeepsHanjaWhenHangulUsageIsZero() {
        let tokens = [
            Token(form: "한국", tag: .nnp, position: 0, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국",
            candidateLookup: { key in
                key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            },
            hangulUsageLookup: { _ in 0 }
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "韓國")
    }

    func testRealtimeAutoCommitPolicyClassifiesPreparedTriggers() {
        XCTAssertTrue(RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting("."))
        XCTAssertTrue(RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting("?"))
        XCTAssertTrue(RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting("a"))
        XCTAssertFalse(RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting("5"))
        XCTAssertFalse(RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting(","))
        XCTAssertFalse(RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting("한"))
    }

    func testRealtimeAutoConversionSkippedForExcludedTags() {
        let excludedTokens: [Token] = [
            Token(form: "그것", tag: .np, position: 0, length: 2),
            Token(form: "야", tag: .ic, position: 0, length: 1),
            Token(form: "보다", tag: .vx, position: 0, length: 2),
            Token(form: "하", tag: .xsv, position: 0, length: 1),
            Token(form: "스럽", tag: .xsa, position: 0, length: 2),
            Token(form: "가", tag: .xsn, position: 0, length: 1),
        ]
        for token in excludedTokens {
            let surface = token.form
            let segments = KiwiAnalysisService.makeRealtimeSegments(
                from: [token],
                in: surface,
                candidateLookup: { key in
                    key == surface ? [candidate(reading: key, value: "漢")] : []
                }
            )
            XCTAssertEqual(segments.count, 1, "tag \(token.tag) should still produce a segment")
            XCTAssertTrue(segments.first?.isConvertible == true, "tag \(token.tag) should remain convertible")
            XCTAssertNil(segments.first?.previewCandidate, "tag \(token.tag) must not auto-convert")
        }
    }

    func testExcludedTagSegmentRemainsCandidateSelectable() {
        let selected = candidate(reading: "그것", value: "其")
        let tokens = [
            Token(form: "그것", tag: .np, position: 0, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "그것",
            candidateLookup: { key in
                key == "그것" ? [selected] : []
            }
        )
        var state = RealtimeClauseState()
        state.rawClauseText = "그것"
        state.updateAnalysis(segments: segments)

        XCTAssertEqual(state.previewClauseText, "그것")
        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertTrue(state.applyCandidateSelection(selected))
        XCTAssertEqual(state.previewClauseText, "其")
    }

    private func candidate(reading: String, value: String, usageCount: Int = 0) -> HanjaCandidate {
        HanjaCandidate(
            reading: reading,
            value: value,
            comment: "",
            source: .system,
            usageCount: usageCount,
            frequency: 0,
            baseRank: 0
        )
    }
}
