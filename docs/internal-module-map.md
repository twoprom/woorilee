# Woorilee Internal Module Map

This map describes the current runtime structure of the IME process. The
historical InputController split is complete; the boundaries below are the
ones to preserve when extending the code.

## Entry Points

- `woorilee/main.swift`
  - Starts `NSManualApplication.shared`.
  - Must remain the manual launch path for the IME process — no storyboard / nib.
- `woorilee/AppDelegate.swift`
  - Creates `IMKServer` from `Info.plist`'s `InputMethodConnectionName`.
  - Kicks off Hanja / Kiwi warm-up via `HanjaServiceCoordinator.shared`.

## Core IME Runtime

- `woorilee/InputController.swift`
  - Public IMK entry point (`InputMethodServerControllerClass` in `Info.plist`).
  - Keeps only IMK-facing orchestration: `handle(_:client:)`, menu hookup,
    and dispatch into the helpers below. Does not own composition state.
- `woorilee/InputEventPolicy.swift`
  - Pure key-event normalization: printable ASCII extraction, two-beolsik
    shift mapping, navigation / selector classification. Stateless.
- `woorilee/InputCompositionEngine.swift`
  - Marked-text and replacement-range bookkeeping; commit / update helpers
    that wrap the `IMKTextInput` calls.
- `woorilee/InputSession.swift`
  - Per-client `InputSession`, plus `InputSessionCache` and `InputRangeState`.
  - `InputController` resolves sessions through the cache. Never store
    composition state on `InputController` itself — IMK reuses controller
    instances across clients.

## Hanja Conversion Path

- `woorilee/HanjaServiceCoordinator.swift`
  - `@MainActor` singleton coordinating Hanja menu state, warm-up panel,
    manual candidate panel, and the Kiwi-driven realtime conversion path.
  - `realtimeConversionPhaseUnlocked` (currently `true`) is the kill switch
    for the realtime path; `isRealtimeAvailable` additionally requires both
    Kiwi and the Hanja dictionary to be `ready`.
- `woorilee/HanjaConversionModels.swift`
  - `CompositionMode` (`hangul` / `manualHanja` / `realtimeHanja`),
    `SegmentLockKey`, and `RealtimeClauseState` — the value types shared
    between the coordinator, session, and tests.
- `woorilee/ManualHanjaModels.swift`
  - Value types for the manual Hanja panel (target / notice / content).
- `woorilee/ManualHanjaPanelAnchorResolver.swift`
  - Anchor-rect probing logic that places the panel near the caret across
    host apps.
- `woorilee/HanjaCandidatePanelController.swift`
  - Non-activating panel that hosts both manual and realtime candidates.
- `woorilee/HanjaCandidatePanelView.swift`
  - SwiftUI view backing the candidate panel.
- `woorilee/HanjaWarmUpPanelController.swift`
  - Non-activating loading panel shown while Kiwi / Hanja warm up.

## Supporting Services

Each service owns a warm-up `Status` enum
(`uninitialized` / `loading` / `ready` / `unavailable(reason)`):

- `woorilee/KiwiAnalysisService.swift` — background warm-up of Kiwi
  morphological analyzer.
- `woorilee/HanjaDictionaryService.swift` — loads the bundled hanja table.
- `woorilee/HanjaUsageStore.swift` — usage stats used to rank candidates.
- `woorilee/UserHanjaStore.swift` — user-defined entries used to rank
  candidates.
- `woorilee/HanjaSettingsStore.swift` — menu-backed settings (realtime
  conversion toggle, auto-advance after numeric selection, ...).
- `woorilee/HanjaPersonalizationModels.swift` — shared Codable shapes
  (`HanjaCandidateKey`, `HanjaCandidateSource`, ...) used by the stores.
- `woorilee/AppRuntimePaths.swift` — on-disk paths (Application Support
  layout, bundled-resource names).

## Test Coverage

- `woorileeTests/InputEventPolicyTests.swift` — key normalization and
  navigation selector classification.
- `woorileeTests/InputRangeStateTests.swift` — replacement-range and
  marked-range transitions.
- `woorileeTests/InputSessionTests.swift` — per-client session and cache
  behavior.
- `woorileeTests/RealtimeHanjaAnalysisTests.swift` — `RealtimeClauseState`
  segment lifecycle, locking, and hangul fallback.
- `woorileeTests/HanjaCandidateRankingTests.swift` — candidate ranking
  against usage / user stores.
- `woorileeTests/HanjaUsageStoreTests.swift`,
  `woorileeTests/UserHanjaStoreTests.swift` — store persistence.
- `woorileeTests/ManualHanjaModelsTests.swift`,
  `woorileeTests/ManualHanjaPanelAnchorResolverTests.swift` — manual
  panel value types and anchor probing.
