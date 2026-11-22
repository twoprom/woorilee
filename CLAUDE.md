# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Companion docs — read the relevant ones before non-trivial changes:

- [`AGENTS.md`](AGENTS.md) — the Korean counterpart of this file. It carries the same project rules; keep the two in sync when either changes.
- [`docs/internal-module-map.md`](docs/internal-module-map.md) — authoritative per-file runtime map (IME runtime, Hanja path, context recommendation, test coverage).
- [`docs/runtime-resource-inventory.md`](docs/runtime-resource-inventory.md) — exact bundle resource shape and the state of the bundled association table.
- [`docs/refactor-parity-checklist.md`](docs/refactor-parity-checklist.md) — the gate to re-verify after any project-file or resource change.
- [`docs/kiwi-artifacts.md`](docs/kiwi-artifacts.md) — the `Kiwi` submodule, `CKiwi.xcframework`, Git LFS, first-clone setup.
- [`docs/sparkle-release-workflow.md`](docs/sparkle-release-workflow.md) — the release workflow (build → sign → upload → appcast). Follow it exactly when releasing.
- [`docs/hanja-improvement-progress-2026-11-15.md`](docs/hanja-improvement-progress-2026-11-15.md) — the most recent execution record for the Hanja recommendation/conversion work: what shipped, what was measured, and what is explicitly *not* proven yet.
- [`scripts/hanja-context/README.md`](scripts/hanja-context/README.md) — the offline data and evaluation pipeline (corpus mining, association table, `assoc app-verify`, independent review import).
- `docs/plans/` — the staged plan documents the Hanja work is executed against. **Gitignored and local-only** (so is `AGENTS.md` / `CLAUDE.md`); treat them as the spec, not as repo history.

## Project

`woorilee` is a macOS Korean (두벌식 / two-beolsik) input method built on `InputMethodKit`. It is **not** a normal AppKit app: there is no storyboard/nib, and `woorilee/main.swift` launches `NSManualApplication.shared` directly so that `IMKServer` can be registered programmatically. Do not convert it to a storyboard-based launch.

The composition engine is `LibHangul`. Hanja conversion is supported by a bundled dictionary (`woorilee/data/hanja/hanja.txt`) and morphological analysis from the locally-vendored `Kiwi` Swift package + `KiwiModels` resources. `IMKSwift` wraps the raw IMK API — prefer it over `InputMethodKit` directly, and only fall back to raw IMK with an explicit comment explaining why.

Beyond plain Hangul→Hanja lookup, the IME runs a **context-aware** recommendation path: a bundled corpus association table (`hanja-context.bin`), gazette/proper-noun priors, a native-homograph auto-conversion gate (`hanja-native-homograph.txt`), and per-client session context. Context ranking is always on — it is not a menu toggle. The only menu-backed setting is the realtime-conversion toggle (`HanjaSettingsStore`).

## Directory structure

- `/Volumes/Workbench/woorilee/woorilee/` — app target source, resources, bundled data
- `/Volumes/Workbench/woorilee/woorileeTests/` — the only test target (no UI test target)
- `/Volumes/Workbench/woorilee/` — project root: `woorilee.xcodeproj`, build scripts, vendored deps (`Kiwi` submodule, `KiwiModels`, IMKSwift/LibHangul via SwiftPM), documentation
- `Config/` — `Signing.xcconfig` (committed) optionally includes `Signing.local.xcconfig` (gitignored, holds `DEVELOPMENT_TEAM`)
- `scripts/hanja-context/` — Python 3 + Swift offline pipeline for the context association table and evaluation
- `eval/` — committed evaluation sets and preserved result bundles (e.g. `eval/hanja-improvement-2026-11-15/`)

## First-time setup

`Kiwi/` is a **Git submodule** (`https://github.com/twoprom/Kiwi.git`), and both `CKiwi.xcframework` and the runtime model files are Git LFS objects. After cloning:

```sh
git submodule update --init --recursive
git lfs pull
git -C Kiwi lfs pull
scripts/prepare-kiwi-artifacts.sh
```

For signed builds, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and fill in the Team ID. A checkout without that file still builds (the include is optional); Release builds need it.

## Build, install, test

