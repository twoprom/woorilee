// IMK-facing orchestration and event dispatch for woorilee.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import IMKSwift
import OSLog

private let inputLogger = Logger(
    subsystem: "com.twoprom.inputmethod.woorilee",
    category: "Input"
)

// MARK: - InputController
/// The main input controller for the woorilee Hangul input method.
/// Handles two-beolsik Hangul composition via LibHangul and forwards committed
/// text to the active IMK client.
@MainActor
final class InputController: IMKInputSessionController {
    private enum ManualHanjaConversionAttemptResult {
        case started(ManualHanjaLookupResult)
        case blockedLoading(anchorRange: NSRange)
        case blockedUnavailable(anchorRange: NSRange, detail: String?)
        case blockedNoTarget(anchorRange: NSRange)
    }

    private enum CandidatePanelSelectionSource {
        case highlighted
        case numbered
    }

    private weak var session: InputSession?
    private let debugLoggingEnabled = true
    private let hanjaServices = HanjaServiceCoordinator.shared

    private var preeditText: String {
        session?.preeditText ?? ""
    }

    private var activeCompositionText: String {
        guard let session else {
            return ""
        }

        if session.hasRealtimeClause {
            return session.realtimeDisplayText
        }

        return session.preeditText
    }

    override init(server: IMKServer, delegate: Any?, client inputClient: any IMKTextInput) {
        super.init(server: server, delegate: delegate, client: inputClient)
        session = InputSessionCache.session(for: inputClient)
    }

    private func inputSession(for client: any IMKTextInput) -> InputSession {
        if let session {
            return session
        }

        let reboundSession = InputSessionCache.session(for: client)
        session = reboundSession
        return reboundSession
    }

