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
  - Also handles manual target extraction and candidate-panel navigation.
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
  - `RealtimeClauseState` also carries the manual segment-boundary overlay
    (`manualBoundaries` / `focusedSpanStart`) used by Shift+←/→ 신축, with
    `seedManualBoundariesIfNeeded` / `adjustFocusedBoundary` /
    `clearManualSegmentation`. When the overlay is active, `updateAnalysis`
    restores selection by focused-span start rather than `SegmentLockKey`.
- `woorilee/ManualHanjaModels.swift`
  - Value types for the manual Hanja panel (target / notice / content).
- `woorilee/ManualHanjaPanelAnchorResolver.swift`
  - Anchor-rect probing logic that finds the caret rect across host apps.
- `woorilee/CandidatePanelOriginCalculator.swift`
  - Pure placement math: turns the caret anchor rect into the panel origin
    (hang below the caret, flip above when it won't fit, clamp to the visible
    frame). Stateless; covered by `CandidatePanelOriginCalculatorTests`.
- `woorilee/NumericHanjaCandidateGenerator.swift`
  - Stateless generator of 數字 candidates for all-digit input — digit-by-digit
    and quantity-unit readings in both Hanja and Hangul.
- `woorilee/DateHanjaCandidateGenerator.swift`
  - Relative-day expressions produce nine date notations using the current local
    date and time zone, with slash dates and Korean/Hanja weekdays first, followed by
    Gregorian and Republic of Korea era dates.
    Manual and realtime panels share the same fixed candidate order;
    realtime expressions retain their source until explicitly selected, like numeric input.
- `woorilee/HanjaCandidatePanelController.swift`
  - Non-activating panel that hosts both manual and realtime candidates;
    positions itself via `CandidatePanelOriginCalculator`.
- `woorilee/HanjaCandidatePanelView.swift`
  - SwiftUI view backing the candidate panel.
- `woorilee/HanjaWarmUpPanelController.swift`
  - Non-activating loading panel shown while Kiwi / Hanja warm up.

## Context Recommendation and Evaluation

- `HanjaContextRanker.swift` owns containment, corpus associations, gazette priors and session
  scoring. `rankSegmentCandidates` is shared by the panel and app-settings evaluation.
- `HanjaContextAssociationStore.swift` loads the corpus/curated binary table. D3 bias support
  exists but current bundled biases are all zero.
- `SessionHanjaContext.swift` owns memory-only vocabulary and explicit-selection priors per client.
  Automatic previews never create selection priors; a committed Hangul choice clears a stale prior.
- `HanjaPerformance.swift` records scalar-only timing stages and supplies an offline observer.
- Manual lookup uses at most 200 UTF-16 units on each side of the target. Manual boundary edits
  reuse `RealtimeClauseState.automaticContextSegments` without rerunning Kiwi; overlapping spans'
  self-excluded feature sets are intersected to avoid self-voting after merges or splits.
- `HanjaClauseJointSelection.swift` implements the historical R2 experiment. The default weight
  is zero, so joint search is skipped. K1 semantic registration and D3 training remain parked.
- `KiwiAnalysisService.analyzeClause(_:kiwi:...)` is the shared app/offline entry point for
  top-3 analysis, winning segmentation, stable features, reranking and auto-conversion gates.
- `scripts/hanja-context/assoc` compiles the Foundation/Kiwi subset through symlinks. `app-verify`
  calls the shared pipeline; legacy `d2-verify`, `eval-ctx` and `eval5d` preserve old settings.
  `segmentation-compare` evaluates a score-first alternative offline without changing app policy.
  Reranking prepares positional content-feature strings once per call, then excludes each target
  span before deduplication. The zero-weight character-share axis skips grapheme-set construction.

## App UI Windows

Off the IME hot path; shown from the input-method menu:

- `woorilee/AboutWindowController.swift`
  - About panel. Also owns the Sparkle `SPUStandardUpdaterController` that
    drives auto-update.
- `woorilee/HanjaUserDictionaryWindowController.swift`
  - Window controller for the user Hanja dictionary editor.
- `woorilee/HanjaUserDictionaryView.swift`
  - SwiftUI editor view, backed by `UserHanjaStore`.

## Supporting Services

Each service owns a warm-up `Status` enum
(`uninitialized` / `loading` / `ready` / `unavailable(reason)`):

- `woorilee/KiwiAnalysisService.swift` — background warm-up of Kiwi
  morphological analyzer. Also hosts `makeManualSegments`, which builds a
  gap-free `[HanjaSegment]` partition from user-drawn boundaries (no Kiwi
  tokens, dictionary lookup only) for the Shift+←/→ boundary-adjust path.
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

- `woorileeTests/DateHanjaCandidateTests.swift` — relative-day aliases, date notations and labels,
  calendar/time-zone boundaries, real Kiwi segmentation, and manual/realtime candidate paths.
- `woorileeTests/InputEventPolicyTests.swift` — key normalization and
  navigation selector classification.
- `woorileeTests/InputRangeStateTests.swift` — replacement-range and
  marked-range transitions.
- `woorileeTests/InputSessionTests.swift` — per-client session and cache
  behavior.
- `woorileeTests/RealtimeHanjaAnalysisTests.swift` — `RealtimeClauseState`
  segment lifecycle, locking, and hangul fallback.
- `woorileeTests/RealtimeSegmentBoundaryTests.swift` — manual boundary
  seed/expand/shrink/clamp/merge, numeric splitting, focus retention, and
  overlay discard for the Shift+←/→ 신축 path.
- `woorileeTests/RealtimeHanjaCommitCancelTests.swift` — realtime commit /
  cancel transitions.
- `woorileeTests/RealtimeHanjaUsageFlushTests.swift` — usage-stat flushing on
  realtime commit.
- `woorileeTests/HanjaCandidateRankingTests.swift` — candidate ranking
  against usage / user stores.
- `woorileeTests/HanjaUsageStoreTests.swift`,
  `woorileeTests/UserHanjaStoreTests.swift` — store persistence.
- `woorileeTests/ManualHanjaModelsTests.swift`,
  `woorileeTests/ManualHanjaPanelAnchorResolverTests.swift` — manual
  panel value types and anchor probing.
- `woorileeTests/CandidatePanelOriginCalculatorTests.swift` — panel origin
  placement (below / flip-above / clamp).
- `woorileeTests/FakeIMKTextInput.swift` — shared fake `IMKTextInput` client
  used by the session / range tests.
