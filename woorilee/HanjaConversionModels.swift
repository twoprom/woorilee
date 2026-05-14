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

    init(
        id: UUID = UUID(),
        sourceRange: NSRange,
        surface: String,
        normalizedLookupKey: String,
        tag: POSTag,
        isConvertible: Bool,
        previewCandidate: HanjaCandidate?
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.surface = surface
        self.normalizedLookupKey = normalizedLookupKey
        self.tag = tag
        self.isConvertible = isConvertible
        self.previewCandidate = previewCandidate
    }

    func replacingPreviewCandidate(_ candidate: HanjaCandidate?) -> HanjaSegment {
        HanjaSegment(
            id: id,
            sourceRange: sourceRange,
            surface: surface,
            normalizedLookupKey: normalizedLookupKey,
            tag: tag,
            isConvertible: isConvertible,
            previewCandidate: candidate
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

    static func realtimeDefaultHighlightedIsHangul(
        segment: HanjaSegment,
        candidates: [HanjaCandidate],
        hangulUsage: Int
    ) -> Bool {
        if NumericHanjaCandidateGenerator.isNumericCandidateSource(segment.normalizedLookupKey) {
            return true
        }

        let topHanjaUsage = candidates.first?.usageCount ?? 0
        return hangulUsage > 0 && hangulUsage >= topHanjaUsage
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

        if let previousSelectedKey,
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

    @discardableResult
    mutating func applyHangulFallbackForSelectedSegment() -> Bool {
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
        candidateState = nil
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
