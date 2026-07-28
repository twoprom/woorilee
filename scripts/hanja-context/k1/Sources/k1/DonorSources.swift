// Data loading for K1a Part 2 — donor inventory (docs/plans/hanja-context-scaling-plan.md §12 K1a,
// items K1a-2/K1a-3). Loads the target-pair universe and donor candidates from sources (a) anchor
// and (c) association-table; NIKL source (b) lives in NiklDonors.swift since it needs Kiwi analysis.
import Foundation

struct PairKey: Hashable, Comparable {
    let reading: String
    let candidate: String // hanja
    static func < (lhs: PairKey, rhs: PairKey) -> Bool {
        (lhs.reading, lhs.candidate) < (rhs.reading, rhs.candidate)
    }
}

/// The full (reading, candidate) universe from inventory/targets.tsv, with each reading's
/// candidates in the file's own order (already frequency-descending per its header comment) —
/// that order IS the sense_id assignment (1-based candidate index).
struct TargetInventory {
    /// reading -> candidates in rank order (index 0 == sense_id 1)
    let candidatesByReading: [String: [String]]
    /// stable iteration order over all (reading, candidate) pairs, reading-then-rank
    let allPairs: [PairKey]
    /// PairKey -> 1-based candidate index (== sense_id to register)
    let candidateIndex: [PairKey: Int]

    static func load() throws -> TargetInventory {
        var byReading: [String: [String]] = [:]
        var order: [String] = [] // reading first-seen order, for stable output
        for line in try dataLines(of: Paths.inventoryDir.appendingPathComponent("targets.tsv")) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            let reading = String(cols[0])
            var candidates: [String] = []
            for item in cols[2].split(separator: ",") {
                guard let colon = item.firstIndex(of: ":") else { continue }
                candidates.append(String(item[item.startIndex..<colon]))
            }
            guard !candidates.isEmpty else { continue }
            byReading[reading] = candidates
            order.append(reading)
        }
        guard !byReading.isEmpty else { fail("targets.tsv produced no readings") }

        var allPairs: [PairKey] = []
        var index: [PairKey: Int] = [:]
        for reading in order {
            for (i, candidate) in byReading[reading]!.enumerated() {
                let key = PairKey(reading: reading, candidate: candidate)
                allPairs.append(key)
                index[key] = i + 1 // sense_id 1-based; sense 0 stays reserved for any native entry
            }
        }
        return TargetInventory(candidatesByReading: byReading, allPairs: allPairs, candidateIndex: index)
    }
}

/// A candidate donor: a word (`donor`) that exists (we hope) as `pos` in the model, ranked by
/// `sourceScore` (source-specific: anchor freq / NIKL discriminative-morpheme count / assoc
/// weight) within its pair. `pos` is nil for anchor donors (their tag isn't recorded in
/// anchors.tsv — the caller only tries tags the reading itself natively carries, see
/// NativeTags.swift).
struct DonorCandidate {
    let donor: String
    let pos: String?
    let sourceScore: Int
}

extension Array where Element == DonorCandidate {
    /// Deterministic total order: sourceScore desc, then donor asc, then pos asc (nil sorts
    /// first). A plain `.sorted { $0.sourceScore > $1.sourceScore }` is only as deterministic as
    /// the pre-sort element order, which here comes from Dictionary/Set iteration — NOT stable
    /// across process runs (Swift's String hashing is seeded per-process). Fixes the run-to-run
    /// tie-break non-determinism the coordinator flagged.
    func deterministicallyRanked() -> [DonorCandidate] {
        sorted {
            if $0.sourceScore != $1.sourceScore { return $0.sourceScore > $1.sourceScore }
            if $0.donor != $1.donor { return $0.donor < $1.donor }
            return ($0.pos ?? "") < ($1.pos ?? "")
        }
    }
}

/// Source (a): inventory/anchors.tsv — `target_reading<TAB>candidate_hanja<TAB>anchor_reading<TAB>
/// anchor_hanja<TAB>anchor_freq`. Donor = anchor_reading (deduped, freq-descending); pos unknown
/// (anchors.tsv doesn't record POS), so the caller tries NNG then NNP.
func loadAnchorDonors() throws -> [PairKey: [DonorCandidate]] {
    var byPair: [PairKey: [String: Int]] = [:] // pair -> anchorReading -> best freq
    for line in try dataLines(of: Paths.inventoryDir.appendingPathComponent("anchors.tsv")) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 5 else { continue }
        let key = PairKey(reading: String(cols[0]), candidate: String(cols[1]))
        let anchorReading = String(cols[2])
        let freq = Int(cols[4]) ?? 0
        var entry = byPair[key] ?? [:]
        entry[anchorReading] = max(entry[anchorReading] ?? 0, freq)
        byPair[key] = entry
    }
    var result: [PairKey: [DonorCandidate]] = [:]
    for (key, donors) in byPair {
        result[key] = donors
            .map { DonorCandidate(donor: $0.key, pos: nil, sourceScore: $0.value) }
            .deterministicallyRanked()
    }
    return result
}

