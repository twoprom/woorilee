// CompositionMode and SegmentLockKey value types for Hanja conversion.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi

enum CompositionMode: Equatable {
    case hangul
    case manualHanja
    case realtimeHanja
}

struct SegmentLockKey: Equatable, Hashable {
    let location: Int
    let surface: String
    let lookupKey: String

    init(location: Int, surface: String, lookupKey: String) {
        self.location = location
        self.surface = surface
        self.lookupKey = lookupKey
    }

    init(segment: HanjaSegment) {
        self.init(
            location: segment.sourceRange.location,
            surface: segment.surface,
            lookupKey: segment.normalizedLookupKey
        )
    }
}

struct HanjaSegment: Equatable, Identifiable {
    let id: UUID
    let sourceRange: NSRange
    let surface: String
    let normalizedLookupKey: String
    let tag: POSTag
    let isConvertible: Bool
    let previewCandidate: HanjaCandidate?
    /// Step 7 — native-homograph gate (docs/plans/context-aware-hanja-conversion.md §10): `true`
    /// means this segment's reading is flagged as having a real native-Korean-word homograph, its
    /// `previewCandidate` was suppressed to `nil` for that reason (not tag-ineligibility /
    /// preferHangul / step-6 gate failure), and `applyContextReranking` may promote a candidate
    /// back into `previewCandidate` if it finds positive context evidence. Defaults to `false` so
    /// every pre-existing initializer call site reproduces prior behavior exactly.
    let awaitsContextEvidence: Bool
    /// Dominant hanja resolved from the surrounding context (see HanjaContextRanker.swift).
    /// Empty unless step 4b's post-processing reranking pass has run. Carrying this through
    /// every copy helper keeps the panel path (HanjaServiceCoordinator.realtimeCandidates(for:))
    /// able to re-derive the same context without recomputing it.
    let contextDominantHanja: [String]
    /// Segment-specific corpus association features (step 5c — see
    /// docs/plans/context-aware-hanja-conversion.md §7 5c): clause content-morpheme features
    /// (`form/TAG`) minus the ones from tokens overlapping this segment's own sourceRange
    /// (self-exclusion). Empty unless `applyContextReranking` has run with an association lookup.
    /// Carried through the same copy helpers as `contextDominantHanja` so the panel path can
    /// re-derive the same association scoring without recomputing it.
    let contextFeatures: [String]

    init(
        id: UUID = UUID(),
        sourceRange: NSRange,
        surface: String,
        normalizedLookupKey: String,
        tag: POSTag,
        isConvertible: Bool,
        previewCandidate: HanjaCandidate?,
        awaitsContextEvidence: Bool = false,
        contextDominantHanja: [String] = [],
        contextFeatures: [String] = []
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.surface = surface
        self.normalizedLookupKey = normalizedLookupKey
        self.tag = tag
        self.isConvertible = isConvertible
        self.previewCandidate = previewCandidate
        self.awaitsContextEvidence = awaitsContextEvidence
        self.contextDominantHanja = contextDominantHanja
        self.contextFeatures = contextFeatures
    }

    func replacingPreviewCandidate(_ candidate: HanjaCandidate?) -> HanjaSegment {
        HanjaSegment(
            id: id,
            sourceRange: sourceRange,
            surface: surface,
            normalizedLookupKey: normalizedLookupKey,
            tag: tag,
            isConvertible: isConvertible,
            previewCandidate: candidate,
            awaitsContextEvidence: awaitsContextEvidence,
            contextDominantHanja: contextDominantHanja,
            contextFeatures: contextFeatures
        )
    }

    func replacingContext(_ context: [String], features: [String] = [], previewCandidate: HanjaCandidate?) -> HanjaSegment {
        HanjaSegment(
            id: id,
            sourceRange: sourceRange,
            surface: surface,
            normalizedLookupKey: normalizedLookupKey,
            tag: tag,
            isConvertible: isConvertible,
            previewCandidate: previewCandidate,
            awaitsContextEvidence: awaitsContextEvidence,
            contextDominantHanja: context,
            contextFeatures: features
        )
    }
}

struct PendingHanjaUsageEvent: Equatable {
    let segmentLockKey: SegmentLockKey
    let lookupKey: String
    let value: String
}

