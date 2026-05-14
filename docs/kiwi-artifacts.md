# Kiwi Artifacts

woorilee uses Kiwi through the local Swift package at `Kiwi/bindings/swift`.
`Kiwi/` is a Git submodule that points to:

```text
https://github.com/twoprom/Kiwi.git
```

The Swift wrapper imports the C API as `CKiwi`, and `CKiwi` is now supplied by
SwiftPM as a binary target:

```swift
.binaryTarget(
    name: "CKiwi",
    path: "Artifacts/CKiwi.xcframework"
)
```

Do not copy `Kiwi` or `CKiwi.o` into `DerivedData` by hand. That makes the build
depend on machine-local state and breaks clean clones.

## Required Local Files

- `Kiwi/bindings/swift/Artifacts/CKiwi.xcframework`
- `woorilee/KiwiModels/*`

Both should be treated as large artifacts. The `Kiwi` submodule marks
`CKiwi.xcframework` binaries for Git LFS, and the root `.gitattributes` marks
woorilee's runtime model files for Git LFS.

After cloning this repository:

```bash
git submodule update --init --recursive
git lfs pull
git -C Kiwi lfs pull
scripts/prepare-kiwi-artifacts.sh
```

## Preparing CKiwi.xcframework

If you already have an upstream `Kiwi.xcframework` at the repository root, run:

```bash
Kiwi/bindings/swift/scripts/prepare-ckiwi-xcframework.sh
```

To convert a downloaded framework from another location:

```bash
Kiwi/bindings/swift/scripts/prepare-ckiwi-xcframework.sh /path/to/Kiwi.xcframework
```

The script renames the framework module from `Kiwi` to `CKiwi`, updates
`Info.plist`, converts the macOS slice to the required versioned framework
layout, removes Finder metadata, and writes the artifact to
`Kiwi/bindings/swift/Artifacts/CKiwi.xcframework`.

## Building From Kiwi Source

The Swift binding build script now creates `CKiwi.xcframework` directly:

```bash
cd Kiwi/bindings/swift
scripts/build-xcframework.sh
```

It writes:

- `Artifacts/CKiwi.xcframework`
- `Artifacts/CKiwi.xcframework.zip`

For a release-hosted binary target, compute the checksum:

```bash
swift package compute-checksum Kiwi/bindings/swift/Artifacts/CKiwi.xcframework.zip
```

Then replace the local path target in `Kiwi/bindings/swift/Package.swift` with:

```swift
.binaryTarget(
    name: "CKiwi",
    url: "https://github.com/<owner>/<repo>/releases/download/<tag>/CKiwi.xcframework.zip",
    checksum: "<checksum>"
)
```

Keep the local path target while developing this repository. If the fork later
publishes `CKiwi.xcframework.zip` as a GitHub Release asset, the submodule can
switch from the local path target to the URL target.
