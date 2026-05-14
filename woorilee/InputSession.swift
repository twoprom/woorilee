// Per-client input session state and session cache.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import Foundation
import IMKSwift
import LibHangul

func inputUTF16Length(of text: String) -> Int {
    text.utf16.count
}

private func inputUCSCharsToString(_ chars: [UCSChar]) -> String {
    var text = ""
    text.unicodeScalars.append(contentsOf: chars.compactMap { UnicodeScalar($0) })

    let normalizedText = text.precomposedStringWithCanonicalMapping
    var convertedText = ""

    for scalar in normalizedText.unicodeScalars {
        let value = UCSChar(scalar.value)
        if inputIsCombiningHangulJamo(value),
           let compatibilityScalar = UnicodeScalar(HangulCharacter.jamoToCJamo(value)) {
            convertedText.unicodeScalars.append(compatibilityScalar)
        } else {
            convertedText.unicodeScalars.append(scalar)
        }
    }

    return convertedText
}

private func inputIsCombiningHangulJamo(_ value: UCSChar) -> Bool {
    (0x1100...0x11FF).contains(value)
}

struct InputRangeState {
    private(set) var compositionStartRange: NSRange?
    private(set) var currentMarkedRange: NSRange?
    private(set) var usesImplicitReplacementRange = false

    var markedTextRange: NSRange? {
        currentMarkedRange
    }

    var currentReplacementRange: NSRange {
        if let currentMarkedRange {
            return currentMarkedRange
        }

        if usesImplicitReplacementRange {
            return NSRange(location: NSNotFound, length: 0)
        }

        return compositionStartRange ?? NSRange(location: NSNotFound, length: 0)
    }

    var rangeHandlingDescription: String {
        if currentMarkedRange != nil {
            return "client-marked"
        }

        if usesImplicitReplacementRange {
            return "implicit"
        }

        if compositionStartRange != nil {
            return "initial-selection"
        }

        return "none"
    }

    mutating func beginCompositionIfNeeded(with selectedRange: NSRange) {
        guard compositionStartRange == nil, currentMarkedRange == nil, !usesImplicitReplacementRange else {
            return
        }

        guard selectedRange.location != NSNotFound else {
            compositionStartRange = NSRange(location: NSNotFound, length: 0)
            return
        }

        compositionStartRange = selectedRange
    }

    mutating func syncMarkedTextRange(clientRange: NSRange) {
        if clientRange.location != NSNotFound {
            currentMarkedRange = clientRange
            usesImplicitReplacementRange = false
            return
        }

        currentMarkedRange = nil
        usesImplicitReplacementRange = true
    }

    mutating func didInsertCommittedText(length: Int, replacedRange: NSRange) {
        guard replacedRange.location != NSNotFound else {
            compositionStartRange = nil
            currentMarkedRange = nil
            usesImplicitReplacementRange = true
            return
        }

        compositionStartRange = NSRange(location: replacedRange.location + length, length: 0)
        currentMarkedRange = nil
        usesImplicitReplacementRange = false
    }

    mutating func clearMarkedText() {
        guard let currentMarkedRange else {
            return
        }

        compositionStartRange = NSRange(location: currentMarkedRange.location, length: 0)
        self.currentMarkedRange = nil
        usesImplicitReplacementRange = false
    }

    mutating func finishComposition() {
        compositionStartRange = nil
        currentMarkedRange = nil
        usesImplicitReplacementRange = false
    }
}

struct PendingManualHanjaTrigger: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let armedAtUptime: TimeInterval
}

@MainActor
final class InputSessionCache {
    private static let cache = NSMapTable<AnyObject, InputSession>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: [.strongMemory]
    )

    static func session(for client: any IMKTextInput) -> InputSession {
        let key = client as AnyObject

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let newSession = InputSession()
        cache.setObject(newSession, forKey: key)
        return newSession
    }
}

@MainActor
final class InputSession {
    private let hangul = LibHangul.createThreadSafeInputContext(keyboard: "2")
    private var rangeState = InputRangeState()
    private(set) var compositionMode: CompositionMode = .hangul
    private(set) var realtimeClauseState = RealtimeClauseState()
    private(set) var manualCandidateState: HanjaCandidatePanelState?
    private(set) var manualNoticeState: ManualHanjaNoticeState?
    private(set) var pendingManualReplacementRange: NSRange?
    private(set) var pendingManualLookupKey: String?
    private(set) var pendingManualHanjaTrigger: PendingManualHanjaTrigger?
    private(set) var pendingManualHanjaNewlineSuppressionUptime: TimeInterval?
    private var manualHanjaNewlineSuppressionGeneration = 0

