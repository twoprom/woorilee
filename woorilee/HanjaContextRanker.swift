// Context-aware ranking interface for Hanja candidates.
//     Copyright (C) 2026 Seungjin Lee.
//
// Step 4a (사전 내부 문맥 신호, measurement only — see
// docs/plans/context-aware-hanja-conversion.md §5) implements the real context signal here.
// Nothing in this file is wired into the production input path yet; that is step 4b.

import Foundation
import Kiwi

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
    /// NNP gazette bonus, expressed in association RAW-score units (the boost added is
    /// `nnpGazetteBonus * association`): when the segment is tagged `.nnp` and the candidate
    /// carries a non-empty hanja.txt comment (지명·국명 관보 — 韓國:대한민국, 朝鮮:조선민주주의
    /// 인민공화국), the proper-noun reading gets a fixed head start. Calibration (2026-07-18
    /// 실측, "서울은 조선의 수도였다"): must beat 祖先's corpus noise (수도/NNG=66 → 19,800) —
    /// 朝鮮 24×300 + 100×300 = 37,200 > 19,800 ✓ — but must LOSE to a strong real association
    /// like 造船's 중공업 173×300 = 51,900 > 30,000 + 造船-side features ✓. Not part of
    /// `HanjaContextEvidence` — the gazette is a prior, not context evidence, so it never
    /// promotes an `awaitsContextEvidence` segment by itself.
    var nnpGazetteBonus: Int = 100
    /// Session vocabulary association scale (docs/plans/hanja-context-scaling-plan.md §6 R1a
    /// initial value): the session buffer's matched-feature weight counts at this fraction of the
    /// in-clause association weight — session evidence is real but weaker than the current clause.
    var sessionAssociationScale: Double = 0.5
    /// R2 (docs/plans/hanja-context-scaling-plan.md §7): 결합 선택의 도메인 일관성 보너스 크기를
    /// 연관 RAW 점수 단위로 표현한다 — 실제 가점은 `cosine × jointDomainConsistency × association`.
    /// 20.0이었을 때의 근거: 코사인 1.0(현실에서 거의 불가)일 때도 6,000으로, 실측 최약 클로즈
    /// 피처 1건(raw 39 × 300 = 11,700)보다 작다 → 실재하는 클로즈 증거를 결코 뒤집지 못한다.
    /// 반대로 양쪽 분절 모두 클로즈 증거가 0인 경우(모든 boost 0)에는 어떤 양수 가점이든 순위를
    /// 정하므로 R2가 노리는 "증거 없는 자리에서 도메인으로 수렴"은 그대로 작동한다.
    /// containment(10,000,000)와 NNP 관보(30,000)는 애초에 넘볼 수 없다.
    ///
    /// **파킹 결정 (사용자, 2026-07-25): 기본값을 0으로 내렸다.** 281문서·12,855문장 재생
    /// 코퍼스에서 PASS 2가 실제로 돈 3,114개 클로즈 중 결과가 바뀐 건 단 2건, 그중 개선은
    /// 0건 — 유감 사례(遺憾→有感)는 조율자가 사용자 가시 회귀로 판정했고(양쪽 후보 모두 클로즈
    /// 증거 0인 자리에서 有感+謝過 cos 0.066 · 공유 피처 6개짜리 약한 쌍이 겨우 396 boost로
    /// 사전식 동점을 깼다 — 위 문단이 "어떤 양수 가점이든 순위를 정한다"고 경고한 바로 그 실패
    /// 모드), 주공 사례(主攻→周公)는 오답→오답(중립)이었다. 개선 0 · 회귀 1 · 중립 1이라는 실측
    /// 앞에서 사용자가 이 축을 기본 OFF로 파킹하기로 했다(docs/plans/hanja-context-eval-baseline.md
    /// "R2 클로즈 안 결합 선택 측정" 절 "조율자 후속 검증" 참고). **20.0은 이 R2 측정이 쓴 값이자
    /// 재평가 시 복원할 값**이다 — 재활성화 조건은 D3의 복합어 그래프(연구 문서 §2.2, 지금의
    /// 코사인 대리 신호보다 신뢰도 높은 실제 도메인 인접성 신호)와, 그 신호를 측정 가능하게 만들
    /// D2의 gold 세트다. `KiwiAnalysisService.applyContextReranking`의 PASS 2 진입 조건은
    /// `weights.jointDomainConsistency > 0`도 함께 요구하므로, 이 기본값(0)에서는 PASS 2가 아예
    /// 돌지 않는다 — 파킹 비용이 진짜로 0이다(유사도 행렬도, 조합 탐색도 안 돈다).
    var jointDomainConsistency: Double = 0.0
    static let `default` = HanjaContextRankingWeights(containment: 10_000_000, charShare: 0, association: 300)
}

