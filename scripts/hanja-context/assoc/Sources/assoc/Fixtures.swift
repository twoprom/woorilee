// Shared fixtures for the K1b Task 1 offline association-ranker harness.
//     Copyright (C) 2026 Seungjin Lee.
//
// Loads Kiwi / the hanja dictionary / the frequency tables / the association table directly from
// repo files (NOT through HanjaDictionaryService.warmUp / HanjaContextAssociationStore.warmUp,
// which need Bundle.main and are unavailable outside the app bundle) — this mirrors
// woorileeTests/HanjaContextEvalV2Tests.swift's own private static fixtures and
// `candidateLookup(_:)` EXACTLY (that test file's own doc comment: "Mirrors
// HanjaDictionaryService.exactCandidates(for:) ... reading-only, no personalization). Every
// function called here (buildDominantHanjaMap, mergeHanjaCandidates, HanjaContextAssociationStore
// .parse/.parseBinary, LibHangul.loadHanjaTable/searchHanja) is REAL APP OR LIBHANGUL SOURCE — this
// file only decides which files to load from disk, it contains no ranking/segmentation logic.
import Foundation
import Kiwi
import LibHangul

@MainActor
enum Fixtures {
    static let kiwi: Kiwi = {
        guard let built = try? KiwiBuilder(modelPath: Paths.modelDir.path).build() else {
            fatalError("Kiwi failed to build from \(Paths.modelDir.path)")
        }
        return built
    }()

    static let hanjaTable: HanjaTable = {
        guard let table = LibHangul.loadHanjaTable(filename: Paths.hanjaTxt.path) else {
            fatalError("hanja.txt failed to load from \(Paths.hanjaTxt.path)")
        }
        return table
    }()

    static let freqTable: HanjaFrequencyTable = HanjaFrequencyTable(
        characterFrequencyURLs: [Paths.freqHanja],
        wordFrequencyURLs: [Paths.freqHanjaeo]
    )

    static let dominantMap: [String: String] = {
        guard let text = try? String(contentsOf: Paths.hanjaTxt, encoding: .utf8) else { return [:] }
        return buildDominantHanjaMap(
            dictionaryLines: text.split(separator: "\n", omittingEmptySubsequences: true),
            frequency: freqTable.frequency(for:)
        )
    }()

    /// Parsed directly from the repo's hanja-context.txt via the real
    /// HanjaContextAssociationStore.parse — this is what HanjaContextEvalV2Tests uses (deliberately
    /// NOT HanjaContextAssociationStore.shared, so it never depends on app warm-up ordering).
    static let associationTableFromText: [String: [String: [String: Double]]] = {
        guard let contents = try? String(contentsOf: Paths.assocTxt, encoding: .utf8) else { return [:] }
        return HanjaContextAssociationStore.parse(contents: contents)
    }()

    /// Parsed from the repo's hanja-context.bin via the real HanjaContextAssociationStore
    /// .parseBinary — this is what production `warmUp()` actually loads (since step 0c). Kept
    /// separate from `associationTableFromText` so Task 1's mismatch-source check (bin vs txt) can
    /// compare both against the app's printed EVAL5D numbers.
    static let associationTableFromBinary: [String: [String: [String: Double]]] = {
        guard let data = try? Data(contentsOf: Paths.assocBin) else { return [:] }
        return HanjaContextAssociationStore.parseBinary(data: data) ?? [:]
    }()

    /// Mirrors HanjaContextEvalV2Tests.candidateLookup(_:) / HanjaDictionaryService.exactCandidates
    /// exactly: numeric candidates first, else dictionary lookup merged through the real
    /// mergeHanjaCandidates (app source) with empty user/usage tables (reading-only, no
    /// personalization — matching the eval harness's own contract).
    static func candidateLookup(_ key: String) -> [HanjaCandidate] {
        let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
        if !numericCandidates.isEmpty { return numericCandidates }

        guard let list = LibHangul.searchHanja(table: hanjaTable, key: key) else { return [] }
        let seeds: [HanjaCandidateSeed] = (0..<list.getSize()).compactMap { i in
            guard let value = list.getNthValue(i) else { return nil }
            return HanjaCandidateSeed(
                reading: list.getNthKey(i) ?? key, value: value,
                comment: list.getNthComment(i) ?? "", source: .system, baseRank: i
            )
        }
        let merged = mergeHanjaCandidates(
            userEntries: [], systemCandidates: seeds,
            usageCounts: [:], frequencyLookup: freqTable.frequency(for:)
        )
        return merged.filter { $0.value != $0.reading }
    }
}

struct EvalRow {
    let sentence: String
    let reading: String
    let answer: String
}

enum EvalSetLoader {
    /// Loads v1 rows ONLY (stops at "# ---- v2"), byte-identical to
    /// HanjaContextEvalTests.loadRows()/HanjaContextEvalV2Tests's v1 section of `rows`.
    static func loadV1() throws -> [EvalRow] {
        let text = try String(contentsOf: Paths.evalTSV, encoding: .utf8)
        var rows: [EvalRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ---- v2") { break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 3, !c[0].isEmpty, !c[1].isEmpty, !c[2].isEmpty else { continue }
            rows.append(EvalRow(sentence: c[0], reading: c[1], answer: c[2]))
        }
        return rows
    }
}

func pct(_ a: Int, _ b: Int) -> String {
    b == 0 ? "0%" : String(format: "%.1f%%", 100.0 * Double(a) / Double(b))
}
