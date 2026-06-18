# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` (Korean), `docs/internal-module-map.md`, and `docs/runtime-resource-inventory.md` are the authoritative companion docs — read them before non-trivial changes. This file captures the parts most useful when starting cold.

## Project

`woorilee` is a macOS Korean (두벌식 / two-beolsik) input method built on `InputMethodKit`. It is **not** a normal AppKit app: there is no storyboard/nib, and `woorilee/main.swift` launches `NSManualApplication.shared` directly so that `IMKServer` can be registered programmatically. Do not convert it to a storyboard-based launch.

The composition engine is `LibHangul`. Hanja conversion is supported by a bundled dictionary (`woorilee/data/hanja/hanja.txt`) and morphological analysis from the locally-vendored `Kiwi` Swift package + `KiwiModels` resources. `IMKSwift` wraps the raw IMK API — prefer it over `InputMethodKit` directly, and only fall back to raw IMK with an explicit comment explaining why.

## Directory structure

- `/Volumes/Workbench/woorilee/woorilee/` — actual source code (Swift files, resources, data)
- `/Volumes/Workbench/woorilee/` — project root, contains `woorilee.xcodeproj`, build scripts, dependencies (Kiwi, KiwiModels, IMKSwift, LibHangul), and documentation

## Build, install, test

```sh
# Schemes / targets
xcodebuild -list -project woorilee.xcodeproj

# Debug build (app target)
xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build

# Unit tests (woorileeTests)
xcodebuild -project woorilee.xcodeproj -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' test

# Single test (class or method)
xcodebuild -project woorilee.xcodeproj -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:woorileeTests/InputEventPolicyTests
xcodebuild -project woorilee.xcodeproj -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:woorileeTests/InputEventPolicyTests/testPrintableASCIICharacterUsesEventCharacters
```

`scripts/install-built-input-method.sh` runs as an Xcode build phase: it `killall woorilee`s the running input method and `ditto`s the built `.app` into `/Library/Input Methods/` (escalating via `osascript` if needed). Override with env vars: `WOORILEE_SKIP_INSTALL=1` or `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0`. For manual installs, prefer `ditto` over `cp -R` for app bundles, and `killall woorilee` first — macOS will not pick up a replaced bundle while the old process is alive.

There is no UI test target. After input-logic changes, manually verify: Hangul compose/commit, `Backspace`/`Space`/`Return`/`Escape`/`Tab` handling, arrow/movement-induced commits, and that `markedRange` / `replacementRange` stay consistent across clients (Safari, TextEdit, Terminal differ).

## Development workflow

**Always build after code changes.** After any source modification, run a build automatically (do not wait to be asked) so the running input method is refreshed:

```sh
xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build
```

The build phase script then overwrites `/Library/Input Methods/woorilee.app` and restarts the process automatically. Never set `WOORILEE_SKIP_INSTALL=1` or `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0` — the auto-install must run on every build.

After code modifications, the standard Xcode build process handles deployment automatically:

1. Build from Xcode or `xcodebuild` command
2. The build phase script `scripts/install-built-input-method.sh` runs automatically:
   - Executes `killall woorilee` to stop the running input method
   - Copies the built `.app` bundle to `/Library/Input Methods/` using `ditto` (preserving bundle structure and permissions)
   - Escalates permissions via `osascript` if needed

The input method is now live — no manual restart required. To disable automatic installation, set `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0` before building.

## Architecture

Entry path: `main.swift` → `NSManualApplication` (defined in `AppDelegate.swift`) → `AppDelegate.applicationDidFinishLaunching` constructs `IMKServer` from `Info.plist`'s `InputMethodConnectionName` and kicks off Hanja/Kiwi warm-up through `HanjaServiceCoordinator.shared`.

`Info.plist` wiring that must stay in sync if renamed:
- `InputMethodConnectionName` ↔ the `name:` argument passed to `IMKServer` in `AppDelegate`.
- `InputMethodServerControllerClass` ↔ `InputController` (the `IMKInputSessionController` subclass IMK instantiates per client).

The IME runtime is intentionally split (see `docs/internal-module-map.md`); changes should respect these boundaries rather than re-collapsing them into `InputController`:

