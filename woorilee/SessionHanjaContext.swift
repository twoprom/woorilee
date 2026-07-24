// Per-client session vocabulary buffer and last-committed selection priors.
//     Copyright (C) 2026 Seungjin Lee.
//
// Step R1a (docs/plans/hanja-context-scaling-plan.md §6): "방금 고른 후보는 바로 위로, 방금 쓴
// 문장은 문맥으로." Memory-only, per-`InputSession` state — never Codable, never persisted to
// disk, never logged (정지선, see the plan's §1/§12 common rules).

import Foundation

/// Immutable per-keystroke snapshot handed to the ranker (`HanjaContextRanker.sessionContextBoosts`
/// / `KiwiAnalysisService.applyContextReranking`). Built by `InputSession.sessionScoringInputs`
/// from the mutable `HanjaSessionContext` it owns.
struct HanjaSessionScoringInputs {
    /// Content-morpheme features ("form/TAG") from recent committed sentences — deduped union
    /// across sentences. `Set` (not an ordered array): the scoring axis
    /// (`sessionAssociationScores`) iterates each CANDIDATE's association profile and tests
    /// membership against this set, rather than iterating the vocabulary against each candidate —
    /// direction chosen for performance (profiles average ~40 entries vs. up to 400 vocabulary
    /// features), so insertion order is irrelevant.
    let vocabularyFeatures: Set<String>
    /// reading → last-confirmed candidate value + linear decay (1.0 at age 0, 0 at
    /// `HanjaSessionContext.selectionLifetime`).
    let selectionPriors: [String: HanjaSessionSelectionPrior]
    var isEmpty: Bool
}

/// A single reading's most recent confirmed selection and its age-based decay weight.
struct HanjaSessionSelectionPrior {
    let value: String
    let decay: Double
}

/// Mutable per-client session state owned by `InputSession`. Two independent structures:
/// - A ring buffer of recent committed sentences' content-morpheme features, capped at
///   `maxSentences` sentences AND `maxMorphemes` total morphemes (oldest sentence evicted first
///   past either cap).
/// - A short list of recently confirmed `(reading, value)` selections that age by "commits since
///   selection" and decay linearly to zero over `selectionLifetime` commits.
struct HanjaSessionContext {
    static let maxSentences = 20
    static let maxMorphemes = 400
    static let selectionLifetime = 20

    private struct SelectionEntry {
        let value: String
        var age: Int
    }

    private var sentences: [[String]] = []
    private var selections: [String: SelectionEntry] = [:]

    var isEmpty: Bool {
        sentences.isEmpty && selections.isEmpty
    }

    /// Called once per realtime-Hanja commit (see `InputSession.recordRealtimeCommitToSessionContext`).
    /// Ages/evicts existing selection priors first (this happens even when `features` is empty —
    /// the decay clock is "committed sentences since selection", not "sentences with content"),
    /// then records `selections` at age 0, then appends `features` as one new ring-buffer sentence.
    mutating func recordCommittedClause(features: [String], selections newSelections: [(reading: String, value: String)]) {
        let existingKeys = Array(selections.keys)
        for key in existingKeys {
            selections[key]?.age += 1
        }
        selections = selections.filter { $0.value.age < Self.selectionLifetime }

        for (reading, value) in newSelections {
            guard value != reading else { continue }
            selections[reading] = SelectionEntry(value: value, age: 0)
        }

        guard !features.isEmpty else { return }

        var seen = Set<String>()
        var deduped: [String] = []
        for feature in features where !seen.contains(feature) {
            seen.insert(feature)
            deduped.append(feature)
        }
        guard !deduped.isEmpty else { return }

        sentences.append(deduped)
        while sentences.count > Self.maxSentences || totalMorphemeCount > Self.maxMorphemes {
            sentences.removeFirst()
        }
    }

    /// Manual-panel selection (no clause commit involved): age-0 insert/replace only, no aging of
    /// the other entries — the plan's manual-panel selection axis is a pure "most recent pick"
    /// signal, independent of sentence-commit cadence.
    mutating func recordManualSelection(reading: String, value: String) {
        guard value != reading else { return }
        selections[reading] = SelectionEntry(value: value, age: 0)
    }

    private var totalMorphemeCount: Int {
        sentences.reduce(0) { $0 + $1.count }
    }

    var scoringInputs: HanjaSessionScoringInputs {
        var vocabulary = Set<String>()
        for sentence in sentences {
            vocabulary.formUnion(sentence)
        }

        let priors = selections.mapValues { entry in
            HanjaSessionSelectionPrior(
                value: entry.value,
                decay: Double(Self.selectionLifetime - entry.age) / Double(Self.selectionLifetime)
            )
        }

        return HanjaSessionScoringInputs(
            vocabularyFeatures: vocabulary,
            selectionPriors: priors,
            isEmpty: sentences.isEmpty && selections.isEmpty
        )
    }
}
