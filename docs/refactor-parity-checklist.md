# Woorilee Refactor Parity Checklist

This checklist is the baseline for every structural refactor pass in this repo.
Do not merge a refactor pass unless the relevant checks below still hold.

## Build Gate

- Run `xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build`.
- Run `xcodebuild -project woorilee.xcodeproj -scheme woorilee -destination 'platform=macOS,arch=arm64' test`.
- Expect a successful build that does not install into `/Library/Input Methods/`
  unless installation is explicitly opted in.

## Runtime Resource Gate

Confirm the built app bundle still contains:

- `Contents/Resources/main.tiff`
- `Contents/Resources/mainicon.icns`
- `Contents/Resources/data/hanja/hanja.txt`
- `Contents/Resources/data/hanja/freq-hanja.txt`
- `Contents/Resources/data/hanja/freq-hanjaeo.txt`
- `Contents/Resources/KiwiModels/combiningRule.txt`
- `Contents/Resources/KiwiModels/cong.mdl`
- `Contents/Resources/KiwiModels/default.dict`
- `Contents/Resources/KiwiModels/dialect.dict`
- `Contents/Resources/KiwiModels/extract.mdl`
- `Contents/Resources/KiwiModels/multi.dict`
- `Contents/Resources/KiwiModels/nounchr.mdl`
- `Contents/Resources/KiwiModels/sj.morph`
- `Contents/Resources/KiwiModels/typo.dict`
- `Contents/Resources/en.lproj/InfoPlist.strings`
- `Contents/Resources/ko.lproj/InfoPlist.strings`

## Manual IME Parity

Verify at least the following scenarios:

- Basic Hangul composition still produces the same visible preedit text.
- Composition commit still inserts the same final Hangul text.
- `Backspace` edits or clears the current composition without leaving stale marked text.
- `Space` commits the current composition, then inserts a literal space.
- `Return` commits the current composition and does not duplicate text.
- `Escape` commits the current composition and does not leave a stale marked range.
- `Tab` still commits pending Hangul text and otherwise passes through.
- Arrow and other navigation commands still commit pending Hangul text before host navigation proceeds.
- Typing over a selected range still replaces the selection instead of inserting beside it.
- `markedRange` and `replacementRange` stay stable in both normal and implicit replacement cases.

## Logging Parity

When changing range or session code, compare `woorilee-range` log output for:

- selection replacement cases
- implicit replacement fallback cases
- navigation-triggered commit cases

## Script Gate

If a change touches build or deploy scripts:

- Run `sh -n scripts/install-built-input-method.sh`.
- Run `sh scripts/install-built-input-method.sh`.
- Run `WOORILEE_SKIP_INSTALL=1 sh scripts/install-built-input-method.sh`.
- Keep explicit install opt-in and both opt-out env styles working:
  - default invocation skips installation.
  - `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1` allows installation.
  - `WOORILEE_SKIP_INSTALL=1` forces the script to skip installation.
  - `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0` forces the script to skip installation.
- Confirm the default build does not install the built bundle into
  `/Library/Input Methods/`.