- [InputController.swift](woorilee/InputController.swift) — only IMK-facing orchestration: `handle(_:client:)`, menu hookup, dispatch into the helpers below.
- [InputEventPolicy.swift](woorilee/InputEventPolicy.swift) — pure key-event normalization (printable ASCII extraction, two-beolsik shift mapping, navigation/selector classification). Stateless and unit-testable.
- [InputCompositionEngine.swift](woorilee/InputCompositionEngine.swift) — marked-text / replacement-range bookkeeping; commit + update helpers that wrap the `IMKTextInput` calls.
- [InputSession.swift](woorilee/InputSession.swift) — per-client `InputSession` plus `InputSessionCache` and `InputRangeState`. `InputController` looks up sessions through the cache; never store composition state on `InputController` itself, since IMK reuses controller instances across clients.
- [HanjaServiceCoordinator.swift](woorilee/HanjaServiceCoordinator.swift) — singleton coordinating Hanja menu state, warm-up panel, manual candidate panel, and the Kiwi-driven realtime conversion path. The `realtimeConversionPhaseUnlocked` flag (currently `true`) is the kill switch for the realtime path; `isRealtimeAvailable` additionally requires both Kiwi and the Hanja dictionary to be `ready`.
- [HanjaConversionModels.swift](woorilee/HanjaConversionModels.swift) — `CompositionMode` (`hangul` / `manualHanja` / `realtimeHanja`) and `SegmentLockKey`, the value types shared between the coordinator, session, and tests.
- [ManualHanjaModels.swift](woorilee/ManualHanjaModels.swift) / [ManualHanjaPanelAnchorResolver.swift](woorilee/ManualHanjaPanelAnchorResolver.swift) — value types for the manual Hanja panel (target / notice / content) and the anchor-rect probing logic that places the panel near the caret across host apps.

Supporting services (each owns its own warm-up `Status` enum: `uninitialized` / `loading` / `ready` / `unavailable(reason)`):

- [KiwiAnalysisService.swift](woorilee/KiwiAnalysisService.swift) — background warm-up of Kiwi morphological analyzer.
- [HanjaDictionaryService.swift](woorilee/HanjaDictionaryService.swift) — loads the bundled hanja table.
- [HanjaUsageStore.swift](woorilee/HanjaUsageStore.swift) / [UserHanjaStore.swift](woorilee/UserHanjaStore.swift) — usage stats and user-defined entries used to rank candidates. Shared Codable shapes (`HanjaCandidateKey`, `HanjaCandidateSource`, …) live in [HanjaPersonalizationModels.swift](woorilee/HanjaPersonalizationModels.swift); on-disk paths (Application Support layout, bundled-resource names) are centralized in [AppRuntimePaths.swift](woorilee/AppRuntimePaths.swift).
- [HanjaSettingsStore.swift](woorilee/HanjaSettingsStore.swift) — menu-backed settings (e.g. realtime conversion toggle, auto-advance after numeric selection).
- [HanjaWarmUpPanelController.swift](woorilee/HanjaWarmUpPanelController.swift) / [HanjaCandidatePanelController.swift](woorilee/HanjaCandidatePanelController.swift) — non-activating panels (a warm-up loading panel and the manual Hanja candidate picker).

### Concurrency

`InputController`, `AppDelegate`, `InputSession`, and `HanjaServiceCoordinator` are `@MainActor`. Don't break this assumption — IMK callbacks run on the main thread and the panels are AppKit views. Background work (Kiwi/Hanja warm-up, file I/O for usage stores) is dispatched off-main and routed back via `@MainActor` callbacks; preserve that pattern.

### Resources & dependencies

- App-bundle resources live under `woorilee/`: `data/hanja/hanja.txt`, `KiwiModels/*` (`combiningRule.txt`, `cong.mdl`, `default.dict`, `dialect.dict`, `extract.mdl`, `multi.dict`, `nounchr.mdl`, `sj.morph`, `typo.dict`), `main.tiff`, `mainicon.icon`, `*.lproj/InfoPlist.strings`. `docs/refactor-parity-checklist.md` is the canonical list — verify it after any project-file change.
- The repo-root `KiwiModels/` and `Kiwi/` are vendored copies; the **bundled** copies are inside `woorilee/`. Don't confuse the two paths. `Kiwi/` and `KiwiModels/` at the root are gitignored.
- SwiftPM dependencies (resolved via the Xcode project): `IMKSwift` (vChewing), `LibHangul` (Meapri), and a local-path `Kiwi` package at `Kiwi/bindings/swift`. Patching these is a last resort — solve at the app layer first.
- Generated/cache directories — `DerivedData/`, `DerivedDataPlan/`, `.xcode-home/`, `.xcode-swiftpm-modulecache/` — are gitignored and should not be edited.

## Working in this repo

- `git status` is noisy because of `xcuserstate` and DerivedData churn. Scope diffs: `git status --short -- AGENTS.md woorilee woorilee.xcodeproj` and `git diff -- woorilee woorilee.xcodeproj AGENTS.md`.
- `woorilee/InputController.swift` is hot; small refactors there can regress `insertText` / `setMarkedText` / `unmarkText` / `selectedRange` / `markedRange` interactions across apps. Keep edits narrow and verify manually.
- For Apple framework behavior (AppKit, InputMethodKit, text input system), look it up rather than guessing — IMK has subtle, undocumented quirks per host app.

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
