// swift-tools-version:5.9
// K1b Task 1 offline reproduction of the app's context-aware Hanja association ranker
// (docs/plans/hanja-context-scaling-plan.md §12 K1b, Part 2 preparation).
//
// This package COMPILES THE REAL APP SOURCE via symlinks into Sources/assoc/AppSource/ — it does
// not reimplement any ranking/segmentation logic. The symlinked files are exactly the
// Foundation/OSLog/Kiwi/LibHangul subset of woorilee/ needed to call
// KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens + .applyContextReranking +
// HanjaContextRanker.rankWithContext end to end, with zero AppKit/IMKSwift/SwiftUI dependency:
//   HanjaContextRanker, HanjaContextAssociationStore, HanjaPersonalizationModels (the three files
//   whose clean closure the plan's author identified) PLUS KiwiAnalysisService and everything ITS
//   whole-file compilation transitively requires: HanjaConversionModels, HanjaClauseJointSelection,
//   SessionHanjaContext, HanjaDictionaryService, AppRuntimePaths, NumericHanjaCandidateGenerator,
//   UserHanjaStore, HanjaUsageStore, ManualHanjaModels, HanjaPerformance. Every one of those files was individually
//   confirmed (import-only-Foundation/Kiwi/LibHangul, no transitive reference to a Cocoa-importing
//   file) before being added — see the K1b Task 1 report for the file-by-file check.
//
// Depends on the LOCAL vendored Kiwi Swift package (like collector/Package.swift) — NOT the raw
// CKiwi binaryTarget the k1 package uses, so this package's module graph never collides with k1's.
// Also depends on the remote libhangul-swift package (same repo the app project pins,
// github.com/Meapri/libhangul-swift, branch main) since HanjaDictionaryService.swift needs
// LibHangul's HanjaTable/searchHanja for candidate-list construction.
import PackageDescription

let package = Package(
    name: "assoc",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../../../Kiwi/bindings/swift"),
        .package(url: "https://github.com/Meapri/libhangul-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "assoc",
            // The local Kiwi package's identity is its directory basename ("swift").
            dependencies: [
                .product(name: "Kiwi", package: "swift"),
                .product(name: "LibHangul", package: "libhangul-swift"),
            ],
            path: "Sources/assoc"
        ),
    ]
)
