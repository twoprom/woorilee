// verify-contract: reconstructs the morpheme-space contract through the raw CKiwi C API and
// proves — rather than assumes — that it matches scripts/hanja-context/collector's `enum
// Contract` output (docs/plans/hanja-context-scaling-plan.md §12 K1a, item 1-2-3).
import Foundation

/// Parses `sentence<TAB>form/TAG,form/TAG,...` rows (collector `dump-tokens` output format;
/// `#`-prefixed and blank lines ignored). Mirrors the parser in
/// woorileeTests/KiwiOfflinePipelineConsistencyTests.swift.
func parseDumpTokensTSV(_ url: URL) throws -> [(sentence: String, dumped: String)] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var rows: [(sentence: String, dumped: String)] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if raw.hasPrefix("#") { continue }
        let columns = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard !columns.isEmpty, !columns[0].isEmpty else { continue }
        rows.append((String(columns[0]), columns.count > 1 ? String(columns[1]) : ""))
    }
    return rows
}

struct VerifyContractStats: Codable {
    var matchOptionsRaw: Int32
    var expectedMatchOptionsRaw: Int32
    var matchOptionsRawEqual: Bool
    var buildOptionsRaw: Int32
    var expectedBuildOptionsRaw: Int32
    var buildOptionsRawEqual: Bool
    var dialectStandardRaw: Int32
    var referenceFile: String
    var sentencesCompared: Int
    var mismatchCount: Int
    var mismatchSamples: [String]
}

func runVerifyContract(referencePath: String?) throws {
    let referenceURL = referencePath.map { URL(fileURLWithPath: $0) } ?? Paths.trackedDumpTokensTSV

    print("=== verify-contract ===")
    print("matchOptionsRaw (from CKiwi enum constants) = \(Contract.matchOptionsRaw)")
    print("expectedMatchOptionsRaw (hand-derived from MatchOptions.swift) = \(Contract.expectedMatchOptionsRaw)")
    let matchEqual = Contract.matchOptionsRaw == Contract.expectedMatchOptionsRaw
    print(matchEqual ? "PASS: matchOptionsRaw == expectedMatchOptionsRaw" : "FAIL: matchOptionsRaw != expectedMatchOptionsRaw")

    print("buildOptionsRaw (KIWI_BUILD_DEFAULT) = \(Contract.buildOptionsRaw)")
    print("expectedBuildOptionsRaw = \(Contract.expectedBuildOptionsRaw)")
    let buildEqual = Contract.buildOptionsRaw == Contract.expectedBuildOptionsRaw
    print(buildEqual ? "PASS: buildOptionsRaw == expectedBuildOptionsRaw" : "FAIL: buildOptionsRaw != expectedBuildOptionsRaw")
    print("dialectStandardRaw (KIWI_DIALECT_STANDARD) = \(Contract.dialectStandardRaw)")

    guard FileManager.default.fileExists(atPath: referenceURL.path) else {
        fail("reference dump-tokens file not found: \(referenceURL.path) "
            + "(build+run scripts/hanja-context/collector `dump-tokens`, or pass --reference <path>)")
    }
    let rows = try parseDumpTokensTSV(referenceURL)
    guard !rows.isEmpty else { fail("reference file produced 0 rows: \(referenceURL.path)") }
    print("reference file: \(referenceURL.path) (\(rows.count) rows)")

    let builder = try KiwiBuilderRaw(modelPath: Paths.modelDir.path)
    let kiwi = try builder.build()

    var mismatches: [String] = []
    for row in rows {
        let results = try kiwi.analyze(row.sentence, topN: Contract.topN, matchOptionsRaw: Contract.matchOptionsRaw)
        let tokens = results.first?.tokens ?? []
        let features = tokens
            .filter { Contract.contentTags.contains($0.tag) }
            .map { Contract.feature(form: $0.form, tag: $0.tag) }
            .joined(separator: ",")
        if features != row.dumped {
            mismatches.append("sentence: \(row.sentence)\n  offline(collector): \(row.dumped)\n  k1(raw C):          \(features)")
        }
    }

    print("sentences compared = \(rows.count)")
    print("token sequences that differ = \(mismatches.count)")
    if !mismatches.isEmpty {
        print("--- first \(min(5, mismatches.count)) diffs ---")
        for m in mismatches.prefix(5) { print(m) }
    }
    print(mismatches.isEmpty ? "RESULT: PASS (0 diffs)" : "RESULT: FAIL (\(mismatches.count) diffs) — STOP, do not proceed to K1b/Part 2")

    try ensureOutDir()
    let stats = VerifyContractStats(
        matchOptionsRaw: Contract.matchOptionsRaw,
        expectedMatchOptionsRaw: Contract.expectedMatchOptionsRaw,
        matchOptionsRawEqual: matchEqual,
        buildOptionsRaw: Contract.buildOptionsRaw,
        expectedBuildOptionsRaw: Contract.expectedBuildOptionsRaw,
        buildOptionsRawEqual: buildEqual,
        dialectStandardRaw: Contract.dialectStandardRaw,
        referenceFile: referenceURL.path,
        sentencesCompared: rows.count,
        mismatchCount: mismatches.count,
        mismatchSamples: Array(mismatches.prefix(5))
    )
    try writeJSON(stats, to: Paths.outDir.appendingPathComponent("verify-contract-stats.json"))

    if !matchEqual || !buildEqual || !mismatches.isEmpty {
        exit(1)
    }
}