    var preeditText: String {
        inputUCSCharsToString(hangul.getPreeditString())
    }

    var hasPendingHangulText: Bool {
        !preeditText.isEmpty
    }

    var isRealtimeHanjaMode: Bool {
        compositionMode == .realtimeHanja
    }

    var hasRealtimeClause: Bool {
        !realtimeClauseState.isEmpty
    }

    var realtimeDisplayText: String {
        realtimeClauseState.previewClauseText
    }

    var committedText: String {
        inputUCSCharsToString(hangul.getCommitString())
    }

    var markedTextRange: NSRange? {
        rangeState.markedTextRange
    }

    var currentReplacementRange: NSRange {
        rangeState.currentReplacementRange
    }

    var rangeHandlingDescription: String {
        rangeState.rangeHandlingDescription
    }

    var isShowingManualCandidates: Bool {
        manualCandidateState != nil
    }

    var isShowingManualNotice: Bool {
        manualNoticeState != nil
    }

    var isShowingManualPanel: Bool {
        manualCandidateState != nil || manualNoticeState != nil
    }

    var isShowingRealtimeCandidates: Bool {
        realtimeClauseState.candidateState != nil
    }

    var realtimeCandidateState: HanjaCandidatePanelState? {
        realtimeClauseState.candidateState
    }

    var selectedRealtimeSegment: HanjaSegment? {
        realtimeClauseState.selectedSegment
    }

    func process(_ char: Character) -> Bool {
        hangul.process(char)
    }

    func backspace() -> Bool {
        hangul.backspace()
    }

    func flushText() -> String {
        inputUCSCharsToString(hangul.flush())
    }

    func beginCompositionIfNeeded(with selectedRange: NSRange) {
        rangeState.beginCompositionIfNeeded(with: selectedRange)
    }

    func syncMarkedTextRange(clientRange: NSRange) {
        rangeState.syncMarkedTextRange(clientRange: clientRange)
    }

    func didInsertCommittedText(length: Int, replacedRange: NSRange) {
        rangeState.didInsertCommittedText(length: length, replacedRange: replacedRange)
    }

    func clearMarkedText() {
        rangeState.clearMarkedText()
    }

    func finishComposition() {
        rangeState.finishComposition()
    }

    func beginRealtimeClauseIfNeeded() {
        if compositionMode != .realtimeHanja {
            compositionMode = .realtimeHanja
            realtimeClauseState = RealtimeClauseState()
        }

        refreshRealtimePreviewText()
    }

    func appendCommittedTextToRealtimeClause(_ text: String) {
        beginRealtimeClauseIfNeeded()
        realtimeClauseState.rawClauseText += text
        syncRealtimeTailPreedit()
    }

    func appendRawTextToRealtimeClause(_ text: String) {
        beginRealtimeClauseIfNeeded()
        realtimeClauseState.rawClauseText += text
        syncRealtimeTailPreedit()
    }

    func appendSpaceToRealtimeClause() {
        appendRawTextToRealtimeClause(" ")
    }

    func syncRealtimeTailPreedit() {
        guard compositionMode == .realtimeHanja else {
            return
        }

        realtimeClauseState.tailPreedit = preeditText
        refreshRealtimePreviewText()
    }

    func updateRealtimeAnalysis(segments: [HanjaSegment]) {
        guard compositionMode == .realtimeHanja else {
            return
        }

        realtimeClauseState.updateAnalysis(segments: segments)
    }

    @discardableResult
    func moveRealtimeSegmentSelection(by delta: Int, wraps: Bool = false) -> Bool {
        guard compositionMode == .realtimeHanja else {
            return false
        }

        return realtimeClauseState.moveSelectedSegment(by: delta, wraps: wraps)
    }

    func setRealtimeCandidateState(_ state: HanjaCandidatePanelState) {
        guard compositionMode == .realtimeHanja else {
            return
        }

        realtimeClauseState.setCandidateState(state)
    }

    func updateRealtimeCandidateState(_ update: (inout HanjaCandidatePanelState) -> Void) {
        guard compositionMode == .realtimeHanja else {
            return
        }

        realtimeClauseState.updateCandidateState(update)
    }

    func clearRealtimeCandidateState() {
        realtimeClauseState.clearCandidateState()
    }

    @discardableResult
    func applyRealtimeCandidateSelection(_ candidate: HanjaCandidate) -> Bool {
        guard compositionMode == .realtimeHanja else {
            return false
        }

        return realtimeClauseState.applyCandidateSelection(candidate)
    }

