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

struct InputCompositionEngine {
    let client: any IMKTextInput
    let session: InputSession
    let analyzeRealtimeClause: (String) -> [HanjaSegment]
    let flushRealtimeUsageEvents: ([PendingHanjaUsageEvent]) -> Void
    let updateComposition: () -> Void
    let debugLog: (String) -> Void

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
                "update preedit=\(preeditText) selected=\(inputDebugRangeString(client.selectedRange())) clientMarked=\(inputDebugRangeString(clientMarkedRange)) sessionReplacement=\(inputDebugRangeString(session.currentReplacementRange)) mode=\(session.rangeHandlingDescription)"
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
            debugLog("appendRealtimeCommitted text=\(committed) display=\(session.realtimeDisplayText)")
            return
        }

        let replacementRange = effectiveReplacementRange()
        debugLog(
            "insertCommitted text=\(committed) replacement=\(inputDebugRangeString(replacementRange)) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
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
                "commit text=\(textToCommit) replacement=\(inputDebugRangeString(replacementRange)) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
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
            "cancelRealtime display=\(session.realtimeDisplayText) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
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

    private func updateRealtimeDisplay() {
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
            "updateRealtime display=\(displayText) selected=\(inputDebugRangeString(client.selectedRange())) clientMarked=\(inputDebugRangeString(clientMarkedRange)) sessionReplacement=\(inputDebugRangeString(session.currentReplacementRange)) mode=\(session.rangeHandlingDescription)"
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
            "commitRealtime text=\(textToCommit) replacement=\(inputDebugRangeString(replacementRange)) marked=\(inputDebugRangeString(client.markedRange())) selected=\(inputDebugRangeString(client.selectedRange()))"
        )
        client.insertText(textToCommit, replacementRange: replacementRange)
        flushRealtimeUsageEvents(session.drainPendingRealtimeUsageEvents())
        session.reset()
    }

    private func updateRealtimeAnalysis() {
        let sourceText = session.realtimeClauseState.rawClauseText + session.realtimeClauseState.tailPreedit
        guard !sourceText.isEmpty else {
            return
        }

        let segments = analyzeRealtimeClause(sourceText)
        session.updateRealtimeAnalysis(segments: segments)
    }
}
