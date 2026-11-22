// Marked-text and replacement-range bookkeeping for IMKTextInput.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import IMKSwift

func inputDebugRangeString(_ range: NSRange) -> String {
    "{loc=\(range.location), len=\(range.length)}"
}

func inputMarkedAttributedString(_ text: String) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.underlineStyle: 0])
}

func inputRealtimeMarkedAttributedString(_ state: RealtimeClauseState) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(
        string: state.previewClauseText,
        attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
    )
    guard let selectedRange = state.displayRangeForSelectedSegment(),
          selectedRange.length > 0
    else {
        return attributedString
    }

    attributedString.addAttributes(
        [
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.18),
        ],
        range: selectedRange
    )

    return attributedString
}

/// Sentence-boundary characters used by `documentContextWindow(from:)` to find where the last two
/// complete sentences begin. Mirrors `RealtimeClauseAutoCommitPolicy`'s ASCII sentence enders plus
/// the full-width Korean/CJK equivalents (`。？！`) that plain `.`/`?`/`!` don't cover in Korean text.
private let documentContextSentenceBoundaryCharacters: Set<Character> = [".", "?", "!", "\n", "。", "？", "！"]

/// R1b pure truncation (docs/plans/hanja-context-scaling-plan.md §6, unit-tested standalone by
/// `DocumentContextFetchTests`): refines a raw pre-cursor text window down to at most the last two
/// complete sentences plus the trailing (incomplete, right-before-cursor) fragment. "마지막 2개
/// 문장 경계" is read here as "the boundary that starts those last two sentences" — everything
/// strictly before it is cut. Fewer than 3 boundary characters in the window means there's nothing
/// meaningful to cut (the window already holds at most ~2 sentences), so the whole (capped) window
/// is kept as-is.
///
/// Independently re-caps to `InputCompositionEngine.documentContextWindowMaxUTF16Length` UTF-16
/// units by keeping the TRAILING units (closest to the cursor) — the caller's fetch range is
/// already capped, but this function is exercised standalone in tests with arbitrary input. The
/// re-cap snaps forward to the nearest valid grapheme boundary so a surrogate pair (or combining
/// cluster) is never split.
func documentContextWindow(from text: String) -> String {
    let capped = documentContextCapToTrailingUTF16Units(
        of: text, maxLength: InputCompositionEngine.documentContextWindowMaxUTF16Length
    )
    guard !capped.isEmpty else {
        return capped
    }

    var boundaryEndIndices: [String.Index] = []
    var cursor = capped.startIndex
    while cursor < capped.endIndex {
        if documentContextSentenceBoundaryCharacters.contains(capped[cursor]) {
            boundaryEndIndices.append(capped.index(after: cursor))
        }
        cursor = capped.index(after: cursor)
    }

    guard boundaryEndIndices.count >= 3 else {
        return capped
    }

    let cutIndex = boundaryEndIndices[boundaryEndIndices.count - 3]
    return String(capped[cutIndex...])
}

/// Keeps the trailing `maxLength` UTF-16 units of `text` (or all of it if already shorter),
/// snapping the cut point FORWARD to the nearest character (grapheme cluster) boundary so a
/// surrogate pair is never split in half.
private func documentContextCapToTrailingUTF16Units(of text: String, maxLength: Int) -> String {
    guard text.utf16.count > maxLength else {
        return text
    }

    let utf16View = text.utf16
    var cutUTF16Index = utf16View.index(utf16View.endIndex, offsetBy: -maxLength)
    while cutUTF16Index < utf16View.endIndex, cutUTF16Index.samePosition(in: text) == nil {
        cutUTF16Index = utf16View.index(after: cutUTF16Index)
    }
    guard let stringIndex = cutUTF16Index.samePosition(in: text) else {
        return text
    }
    return String(text[stringIndex...])
}