/// Sums matched-feature weights from `lookup(candidate.reading, candidate.value)` against
/// `contextFeatures`, for every candidate — O(candidates × contextFeatures), precomputed once by
/// the caller and fed into `rankWithContext`'s `associationScores`. Feature values are `Double`
/// (step 0c — docs/plans/hanja-context-scaling-plan.md §5): the binary loader's per-reading
/// quantization no longer lands on exact integers, so the sum is a Double too.
func associationScores(
    for candidates: [HanjaCandidate],
    contextFeatures: [String],
    lookup: (String, String) -> [String: Double]?
) -> [String: Double] {
    guard !contextFeatures.isEmpty else {
        return [:]
    }

    var scores: [String: Double] = [:]
    for candidate in candidates {
        guard let features = lookup(candidate.reading, candidate.value) else { continue }
        var sum = 0.0
        for feature in contextFeatures {
            if let weight = features[feature] {
                sum += weight
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
    /// Step-5 axis: raw (unweighted) matched association score for this candidate. `Double` since
    /// step 0c (docs/plans/hanja-context-scaling-plan.md §5) — the binary-loaded feature values are
    /// no longer exact integers.
    let associationScore: Double

    /// Step 7's promotion condition: containment/dominance contributed something, OR the
    /// association table scored this candidate above zero.
    var hasPositiveEvidence: Bool {
        dictionaryBoost > 0 || associationScore > 0
    }
}

/// Session vocabulary axis score, direction-reversed from `associationScores` (docs/plans/
/// hanja-context-scaling-plan.md §6 R1a perf fix): iterates each candidate's association PROFILE
/// (~40 entries on average — 827,380 entries / ~22,600 profiles) and sums the entries whose
/// feature is a member of `vocabulary`, instead of probing the (up to 400-entry) session
/// vocabulary set against each candidate's profile dict. Same "sum > 0 → record" contract as
/// `associationScores`. Cheaper by roughly the profile/vocabulary size ratio because the smaller
/// side drives the iteration.
func sessionAssociationScores(
    for candidates: [HanjaCandidate],
    vocabulary: Set<String>,
    lookup: (String, String) -> [String: Double]?
) -> [String: Double] {
    guard !vocabulary.isEmpty else {
        return [:]
    }

    var scores: [String: Double] = [:]
    for candidate in candidates {
        guard let features = lookup(candidate.reading, candidate.value) else { continue }
        var sum = 0.0
        for (feature, weight) in features where vocabulary.contains(feature) {
            sum += weight
        }
        if sum > 0 {
            scores[candidate.value] = sum
        }
    }
    return scores
}

/// Session-context boost per candidate value (docs/plans/hanja-context-scaling-plan.md §6 R1a):
/// the session vocabulary axis (`sessionAssociationScores`, scaled by
/// `weights.sessionAssociationScale`) plus the last-selection-prior axis (`containment × decay`
/// for the reading's most recent confirmed value). Deliberately does NOT exclude features already
/// counted by the in-clause association axis — a morpheme present in both the current clause and
/// the session buffer is counted twice (clause 1.0× + session 0.5× = 1.5× ceiling for that
/// feature), which is accepted for direction/simplicity: it only ever strengthens an
/// already-positive signal and never overturns containment. Deliberately NOT folded into
/// `HanjaContextEvidence` / `contextEvidence` — session boosts affect ranking only, never the
/// `awaitsContextEvidence` promotion gate (auto-convert safety invariant). Empty session ⇒ `[:]`.
func sessionContextBoosts(
    for candidates: [HanjaCandidate],
    reading: String,
    session: HanjaSessionScoringInputs,
    lookup: ((String, String) -> [String: Double]?)?,
    weights: HanjaContextRankingWeights
) -> [String: Double] {
    guard !session.isEmpty else {
        return [:]
    }

    var boosts: [String: Double] = [:]

    if let lookup {
        let scores = sessionAssociationScores(for: candidates, vocabulary: session.vocabularyFeatures, lookup: lookup)
        for (value, score) in scores {
            boosts[value, default: 0] += score * Double(weights.association) * weights.sessionAssociationScale
        }
    }

    if let prior = session.selectionPriors[reading] {
        boosts[prior.value, default: 0] += Double(weights.containment) * prior.decay
    }

    return boosts
}

/// Computes `candidate`'s `HanjaContextEvidence` against `contextDominantHanja` /
/// `associationScores` — the same per-candidate quantities `rankWithContext` folds into its boost.
func contextEvidence(
    for candidate: HanjaCandidate,
    contextDominantHanja: [String],
    associationScores: [String: Double] = [:],
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

/// `rankWithContext`와 동일한 계산·정렬. 결합 선택(R2, docs/plans/hanja-context-scaling-plan.md
/// §7)이 후보별 boost를 필요로 해서 분리했다. `rankWithContext`는 이 함수의 `.map(\.candidate)`
/// 래퍼다 — 동작 동일 (`HanjaContextRankerTests`가 두 함수의 산출 순서 동일성을 고정한다).
func rankWithContextScored(
    candidates: [HanjaCandidate],
    contextDominantHanja: [String],
    associationScores: [String: Double] = [:],
    weights: HanjaContextRankingWeights,
    segmentTag: POSTag? = nil,
    sessionBoosts: [String: Double] = [:]
) -> [(candidate: HanjaCandidate, boost: Double)] {
    let boosted: [(candidate: HanjaCandidate, boost: Double)] = candidates.map { candidate in
        let evidence = contextEvidence(
            for: candidate,
            contextDominantHanja: contextDominantHanja,
            associationScores: associationScores,
            weights: weights
        )
        var boost = Double(evidence.dictionaryBoost) + evidence.associationScore * Double(weights.association)
        if segmentTag == .nnp, !candidate.comment.isEmpty {
            boost += Double(weights.nnpGazetteBonus * weights.association)
        }
        boost += sessionBoosts[candidate.value] ?? 0
        return (candidate, boost)
    }

    return boosted.sorted { lhs, rhs in
        if lhs.boost != rhs.boost {
            return lhs.boost > rhs.boost
        }
        return compareHanjaCandidate(lhs.candidate, rhs.candidate)
    }
}

/// Re-ranks `candidates` context-first: each candidate's total context boost (containment +
/// char-share + association, plus the NNP gazette bonus when `segmentTag == .nnp` and the
/// candidate has a hanja.txt comment) is precomputed once — O(K × context) — then candidates are
/// sorted by **boost descending, ties broken by `compareHanjaCandidate`**. Context evidence
/// therefore outranks every personalization tier (source / usageCount / frequency), per the
/// 2026-07-18 user directive; containment's 10M scale keeps it above everything else naturally.
/// When every boost is 0 (no context, no gazette hit) the comparator degenerates to EXACTLY
/// `compareHanjaCandidate` order — this is the invariant `HanjaContextRankerTests` pins.
/// - Parameter segmentTag: the segment's Kiwi POS tag. `nil` (the default) disables the gazette
///   bonus, reproducing tag-unaware behavior exactly.
func rankWithContext(
    candidates: [HanjaCandidate],
    contextDominantHanja: [String],
    associationScores: [String: Double] = [:],
    weights: HanjaContextRankingWeights,
    segmentTag: POSTag? = nil,
    sessionBoosts: [String: Double] = [:]
) -> [HanjaCandidate] {
    rankWithContextScored(
        candidates: candidates,
        contextDominantHanja: contextDominantHanja,
        associationScores: associationScores,
        weights: weights,
        segmentTag: segmentTag,
        sessionBoosts: sessionBoosts
    ).map(\.candidate)
}