```sh
# Schemes / targets
xcodebuild -list -project woorilee.xcodeproj

# Debug build (app target). The WOORILEE_INSTALL_BUILT_INPUT_METHOD=1 prefix opts into
# the install PostAction so the running input method is refreshed (see below).
WOORILEE_INSTALL_BUILT_INPUT_METHOD=1 \
  xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build

# Unit tests (woorileeTests). CLI test runs fail on a signing Team ID mismatch between the
# app and the test bundle, so override signing for the test run only — never commit this
# into the project's signing settings.
xcodebuild -project woorilee.xcodeproj -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' test \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO

# Single test (class or method) — same signing overrides apply
xcodebuild -project woorilee.xcodeproj -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:woorileeTests/InputEventPolicyTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO
```

For a Release test sweep add `ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES`. The current full Release suite is 345 tests.

`scripts/install-built-input-method.sh` runs as the scheme's `Install Built Input Method` **build PostAction** (it fires on every build, including CLI `xcodebuild`). It **skips install by default** and only installs when `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1` is set; with the opt-in it `killall woorilee`s the running input method and `ditto`s the built `.app` into `/Library/Input Methods/` (escalating via `osascript` if needed). `WOORILEE_SKIP_INSTALL=1` or `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0` force-skip even when the opt-in is present. For manual installs, prefer `ditto` over `cp -R` for app bundles, and `killall woorilee` first — macOS will not pick up a replaced bundle while the old process is alive.

When passing an explicit `SYMROOT`/DerivedData path, use an absolute path. With the project's own settings the Release app lands in `DerivedData/Build/Products/Release/`, not `build/Build/Products/Release/`.

There is no UI test target, and automated tests cannot cover host-app behavior. After input-logic changes, manually verify in Safari, TextEdit and Terminal: Hangul compose/commit, `Backspace`/`Space`/`Return`/`Escape`/`Tab` handling, arrow/movement-induced commits, selection-based and mid-composition manual conversion, `Shift+←/→` boundary adjustment, candidate paging, and that `markedRange` / `replacementRange` stay consistent across clients.

## Development workflow

**Always build with the install opt-in after code changes.** After any source modification, run a build automatically (do not wait to be asked) **with `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1`** so the running input method is refreshed:

```sh
WOORILEE_INSTALL_BUILT_INPUT_METHOD=1 \
  xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build
```

Install is **opt-in**, not automatic. The scheme's `Install Built Input Method` build PostAction (`scripts/install-built-input-method.sh`) fires on every build but **skips unless `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1`** is set. With the opt-in, the PostAction:

1. Executes `killall woorilee` to stop the running input method
2. Copies the built `.app` bundle into `/Library/Input Methods/` using `ditto` (preserving bundle structure and permissions; escalating via `osascript` if needed)

The input method is then live — no manual restart required. Never set `WOORILEE_SKIP_INSTALL=1` or `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0` — they force-skip the install. A plain build with no env var compiles but does **not** install; reserve that for `xcodebuild … test`, which should not touch `/Library/Input Methods/`.

## Architecture

Entry path: `main.swift` → `NSManualApplication` (defined in `AppDelegate.swift`) → `AppDelegate.applicationDidFinishLaunching` constructs `IMKServer` from `Info.plist`'s `InputMethodConnectionName` and kicks off Hanja/Kiwi warm-up through `HanjaServiceCoordinator.shared`.

`Info.plist` wiring that must stay in sync if renamed:
- `InputMethodConnectionName` ↔ the `name:` argument passed to `IMKServer` in `AppDelegate`.
- `InputMethodServerControllerClass` ↔ `InputController` (the `IMKInputSessionController` subclass IMK instantiates per client).

The IME runtime is intentionally split (see `docs/internal-module-map.md`); changes should respect these boundaries rather than re-collapsing them into `InputController`:

