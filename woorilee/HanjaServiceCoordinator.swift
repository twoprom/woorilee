//
//  HanjaServiceCoordinator.swift
//  woorilee
//

import Cocoa
import IMKSwift
import OSLog

private let manualHanjaPanelLogger = Logger(
    subsystem: "com.twoprom.inputmethod.woorilee",
    category: "ManualHanjaPanel"
)

@MainActor
final class HanjaServiceCoordinator: NSObject, NSMenuDelegate {
    static let shared = HanjaServiceCoordinator()
    private let realtimeConversionPhaseUnlocked = true

    enum ManualHanjaAvailability: Equatable {
        case loading
        case ready
        case unavailable(String)
    }

    private enum MenuTitle {
        static let realtimeConversion = "실시간 변환"
        static let manageUserDictionary = "漢字 사전 편집…"
        static let about = "우리입력기에 관하여"
    }

    private let kiwiService = KiwiAnalysisService.shared
    private let hanjaService = HanjaDictionaryService.shared
    private let settingsStore = HanjaSettingsStore.shared
    private let warmUpPanelController = HanjaWarmUpPanelController.shared
    private let candidatePanelController = HanjaCandidatePanelController.shared
    private let userDictionaryWindowController = HanjaUserDictionaryWindowController.shared
    private weak var currentMenu: NSMenu?
    private weak var realtimeMenuItem: NSMenuItem?
    private weak var manageUserDictionaryMenuItem: NSMenuItem?

    private override init() {
        super.init()
    }