enum HanjaCandidatePanelMode: Equatable {
    case manual(sourceText: String, replacementRange: NSRange)
    case realtime(segmentIndex: Int, segmentSurface: String)

    var allowsNumberedSelection: Bool {
        switch self {
        case .manual:
            return true
        case .realtime:
            return false
        }
    }

    var manualSourceText: String? {
        guard case .manual(let sourceText, _) = self else {
            return nil
        }

        return sourceText
    }

    var manualReplacementRange: NSRange? {
        guard case .manual(_, let replacementRange) = self else {
            return nil
        }

        return replacementRange
    }

    var realtimeSegmentIndex: Int? {
        guard case .realtime(let segmentIndex, _) = self else {
            return nil
        }

        return segmentIndex
    }

    var realtimeSegmentSurface: String? {
        guard case .realtime(_, let segmentSurface) = self else {
            return nil
        }

        return segmentSurface
    }
}

enum HanjaCandidatePanelSelection: Equatable {
    case candidate(HanjaCandidate)
    case hangul
}

struct HanjaCandidatePanelState: Equatable {
    static let defaultPageSize = 9

    let mode: HanjaCandidatePanelMode
    let anchorRange: NSRange
    let candidates: [HanjaCandidate]
    var highlightedIndex: Int
    var page: Int
    let pageSize: Int
    var highlightedIsHangul: Bool

    init(
        mode: HanjaCandidatePanelMode,
        anchorRange: NSRange,
        candidates: [HanjaCandidate],
        highlightedIndex: Int = 0,
        page: Int = 0,
        pageSize: Int = Self.defaultPageSize,
        highlightedIsHangul: Bool = false
    ) {
        self.mode = mode
        self.anchorRange = anchorRange
        self.candidates = candidates
        self.pageSize = max(1, pageSize)
        self.highlightedIsHangul = highlightedIsHangul

        if candidates.isEmpty {
            self.highlightedIndex = 0
            self.page = 0
        } else {
            self.highlightedIndex = min(max(highlightedIndex, 0), candidates.count - 1)
            self.page = min(max(page, 0), max(0, (candidates.count - 1) / self.pageSize))
            if self.highlightedIndex / self.pageSize != self.page {
                self.highlightedIndex = min(self.page * self.pageSize, candidates.count - 1)
            }
        }
    }

    var pageCount: Int {
        guard !candidates.isEmpty else {
            return 0
        }

        return Int(ceil(Double(candidates.count) / Double(pageSize)))
    }

    var visibleCandidateRange: Range<Int> {
        guard !candidates.isEmpty else {
            return 0..<0
        }

        let start = min(page * pageSize, candidates.count)
        let end = min(start + pageSize, candidates.count)
        return start..<end
    }

    var highlightedCandidate: HanjaCandidate? {
        guard candidates.indices.contains(highlightedIndex) else {
            return nil
        }

        return candidates[highlightedIndex]
    }

    var hasHangulRow: Bool {
        let text = mode.manualSourceText ?? mode.realtimeSegmentSurface
        return text?.isEmpty == false
    }

    static func realtimeDefaultHighlightedIsHangul(segment: HanjaSegment) -> Bool {
        // The inline preview is the source of truth. Recomputing a default from candidate usage
        // can highlight 華麗 while the marked text still shows 화려 when the auto-convert gate
        // deliberately left previewCandidate nil.
        segment.previewCandidate == nil
    }

    mutating func moveHighlight(by delta: Int) {
        guard !candidates.isEmpty else {
            highlightedIsHangul = false
            return
        }

        guard delta != 0 else { return }
        let step = delta > 0 ? 1 : -1
        var remaining = abs(delta)
        let count = candidates.count
        let includeHangul = hasHangulRow

        while remaining > 0 {
            if highlightedIsHangul {
                highlightedIsHangul = false
                highlightedIndex = step > 0 ? 0 : count - 1
            } else {
                let next = highlightedIndex + step
                if next >= count {
                    if includeHangul {
                        highlightedIsHangul = true
                    } else {
                        highlightedIndex = 0
                    }
                } else if next < 0 {
                    if includeHangul {
                        highlightedIsHangul = true
                    } else {
                        highlightedIndex = count - 1
                    }
                } else {
                    highlightedIndex = next
                }
            }
            remaining -= 1
        }

        if !highlightedIsHangul {
            page = highlightedIndex / pageSize
        }
    }

