// Context-aware ranking interface for Hanja candidates.
//     Copyright (C) 2026 Seungjin Lee.
//
// Step 4a (사전 내부 문맥 신호, measurement only — see
// docs/plans/context-aware-hanja-conversion.md §5) implements the real context signal here.
// Nothing in this file is wired into the production input path yet; that is step 4b.

import Foundation

struct HanjaContextRankingWeights {
    /// Boost applied when a context word's dominant hanja CONTAINS the candidate as a substring
    /// (e.g. 上下水道 contains 水道). Large enough to override any realistic frequency gap.
    var containment: Int
    /// Boost per hanja character the candidate shares with a context word's dominant hanja.
    /// Weaker/tunable signal; starts at 0 (unused) — containment alone covers the flagship cases.
    var charShare: Int
    /// Boost per unit of matched-feature weight from the step-5 corpus association table (see
    /// HanjaContextAssociationStore). Scale rationale (docs/plans/context-aware-hanja-conversion.md
    /// §7 5c, pinned by HanjaContextRankerTests):
    /// - Must overcome within-reading frequency gaps: 수도 freq gap 首都 11,750 − 水道 2,106 = 9,644;
    ///   a single matched feature 집/NNG weight 37 × 300 = 11,100 > 9,644.
    /// - Must never overcome containment: realistic max association sum (~30 features × 255 ≈
    ///   7,650) × 300 ≈ 2.3M, still well under containment's 10,000,000.
    var association: Int
    static let `default` = HanjaContextRankingWeights(containment: 10_000_000, charShare: 0, association: 300)
}

/// Sums matched-feature weights from `lookup(candidate.reading, candidate.value)` against
/// `contextFeatures`, for every candidate — O(candidates × contextFeatures), precomputed once by
/// the caller and fed into `rankWithContext`'s `associationScores`.
func associationScores(
    for candidates: [HanjaCandidate],
    contextFeatures: [String],
    lookup: (String, String) -> [String: UInt8]?
) -> [String: Int] {
    guard !contextFeatures.isEmpty else {
        return [:]
    }

    var scores: [String: Int] = [:]
    for candidate in candidates {
        guard let features = lookup(candidate.reading, candidate.value) else { continue }
        var sum = 0
        for feature in contextFeatures {
            if let weight = features[feature] {
                sum += Int(weight)
            }
        }
        if sum > 0 {
            scores[candidate.value] = sum
        }
    }
    return scores
}

/// Groups `hanja.txt` (`읽기:한자:주석`) entries by reading and keeps only readings with a single
/// dominant hanja: either the reading has exactly one candidate, or its top candidate's frequency
/// is at least `dominanceRatio` times the runner-up's. Single pass, no `searchHanja` calls.
func buildDominantHanjaMap(
    dictionaryLines: [Substring],
    frequency: (String) -> Int,
    dominanceRatio: Int = 5
) -> [String: String] {
    var candidatesByReading: [String: [String]] = [:]
    for rawLine in dictionaryLines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let firstColon = line.firstIndex(of: ":") else { continue }
        let reading = String(line[..<firstColon])
        guard !reading.isEmpty else { continue }
        let rest = line[line.index(after: firstColon)...]
        guard let secondColon = rest.firstIndex(of: ":") else { continue }
        let value = String(rest[..<secondColon])
        guard !value.isEmpty else { continue }
        candidatesByReading[reading, default: []].append(value)
    }

    var result: [String: String] = [:]
    result.reserveCapacity(candidatesByReading.count)
    for (reading, values) in candidatesByReading {
        if values.count == 1 {
            result[reading] = values[0]
            continue
        }
        let ranked = values.sorted { frequency($0) > frequency($1) }
        let topFrequency = frequency(ranked[0])
        let runnerUpFrequency = frequency(ranked[1])
        if runnerUpFrequency == 0 || topFrequency >= dominanceRatio * runnerUpFrequency {
            result[reading] = ranked[0]
        }
    }
    return result
}

