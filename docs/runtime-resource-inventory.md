# Woorilee Runtime Resource Inventory

This inventory captures the current runtime resource shape that refactors must preserve.

## Built Bundle

Current debug bundle root:

- `build/Debug/woorilee.app`

Current runtime resources:

- `Contents/Resources/main.tiff`
- `Contents/Resources/mainicon.icns`
- `Contents/Resources/data/hanja/hanja.txt`
- `Contents/Resources/data/hanja/freq-hanja.txt`
- `Contents/Resources/data/hanja/freq-hanjaeo.txt`
- `Contents/Resources/data/hanja/hanja-context.txt`
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

## Source Of Truth Paths

Live source paths used by the app target:

- `woorilee/main.swift`
- `woorilee/AppDelegate.swift`
- `woorilee/InputController.swift`
- `woorilee/Info.plist`
- `woorilee/main.tiff`
- `woorilee/mainicon.icon`
- `woorilee/Assets.xcassets`
- `woorilee/data/hanja/hanja.txt`
- `woorilee/data/hanja/freq-hanja.txt`
- `woorilee/data/hanja/freq-hanjaeo.txt`
- `woorilee/data/hanja/hanja-context.txt`
- `woorilee/KiwiModels/*`
- `woorilee/en.lproj/InfoPlist.strings`
- `woorilee/ko.lproj/InfoPlist.strings`

Paths that currently exist in the repo but are not the live source path for the app target:

- `docs/design/legacy-input-source-assets/main.tiff`
- `docs/design/legacy-input-source-assets/1.pxd`
- `docs/design/legacy-input-source-assets/1.tiff`
- `docs/design/legacy-input-source-assets/2.pxd`
- `docs/design/legacy-input-source-assets/2.tiff`
- `KiwiModels/` at the repo root

## Build Copy Behavior

Resource assembly is currently split across:

- Xcode folder-synchronized files under `woorilee/`
- the `Copy Bundled Hanja Dictionary` shell phase
- the `Copy Bundled Kiwi Models` shell phase

Refactors may simplify structure around these paths, but must not change the resulting bundle layout in this stream.

## Install Control

The Xcode build phase calls `scripts/install-built-input-method.sh`, but the
script skips installation by default. It only installs the built `.app` into
`/Library/Input Methods/` when explicitly opted in:

- `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1` — install the built input method.
- `WOORILEE_SKIP_INSTALL=1` — skip install, even if the build script is called.
- `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0` — skip install.
