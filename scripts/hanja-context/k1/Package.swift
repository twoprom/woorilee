// swift-tools-version:5.9
// K1a offline Kiwi LM alias-registration runner (문맥 기반 한자 변환 —
// docs/plans/hanja-context-scaling-plan.md §12 K1a). Talks to the raw CKiwi C API directly —
// it does NOT depend on the `Kiwi` Swift package (that would create two Swift modules wrapping
// the same CKiwi binary). Self-contained: declares its own .binaryTarget pointing at the same
// vendored xcframework the Kiwi package uses, so no changes to Kiwi/ (submodule) are needed.
import PackageDescription

let package = Package(
    name: "k1",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .binaryTarget(
            name: "CKiwi",
            path: "../../../Kiwi/bindings/swift/Artifacts/CKiwi.xcframework"
        ),
        .executableTarget(
            name: "k1",
            dependencies: ["CKiwi"],
            path: "Sources/k1",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