/// Resolves eojeol readings (already stripped of trailing josa/endings by the caller) to their
/// dominant hanja, dropping readings absent from the map and de-duplicating.
func contextDominantHanja(forEojeolReadings readings: [String], dominantMap: [String: String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for reading in readings {
        guard let hanja = dominantMap[reading], !seen.contains(hanja) else { continue }
        seen.insert(hanja)
        result.append(hanja)
    }
    return result
}

/// Count of distinct hanja characters in `candidate` that also appear in `contextHanja`.
func sharedHanjaCharCount(_ candidate: String, _ contextHanja: String) -> Int {
    let contextChars = Set(contextHanja)
    return Set(candidate).filter { contextChars.contains($0) }.count
}

/// Per-candidate context-evidence breakdown (docs/plans/context-aware-hanja-conversion.md §10,
/// step 7's native-homograph gate): the step-4 dictionary axis (containment + char-share against
/// every context dominant hanja) and the step-5 corpus association axis, kept separate so a
/// caller can ask "did this candidate get ANY positive context evidence" without re-deriving
/// `rankWithContext`'s boost math. `rankWithContext` itself just sums the two axes (after applying
/// `weights`) into its existing boost — this is a pure decomposition, not a behavior change.
struct HanjaContextEvidence {
    /// Step-4 axis: containment count × `weights.containment` + char-share count × `weights.charShare`.
    let dictionaryBoost: Int
    /// Step-5 axis: raw (unweighted) matched association score for this candidate.
    let associationScore: Int

    /// Step 7's promotion condition: containment/dominance contributed something, OR the
    /// association table scored this candidate above zero.
    var hasPositiveEvidence: Bool {
        dictionaryBoost > 0 || associationScore > 0
    }
}

/// Computes `candidate`'s `HanjaContextEvidence` against `contextDominantHanja` /
/// `associationScores` — the same per-candidate quantities `rankWithContext` folds into its boost.
func contextEvidence(
    for candidate: HanjaCandidate,
    contextDominantHanja: [String],
    associationScores: [String: Int] = [:],
    weights: HanjaContextRankingWeights
) -> HanjaContextEvidence {
    var dictionaryBoost = 0
    for contextHanja in contextDominantHanja where contextHanja != candidate.value {
        if contextHanja.contains(candidate.value) {
            dictionaryBoost += weights.containment
        }
        dictionaryBoost += sharedHanjaCharCount(candidate.value, contextHanja) * weights.charShare
    }
    let associationScore = associationScores[candidate.value] ?? 0
    return HanjaContextEvidence(dictionaryBoost: dictionaryBoost, associationScore: associationScore)
}

/// Re-ranks `candidates` using dominant hanja resolved from the surrounding context. Each
/// candidate's boost (containment + char-share against every context dominant hanja) is
/// precomputed once — O(K × context) — then folded into a copy's `frequency` before applying the
/// existing `compareHanjaCandidate` order, so all other tie-break tiers (source, usageCount,
/// baseRank, value, reading) are untouched. When `contextDominantHanja` is empty (or every boost
/// is 0), every copy keeps its original frequency and the result is EXACTLY
/// `compareHanjaCandidate` order — this is the invariant `HanjaContextRankerTests` pins.
func rankWithContext(
    candidates: [HanjaCandidate],
    contextDominantHanja: [String],
    associationScores: [String: Int] = [:],
    weights: HanjaContextRankingWeights
) -> [HanjaCandidate] {
    let boosts: [Int] = candidates.map { candidate in
        let evidence = contextEvidence(
            for: candidate,
            contextDominantHanja: contextDominantHanja,
            associationScores: associationScores,
            weights: weights
        )
        return evidence.dictionaryBoost + evidence.associationScore * weights.association
    }

    let boosted: [(original: HanjaCandidate, copy: HanjaCandidate)] = zip(candidates, boosts).map { candidate, boost in
        guard boost != 0 else { return (candidate, candidate) }
        let copy = HanjaCandidate(
            reading: candidate.reading,
            value: candidate.value,
            comment: candidate.comment,
            source: candidate.source,
            usageCount: candidate.usageCount,
            frequency: candidate.frequency + boost,
            baseRank: candidate.baseRank
        )
        return (candidate, copy)
    }

    return boosted
        .sorted { compareHanjaCandidate($0.copy, $1.copy) }
        .map(\.original)
}