struct InputCompositionEngine {
    /// R1b (docs/plans/hanja-context-scaling-plan.md §6): max UTF-16 length of the pre-cursor
    /// document-context fetch window. Shared by `fetchDocumentContextIfNeeded` (the fetch range)
    /// and `documentContextWindow(from:)` (its own independent re-cap for unit testing).
    static let documentContextWindowMaxUTF16Length = 200

    let client: any IMKTextInput
    let session: InputSession
    let analyzeRealtimeClause: (String, Int, HanjaSessionScoringInputs?) -> RealtimeClauseAnalysis
    let analyzeManualClause: (String, [Int]) -> [HanjaSegment]
    var rankManualClause: ([HanjaSegment], [HanjaSegment], HanjaSessionScoringInputs?) -> [HanjaSegment] = { segments, _, _ in segments }
    /// R1b: analyzes the document-context fetch window into content-morpheme features (same
    /// feature space as `analyzeRealtimeClause`'s clause features). Defaults to "no features" so
    /// call sites that predate R1b (only test helpers today) don't need to be touched. `var` (not
    /// `let`) so the default is actually overridable via the memberwise init — a `let` stored
    /// property with an inline default is fixed and excluded from the synthesized init entirely.
    var analyzeDocumentContext: (String) -> [String] = { _ in [] }
    let flushRealtimeUsageEvents: ([PendingHanjaUsageEvent]) -> Void
    let updateComposition: () -> Void
    let debugLog: (String) -> Void
    /// R1b test-injection point: production defers the document-context Kiwi analysis to the next
    /// run-loop turn via `DispatchQueue.main.async` so it never blocks the current keystroke's
    /// response (see `fetchDocumentContextIfNeeded`'s doc); tests inject an immediate-execution
    /// closure so `documentContextFeatures` is observable synchronously within the same test. `var`
    /// for the same memberwise-init-default reason as `analyzeDocumentContext` above.
    var scheduleDocumentContextAnalysis: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    func updateDisplay() {
        if session.isRealtimeHanjaMode {
            updateRealtimeDisplay()
            return
        }

        let preeditText = session.preeditText

        if preeditText.isEmpty {
            clearMarkedText()
            session.finishComposition()
        } else {
            session.beginCompositionIfNeeded(with: client.selectedRange())
            updateComposition()
            let clientMarkedRange = client.markedRange()
            session.syncMarkedTextRange(clientRange: clientMarkedRange)
            debugLog(
                "update preeditLength=\(preeditText.utf16.count) selected=\(inputDebugRangeString(client.selectedRange())) clientMarked=\(inputDebugRangeString(clientMarkedRange)) sessionReplacement=\(inputDebugRangeString(session.currentReplacementRange)) mode=\(session.rangeHandlingDescription)"
            )
        }
    }

    func clearMarkedText() {
        if let markedRange = effectiveMarkedRange() {
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: markedRange
            )
        }

        if let textClient = client as? any NSTextInputClient, textClient.hasMarkedText() {
            textClient.unmarkText()
        }