    mutating func movePage(by delta: Int) {
        guard pageCount > 0 else {
            highlightedIsHangul = false
            return
        }

        highlightedIsHangul = false
        page = ((page + delta) % pageCount + pageCount) % pageCount
        highlightedIndex = min(page * pageSize, candidates.count - 1)
    }

    func pageNumberLabel(forAbsoluteIndex index: Int) -> String {
        let localIndex = index - visibleCandidateRange.lowerBound
        return "\(localIndex + 1)"
    }

    func candidateForPageNumberIndex(_ index: Int) -> HanjaCandidate? {
        guard index >= 0, index < pageSize else {
            return nil
        }

        let absoluteIndex = visibleCandidateRange.lowerBound + index
        guard candidates.indices.contains(absoluteIndex) else {
            return nil
        }

        return candidates[absoluteIndex]
    }
}

struct RealtimeClauseState: Equatable {
    var rawClauseText = ""
    var tailPreedit = ""
    var previewClauseText = ""
    var segments: [HanjaSegment] = []
    var selectedSegmentIndex: Int?
    var candidateState: HanjaCandidatePanelState?
    var lockedCandidates: [SegmentLockKey: HanjaCandidate] = [:]
    var hangulLockedSegments: Set<SegmentLockKey> = []
    var pendingUsageEvents: [PendingHanjaUsageEvent] = []

    /// 수동 경계 조정(일본어 IME식 문절 신축)이 활성일 때 소스(rawClauseText + tailPreedit)에 대한
    /// 내부 분할 지점들. UTF-16 오프셋, 오름차순, 0 < bᵢ < N. nil이면 Kiwi 자동 분절.
    var manualBoundaries: [Int]? = nil

    /// 포커스 중인 span의 왼쪽 경계 오프셋(안정 식별자). 재분석 후 같은 시작 오프셋의 span으로
    /// 선택을 복원하는 데 쓴다.
    var focusedSpanStart: Int? = nil

    var isEmpty: Bool {
        rawClauseText.isEmpty && tailPreedit.isEmpty
    }

    mutating func refreshPreviewText() {
        previewClauseText = rawClauseText + tailPreedit
        if previewClauseText.isEmpty {
            segments = []
            selectedSegmentIndex = nil
            candidateState = nil
            lockedCandidates = [:]
            hangulLockedSegments = []
            pendingUsageEvents = []
            manualBoundaries = nil
            focusedSpanStart = nil
        }
    }

    mutating func updateAnalysis(segments analyzedSegments: [HanjaSegment]) {
        let sourceText = rawClauseText + tailPreedit
        let previousSelectedKey = selectedSegmentIndex.flatMap { index in
            segments.indices.contains(index) ? SegmentLockKey(segment: segments[index]) : nil
        }

        let refreshedSegments = analyzedSegments.map { segment -> HanjaSegment in
            let lockKey = SegmentLockKey(segment: segment)
            if hangulLockedSegments.contains(lockKey) {
                return segment.replacingPreviewCandidate(nil)
            }

            if let lockedCandidate = lockedCandidates[lockKey] {
                return segment.replacingPreviewCandidate(lockedCandidate)
            }

            return segment
        }

        let validLockKeys = Set(refreshedSegments.map { SegmentLockKey(segment: $0) })
        lockedCandidates = lockedCandidates.filter { validLockKeys.contains($0.key) }
        hangulLockedSegments = hangulLockedSegments.filter { validLockKeys.contains($0) }
        pendingUsageEvents.removeAll { !validLockKeys.contains($0.segmentLockKey) }
        segments = refreshedSegments

        if isManualSegmentation {
            // 수동 모드: 포커스 span(시작 오프셋)으로 선택을 복원한다. 그 span이 일시적으로 비변환이어도
            // 사용자가 계속 신축할 수 있도록 선택을 유지한다(설계 5.3).
            selectedSegmentIndex = focusedSpanStart
                .flatMap { start in refreshedSegments.firstIndex { $0.sourceRange.location == start } }
                ?? Self.defaultSelectedSegmentIndex(in: refreshedSegments)
        } else if let previousSelectedKey,
           let preservedIndex = refreshedSegments.firstIndex(where: { SegmentLockKey(segment: $0) == previousSelectedKey }),
           Self.isSelectableRealtimeSegment(refreshedSegments[preservedIndex]) {
            selectedSegmentIndex = preservedIndex
        } else {
            selectedSegmentIndex = Self.defaultSelectedSegmentIndex(in: refreshedSegments)
        }

        if selectedSegmentIndex == nil {
            candidateState = nil
        }

        previewClauseText = Self.previewText(sourceText: sourceText, segments: refreshedSegments)
    }

