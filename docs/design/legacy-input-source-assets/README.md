# Legacy Input Source Assets

This folder archives tracked top-level assets that are no longer part of the live app target.

Moved here during the refactor:

- `1.pxd`
- `1.tiff`
- `2.pxd`
- `2.tiff`
- root `main.tiff`

These files are preserved as design or migration artifacts, but the live app continues to use:

- `woorilee/main.tiff`
- `woorilee/Assets.xcassets`
- `woorilee/mainicon.icon`

Do not repoint the app target to this folder in the current refactor stream.