        session.clearMarkedText()
    }

    func insertCommittedTextIfNeeded() {
        let committed = session.committedText
        guard !committed.isEmpty else {
            return
        }

        if session.isRealtimeHanjaMode {
            session.appendCommittedTextToRealtimeClause(committed)
            debugLog("appendRealtimeCommitted textLength=\(committed.utf16.count) displayLength=\(session.realtimeDisplayText.utf16.count)")
            return
        }

        let replacementRange = effectiveReplacementRange()
        debugLog(
            "insertCommitted textLength=\(committed.utf16.count) replacement=\(inputDebugRangeString(replacementRange)) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
        )
        client.insertText(committed, replacementRange: replacementRange)
        session.didInsertCommittedText(length: inputUTF16Length(of: committed), replacedRange: replacementRange)
    }

    func commitCurrentComposition() {
        if session.isRealtimeHanjaMode {
            commitRealtimeComposition()
            return
        }

        var textToCommit = session.committedText
        let flushed = session.flushText()
        if !flushed.isEmpty {
            textToCommit += flushed
        }

        if textToCommit.isEmpty {
            clearMarkedText()
        } else {
            let replacementRange = effectiveReplacementRange()
            debugLog(
                "commit textLength=\(textToCommit.utf16.count) replacement=\(inputDebugRangeString(replacementRange)) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
            )
            client.insertText(textToCommit, replacementRange: replacementRange)
        }

        session.reset()
    }

    func cancelRealtimeComposition() {
        guard session.isRealtimeHanjaMode else {
            clearMarkedText()
            session.reset()
            return
        }

        debugLog(
            "cancelRealtime displayLength=\(session.realtimeDisplayText.utf16.count) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
        )
        session.resetHangulState()
        clearMarkedText()
        session.clearRealtimeClauseState()
        session.finishComposition()
    }

    func insertSpace() {
        client.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    static func replacementRange(forSelection selectedRange: NSRange) -> NSRange {
        guard selectedRange.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }

        return selectedRange
    }

    private func effectiveMarkedRange() -> NSRange? {
        if let markedRange = session.markedTextRange {
            return markedRange
        }

        guard let textClient = client as? any NSTextInputClient else {
            return nil
        }

        let markedRange = textClient.markedRange()
        guard markedRange.location != NSNotFound else {
            return nil
        }

        return markedRange
    }

    private func effectiveReplacementRange() -> NSRange {
        effectiveMarkedRange() ?? session.currentReplacementRange
    }

    /// R1b (docs/plans/hanja-context-scaling-plan.md §6): once per composition, fetches the
    /// already-committed document text just before the cursor and folds it into the session
    /// ranking context — so even a freshly-started session (process restart / client switch, no
    /// `hanjaSessionContext` history yet) gets SOME context from text the user already wrote.
    ///
    /// Client IPC (`selectedRange`/`attributedSubstring`) happens SYNCHRONOUSLY here, at the very
    /// top of `updateRealtimeDisplay()` — before any `setMarkedText` call this composition — since
    /// the cursor position is only meaningful at this instant, and marked text would otherwise
    /// contaminate what "before the cursor" means. Kiwi analysis of the fetched (already-truncated)
    /// text is deferred via `scheduleDocumentContextAnalysis` (production: `DispatchQueue.main.async`)
    /// so it never blocks the current keystroke's response — `session.sessionScoringInputs` only
    /// reflects it starting the NEXT keystroke. Kiwi remains main-thread-only (no background queue).
    ///
    /// Every step fails quietly (NSNotFound / location 0 / nil / empty substring / empty truncated
    /// window) — no exception, no retry; `InputSession.sessionScoringInputs` already degrades to
    /// session-buffer-only when `documentContextFeatures` stays nil, so this function itself needs
    /// no explicit fallback logic beyond returning early.
    ///
    /// Privacy (docs/plans/hanja-context-scaling-plan.md §1 common rules): the fetched text is held
    /// only in this function's and the scheduled closure's local scope, long enough to truncate and
    /// analyze, then discarded — only the resulting `[String]` features are stored. The `debugLog`
    /// below is numbers-only (elapsed µs, character/feature counts) — never the text or features.
    func fetchDocumentContextIfNeeded() {
        guard session.isRealtimeHanjaMode, !session.documentContextFetchAttempted else {
            return
        }
        session.markDocumentContextFetchAttempted()

        let fetchStart = DispatchTime.now()
        let selectedRange = client.selectedRange()
        guard selectedRange.location != NSNotFound, selectedRange.location > 0 else {
            return
        }

        let windowStart = max(0, selectedRange.location - Self.documentContextWindowMaxUTF16Length)
        let windowRange = NSRange(location: windowStart, length: selectedRange.location - windowStart)
        guard windowRange.length > 0,
              let attributedText = client.attributedSubstring(from: windowRange),
              !attributedText.string.isEmpty
        else {
            return
        }

        let windowText = documentContextWindow(from: attributedText.string)
        guard !windowText.isEmpty else {
            return
        }

        let fetchElapsedMicroseconds = Double(DispatchTime.now().uptimeNanoseconds - fetchStart.uptimeNanoseconds) / 1000.0
        let characterCount = windowText.utf16.count

        scheduleDocumentContextAnalysis {
            let analyzeStart = DispatchTime.now()
            let features = analyzeDocumentContext(windowText)
            let analyzeElapsedMicroseconds = Double(DispatchTime.now().uptimeNanoseconds - analyzeStart.uptimeNanoseconds) / 1000.0
            session.setDocumentContextFeatures(features)
            debugLog(
                "documentContext fetch=\(String(format: "%.1f", fetchElapsedMicroseconds))µs analyze=\(String(format: "%.1f", analyzeElapsedMicroseconds))µs chars=\(characterCount) features=\(features.count)"
            )
        }
    }

    private func updateRealtimeDisplay() {
        fetchDocumentContextIfNeeded()
        session.syncRealtimeTailPreedit()
        updateRealtimeAnalysis()
        let displayText = session.realtimeDisplayText

        if displayText.isEmpty {
            clearMarkedText()
            session.clearRealtimeClauseState()
            session.finishComposition()
            return
        }

        session.beginCompositionIfNeeded(with: client.selectedRange())
        updateComposition()
        let clientMarkedRange = client.markedRange()
        session.syncMarkedTextRange(clientRange: clientMarkedRange)
        debugLog(
            "updateRealtime displayLength=\(displayText.utf16.count) selected=\(inputDebugRangeString(client.selectedRange())) clientMarked=\(inputDebugRangeString(clientMarkedRange)) sessionReplacement=\(inputDebugRangeString(session.currentReplacementRange)) mode=\(session.rangeHandlingDescription)"
        )
    }

    private func commitRealtimeComposition() {
        let flushed = session.flushText()
        if !flushed.isEmpty {
            session.appendCommittedTextToRealtimeClause(flushed)
        } else {
            session.syncRealtimeTailPreedit()
        }
        updateRealtimeAnalysis()

        let textToCommit = session.realtimeDisplayText
        if textToCommit.isEmpty {
            clearMarkedText()
            session.reset()
            return
        }

        let replacementRange = effectiveReplacementRange()
        debugLog(
            "commitRealtime textLength=\(textToCommit.utf16.count) replacement=\(inputDebugRangeString(replacementRange)) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
        )
        client.insertText(textToCommit, replacementRange: replacementRange)
        // R1a (docs/plans/hanja-context-scaling-plan.md §6): must run BEFORE session.reset() below
        // — it reads realtimeClauseState, which reset() clears.
        session.recordRealtimeCommitToSessionContext()
        flushRealtimeUsageEvents(session.drainPendingRealtimeUsageEvents())
        session.reset()
    }

    private func updateRealtimeAnalysis() {
        let state = session.realtimeClauseState
        let sourceText = state.rawClauseText + state.tailPreedit
        guard !sourceText.isEmpty else {
            return
        }

        // 수동 경계 오버레이가 있으면 재분석이 그것을 존중한다(Kiwi 재분절 중단).
        if let boundaries = state.manualBoundaries {
            let segments = analyzeManualClause(sourceText, boundaries)
            session.updateRealtimeAnalysis(segments: rankManualClause(segments, state.automaticContextSegments, session.sessionScoringInputs))
        } else {
            // tailPreedit is still-composing (uncommitted) — its offset is passed through so the
            // context-feature axis can ignore tokens overlapping it (see KiwiAnalysisService.
            // analyzeClause's composingTailStart doc). Segmentation still uses the full sourceText.
            let composingTailStart = inputUTF16Length(of: state.rawClauseText)
            let analysis = analyzeRealtimeClause(sourceText, composingTailStart, session.sessionScoringInputs)
            session.updateRealtimeAnalysis(segments: analysis.segments, clauseContentFeatures: analysis.clauseContentFeatures)
        }
    }
}
