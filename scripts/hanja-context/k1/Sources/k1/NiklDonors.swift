// Source (b): NIKL 판별 단순어 donors (docs/plans/hanja-context-scaling-plan.md §12 K1a-2).
// For each (reading, candidate) pair, take content morphemes from that candidate's 뜻풀이 that do
// NOT appear in any sibling candidate's 뜻풀이 for the same reading. Individual analyzed tokens
// are inherently single morphemes (never n-gram joins), satisfying the "단순어" preference without
// extra logic. Needs a plain (unregistered) Kiwi instance for tokenization — reuses the same
// contract (topN=1, Contract.matchOptionsRaw, content-tag filter) as verify-contract/collector.
import Foundation

/// Loads nikl/definitions.tsv, tokenizes every definition with the contract pipeline, and returns
/// only the discriminative (candidate-exclusive) content morphemes per pair, ranked by occurrence
/// count within that candidate's own definitions.
func loadNiklDonors(kiwi: KiwiRaw) throws -> [PairKey: [DonorCandidate]] {
    var defsByPair: [PairKey: [String]] = [:]
    for line in try dataLines(of: Paths.niklDefsTSV) {
        let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard cols.count >= 4 else { continue }
        let reading = String(cols[0])
        let hanja = String(cols[1])
        let definition = String(cols[3])
        guard !definition.isEmpty else { continue }
        defsByPair[PairKey(reading: reading, candidate: hanja), default: []].append(definition)
    }
    guard !defsByPair.isEmpty else { fail("nikl/definitions.tsv produced no (reading,candidate) groups") }

    var pairsByReading: [String: Set<String>] = [:] // reading -> candidates with >=1 definition
    for key in defsByPair.keys {
        pairsByReading[key.reading, default: []].insert(key.candidate)
    }

    // form/TAG -> occurrence count, per pair, over ALL of that pair's definitions.
    var tokenCountsByPair: [PairKey: [String: Int]] = [:]
    for (key, definitions) in defsByPair {
        var counts: [String: Int] = [:]
        for definition in definitions {
            let results = try kiwi.analyze(definition, topN: Contract.topN, matchOptionsRaw: Contract.matchOptionsRaw)
            let tokens = results.first?.tokens ?? []
            for t in tokens where Contract.contentTags.contains(t.tag) {
                counts[Contract.feature(form: t.form, tag: t.tag), default: 0] += 1
            }
        }
        tokenCountsByPair[key] = counts
    }

    var result: [PairKey: [DonorCandidate]] = [:]
    for (reading, candidates) in pairsByReading {
        for candidate in candidates {
            let key = PairKey(reading: reading, candidate: candidate)
            guard let ownCounts = tokenCountsByPair[key] else { continue }
            var siblingFeatures = Set<String>()
            for other in candidates where other != candidate {
                if let otherCounts = tokenCountsByPair[PairKey(reading: reading, candidate: other)] {
                    siblingFeatures.formUnion(otherCounts.keys)
                }
            }
            var donors: [DonorCandidate] = []
            for (feature, count) in ownCounts where !siblingFeatures.contains(feature) {
                guard let slash = feature.lastIndex(of: "/") else { continue }
                let form = String(feature[feature.startIndex..<slash])
                let tag = String(feature[feature.index(after: slash)...])
                donors.append(DonorCandidate(donor: form, pos: tag, sourceScore: count))
            }
            guard !donors.isEmpty else { continue }
            result[key] = donors.deterministicallyRanked()
        }
    }
    return result
}