/// Reverses the 5b percent-escaping (`%25`->`%`, `%3A`->`:`, `%2C`->`,`, `%3D`->`=`) in a single
/// left-to-right scan, per woorilee/data/hanja/hanja-context.txt's own header comment. A
/// character-by-character scan (rather than sequential .replacingOccurrences calls) avoids any
/// ordering hazard between the four escape tokens.
func percentDecodeAssocToken(_ s: Substring) -> String {
    let escapes: [(String, Character)] = [("%25", "%"), ("%3A", ":"), ("%2C", ","), ("%3D", "=")]
    var out = ""
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        if chars[i] == "%", i + 2 < chars.count {
            let token = String(chars[i...(i + 2)])
            if let match = escapes.first(where: { $0.0 == token }) {
                out.append(match.1)
                i += 3
                continue
            }
        }
        out.append(chars[i])
        i += 1
    }
    return out
}

/// Source (c): woorilee/data/hanja/hanja-context.txt — `reading:hanja:form/TAG=weight,...`.
/// Donor = feature form, pos = its own recorded TAG, filtered to NNG/NNP per the plan
/// ("Top-weighted NNG/NNP features per candidate"), sorted by weight descending.
func loadAssocDonors() throws -> [PairKey: [DonorCandidate]] {
    var result: [PairKey: [DonorCandidate]] = [:]
    for line in try dataLines(of: Paths.assocTxt) {
        // reading:hanja:features — split on first two ':' only (features may itself be free of
        // ':' since it's percent-escaped, but split conservatively on the first two anyway).
        guard let c1 = line.firstIndex(of: ":") else { continue }
        let reading = String(line[line.startIndex..<c1])
        let rest = line[line.index(after: c1)...]
        guard let c2 = rest.firstIndex(of: ":") else { continue }
        let hanja = String(rest[rest.startIndex..<c2])
        let featuresField = rest[rest.index(after: c2)...]

        var candidates: [DonorCandidate] = []
        for entry in featuresField.split(separator: ",") {
            guard let eq = entry.lastIndex(of: "=") else { continue }
            let rawFeature = entry[entry.startIndex..<eq]
            let weight = Int(entry[entry.index(after: eq)...]) ?? 0
            let decoded = percentDecodeAssocToken(rawFeature)
            guard let slash = decoded.lastIndex(of: "/") else { continue }
            let form = String(decoded[decoded.startIndex..<slash])
            let tag = String(decoded[decoded.index(after: slash)...])
            guard tag == "NNG" || tag == "NNP" else { continue }
            guard !form.isEmpty else { continue }
            candidates.append(DonorCandidate(donor: form, pos: tag, sourceScore: weight))
        }
        guard !candidates.isEmpty else { continue }
        result[PairKey(reading: reading, candidate: hanja)] = candidates.deterministicallyRanked()
    }
    return result
}

/// D1's seed-bearing pairs (docs/plans/hanja-context-scaling-plan.md §12 K1a gate requirement):
/// distinct (reading, hanja) pairs from seeds/part-*.tsv where level=="token" and
/// in_target_inventory=="1" — reproduces the pre-registered 8,379/19,490 (43.0%) figure exactly
/// (verified independently before writing this loader).
func loadD1SeedPairs() throws -> Set<PairKey> {
    var pairs = Set<PairKey>()
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: Paths.seedsDir, includingPropertiesForKeys: nil) else {
        fail("seeds directory not found: \(Paths.seedsDir.path)")
    }
    let partFiles = entries
        .filter { $0.lastPathComponent.hasPrefix("part-") && $0.lastPathComponent.hasSuffix(".tsv") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !partFiles.isEmpty else { fail("no seeds/part-*.tsv files found") }
    for url in partFiles {
        let text = try String(contentsOf: url, encoding: .utf8)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            let cols = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 13 else { continue }
            guard cols[0] == "token", cols[8] == "1" else { continue }
            pairs.insert(PairKey(reading: String(cols[2]), candidate: String(cols[3])))
        }
    }
    return pairs
}