- [InputController.swift](woorilee/InputController.swift) — only IMK-facing orchestration: `handle(_:client:)`, menu hookup, manual target extraction, candidate-panel navigation, dispatch into the helpers below.
- [InputEventPolicy.swift](woorilee/InputEventPolicy.swift) — pure key-event normalization (printable ASCII extraction, two-beolsik shift mapping, navigation/selector classification). Stateless and unit-testable.
- [InputCompositionEngine.swift](woorilee/InputCompositionEngine.swift) — marked-text / replacement-range bookkeeping; commit + update helpers that wrap the `IMKTextInput` calls.
- [InputSession.swift](woorilee/InputSession.swift) — per-client `InputSession` plus `InputSessionCache` and `InputRangeState`. `InputController` looks up sessions through the cache; never store composition state on `InputController` itself, since IMK reuses controller instances across clients.
- [HanjaServiceCoordinator.swift](woorilee/HanjaServiceCoordinator.swift) — singleton coordinating Hanja menu state, warm-up panel, manual candidate panel, and the Kiwi-driven realtime conversion path. The `realtimeConversionPhaseUnlocked` flag (currently `true`) is the kill switch for the realtime path; `isRealtimeAvailable` additionally requires both Kiwi and the Hanja dictionary to be `ready`.
- [HanjaConversionModels.swift](woorilee/HanjaConversionModels.swift) — `CompositionMode` (`hangul` / `manualHanja` / `realtimeHanja`) and `SegmentLockKey`, the value types shared between the coordinator, session, and tests. `RealtimeClauseState` also holds the manual segment-boundary overlay (`manualBoundaries` / `focusedSpanStart`) that powers Japanese-IME-style 문절 신축 via Shift+←/→ in realtime mode; when active, the analysis pipeline honors the overlay (`KiwiAnalysisService.makeManualSegments`) instead of re-running Kiwi, and the overlay is dropped on any source edit (typing / Backspace / Space).
- [ManualHanjaModels.swift](woorilee/ManualHanjaModels.swift) / [ManualHanjaPanelAnchorResolver.swift](woorilee/ManualHanjaPanelAnchorResolver.swift) — value types for the manual Hanja panel (target / notice / content) and the anchor-rect probing logic that finds the caret rect across host apps. [CandidatePanelOriginCalculator.swift](woorilee/CandidatePanelOriginCalculator.swift) is the pure placement math that turns that caret rect into the panel origin (hang below the caret, flip above when it won't fit, clamp to the visible frame); keep it stateless and unit-tested.
- [NumericHanjaCandidateGenerator.swift](woorilee/NumericHanjaCandidateGenerator.swift) — stateless generator of 數字 candidates for numeric input (digit-by-digit and quantity-unit readings, in Hanja and Hangul, plus mixed Hanja-unit forms). Used by the candidate path when the source text is all digits.
- [DateHanjaCandidateGenerator.swift](woorilee/DateHanjaCandidateGenerator.swift) — relative-day expressions (오늘/어제/…) expand to nine date notations from the current local date and time zone: slash dates and Korean/Hanja weekdays first, then Gregorian and ROK-era forms. Manual and realtime panels share one fixed candidate order, and realtime expressions keep their source text until explicitly selected, like numeric input.

### Context recommendation

The ranking path is shared by the app and the offline evaluator — do not fork it:

- [HanjaContextRanker.swift](woorilee/HanjaContextRanker.swift) — containment, corpus associations, gazette priors and session scoring. `rankSegmentCandidates` is the single ordering function used by both the candidate panel and `assoc app-verify`. `buildDominantHanjaMap` (dominance ratio 5) defines what counts as an ambiguous reading, and the offline Python mirrors it.
- [HanjaContextAssociationStore.swift](woorilee/HanjaContextAssociationStore.swift) — loads the corpus/curated binary table. Per-candidate D3 bias support stays in the loader for experiments, but every bias in the current bundle is zero.
- [SessionHanjaContext.swift](woorilee/SessionHanjaContext.swift) — memory-only vocabulary and explicit-selection priors per client. **Automatic previews never create selection priors**; a committed Hangul choice clears a stale Hanja prior, and cancelling leaves priors untouched.
- [HanjaClauseJointSelection.swift](woorilee/HanjaClauseJointSelection.swift) — the parked R2 joint-selection experiment. `jointDomainConsistency` defaults to `0`, so the second pass is skipped entirely.
- [HanjaPerformance.swift](woorilee/HanjaPerformance.swift) — scalar-only stage timing plus the hook the offline tool uses. Timing events carry stage names and durations only; **never add raw user text to a log or timing field** (logs record lengths and ranges instead).
- `KiwiAnalysisService.analyzeClause(_:kiwi:…)` — the shared app/offline entry point for top-3 analysis, winning segmentation, stable features, reranking and the auto-conversion gates.
- Manual lookup requests at most 200 UTF-16 units of host context on each side of the target and excludes the target span itself; on failure it falls back to the existing candidates and session history. Manual boundary edits reuse the last automatic analysis (intersecting the self-excluded feature sets of overlapping spans) instead of re-running Kiwi.

Supporting services (each owns its own warm-up `Status` enum: `uninitialized` / `loading` / `ready` / `unavailable(reason)`):

- [KiwiAnalysisService.swift](woorilee/KiwiAnalysisService.swift) — background warm-up of Kiwi morphological analyzer; also hosts `makeManualSegments`, which builds a gap-free partition from user-drawn boundaries (dictionary lookup only, no Kiwi tokens).
- [HanjaDictionaryService.swift](woorilee/HanjaDictionaryService.swift) — loads the bundled hanja table and the native-homograph flag list (`isNativeHomographReading`, fail-open).
- [HanjaUsageStore.swift](woorilee/HanjaUsageStore.swift) / [UserHanjaStore.swift](woorilee/UserHanjaStore.swift) — usage stats and user-defined entries used to rank candidates. Shared Codable shapes (`HanjaCandidateKey`, `HanjaCandidateSource`, …) live in [HanjaPersonalizationModels.swift](woorilee/HanjaPersonalizationModels.swift); on-disk paths (Application Support layout, bundled-resource names) are centralized in [AppRuntimePaths.swift](woorilee/AppRuntimePaths.swift).
- [HanjaSettingsStore.swift](woorilee/HanjaSettingsStore.swift) — the menu-backed realtime-conversion toggle (`useRealtimeHanjaConversion`). Context-based conversion has no menu switch; it was made unconditional.
- [HanjaWarmUpPanelController.swift](woorilee/HanjaWarmUpPanelController.swift) / [HanjaCandidatePanelController.swift](woorilee/HanjaCandidatePanelController.swift) — non-activating panels (a warm-up loading panel and the Hanja candidate picker, used for both manual and realtime candidates). [HanjaCandidatePanelView.swift](woorilee/HanjaCandidatePanelView.swift) is the SwiftUI view hosted inside the candidate panel. The panel highlights the preview until the user navigates, then restores selection and page by candidate identity.
- App UI windows (not on the IME hot path): [AboutWindowController.swift](woorilee/AboutWindowController.swift) — About panel; also owns the Sparkle `SPUStandardUpdaterController` (auto-update). [HanjaUserDictionaryWindowController.swift](woorilee/HanjaUserDictionaryWindowController.swift) / [HanjaUserDictionaryView.swift](woorilee/HanjaUserDictionaryView.swift) — the user Hanja dictionary editor backed by `UserHanjaStore`.

### Concurrency

`InputController`, `AppDelegate`, `InputSession`, and `HanjaServiceCoordinator` are `@MainActor`. Don't break this assumption — IMK callbacks run on the main thread and the panels are AppKit views. Background work (Kiwi/Hanja warm-up, file I/O for usage stores) is dispatched off-main and routed back via `@MainActor` callbacks; preserve that pattern.

### Resources & dependencies

- App-bundle resources live under `woorilee/`: `data/hanja/{hanja.txt,freq-hanja.txt,freq-hanjaeo.txt,hanja-context.bin,hanja-native-homograph.txt}`, `KiwiModels/*` (`combiningRule.txt`, `cong.mdl`, `default.dict`, `dialect.dict`, `extract.mdl`, `multi.dict`, `nounchr.mdl`, `sj.morph`, `typo.dict`), `main.tiff`, `mainicon.icon` (an Icon Composer bundle that compiles to `mainicon.icns`), `*.lproj/InfoPlist.strings`. Assembly is split across Xcode folder-sync plus the `Copy Bundled Hanja Dictionary` and `Copy Bundled Kiwi Models` shell phases. `docs/refactor-parity-checklist.md` is the canonical list — verify it after any project-file change.
- `hanja-context.txt` sits next to `hanja-context.bin` for tests and diffs but is **not** bundled; the app reads the binary. `*.d3-backup` copies are local-only A/B artifacts.
- `Kiwi/` at the repo root is a **Git submodule** (don't edit it without an explicit request); root `KiwiModels/` is a gitignored reference copy. The **bundled** models are `woorilee/KiwiModels/`. Don't confuse the two paths.
- SwiftPM dependencies (resolved via the Xcode project): `IMKSwift` (vChewing), `LibHangul` (Meapri), `Sparkle` (auto-update, used only by `AboutWindowController`), and a local-path `Kiwi` package at `Kiwi/bindings/swift` (whose `CKiwi` comes from `Artifacts/CKiwi.xcframework`). Patching these is a last resort — solve at the app layer first.
- Generated/cache directories — `DerivedData/`, `DerivedDataPlan/`, `.xcode-home/`, `.xcode-swiftpm-modulecache/`, `build/`, and the `.build/` dirs under `scripts/hanja-context/*` — are gitignored and should not be edited.

## Offline data & evaluation pipeline

`scripts/hanja-context/` builds and checks the bundled association table; `scripts/hanja-context/README.md` is the authoritative reference for every command and parameter. Key points:

- Python stages use **Python 3 standard library only** (no third-party packages; `kiwipiepy` is banned because it would break the morpheme-space contract). Large intermediates are written outside this repo, under `/Volumes/Workbench/wooriHanjaModel/work/hanja-context/`.
- The offline/runtime **morpheme-space contract** (Kiwi version, bundled models, analysis options, content tags, `form/TAG` feature keys) must match exactly, or the table silently stops working.
- `build_association_table.py` regenerates `hanja-context.{txt,bin}` from mined counts and merges `curated-association-overrides.txt`; `verify_binary_roundtrip.py` validates keys, quantization error, CRC/header and bias slots against the matching stats file. The 2026-11-15 bundle verified at 3,260 readings / 18,126 profiles / 827,610 associations with all biases zero.
- The Swift evaluator lives in `scripts/hanja-context/assoc`. `assoc app-verify` is the production-path evaluator (shared top-3 analysis, both conversion gates, panel ranking, actual automatic value, hold reason, dictionary call count, per-stage timing). Legacy modes `d2-verify`, `eval-ctx`, `eval5d` preserve their original settings — don't "fix" them. `app-preview-trace` and `segmentation-compare` are diagnostic only.
- Result bundles are committed under `eval/` and are **evidence, not scratch**: keep `app-baseline.jsonl` / `legacy-baseline.tsv` with their resource manifest, and never regenerate a historical audit against a changed dictionary (the audit refuses a hash mismatch).

### Evidence discipline

The Hanja work is deliberately conservative about claims. Keep these rules:

- **Don't declare accuracy or generalization wins.** The D2 set and v1/v2 labels have already been used for error analysis and tuning, so they cannot prove unseen performance. Do not tune thresholds against reviewed D2 rows. The frozen three-row modern-prose holdout is an unscored pilot, not an acceptance gate.
- The current measured state (2026-11-15): 936/1,105 exact target spans under app settings, automatic-conversion precision 72.7% (32/44 scorable rows) on the 73-row independent review, rerank p95 0.123 ms (short) / 0.483 ms (long) offline in Release. Host-app input latency and behavior are **still unverified**.
- A stricter hold policy was measured and **rejected** (it cut correct automatic conversions more than it cut errors). Don't reintroduce it without new independent evidence.
- **Parked experiments:** D3 signed-sparse ranker training (biases inactive; don't run the D3 export as routine regeneration), R2 joint selection (`jointDomainConsistency = 0`), K1 Kiwi-LM semantic registration, background analysis. Leave them parked unless the plan docs say otherwise.
- Dictionary additions need a cited source recorded in the matching `eval/.../dictionary-provenance.md`. Don't invent frequencies, glosses or association weights; readings without primary-source evidence stay out (e.g. `재주:才操` is still on hold).

## Working in this repo

- `git status` is noisy because of `xcuserstate` and DerivedData churn. Scope diffs: `git status --short -- AGENTS.md woorilee woorilee.xcodeproj` and `git diff -- woorilee woorilee.xcodeproj AGENTS.md`.
- `woorilee/InputController.swift` is hot; small refactors there can regress `insertText` / `setMarkedText` / `unmarkText` / `selectedRange` / `markedRange` interactions across apps. Keep edits narrow and verify manually.
- Don't revert the user's own in-flight changes, especially in `InputController.swift`.
- For Apple framework behavior (AppKit, InputMethodKit, text input system), look it up rather than guessing — IMK has subtle, undocumented quirks per host app. Use the `sosumi` skill (Apple docs) instead of recalling from memory.
- When this file changes, mirror the change into `AGENTS.md`, and update `docs/internal-module-map.md` / `docs/runtime-resource-inventory.md` if the module or resource shape moved.

# Guidelines

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
