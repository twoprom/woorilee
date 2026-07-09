// swift-tools-version:5.9
// Step 5a offline Kiwi collector (문맥 기반 한자 변환 — docs/plans/context-aware-hanja-conversion.md §7 5a).
// Analyzes the prefiltered wiki corpus with the LOCAL vendored Kiwi Swift package (never kiwipiepy)
// so the offline morpheme space matches the woorilee runtime exactly.
import PackageDescription

let package = Package(
    name: "collector",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "../../../Kiwi/bindings/swift"),
    ],
    targets: [
        .executableTarget(
            name: "collector",
            // The local Kiwi package's identity is its directory basename ("swift").
            dependencies: [.product(name: "Kiwi", package: "swift")],
            path: "Sources/collector"
        ),
    ]
)