    var selectedSegment: HanjaSegment? {
        guard let selectedSegmentIndex,
              segments.indices.contains(selectedSegmentIndex)
        else {
            return nil
        }

        return segments[selectedSegmentIndex]
    }

    mutating func moveSelectedSegment(by delta: Int, wraps: Bool = false) -> Bool {
        let convertibleIndices = segments.indices.filter {
            Self.isSelectableRealtimeSegment(segments[$0])
        }
        guard !convertibleIndices.isEmpty else {
            selectedSegmentIndex = nil
            candidateState = nil
            return false
        }

        let currentIndex = selectedSegmentIndex ?? convertibleIndices[0]
        let nextIndex: Int
        if delta > 0 {
            nextIndex = convertibleIndices.first { $0 > currentIndex }
                ?? (wraps ? convertibleIndices[0] : currentIndex)
        } else if delta < 0 {
            nextIndex = convertibleIndices.last { $0 < currentIndex }
                ?? (wraps ? convertibleIndices[convertibleIndices.count - 1] : currentIndex)
        } else {
            nextIndex = currentIndex
        }

        selectedSegmentIndex = nextIndex
        // 수동 모드에서 평소 ←/→ 이동은 포커스 span도 함께 옮긴다(다음 재분석에서 선택이
        // 포커스로 되돌아오지 않도록).
        if manualBoundaries != nil, segments.indices.contains(nextIndex) {
            focusedSpanStart = segments[nextIndex].sourceRange.location
        }
        if candidateState?.mode.realtimeSegmentIndex != nextIndex {
            candidateState = nil
        }
        return nextIndex != currentIndex
    }

    mutating func setCandidateState(_ state: HanjaCandidatePanelState) {
        candidateState = state
    }

    mutating func updateCandidateState(_ update: (inout HanjaCandidatePanelState) -> Void) {
        guard var state = candidateState else {
            return
        }

        update(&state)
        candidateState = state
    }

    mutating func clearCandidateState() {
        candidateState = nil
    }

    @discardableResult
    mutating func applyCandidateSelection(_ candidate: HanjaCandidate) -> Bool {
        guard let selectedSegmentIndex,
              segments.indices.contains(selectedSegmentIndex)
        else {
            return false
        }

        let segment = segments[selectedSegmentIndex]
        let lockKey = SegmentLockKey(segment: segment)
        hangulLockedSegments.remove(lockKey)
        lockedCandidates[lockKey] = candidate
        pendingUsageEvents.removeAll { $0.segmentLockKey == lockKey }
        pendingUsageEvents.append(
            PendingHanjaUsageEvent(
                segmentLockKey: lockKey,
                lookupKey: segment.normalizedLookupKey,
                value: candidate.value
            )
        )
        segments[selectedSegmentIndex] = segment.replacingPreviewCandidate(candidate)
        previewClauseText = Self.previewText(
            sourceText: rawClauseText + tailPreedit,
            segments: segments
        )
        return true
    }

    /// - Parameter keepingCandidateState: `true` keeps the candidate panel state alive (used by
    ///   the WYSIWYG highlight-preview path, where browsing onto the hangul row must update the
    ///   inline display without closing the panel). `false` (the default) preserves the original
    ///   select-and-dismiss behavior.
    @discardableResult
    mutating func applyHangulFallbackForSelectedSegment(keepingCandidateState: Bool = false) -> Bool {
        guard let selectedSegmentIndex,
              segments.indices.contains(selectedSegmentIndex)
        else {
            return false
        }

        let segment = segments[selectedSegmentIndex]
        let lockKey = SegmentLockKey(segment: segment)
        lockedCandidates.removeValue(forKey: lockKey)
        hangulLockedSegments.insert(lockKey)
        pendingUsageEvents.removeAll { $0.segmentLockKey == lockKey }
        pendingUsageEvents.append(
            PendingHanjaUsageEvent(
                segmentLockKey: lockKey,
                lookupKey: segment.normalizedLookupKey,
                value: segment.normalizedLookupKey
            )
        )
        if !keepingCandidateState {
            candidateState = nil
        }
        segments[selectedSegmentIndex] = segment.replacingPreviewCandidate(nil)
        previewClauseText = Self.previewText(
            sourceText: rawClauseText + tailPreedit,
            segments: segments
        )
        return true
    }

