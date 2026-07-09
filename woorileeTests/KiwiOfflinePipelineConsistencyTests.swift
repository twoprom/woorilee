// Step 5a 형태소 공간 일치 검증 (offline↔runtime morpheme-space consistency).
//     Copyright (C) 2026 Seungjin Lee.
//
// The 5a gate requires proving that the offline corpus collector
// (scripts/hanja-context/collector, built on the vendored Kiwi Swift package) and the runtime
// analysis path produce IDENTICAL content-morpheme tokens. The collector's `dump-tokens` mode
// analyzes the 195 eval sentences and writes scripts/hanja-context/verification-tokens.tsv
// (`sentence<TAB>form/TAG,form/TAG,...`, content tags only, raw filtered sequence). This test
// re-analyzes every dumped sentence with the runtime contract constants
// (`KiwiAnalysisService.realtimeAnalysisMatchOptions` + `isContextContentMorphemeTag`) and
// asserts exact equality. A mismatch means options/model/filter drift — do NOT paper over it.
//
// Self-skips (prints and returns) if the Kiwi model directory or the dump file is missing,
// mirroring the integration-test pattern used elsewhere.

import Foundation
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class KiwiOfflinePipelineConsistencyTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testOfflineCollectorTokensMatchRuntimeMorphemeSpace() throws {
        let root = repoRoot()
        let modelDir = root.appendingPathComponent("woorilee/KiwiModels")
        let dumpURL = root.appendingPathComponent("scripts/hanja-context/verification-tokens.tsv")

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            print("Kiwi model directory not found at \(modelDir.path), skipping KiwiOfflinePipelineConsistencyTests.")
            return
        }
        guard FileManager.default.fileExists(atPath: dumpURL.path) else {
            print("verification-tokens.tsv not found at \(dumpURL.path), skipping KiwiOfflinePipelineConsistencyTests.")
            return
        }

        // (sentence, dumped feature column) rows; `#` comments and blank lines ignored.
        var rows: [(sentence: String, dumped: String)] = []
        let text = try String(contentsOf: dumpURL, encoding: .utf8)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            let columns = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard !columns.isEmpty, !columns[0].isEmpty else { continue }
            rows.append((String(columns[0]), columns.count > 1 ? String(columns[1]) : ""))
        }

        // Same builder defaults as the runtime warm-up path (BuildOptions.default, .standard).
        let kiwi = try KiwiBuilder(modelPath: modelDir.path).build()

        var mismatches: [String] = []
        for row in rows {
            let results = try kiwi.analyze(
                row.sentence,
                topN: 1,
                options: KiwiAnalysisService.realtimeAnalysisMatchOptions
            )
            let tokens = results.first?.tokens ?? []
            let runtimeFeatures = tokens
                .filter { KiwiAnalysisService.isContextContentMorphemeTag($0.tag) }
                .map { "\($0.form)/\($0.tag.description)" }
                .joined(separator: ",")
            if runtimeFeatures != row.dumped {
                mismatches.append(
                    "sentence: \(row.sentence)\n  offline: \(row.dumped)\n  runtime: \(runtimeFeatures)")
            }
        }

        print("CONSISTENCY|rows=\(rows.count) mismatches=\(mismatches.count)")
        XCTAssertEqual(rows.count, 195, "verification dump must cover all 195 eval sentences")
        XCTAssertTrue(
            mismatches.isEmpty,
            "offline↔runtime morpheme-space drift in \(mismatches.count) sentence(s):\n"
                + mismatches.joined(separator: "\n"))
    }
}