    private func compositionEngine(for client: any IMKTextInput, session: InputSession) -> InputCompositionEngine {
        InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { self.hanjaServices.analyzeRealtimeClause($0, composingTailStart: $1) },
            analyzeManualClause: { self.hanjaServices.manualSegments(for: $0, boundaries: $1) },
            flushRealtimeUsageEvents: { self.hanjaServices.flushRealtimeUsageEvents($0) },
            updateComposition: { self.updateComposition() },
            debugLog: { self.debugLog($0) }
        )
    }

    override func handle(_ event: NSEvent?, client sender: any IMKTextInput) -> Bool {
        guard let event = event else { return false }
        let session = inputSession(for: sender)

        guard event.type == .keyDown else { return false }

        inputLogger.info(
            "woorilee: handle keyCode=\(event.keyCode, privacy: .public) modifiers=\(event.modifierFlags.rawValue, privacy: .public) chars=\(event.charactersIgnoringModifiers ?? "", privacy: .public)"
        )

        return handleKeyInput(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers,
            client: sender,
            session: session
        )
    }

    override func inputText(
        _ string: String,
        key keyCode: Int,
        modifiers flags: UInt,
        client sender: any IMKTextInput
    ) -> Bool {
        let session = inputSession(for: sender)
        let modifiers = NSEvent.ModifierFlags(rawValue: flags)
        inputLogger.info(
            "woorilee: inputText:key keyCode=\(keyCode, privacy: .public) modifiers=\(flags, privacy: .public) text=\(string, privacy: .public)"
        )

        return handleKeyInput(
            keyCode: UInt16(truncatingIfNeeded: keyCode),
            modifiers: modifiers,
            characters: string,
            client: sender,
            session: session
        )
    }

    override func inputText(_ string: String, client sender: any IMKTextInput) -> Bool {
        let session = inputSession(for: sender)
        inputLogger.info("woorilee: inputText text=\(string, privacy: .private)")
        let currentModifierFlags = InputEventPolicy.currentSessionModifierFlags()

        if isBareNewlineText(string) {
            if session.consumeManualHanjaNewlineSuppressionIfNeeded() {
                debugLog("manual-hanja suppress duplicate text newline")
                return true
            }

            let consumedTrigger = session.consumeManualHanjaTriggerIfArmedForNewline()
            if consumedTrigger != nil || InputEventPolicy.isManualHanjaTrigger(modifiers: currentModifierFlags) {
                debugLog(
                    "manual-hanja trigger text=\(string) trigger=\(consumedTrigger != nil ? "armed" : "modifier") flags=\(currentModifierFlags.rawValue)"
                )
                return handleManualHanjaTrigger(sender, session: session)
            }
        }

        session.clearManualHanjaTrigger()
        return handleTextInput(string, client: sender, session: session)
    }

    override func activateServer(_ sender: any IMKTextInput) {
        super.activateServer(sender)
        inputLogger.info("woorilee: activateServer")
        hanjaServices.hideManualCandidatePanel()
        hanjaServices.showWarmUpPanelIfNeeded()
        inputSession(for: sender).reset()
    }

    override func deactivateServer(_ sender: any IMKTextInput) {
        inputLogger.info("woorilee: deactivateServer")
        let session = inputSession(for: sender)
        clearManualHanjaTransientState(session: session)
        commitCurrentComposition(sender, session: session)
        hanjaServices.hideWarmUpPanelIfNeeded()
        super.deactivateServer(sender)
    }

    private func handleKeyInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?,
        client: any IMKTextInput,
        session: InputSession
    ) -> Bool {
        if isReturnKey(keyCode), session.consumeManualHanjaNewlineSuppressionIfNeeded() {
            debugLog("manual-hanja suppress duplicate key newline keyCode=\(keyCode)")
            return true
        }

        if let handled = handleManualPanelKeyInput(
            keyCode: keyCode,
            modifiers: modifiers,
            client: client,
            session: session
        ) {
            return handled
        }

        if let handled = handleRealtimePanelKeyInput(
            keyCode: keyCode,
            modifiers: modifiers,
            client: client,
            session: session
        ) {
            return handled
        }

        commitRealtimeIfHostMarkedRangeMoved(client: client, session: session)

        if InputEventPolicy.isRealtimeHanjaToggleShortcut(
            modifiers: modifiers,
            characters: characters
        ) {
            commitCurrentComposition(client, session: session)
            hanjaServices.toggleRealtimeHanjaConversion()
            return true
        }

        if InputEventPolicy.isManualHanjaTrigger(keyCode: keyCode, modifiers: modifiers) {
            if session.isRealtimeHanjaMode {
                return true
            }

            debugLog("manual-hanja trigger keyCode=\(keyCode) modifiers=\(modifiers.rawValue)")
            return handleManualHanjaTrigger(client, session: session)
        }

        let composition = compositionEngine(for: client, session: session)
        session.clearManualHanjaTrigger()

        if InputEventPolicy.shouldPassThrough(modifiers) {
            commitCurrentComposition(client, session: session)
            return false
        }

        switch keyCode {
        case InputEventPolicy.KeyCode.backspace:
            return handleBackspace(client, session: session)

        case InputEventPolicy.KeyCode.returnKey, InputEventPolicy.KeyCode.enter:
            return handleReturn(client, session: session)

        case InputEventPolicy.KeyCode.escape:
            return handleEscape(client, session: session)

        case InputEventPolicy.KeyCode.space:
            return handleSpace(client, session: session)

        case InputEventPolicy.KeyCode.tab:
            if session.isRealtimeHanjaMode {
                return session.hasRealtimeClause
            }

            if session.hasPendingHangulText {
                commitCurrentComposition(client, session: session)
            }
            return false

        case InputEventPolicy.KeyCode.upArrow,
             InputEventPolicy.KeyCode.downArrow:
            if session.isRealtimeHanjaMode {
                if keyCode == InputEventPolicy.KeyCode.downArrow, session.hasRealtimeClause {
                    return showRealtimeCandidatePanel(client: client, session: session)
                }

                return session.hasRealtimeClause
            }

            commitCurrentComposition(client, session: session)
            return false

        case InputEventPolicy.KeyCode.leftArrow,
             InputEventPolicy.KeyCode.rightArrow:
            if session.isRealtimeHanjaMode {
                guard session.hasRealtimeClause else {
                    return false
                }

                if let boundaryDelta = InputEventPolicy.segmentBoundaryAdjustDelta(
                    keyCode: keyCode,
                    modifiers: modifiers
                ) {
                    return adjustRealtimeSegmentBoundary(by: boundaryDelta, client: client, session: session)
                }

                let delta = keyCode == InputEventPolicy.KeyCode.rightArrow ? 1 : -1
                _ = session.moveRealtimeSegmentSelection(by: delta, wraps: true)
                composition.updateDisplay()
                _ = showRealtimeCandidatePanel(client: client, session: session)
                return session.hasRealtimeClause
            }

            commitCurrentComposition(client, session: session)
            return false

        default:
            return handleTextInput(characters, modifiers: modifiers, client: client, session: session)
        }
    }

    private func handleTextInput(
        _ characters: String?,
        modifiers: NSEvent.ModifierFlags = [],
        client: any IMKTextInput,
        session: InputSession
    ) -> Bool {
        let selectedRange = client.selectedRange()
        let hadPendingComposition = session.hasPendingHangulText
        let hadRealtimeClause = session.hasRealtimeClause
        let composition = compositionEngine(for: client, session: session)
        // 새 글자 입력은 소스를 바꿔 수동 경계 오프셋을 무효화하므로 오버레이를 버리고 Kiwi 분절로 복귀한다.
        session.clearManualSegmentation()
        debugLog(
            "textInput selected=\(inputDebugRangeString(selectedRange)) marked=\(inputDebugRangeString(client.markedRange())) preedit=\(session.preeditText) raw=\(characters ?? "")"
        )

        guard let char = InputEventPolicy.normalizedASCIICharacter(
            characters: characters,
            modifiers: modifiers
        ) else {
            commitCurrentComposition(client, session: session)
            return false
        }

        if char == "`" {
            commitCurrentComposition(client, session: session)
            client.insertText(
                "₩",
                replacementRange: (hadPendingComposition || hadRealtimeClause)
                    ? NSRange(location: NSNotFound, length: 0)
                    : InputCompositionEngine.replacementRange(forSelection: selectedRange)
            )
            return true
        }

        let processed = session.process(char)

        if processed {
            if shouldUseRealtimeHanja(session: session) {
                session.beginRealtimeClauseIfNeeded()
            }

            session.beginCompositionIfNeeded(with: selectedRange)
            composition.insertCommittedTextIfNeeded()
            composition.updateDisplay()
            showRealtimeCandidatePanelIfAvailable(client: client, session: session)
            return true
        }

        if shouldUseRealtimeHanja(session: session),
           NumericHanjaCandidateGenerator.isNumericStartCharacter(char) {
            session.beginRealtimeClauseIfNeeded()
            session.beginCompositionIfNeeded(with: selectedRange)
        }

        if session.isRealtimeHanjaMode, session.hasRealtimeClause {
            return handleRealtimeRawCharacter(
                char,
                client: client,
                session: session,
                composition: composition
            )
        }

        commitCurrentComposition(client, session: session)
        client.insertText(
            String(char),
            replacementRange: (hadPendingComposition || hadRealtimeClause)
                ? NSRange(location: NSNotFound, length: 0)
                : InputCompositionEngine.replacementRange(forSelection: selectedRange)
        )
        return true
    }

    override func composedString(_ sender: any IMKTextInput) -> Any? {
        let session = inputSession(for: sender)
        if session.hasRealtimeClause {
            return session.realtimeDisplayText.isEmpty
                ? ""
                : inputRealtimeMarkedAttributedString(session.realtimeClauseState)
        }

        let preeditText = session.preeditText
        return preeditText.isEmpty ? "" : inputMarkedAttributedString(preeditText)
    }

    override func originalString(_ sender: any IMKTextInput) -> NSAttributedString? {
        let session = inputSession(for: sender)
        if session.hasRealtimeClause {
            return inputRealtimeMarkedAttributedString(session.realtimeClauseState)
        }

        let text = session.preeditText
        return inputMarkedAttributedString(text)
    }

    override func selectionRange() -> NSRange {
        let location = inputUTF16Length(of: activeCompositionText)
        guard location > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: location, length: 0)
    }

    override func replacementRange() -> NSRange {
        session?.currentReplacementRange ?? NSRange(location: NSNotFound, length: 0)
    }

    override func commitComposition(_ sender: any IMKTextInput) {
        let session = inputSession(for: sender)
        clearManualHanjaTransientState(session: session)
        commitCurrentComposition(sender, session: session)
    }

    override func menu() -> NSMenu? {
        hanjaServices.makeMenu(
            target: self,
            realtimeAction: #selector(toggleRealtimeHanjaConversion(_:)),
            contextRankingAction: #selector(toggleContextHanjaRanking(_:)),
            manageUserDictionaryAction: #selector(openUserHanjaDictionary(_:)),
            resetUsageDataAction: #selector(resetUserLearningData(_:)),
            aboutAction: #selector(showAbout(_:))
        )
    }

    @objc func openUserHanjaDictionary(_ sender: Any?) {
        hanjaServices.showUserDictionaryWindow()
    }

    @objc private func resetUserLearningData(_ sender: Any?) {
        hanjaServices.confirmAndResetUsageData()
    }

    @objc func showAbout(_ sender: Any?) {
        hanjaServices.showAboutWindow()
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleRealtimeHanjaConversion(_:)):
            menuItem.state = hanjaServices.isRealtimeHanjaConversionEnabled ? .on : .off
            return hanjaServices.canToggleRealtimeHanjaConversion

        case #selector(toggleContextHanjaRanking(_:)):
            menuItem.state = hanjaServices.isContextHanjaRankingEnabled ? .on : .off
            return hanjaServices.canToggleContextHanjaRanking

        case #selector(openUserHanjaDictionary(_:)):
            return hanjaServices.isManualHanjaAvailable

        case #selector(resetUserLearningData(_:)):
            return hanjaServices.isResetUsageDataAvailable

        default:
            return menuItem.isEnabled
        }
    }

    override func didCommand(by aSelector: Selector, client sender: any IMKTextInput) -> Bool {
        let session = inputSession(for: sender)
        let commandName = NSStringFromSelector(aSelector)
        let currentModifierFlags = InputEventPolicy.currentSessionModifierFlags()
        let manualTriggerFromModifiers = InputEventPolicy.isManualHanjaTrigger(modifiers: currentModifierFlags)

        inputLogger.info(
            "woorilee: didCommand selector=\(commandName, privacy: .public) modifiers=\(currentModifierFlags.rawValue, privacy: .public) armed=\(session.pendingManualHanjaTrigger != nil, privacy: .public)"
        )

        if InputEventPolicy.isNewlineCommand(aSelector) {
            if session.consumeManualHanjaNewlineSuppressionIfNeeded() {
                debugLog("manual-hanja suppress duplicate selector=\(commandName)")
                return true
            }

            let consumedTrigger = session.consumeManualHanjaTriggerIfArmedForNewline()
            if consumedTrigger != nil || manualTriggerFromModifiers {
                debugLog(
                    "manual-hanja trigger selector=\(commandName) trigger=\(consumedTrigger != nil ? "armed" : "modifier") flags=\(currentModifierFlags.rawValue)"
                )
                return handleManualHanjaTrigger(sender, session: session)
            }

            if session.isRealtimeHanjaMode, session.hasRealtimeClause {
                commitCurrentComposition(sender, session: session)
                return true
            }
        }

        if session.isShowingManualCandidates, InputEventPolicy.isNavigationCommand(aSelector) {
            dismissManualPanel(session: session)
            return true
        }

        session.clearManualHanjaTrigger()
        guard InputEventPolicy.isNavigationCommand(aSelector) else {
            return false
        }

        if session.isRealtimeHanjaMode, session.hasRealtimeClause {
            return true
        }

        if session.hasPendingHangulText {
            debugLog(
                "didCommand selector=\(NSStringFromSelector(aSelector)) selected=\(inputDebugRangeString(sender.selectedRange())) marked=\(inputDebugRangeString(sender.markedRange())) preedit=\(session.preeditText)"
            )
            commitCurrentComposition(sender, session: session)
        }

        return false
    }

    private func handleBackspace(_ client: any IMKTextInput, session: InputSession) -> Bool {
        let composition = compositionEngine(for: client, session: session)
        if session.isRealtimeHanjaMode {
            // 소스 편집이므로 수동 경계 오버레이를 버린다.
            session.clearManualSegmentation()
            if session.hasPendingHangulText {
                if session.backspace() {
                    composition.insertCommittedTextIfNeeded()
                    composition.updateDisplay()
                    showRealtimeCandidatePanelIfAvailable(client: client, session: session)
                    return true
                }

                session.resetHangulState()
                session.syncRealtimeTailPreedit()
                composition.updateDisplay()
                showRealtimeCandidatePanelIfAvailable(client: client, session: session)
                return true
            }

            if session.deleteLastRealtimeRawCharacter() {
                composition.updateDisplay()
                showRealtimeCandidatePanelIfAvailable(client: client, session: session)
                return true
            }

            if session.hasRealtimeClause {
                dismissRealtimeCandidatePanel(session: session)
                composition.cancelRealtimeComposition()
                return true
            }

            return false
        }

        guard session.hasPendingHangulText else {
            return false
        }

        if session.backspace() {
            composition.insertCommittedTextIfNeeded()
            composition.updateDisplay()
            return true
        }

        session.resetHangulState()
        composition.clearMarkedText()
        session.finishComposition()
        return true
    }

    private func handleManualPanelKeyInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        client: any IMKTextInput,
        session: InputSession
    ) -> Bool? {
        guard session.isShowingManualPanel else {
            return nil
        }

        switch keyCode {
        case InputEventPolicy.KeyCode.escape:
            dismissManualPanel(session: session)
            return true
        default:
            if session.isShowingManualNotice {
                dismissManualPanel(session: session)
                return nil
            }

            if let handled = handleCandidatePanelCommonKeyInput(
                keyCode: keyCode,
                modifiers: modifiers,
                currentState: { session.manualCandidateState },
                updateState: { session.updateManualCandidateState($0) },
                refreshPanel: { showManualCandidatePanel(client: client, session: session) },
                dismissPanel: { dismissManualPanel(session: session) },
                selectCandidate: { candidate, _ in
                    applyManualCandidateSelection(candidate, client: client, session: session)
                },
                selectHangul: {
                    applyManualHangulSelection(client: client, session: session)
                }
            ) {
                return handled
            }

            switch keyCode {
            case InputEventPolicy.KeyCode.leftArrow,
                 InputEventPolicy.KeyCode.rightArrow:
                session.updateManualCandidateState { state in
                    state.movePage(by: keyCode == InputEventPolicy.KeyCode.rightArrow ? 1 : -1)
                }
                showManualCandidatePanel(client: client, session: session)
                return true

            case InputEventPolicy.KeyCode.space:
                dismissManualPanel(session: session)
                return true

            default:
                dismissManualPanel(session: session)
                return nil
            }
        }
    }

    private func handleReturn(_ client: any IMKTextInput, session: InputSession) -> Bool {
        if session.isRealtimeHanjaMode, session.hasRealtimeClause {
            commitCurrentComposition(client, session: session)
            return true
        }

        if session.hasPendingHangulText {
            commitCurrentComposition(client, session: session)
            return true
        }

        return false
    }

    private func handleEscape(_ client: any IMKTextInput, session: InputSession) -> Bool {
        if session.isRealtimeHanjaMode, session.hasRealtimeClause {
            dismissRealtimeCandidatePanel(session: session)
            compositionEngine(for: client, session: session).cancelRealtimeComposition()
            return true
        }

        if session.hasPendingHangulText {
            commitCurrentComposition(client, session: session)
            return true
        }

        return false
    }

    private func handleSpace(_ client: any IMKTextInput, session: InputSession) -> Bool {
        let composition = compositionEngine(for: client, session: session)
        if session.isRealtimeHanjaMode {
            dismissRealtimeCandidatePanel(session: session)
            // 공백 추가도 소스를 바꾸므로 수동 경계 오버레이를 버린다.
            session.clearManualSegmentation()
            if session.hasPendingHangulText {
                let flushed = session.flushText()
                if !flushed.isEmpty {
                    session.appendCommittedTextToRealtimeClause(flushed)
                }
            }

            guard session.hasRealtimeClause else {
                return false
            }

            session.appendSpaceToRealtimeClause()
            composition.updateDisplay()
            showRealtimeCandidatePanelIfAvailable(client: client, session: session)
            return true
        }

        if !session.hasPendingHangulText {
            return false
        }

        commitCurrentComposition(client, session: session)
        composition.insertSpace()
        return true
    }

    private func handleRealtimeRawCharacter(
        _ character: Character,
        client: any IMKTextInput,
        session: InputSession,
        composition: InputCompositionEngine
    ) -> Bool {
        dismissRealtimeCandidatePanel(session: session)

        if RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting(character) {
            commitCurrentComposition(client, session: session)
            client.insertText(
                String(character),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        if session.hasPendingHangulText {
            let flushed = session.flushText()
            if !flushed.isEmpty {
                session.appendCommittedTextToRealtimeClause(flushed)
            }
        }

        session.appendRawTextToRealtimeClause(String(character))
        composition.updateDisplay()
        showRealtimeCandidatePanelIfAvailable(client: client, session: session)
        return true
    }

    private func applyRealtimeHangulFallbackSelection(
        client: any IMKTextInput,
        session: InputSession
    ) -> Bool {
        guard session.isRealtimeHanjaMode, session.hasRealtimeClause else {
            return false
        }

        guard session.applyRealtimeHangulFallbackForSelectedSegment() else {
            dismissRealtimeCandidatePanel(session: session)
            return true
        }

        let composition = compositionEngine(for: client, session: session)
        composition.updateDisplay()

        if session.moveRealtimeSegmentSelection(by: 1) {
            composition.updateDisplay()
            showRealtimeCandidatePanelIfAvailable(client: client, session: session)
        } else {
            commitCurrentComposition(client, session: session)
        }

        return true
    }

    private func adjustRealtimeSegmentBoundary(
        by delta: Int,
        client: any IMKTextInput,
        session: InputSession
    ) -> Bool {
        guard session.isRealtimeHanjaMode, session.hasRealtimeClause else {
            return false
        }

        // 조합 중인 한글을 먼저 clause로 flush 해 소스를 안정 grapheme으로 고정한다.
        session.flushPendingHangulIntoRealtimeClause()
        // 첫 조정이면 현재 분절로 오버레이 seed 후 포커스 경계를 이동한다.
        _ = session.adjustRealtimeSegmentBoundary(byCharacters: delta)

        // 수동 분절로 재빌드 + 표시/패널 갱신. 연속 신축 시 깜빡임을 막으려 "후보 없음" 토스트는 띄우지 않는다.
        compositionEngine(for: client, session: session).updateDisplay()
        _ = showRealtimeCandidatePanel(client: client, session: session, showEmptyNotice: false)
        return session.hasRealtimeClause
    }

    private func handleRealtimePanelKeyInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        client: any IMKTextInput,
        session: InputSession
    ) -> Bool? {
        guard session.isShowingRealtimeCandidates else {
            return nil
        }

        if let handled = handleCandidatePanelCommonKeyInput(
            keyCode: keyCode,
            modifiers: modifiers,
            currentState: { session.realtimeCandidateState },
            updateState: { session.updateRealtimeCandidateState($0) },
            refreshPanel: { _ = showRealtimeCandidatePanel(client: client, session: session, showEmptyNotice: false) },
            dismissPanel: { dismissRealtimeCandidatePanel(session: session) },
            selectCandidate: { candidate, source in
                applyRealtimeCandidateSelection(
                    candidate,
                    client: client,
                    session: session,
                    advanceAfterSelection: source == .numbered,
                    keepPanelWhenNotAdvancing: source == .numbered
                )
            },
            selectHangul: {
                _ = applyRealtimeHangulFallbackSelection(client: client, session: session)
            }
        ) {
            return handled
        }

        switch keyCode {
        case InputEventPolicy.KeyCode.leftArrow,
             InputEventPolicy.KeyCode.rightArrow:
            if let boundaryDelta = InputEventPolicy.segmentBoundaryAdjustDelta(
                keyCode: keyCode,
                modifiers: modifiers
            ) {
                return adjustRealtimeSegmentBoundary(by: boundaryDelta, client: client, session: session)
            }

            let delta = keyCode == InputEventPolicy.KeyCode.rightArrow ? 1 : -1
            _ = session.moveRealtimeSegmentSelection(by: delta, wraps: true)
            compositionEngine(for: client, session: session).updateDisplay()
            _ = showRealtimeCandidatePanel(client: client, session: session, showEmptyNotice: false)
            return true

        case InputEventPolicy.KeyCode.space,
             InputEventPolicy.KeyCode.backspace:
            dismissRealtimeCandidatePanel(session: session)
            return nil

        default:
            dismissRealtimeCandidatePanel(session: session)
            return nil
        }
    }

    private func handleCandidatePanelCommonKeyInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        currentState: () -> HanjaCandidatePanelState?,
        updateState: ((inout HanjaCandidatePanelState) -> Void) -> Void,
        refreshPanel: () -> Void,
        dismissPanel: () -> Void,
        selectCandidate: (HanjaCandidate, CandidatePanelSelectionSource) -> Void,
        selectHangul: () -> Void
    ) -> Bool? {
        switch keyCode {
        case InputEventPolicy.KeyCode.escape:
            dismissPanel()
            return true

        case InputEventPolicy.KeyCode.returnKey,
             InputEventPolicy.KeyCode.enter:
            if currentState()?.highlightedIsHangul == true {
                selectHangul()
                return true
            }
            guard let candidate = currentState()?.highlightedCandidate else {
                dismissPanel()
                return true
            }

            selectCandidate(candidate, .highlighted)
            return true

        case InputEventPolicy.KeyCode.tab:
            updateState { state in
                state.movePage(by: modifiers.contains(.shift) ? -1 : 1)
            }
            refreshPanel()
            return true

        case InputEventPolicy.KeyCode.upArrow,
             InputEventPolicy.KeyCode.downArrow:
            updateState { state in
                state.moveHighlight(by: keyCode == InputEventPolicy.KeyCode.downArrow ? 1 : -1)
            }
            refreshPanel()
            return true

        default:
            guard let state = currentState(),
                  state.mode.allowsNumberedSelection,
                  let numericIndex = InputEventPolicy.numericCandidateIndex(keyCode: keyCode),
                  !modifiers.contains(.shift) else {
                return nil
            }

            if numericIndex == 9 {
                selectHangul()
                return true
            }

            guard let candidate = state.candidateForPageNumberIndex(numericIndex) else {
                return true
            }

            selectCandidate(candidate, .numbered)
            return true
        }
    }

    private func applyRealtimeCandidateSelection(
        _ candidate: HanjaCandidate,
        client: any IMKTextInput,
        session: InputSession,
        advanceAfterSelection: Bool,
        keepPanelWhenNotAdvancing: Bool
    ) {
        guard session.applyRealtimeCandidateSelection(candidate) else {
            dismissRealtimeCandidatePanel(session: session)
            return
        }

        let composition = compositionEngine(for: client, session: session)
        composition.updateDisplay()

        if advanceAfterSelection {
            if session.moveRealtimeSegmentSelection(by: 1) {
                composition.updateDisplay()
                _ = showRealtimeCandidatePanel(client: client, session: session, showEmptyNotice: false)
            } else {
                commitCurrentComposition(client, session: session)
            }
            return
        }

        if keepPanelWhenNotAdvancing {
            _ = showRealtimeCandidatePanel(client: client, session: session, showEmptyNotice: false)
        } else {
            dismissRealtimeCandidatePanel(session: session)
        }
    }

    private func showRealtimeCandidatePanel(
        client: any IMKTextInput,
        session: InputSession,
        showEmptyNotice: Bool = true
    ) -> Bool {
        guard let state = makeRealtimeCandidateState(client: client, session: session) else {
            dismissRealtimeCandidatePanel(session: session)
            return false
        }

        guard !state.candidates.isEmpty else {
            dismissRealtimeCandidatePanel(session: session)
            if showEmptyNotice {
                showRealtimeNoCandidatesNotice(state: state, client: client)
            }
            return true
        }

        session.setRealtimeCandidateState(state)
        let clientObject = client as AnyObject
        hanjaServices.showCandidatePanel(content: .candidates(state), client: client) { [weak self, weak clientObject] selection in
            guard let self,
                  let client = clientObject as? any IMKTextInput
            else {
                return
            }

            switch selection {
            case .candidate(let candidate):
                self.applyRealtimeCandidateSelection(
                    candidate,
                    client: client,
                    session: session,
                    advanceAfterSelection: false,
                    keepPanelWhenNotAdvancing: false
                )
            case .hangul:
                _ = self.applyRealtimeHangulFallbackSelection(client: client, session: session)
            }
        }
        return true
    }

    private func makeRealtimeCandidateState(
        client: any IMKTextInput,
        session: InputSession
    ) -> HanjaCandidatePanelState? {
        guard let selectedIndex = session.realtimeClauseState.selectedSegmentIndex,
              let segment = session.selectedRealtimeSegment,
              let anchorRange = realtimeCandidateAnchorRange(client: client, session: session)
        else {
            return nil
        }

        let candidates = hanjaServices.realtimeCandidates(for: segment)
        let previousState = session.realtimeCandidateState
        let preservesPreviousState = previousState?.mode.realtimeSegmentIndex == selectedIndex
        let highlightedIndex: Int
        let page: Int
        let highlightedIsHangul: Bool
        if preservesPreviousState, let previousState {
            highlightedIndex = previousState.highlightedIndex
            page = previousState.page
            highlightedIsHangul = previousState.highlightedIsHangul
        } else if let previewValue = segment.previewCandidate?.value,
                  let currentPreviewIndex = candidates.firstIndex(where: { $0.value == previewValue }) {
            highlightedIndex = currentPreviewIndex
            page = currentPreviewIndex / HanjaCandidatePanelState.defaultPageSize
            highlightedIsHangul = false
        } else {
            let hangulUsage = hanjaServices.hangulUsageCount(for: segment.normalizedLookupKey)
            highlightedIndex = 0
            page = 0
            highlightedIsHangul = HanjaCandidatePanelState.realtimeDefaultHighlightedIsHangul(
                segment: segment,
                candidates: candidates,
                hangulUsage: hangulUsage
            )
        }

        return HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: selectedIndex, segmentSurface: segment.surface),
            anchorRange: anchorRange,
            candidates: candidates,
            highlightedIndex: highlightedIndex,
            page: page,
            highlightedIsHangul: highlightedIsHangul
        )
    }

    private func realtimeCandidateAnchorRange(
        client: any IMKTextInput,
        session: InputSession
    ) -> NSRange? {
        guard let displayRange = session.realtimeClauseState.displayRangeForSelectedSegment() else {
            return nil
        }

        if let markedRange = session.markedTextRange,
           markedRange.location != NSNotFound {
            return NSRange(
                location: markedRange.location + displayRange.location,
                length: displayRange.length
            )
        }

        let clientMarkedRange = client.markedRange()
        if clientMarkedRange.location != NSNotFound {
            return NSRange(
                location: clientMarkedRange.location + displayRange.location,
                length: displayRange.length
            )
        }

        let selectedRange = client.selectedRange()
        guard selectedRange.location != NSNotFound else {
            return nil
        }

        return NSRange(location: selectedRange.location + selectedRange.length, length: 0)
    }

    private func showRealtimeNoCandidatesNotice(
        state: HanjaCandidatePanelState,
        client: any IMKTextInput
    ) {
        let notice = ManualHanjaNoticeState(
            message: "후보 없음",
            detail: state.mode.realtimeSegmentSurface,
            anchorRange: state.anchorRange
        )
        hanjaServices.showCandidatePanel(content: .notice(notice), client: client)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.hanjaServices.hideManualCandidatePanel()
        }
    }

    private func showRealtimeCandidatePanelIfAvailable(
        client: any IMKTextInput,
        session: InputSession
    ) {
        guard session.isRealtimeHanjaMode, session.hasRealtimeClause else {
            dismissRealtimeCandidatePanel(session: session)
            return
        }

        _ = showRealtimeCandidatePanel(client: client, session: session, showEmptyNotice: false)
    }

    private func dismissRealtimeCandidatePanel(session: InputSession, force: Bool = false) {
        guard force || session.isShowingRealtimeCandidates else {
            return
        }

        hanjaServices.hideManualCandidatePanel()
        session.clearRealtimeCandidateState()
    }

    private func commitCurrentComposition(_ client: any IMKTextInput, session: InputSession) {
        dismissRealtimeCandidatePanel(session: session, force: session.isRealtimeHanjaMode)
        compositionEngine(for: client, session: session).commitCurrentComposition()
    }

    private func commitRealtimeIfHostMarkedRangeMoved(
        client: any IMKTextInput,
        session: InputSession
    ) {
        guard session.isRealtimeHanjaMode,
              session.hasRealtimeClause,
              let sessionMarkedRange = session.markedTextRange,
              sessionMarkedRange.location != NSNotFound
        else {
            return
        }

        let clientMarkedRange = client.markedRange()
        guard clientMarkedRange.location != NSNotFound,
              clientMarkedRange != sessionMarkedRange
        else {
            return
        }

        debugLog(
            "realtime marked-range moved client=\(inputDebugRangeString(clientMarkedRange)) session=\(inputDebugRangeString(sessionMarkedRange))"
        )
        commitCurrentComposition(client, session: session)
    }

    private func shouldUseRealtimeHanja(session: InputSession) -> Bool {
        session.isRealtimeHanjaMode || hanjaServices.isRealtimeHanjaConversionEnabled
    }

    private func beginManualHanjaConversion(
        _ client: any IMKTextInput,
        session: InputSession
    ) -> ManualHanjaConversionAttemptResult {
        let defaultAnchorRange = manualHanjaAnchorRange(for: client)

        guard !hanjaServices.isRealtimeHanjaConversionEnabled else {
            return .blockedUnavailable(
                anchorRange: defaultAnchorRange,
                detail: "실시간 변환이 활성화되어 있습니다."
            )
        }

        guard let target = extractManualHanjaTarget(from: client, session: session) else {
            return .blockedNoTarget(anchorRange: defaultAnchorRange)
        }

        switch hanjaServices.manualHanjaAvailability {
        case .ready:
            break
        case .loading:
            return .blockedLoading(anchorRange: target.anchorRange)
        case .unavailable(let reason):
            return .blockedUnavailable(anchorRange: target.anchorRange, detail: reason)
        }

        let lookup = hanjaServices.manualLookup(for: target)
        return .started(lookup)
    }

    private func handleManualHanjaTrigger(
        _ client: any IMKTextInput,
        session: InputSession
    ) -> Bool {
        session.clearManualHanjaTrigger()
        session.suppressNextManualHanjaNewline()

        switch beginManualHanjaConversion(client, session: session) {
        case .started(let lookup):
            session.setManualCandidateState(lookup.state, lookupKey: lookup.lookupKey)
            showManualCandidatePanel(client: client, session: session)
            debugLog("manual-hanja started lookupKey=\(lookup.lookupKey)")
            return true

        case .blockedLoading(let anchorRange):
            let notice = ManualHanjaNoticeState(
                message: "한자 사전을 불러오는 중입니다.",
                detail: nil,
                anchorRange: anchorRange
            )
            session.setManualNoticeState(notice)
            hanjaServices.showCandidatePanel(content: .notice(notice), client: client)
            debugLog("manual-hanja blocked loading")
            return true

        case .blockedUnavailable(let anchorRange, let detail):
            let notice = ManualHanjaNoticeState(
                message: "한자 사전을 사용할 수 없습니다.",
                detail: detail,
                anchorRange: anchorRange
            )
            session.setManualNoticeState(notice)
            hanjaServices.showCandidatePanel(content: .notice(notice), client: client)
            debugLog("manual-hanja blocked unavailable detail=\(detail ?? "")")
            return true

        case .blockedNoTarget(let anchorRange):
            let notice = ManualHanjaNoticeState(
                message: "변환할 텍스트가 없습니다.",
                detail: nil,
                anchorRange: anchorRange
            )
            session.setManualNoticeState(notice)
            hanjaServices.showCandidatePanel(content: .notice(notice), client: client)
            debugLog("manual-hanja blocked no-target")
            return true
        }
    }

    private func showManualCandidatePanel(
        client: any IMKTextInput,
        session: InputSession
    ) {
        guard let state = session.manualCandidateState else {
            dismissManualPanel(session: session)
            return
        }

        let clientObject = client as AnyObject
        hanjaServices.showCandidatePanel(content: .candidates(state), client: client) { [weak self, weak clientObject] selection in
            guard let self,
                  let client = clientObject as? any IMKTextInput
            else {
                return
            }

            switch selection {
            case .candidate(let candidate):
                self.applyManualCandidateSelection(candidate, client: client, session: session)
            case .hangul:
                self.applyManualHangulSelection(client: client, session: session)
            }
        }
    }

    private func isReturnKey(_ keyCode: UInt16) -> Bool {
        keyCode == InputEventPolicy.KeyCode.returnKey || keyCode == InputEventPolicy.KeyCode.enter
    }

    private func manualHanjaAnchorRange(for client: any IMKTextInput) -> NSRange {
        let markedRange = client.markedRange()
        if markedRange.location != NSNotFound {
            return NSRange(location: markedRange.location + markedRange.length, length: 0)
        }

        let selectedRange = client.selectedRange()
        guard selectedRange.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }

        return NSRange(location: selectedRange.location + selectedRange.length, length: 0)
    }

    private func extractManualHanjaTarget(
        from client: any IMKTextInput,
        session: InputSession
    ) -> ManualHanjaTarget? {
        if session.hasPendingHangulText {
            return extractManualTargetFromComposition(client: client, session: session)
        }

        let selectedRange = client.selectedRange()
        let markedRange = client.markedRange()
        debugLog(
            "manual-hanja document selected=\(inputDebugRangeString(selectedRange)) marked=\(inputDebugRangeString(markedRange)) sessionMarked=\(session.markedTextRange.map(inputDebugRangeString) ?? "nil") preedit=\(session.preeditText)"
        )
        guard selectedRange.location != NSNotFound else {
            debugLog("manual-hanja document no-target invalid-selection selected=\(inputDebugRangeString(selectedRange))")
            return nil
        }
        if selectedRange.length > 0 {
            guard let context = manualHanjaString(from: client, proposedRange: selectedRange),
                  let target = manualHanjaTarget(fromSelectedText: context.text, actualRange: context.actualRange)
            else {
                debugLog("manual-hanja document no-target invalid-selected-text selected=\(inputDebugRangeString(selectedRange))")
                return nil
            }

            debugLog(
                "manual-hanja document selectedTextRange=\(inputDebugRangeString(context.actualRange)) text=\(context.text) target=\(target.sourceText) replacement=\(inputDebugRangeString(target.replacementRange))"
            )
            return target
        }

        guard selectedRange.location > 0 else {
            debugLog("manual-hanja document no-target at-document-start")
            return nil
        }

        guard let context = manualHanjaString(
            from: client,
            proposedRange: NSRange(location: 0, length: selectedRange.location)
        ) else {
            debugLog("manual-hanja document no-target missing-left-context")
            return nil
        }

        let target = manualHanjaTarget(
            fromLeftContext: context.text,
            actualRange: context.actualRange,
            caretLocation: selectedRange.location
        )
        debugLog(
            "manual-hanja document contextRange=\(inputDebugRangeString(context.actualRange)) text=\(context.text) target=\(target?.sourceText ?? "nil") replacement=\(target.map { inputDebugRangeString($0.replacementRange) } ?? "nil")"
        )
        return target
    }

    private func extractManualTargetFromComposition(
        client: any IMKTextInput,
        session: InputSession
    ) -> ManualHanjaTarget? {
        let preeditText = session.preeditText
        let clientMarkedRange = client.markedRange()
        let markedRange = manualHanjaMarkedRange(
            clientMarkedRange: clientMarkedRange,
            session: session,
            preeditText: preeditText
        )
        debugLog(
            "manual-hanja composition selected=\(inputDebugRangeString(client.selectedRange())) clientMarked=\(inputDebugRangeString(clientMarkedRange)) effectiveMarked=\(inputDebugRangeString(markedRange)) sessionMarked=\(session.markedTextRange.map(inputDebugRangeString) ?? "nil") replacement=\(inputDebugRangeString(session.currentReplacementRange)) preedit=\(preeditText)"
        )
        guard !preeditText.isEmpty else {
            debugLog("manual-hanja composition no-target empty-preedit")
            return nil
        }
        guard markedRange.location != NSNotFound else {
            debugLog("manual-hanja composition no-target missing-marked-range")
            return nil
        }

        if markedRange.location == 0 {
            let target = manualHanjaTarget(
                fromCommittedLeftText: "",
                committedRange: NSRange(location: 0, length: 0),
                markedText: preeditText,
                markedRange: markedRange
            )
            debugLog(
                "manual-hanja composition target=\(target?.sourceText ?? "nil") replacement=\(target.map { inputDebugRangeString($0.replacementRange) } ?? "nil")"
            )
            return target
        }

        guard let context = manualHanjaString(
            from: client,
            proposedRange: NSRange(location: 0, length: max(markedRange.location, 0))
        ) else {
            debugLog("manual-hanja composition no-target missing-left-context marked=\(inputDebugRangeString(markedRange))")
            return nil
        }

        let target = manualHanjaTarget(
            fromCommittedLeftText: context.text,
            committedRange: context.actualRange,
            markedText: preeditText,
            markedRange: markedRange
        )
        debugLog(
            "manual-hanja composition contextRange=\(inputDebugRangeString(context.actualRange)) text=\(context.text) target=\(target?.sourceText ?? "nil") replacement=\(target.map { inputDebugRangeString($0.replacementRange) } ?? "nil")"
        )
        return target
    }

    private func manualHanjaString(
        from client: any IMKTextInput,
        proposedRange: NSRange
    ) -> (text: String, actualRange: NSRange)? {
        var actualRange = NSRange(location: NSNotFound, length: 0)
        if let text = client.string(from: proposedRange, actualRange: &actualRange) {
            return (text, actualRange)
        }

        if let attributedText = client.attributedSubstring(from: proposedRange) {
            return (attributedText.string, proposedRange)
        }

        return nil
    }

    private func manualHanjaMarkedRange(
        clientMarkedRange: NSRange,
        session: InputSession,
        preeditText: String
    ) -> NSRange {
        if clientMarkedRange.location != NSNotFound {
            return clientMarkedRange
        }

        if let sessionMarkedRange = session.markedTextRange,
           sessionMarkedRange.location != NSNotFound {
            return sessionMarkedRange
        }

        let replacementRange = session.currentReplacementRange
        if replacementRange.location != NSNotFound {
            return NSRange(
                location: replacementRange.location,
                length: inputUTF16Length(of: preeditText)
            )
        }

        return NSRange(location: NSNotFound, length: 0)
    }

    private func applyManualCandidateSelection(
        _ candidate: HanjaCandidate,
        client: any IMKTextInput,
        session: InputSession
    ) {
        guard let replacementRange = session.pendingManualReplacementRange else {
            dismissManualPanel(session: session)
            return
        }

        let lookupKey = session.pendingManualLookupKey ?? candidate.reading
        hanjaServices.hideManualCandidatePanel()

        // 마크된 한글이 남아 있으면 먼저 커밋해 일반 텍스트로 바꿔야
        // 클라이언트(NSTextView 등)가 아래 replacementRange를 마크 영역
        // 기준이 아닌 문서 절대 좌표로 해석한다.
        if session.hasPendingHangulText {
            commitCurrentComposition(client, session: session)
        }

        client.insertText(candidate.value, replacementRange: replacementRange)
        hanjaServices.recordSelection(lookupKey: lookupKey, value: candidate.value)
        session.reset()
    }

    private func applyManualHangulSelection(
        client: any IMKTextInput,
        session: InputSession
    ) {
        guard let replacementRange = session.pendingManualReplacementRange,
              let sourceText = session.manualCandidateState?.mode.manualSourceText
        else {
            dismissManualPanel(session: session)
            return
        }

        let lookupKey = session.pendingManualLookupKey ?? sourceText
        hanjaServices.hideManualCandidatePanel()

        if session.hasPendingHangulText {
            commitCurrentComposition(client, session: session)
        }

        client.insertText(sourceText, replacementRange: replacementRange)
        hanjaServices.recordHangulSelection(lookupKey: lookupKey)
        session.reset()
    }

    private func dismissManualPanel(session: InputSession) {
        clearManualHanjaTransientState(session: session)
    }

    private func clearManualHanjaTransientState(session: InputSession) {
        hanjaServices.hideManualCandidatePanel()
        session.clearManualPanelState()
        session.clearManualHanjaTrigger()
    }

    private func isBareNewlineText(_ string: String) -> Bool {
        switch string {
        case "\r", "\n", "\u{2028}", "\u{2029}":
            return true
        default:
            return false
        }
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else {
            return
        }

        inputLogger.debug("woorilee-range: \(message, privacy: .public)")
    }

    @objc private func toggleRealtimeHanjaConversion(_ sender: Any?) {
        hanjaServices.toggleRealtimeHanjaConversion()
        refreshVisibleMenuState(from: sender)
    }

    @objc private func toggleContextHanjaRanking(_ sender: Any?) {
        hanjaServices.toggleContextHanjaRanking()
        refreshVisibleMenuState(from: sender)
    }

    private func refreshVisibleMenuState(from sender: Any?) {
        if let menu = commandMenuItem(from: sender)?.menu {
            hanjaServices.refreshMenuState(menu)
            return
        }

        hanjaServices.refreshMenuState()
    }

    private func commandMenuItem(from sender: Any?) -> NSMenuItem? {
        if let item = sender as? NSMenuItem {
            return item
        }

        guard let commandInfo = sender as? [AnyHashable: Any] else {
            return nil
        }

        let menuItemKey = kIMKCommandMenuItemName as String
        return commandInfo[menuItemKey] as? NSMenuItem
            ?? commandInfo[kIMKCommandMenuItemName] as? NSMenuItem
    }
}