    func displayRangeForSelectedSegment() -> NSRange? {
        guard let selectedSegmentIndex else {
            return nil
        }

        return displayRangeForSegment(at: selectedSegmentIndex)
    }

    func displayRangeForSegment(at index: Int) -> NSRange? {
        guard segments.indices.contains(index) else {
            return nil
        }

        let sourceText = rawClauseText + tailPreedit
        var sourceCursor = sourceText.startIndex
        var previewLocation = 0
        let orderedSegments = segments.enumerated().sorted {
            if $0.element.sourceRange.location != $1.element.sourceRange.location {
                return $0.element.sourceRange.location < $1.element.sourceRange.location
            }

            return $0.element.sourceRange.length < $1.element.sourceRange.length
        }

        for (segmentIndex, segment) in orderedSegments {
            guard let sourceRange = Range(segment.sourceRange, in: sourceText),
                  sourceCursor <= sourceRange.lowerBound
            else {
                continue
            }

            previewLocation += inputUTF16Length(of: String(sourceText[sourceCursor..<sourceRange.lowerBound]))
            let segmentDisplayText = segment.previewCandidate?.value ?? String(sourceText[sourceRange])
            let segmentDisplayLength = inputUTF16Length(of: segmentDisplayText)
            if segmentIndex == index {
                return NSRange(location: previewLocation, length: segmentDisplayLength)
            }

            previewLocation += segmentDisplayLength
            sourceCursor = sourceRange.upperBound
        }

        return nil
    }

    nonisolated private static func defaultSelectedSegmentIndex(in segments: [HanjaSegment]) -> Int? {
        segments.firstIndex(where: isSelectableRealtimeSegment)
    }

    nonisolated private static func isSelectableRealtimeSegment(_ segment: HanjaSegment) -> Bool {
        segment.isConvertible
    }

    static func previewText(sourceText: String, segments: [HanjaSegment]) -> String {
        guard !sourceText.isEmpty, !segments.isEmpty else {
            return sourceText
        }

        var result = ""
        var cursor = sourceText.startIndex
        let orderedSegments = segments.sorted {
            if $0.sourceRange.location != $1.sourceRange.location {
                return $0.sourceRange.location < $1.sourceRange.location
            }

            return $0.sourceRange.length < $1.sourceRange.length
        }

        for segment in orderedSegments {
            guard let range = Range(segment.sourceRange, in: sourceText),
                  cursor <= range.lowerBound
            else {
                continue
            }

            result += sourceText[cursor..<range.lowerBound]
            result += segment.previewCandidate?.value ?? String(sourceText[range])
            cursor = range.upperBound
        }

        result += sourceText[cursor..<sourceText.endIndex]
        return result
    }
}

extension RealtimeClauseState {
    var isManualSegmentation: Bool { manualBoundaries != nil }

    private var manualSourceText: String { rawClauseText + tailPreedit }

    /// 현재 `segments`(+gap)로부터 소스 전체 `[0, N]`을 빈틈없는 연속 span으로 분할(seed)한다.
    /// 이미 수동 모드면 아무것도 하지 않는다. seed 후 현재 선택 분절을 포커스로 잡는다.
    mutating func seedManualBoundariesIfNeeded() {
        guard manualBoundaries == nil else { return }
        let source = manualSourceText
        let n = inputUTF16Length(of: source)
        guard n > 0 else { return }

        var points = Set<Int>()
        for segment in segments {
            let start = segment.sourceRange.location
            let end = segment.sourceRange.location + segment.sourceRange.length
            if start > 0, start < n { points.insert(start) }
            if end > 0, end < n { points.insert(end) }
        }
        manualBoundaries = points.sorted()
        focusedSpanStart = selectedSegment?.sourceRange.location ?? 0
    }