    @discardableResult
    func applyRealtimeHangulFallbackForSelectedSegment() -> Bool {
        guard compositionMode == .realtimeHanja else {
            return false
        }

        return realtimeClauseState.applyHangulFallbackForSelectedSegment()
    }

    func drainPendingRealtimeUsageEvents() -> [PendingHanjaUsageEvent] {
        let events = realtimeClauseState.pendingUsageEvents
        realtimeClauseState.pendingUsageEvents = []
        return events
    }

    @discardableResult
    func deleteLastRealtimeRawCharacter() -> Bool {
        guard compositionMode == .realtimeHanja,
              !realtimeClauseState.rawClauseText.isEmpty
        else {
            return false
        }

        realtimeClauseState.rawClauseText.removeLast()
        syncRealtimeTailPreedit()
        if realtimeClauseState.isEmpty {
            compositionMode = .hangul
        }
        return true
    }

    func clearRealtimeClauseState() {
        realtimeClauseState = RealtimeClauseState()
        if compositionMode == .realtimeHanja {
            compositionMode = .hangul
        }
    }

    func setManualCandidateState(_ state: HanjaCandidatePanelState, lookupKey: String) {
        compositionMode = .manualHanja
        manualCandidateState = state
        manualNoticeState = nil
        pendingManualReplacementRange = state.mode.manualReplacementRange
        pendingManualLookupKey = lookupKey
    }

    func updateManualCandidateState(_ update: (inout HanjaCandidatePanelState) -> Void) {
        guard var state = manualCandidateState else {
            return
        }

        update(&state)
        manualCandidateState = state
    }

    func setManualNoticeState(_ state: ManualHanjaNoticeState) {
        compositionMode = .manualHanja
        manualCandidateState = nil
        manualNoticeState = state
        pendingManualReplacementRange = nil
        pendingManualLookupKey = nil
    }

    func clearManualCandidateState() {
        clearManualPanelState()
    }

    func clearManualPanelState() {
        manualCandidateState = nil
        manualNoticeState = nil
        pendingManualReplacementRange = nil
        pendingManualLookupKey = nil
        if compositionMode == .manualHanja {
            compositionMode = .hangul
        }
    }

    func armManualHanjaTrigger(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        pendingManualHanjaTrigger = PendingManualHanjaTrigger(
            keyCode: keyCode,
            modifiers: modifiers,
            armedAtUptime: uptime
        )
    }

    func consumeManualHanjaTriggerIfArmedForNewline(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        maxAge: TimeInterval = 1.0
    ) -> PendingManualHanjaTrigger? {
        guard let pendingManualHanjaTrigger else {
            return nil
        }

        self.pendingManualHanjaTrigger = nil
        guard nowUptime - pendingManualHanjaTrigger.armedAtUptime <= maxAge else {
            return nil
        }

        return pendingManualHanjaTrigger
    }

    func clearManualHanjaTrigger() {
        pendingManualHanjaTrigger = nil
    }

    func suppressNextManualHanjaNewline(
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        manualHanjaNewlineSuppressionGeneration += 1
        let generation = manualHanjaNewlineSuppressionGeneration
        pendingManualHanjaNewlineSuppressionUptime = uptime
        DispatchQueue.main.async { [weak self] in
            self?.clearManualHanjaNewlineSuppressionIfUnchanged(generation: generation)
        }
    }

    func consumeManualHanjaNewlineSuppressionIfNeeded(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        maxAge: TimeInterval = 0.5
    ) -> Bool {
        guard let pendingManualHanjaNewlineSuppressionUptime else {
            return false
        }

        guard nowUptime - pendingManualHanjaNewlineSuppressionUptime <= maxAge else {
            clearManualHanjaNewlineSuppression()
            return false
        }

        return true
    }

    func clearManualHanjaNewlineSuppression() {
        manualHanjaNewlineSuppressionGeneration += 1
        pendingManualHanjaNewlineSuppressionUptime = nil
    }

    private func clearManualHanjaNewlineSuppressionIfUnchanged(generation: Int) {
        guard manualHanjaNewlineSuppressionGeneration == generation else {
            return
        }

        pendingManualHanjaNewlineSuppressionUptime = nil
    }

    func resetHangulState() {
        hangul.reset()
    }

    func reset() {
        hangul.reset()
        rangeState.finishComposition()
        compositionMode = .hangul
        realtimeClauseState = RealtimeClauseState()
        clearManualPanelState()
        clearManualHanjaTrigger()
        clearManualHanjaNewlineSuppression()
    }

    private func refreshRealtimePreviewText() {
        realtimeClauseState.refreshPreviewText()
    }
}
