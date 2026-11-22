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

    /// D3 (docs/plans/hanja-context-scaling-plan.md §10): the candidate-profile `bias` slot, read
    /// through the SAME real app parser as the feature table above (`parseBinaryWithBias`), so the
    /// offline harness scores exactly what production scores. Text tables carry no bias by design,
    /// so the txt path keeps an empty bias table — that is the correct pre-D3 behavior, not a gap.
    static let associationBiasFromBinary: [String: [String: Double]] = {
        guard let data = try? Data(contentsOf: Paths.assocBin) else { return [:] }
        return HanjaContextAssociationStore.parseBinaryWithBias(data: data)?.biases ?? [:]
    }()

    /// D2 Task 3 (docs/plans/hanja-context-scaling-plan.md §9): the real bundled resource behind
    /// `HanjaDictionaryService.isNativeHomographReading` — loaded here directly from disk (not
    /// through `HanjaDictionaryService.shared.warmUp()`, which needs `Bundle.main`), but parsed by
    /// the REAL app function `HanjaDictionaryService.parseNativeHomographReadings(contents:)` — no
    /// gate logic is reimplemented, only the file read is local.
    static let nativeHomographReadings: Set<String> = {
        guard let contents = try? String(contentsOf: Paths.hanjaNativeHomograph, encoding: .utf8) else { return [] }
        return HanjaDictionaryService.parseNativeHomographReadings(contents: contents)
    }()

    /// D2 Task 3: the real step-6 auto-convert word-evidence gate
    /// (`KiwiAnalysisService.hasAutoConvertWordEvidence`), closed over this harness's own
    /// `freqTable` — byte-identical in behavior to `KiwiAnalysisService.analyzeClauseDetailed`'s own
    /// `autoConvertGate` closure (see that function: `hanjaService.hasWordFrequencyData ? { candidate,
    /// tag in Self.hasAutoConvertWordEvidence(...) } : nil`), except this harness's word-frequency
    /// table always has rows (loaded straight from freq-hanjaeo.txt), so the gate is never nil here.
    static let autoConvertGate: (HanjaCandidate, POSTag) -> Bool = { candidate, tag in
        KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, tag: tag, wordFrequency: freqTable.wordFrequency(for:))
    }

    /// D2 Task 3: the real step-7 native-homograph gate
    /// (`HanjaDictionaryService.isNativeHomographReading`), backed by `nativeHomographReadings` above.
    static let nativeHomographLookup: (String) -> Bool = { reading in
        nativeHomographReadings.contains(reading)
    }

    /// Mirrors HanjaContextEvalV2Tests.candidateLookup(_:) / HanjaDictionaryService.exactCandidates
    /// exactly: numeric/date candidates first, else dictionary lookup merged through the real
    /// mergeHanjaCandidates (app source) with empty user/usage tables (reading-only, no
    /// personalization — matching the eval harness's own contract).
    static func candidateLookup(_ key: String) -> [HanjaCandidate] {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { HanjaPerformance.record("dictionary_lookup", since: start) }
        let specialCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
            + DateHanjaCandidateGenerator.candidates(for: key)
        if !specialCandidates.isEmpty { return specialCandidates }

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