    var manualHanjaAvailability: ManualHanjaAvailability {
        switch hanjaService.status {
        case .ready:
            return .ready
        case .loading, .uninitialized:
            return .loading
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    var isManualHanjaAvailable: Bool {
        if case .ready = manualHanjaAvailability {
            return true
        }

        return false
    }

    var isRealtimeHanjaAvailable: Bool {
        realtimeConversionPhaseUnlocked && kiwiService.isAvailable && hanjaService.isAvailable
    }

    var isRealtimeHanjaConversionEnabled: Bool {
        isRealtimeHanjaAvailable ? settingsStore.useRealtimeHanjaConversion : false
    }

    var canToggleRealtimeHanjaConversion: Bool {
        isRealtimeHanjaAvailable
    }

    var areServicesLoading: Bool {
        kiwiService.isLoading || hanjaService.isLoading
    }

    func warmUp(
        kiwiStatusDidResolve: @escaping (KiwiAnalysisService.Status) -> Void,
        hanjaStatusDidResolve: @escaping (HanjaDictionaryService.Status) -> Void
    ) {
        kiwiService.warmUp { [weak self] in
            guard let self else {
                return
            }

            kiwiStatusDidResolve(self.kiwiService.status)

            self.hanjaService.warmUp { [weak self] in
                guard let self else {
                    return
                }

                hanjaStatusDidResolve(self.hanjaService.status)
                self.warmUpPanelController.hide()
            }
        }
    }

    func showWarmUpPanelIfNeeded() {}

func hideWarmUpPanelIfNeeded() {
        guard areServicesLoading else {
            return
        }

        warmUpPanelController.hide()
    }

    func hideWarmUpPanel() {
        warmUpPanelController.hide()
    }

    var isManualCandidatePanelVisible: Bool {
        candidatePanelController.isVisible
    }

    func makeMenu(
        target: AnyObject,
        realtimeAction: Selector,
        manageUserDictionaryAction: Selector,
        aboutAction: Selector
    ) -> NSMenu {
        let menu = NSMenu(title: "우리입력기")
        menu.autoenablesItems = false
        menu.delegate = self
        let realtimeItem = makeToggleMenuItem(
            title: MenuTitle.realtimeConversion,
            action: realtimeAction,
            isOn: isRealtimeHanjaConversionEnabled,
            isEnabled: canToggleRealtimeHanjaConversion,
            target: target,
            keyEquivalent: InputEventPolicy.realtimeHanjaToggleKeyEquivalent,
            keyEquivalentModifierMask: InputEventPolicy.realtimeHanjaToggleModifierMask
        )
        menu.addItem(realtimeItem)
        menu.addItem(.separator())

        let manageItem = NSMenuItem(
            title: MenuTitle.manageUserDictionary,
            action: manageUserDictionaryAction,
            keyEquivalent: ""
        )
        manageItem.target = target
        manageItem.isEnabled = isManualHanjaAvailable
        menu.addItem(manageItem)

        menu.addItem(.separator())
        let aboutItem = NSMenuItem(
            title: MenuTitle.about,
            action: aboutAction,
            keyEquivalent: ""
        )
        aboutItem.target = target
        menu.addItem(aboutItem)

        currentMenu = menu
        realtimeMenuItem = realtimeItem
        manageUserDictionaryMenuItem = manageItem
        refreshMenuState(menu)
        return menu
    }

    func showUserDictionaryWindow() {
        userDictionaryWindowController.show()
    }

    func showAboutWindow() {
        AboutWindowController.shared.show()
    }

    func toggleRealtimeHanjaConversion() {
        guard canToggleRealtimeHanjaConversion else {
            return
        }

        settingsStore.toggleUseRealtimeHanjaConversion()
        refreshMenuState()
    }

    func flushUsageWrites() {
        hanjaService.flushUsageWrites()
    }

    func analyzeRealtimeClause(_ clause: String) -> [HanjaSegment] {
        guard kiwiService.isAvailable, hanjaService.isAvailable else {
            return []
        }

        return kiwiService.analyzeClause(clause, hanjaService: hanjaService)
    }

    func manualLookup(for target: ManualHanjaTarget) -> ManualHanjaLookupResult {
        hanjaService.manualLookup(for: target)
    }

    func recordSelection(lookupKey: String, value: String) {
        hanjaService.recordSelection(lookupKey: lookupKey, value: value)
    }

    func recordHangulSelection(lookupKey: String) {
        hanjaService.recordHangulSelection(lookupKey: lookupKey)
    }

    func hangulUsageCount(for lookupKey: String) -> Int {
        hanjaService.hangulUsageCount(for: lookupKey)
    }

    func showCandidatePanel(
        content: ManualHanjaPanelContent,
        client: any IMKTextInput,
        onSelect: ((HanjaCandidatePanelSelection) -> Void)? = nil
    ) {
        switch content {
        case .candidates(let state):
            switch state.mode {
            case .manual(let sourceText, _):
                manualHanjaPanelLogger.info(
                    "show manual candidates sourceText=\(sourceText, privacy: .public) count=\(state.candidates.count, privacy: .public)"
                )
            case .realtime(_, let segmentSurface):
                manualHanjaPanelLogger.info(
                    "show realtime candidates segment=\(segmentSurface, privacy: .public) count=\(state.candidates.count, privacy: .public) page=\(state.page, privacy: .public)"
                )
            }
        case .notice(let state):
            manualHanjaPanelLogger.info(
                "show notice message=\(state.message, privacy: .public) detail=\(state.detail ?? "", privacy: .public)"
            )
        }

        let anchorResolution = ManualHanjaPanelAnchorResolver.resolve(content: content, client: client)
        for probe in anchorResolution.probes {
            manualHanjaPanelLogger.debug(
                "anchor candidate range=\(inputDebugRangeString(probe.range), privacy: .public) actual=\(inputDebugRangeString(probe.actualRange), privacy: .public) rect=\(String(describing: probe.rect), privacy: .public) valid=\(probe.isValid, privacy: .public)"
            )
        }

        if anchorResolution.rect == nil {
            manualHanjaPanelLogger.warning("anchor rect invalid; showing panel with fallback position")
        }
        candidatePanelController.show(
            content: content,
            anchorRect: anchorResolution.rect,
            onSelect: onSelect
        )
    }

    func realtimeCandidates(for segment: HanjaSegment) -> [HanjaCandidate] {
        let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: segment.normalizedLookupKey)
        if !numericCandidates.isEmpty {
            return numericCandidates
        }

        return hanjaService.exactCandidates(for: segment.normalizedLookupKey)
    }

    func flushRealtimeUsageEvents(_ events: [PendingHanjaUsageEvent]) {
        guard !events.isEmpty else {
            return
        }

        for event in events {
            hanjaService.recordSelection(lookupKey: event.lookupKey, value: event.value)
        }
        hanjaService.flushUsageWrites()
    }

    func hideManualCandidatePanel() {
        manualHanjaPanelLogger.info("hide panel")
        candidatePanelController.hide()
    }

    func refreshMenuState(_ menu: NSMenu? = nil) {
        let menu = menu ?? currentMenu

        let realtimeItem = menu?.item(withTitle: MenuTitle.realtimeConversion) ?? realtimeMenuItem
        realtimeItem?.state = isRealtimeHanjaConversionEnabled ? .on : .off
        realtimeItem?.isEnabled = canToggleRealtimeHanjaConversion

        let manageItem = menu?.item(withTitle: MenuTitle.manageUserDictionary) ?? manageUserDictionaryMenuItem
        manageItem?.isEnabled = isManualHanjaAvailable
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState(menu)
    }

    private func makeToggleMenuItem(
        title: String,
        action: Selector,
        isOn: Bool,
        isEnabled: Bool,
        target: AnyObject,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalentModifierMask
        item.target = target
        item.state = isOn ? .on : .off
        item.isEnabled = isEnabled
        return item
    }
}