    /// 포커스 span의 오른쪽 경계를 delta 글자(+1: 확장 / -1: 축소)만큼 이동한다.
    /// 한 글자는 소스의 1 grapheme이며 UTF-16 오프셋으로 환산한다.
    /// 클램프: focus span 최소 길이 1, 소스 끝 N 초과 금지, 이웃 경계와 만나면 병합.
    /// 반환: 경계가 실제로 바뀌었으면 true.
    @discardableResult
    mutating func adjustFocusedBoundary(byCharacters delta: Int) -> Bool {
        guard delta != 0, manualBoundaries != nil else { return false }
        let source = manualSourceText
        let n = inputUTF16Length(of: source)
        guard n > 0 else { return false }

        // 평소 ←/→로 옮긴 선택을 반영해 포커스를 동기화한다(선택이 없으면 기존 포커스 유지).
        if let selectedStart = selectedSegment?.sourceRange.location {
            focusedSpanStart = selectedStart
        }
        let focusStart = focusedSpanStart ?? 0

        var changed = false
        for _ in 0..<abs(delta) {
            guard moveFocusedBoundaryOneStep(expanding: delta > 0, focusStart: focusStart, source: source, n: n) else {
                break
            }
            changed = true
        }
        return changed
    }

    /// 소스 편집(타이핑/Backspace/Space) 시 오버레이를 버리고 Kiwi 자동 분절로 복귀한다.
    mutating func clearManualSegmentation() {
        manualBoundaries = nil
        focusedSpanStart = nil
    }

    private mutating func moveFocusedBoundaryOneStep(
        expanding: Bool, focusStart: Int, source: String, n: Int
    ) -> Bool {
        var edges = [0] + (manualBoundaries ?? []) + [n]   // 0 < bᵢ < n, 오름차순
        guard let i = edges.firstIndex(of: focusStart), i + 1 < edges.count else {
            return false
        }
        let leftEdge = edges[i]
        let rightEdge = edges[i + 1]
        let isLastSpan = (i + 1 == edges.count - 1)        // rightEdge == n

        if expanding {
            // 마지막 span은 더 늘릴 글자가 없음.
            guard !isLastSpan,
                  let next = realtimeGraphemeOffset(from: rightEdge, in: source, forward: true) else {
                return false
            }
            let limit = edges[i + 2]                        // 이웃(오른쪽) span의 오른쪽 경계
            let newRight = min(next, limit)
            guard newRight > rightEdge else { return false }
            if newRight == limit {
                edges.remove(at: i + 1)                     // 이웃 span 소멸 → 경계 병합
            } else {
                edges[i + 1] = newRight
            }
        } else {
            guard let prev = realtimeGraphemeOffset(from: rightEdge, in: source, forward: false),
                  prev > leftEdge else {                    // focus span 최소 길이 1
                return false
            }
            if isLastSpan {
                edges.insert(prev, at: i + 1)               // 마지막 span 축소 → N-1 지점에 새 경계
            } else {
                edges[i + 1] = prev
            }
        }

        manualBoundaries = Array(edges.dropFirst().dropLast())
        return true
    }
}

/// `offset`(UTF-16) 위치에서 한 grapheme 앞/뒤 경계의 UTF-16 오프셋을 구한다.
/// 경계가 소스의 끝/시작을 넘으면 nil.
private func realtimeGraphemeOffset(from offset: Int, in text: String, forward: Bool) -> Int? {
    let utf16 = text.utf16
    guard let unit = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
          let charIndex = unit.samePosition(in: text) else {
        return nil
    }

    if forward {
        guard charIndex < text.endIndex else { return nil }
        let next = text.index(after: charIndex)
        return next.samePosition(in: utf16).map { utf16.distance(from: utf16.startIndex, to: $0) }
    }

    guard charIndex > text.startIndex else { return nil }
    let prev = text.index(before: charIndex)
    return prev.samePosition(in: utf16).map { utf16.distance(from: utf16.startIndex, to: $0) }
}

enum RealtimeClauseAutoCommitPolicy {
    static func shouldCommitBeforeInserting(_ character: Character) -> Bool {
        if sentenceBoundaryCharacters.contains(character) {
            return true
        }

        guard let ascii = character.asciiValue else {
            return false
        }

        return (ascii >= 0x41 && ascii <= 0x5A)
            || (ascii >= 0x61 && ascii <= 0x7A)
    }

    private static let sentenceBoundaryCharacters: Set<Character> = [".", "?", "!", ";", "\n", "\r"]
}
