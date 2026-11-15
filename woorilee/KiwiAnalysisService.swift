// Background warm-up of Kiwi morphological analyzer.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi

/// Bundles the winning realtime segmentation with the clause-wide content-morpheme features the
/// session buffer needs at commit time (docs/plans/hanja-context-scaling-plan.md §6 R1a) — computed
/// once per analysis pass so `InputSession.recordRealtimeCommitToSessionContext()` never has to
/// re-run Kiwi.
struct RealtimeClauseAnalysis {
    let segments: [HanjaSegment]
    /// Stable content-morpheme features ("form/TAG") for the WHOLE clause (no self-exclusion),
    /// computed regardless of association-table availability — this is the commit-time buffer
    /// input, not a reranking signal. Empty for a failed/empty clause.
    let clauseContentFeatures: [String]
}

@MainActor
final class KiwiAnalysisService {
    static let realtimeAnalysisCandidateCount = 3

    /// Kiwi match options for the realtime conversion path. Also one half of the step-5a
    /// offline↔runtime morpheme-space contract (see scripts/hanja-context/README.md): the offline
    /// corpus collector (scripts/hanja-context/collector) analyzes with exactly these options,
    /// and `KiwiOfflinePipelineConsistencyTests` pins the equivalence against its
    /// `dump-tokens` output.
    static let realtimeAnalysisMatchOptions: MatchOptions = [.allWithNormalizing, .joinNounPrefix, .joinNounSuffix]

    /// Step 6 — auto-convert word evidence gate threshold (docs/plans/context-aware-hanja-conversion.md
    /// §9). Decoded freq-hanjaeo.txt 하위값 실측: 고유어 충돌어(단자 훈음 후보 등) ≤104 — 牛李 92,
    /// 南無 104, 可知 102, 加持 88, 茄子 66 — vs 일반 명사의 정당한 한자어 ≥1,516 — 口頭 1,516,
    /// 水道 2,106, 修道 2,737, 故障 7,492, 首都 11,750. 500 splits the two NNG bands; NNP와 XR의
    /// 구조적으로 낮은 단어 빈도는 아래의 품사별 약한 증거 축에서 별도로 다룬다.
    static let autoConvertWordEvidenceThreshold = 500

    /// Whether `candidate` has word-level evidence for auto-conversion (step 6). Gates
    /// `previewCandidate` only — `isConvertible` (candidate-panel access) is untouched by this.
    ///
    /// - Parameter tag: the segment's Kiwi POS tag, enabling weak-evidence axes for proper nouns
    ///   and roots.
    ///
    ///   Proper-noun axis
    ///   (2026-07-11 실측): 국명·지명의 freq-hanjaeo 하위값은 전부 ~100 대역이라 (韓國 104,
    ///   美國 104, 中國 107, 釜山 84) 임계값 500에 원리적으로 걸린다. `.nnp`-tagged multi-syllable
    ///   segments therefore accept weaker evidence: any word-table presence (decoded 하위값 > 0)
    ///   OR a non-empty hanja.txt comment (지명·국명 관보 — 韓國:대한민국, 가락동:지명; 다음절
    ///   4,405건 — though 釜山-style major toponyms lack comments, hence the frequency alternative).
    ///   Guards: the NNP condition blocks 고전 음역 오변환 like 가나다→加那陀 ("가나다순" is a
    ///   single NNG token, 실측); the ≥ 2 syllable condition keeps single-character 훈음 candidates
    ///   out (freq-hanjaeo has zero 1-syllable rows — step-6 실측 — so weak-frequency evidence is
    ///   principled-impossible there).
    ///
    ///   Root axis (2026-07-20 실측): 화려/XR의 정당한 단어 후보 華麗도 하위값 72라 일반 NNG
    ///   임계값에 걸린다. XR은 독립 명사와 달리 어근이라는 형태소 제약이 이미 있으므로, 다음절
    ///   후보가 단어표에 실제로 있으면(> 0) 약한 단어 증거로 인정한다. comment-only evidence는
    ///   지명 관보 용도인 NNP에만 허용한다. `nil` tag는 두 축을 모두 끈다.
    static func hasAutoConvertWordEvidence(
        _ candidate: HanjaCandidate,
        tag: POSTag? = nil,
        wordFrequency: (String) -> Int,
        threshold: Int = autoConvertWordEvidenceThreshold
    ) -> Bool {
        if candidate.source == .userDefined || candidate.usageCount > 0 {
            return true
        }

        let frequency = wordFrequency(candidate.value)
        if frequency >= threshold {
            return true
        }

        guard candidate.reading.count >= 2 else {
            return false
        }

        switch tag {
        case .nnp:
            return frequency > 0 || !candidate.comment.isEmpty
        case .xr:
            return frequency > 0
        default:
            return false
        }
    }

    enum Status: Equatable {
        case uninitialized
        case loading
        case ready
        case unavailable(String)
    }

    static let shared = KiwiAnalysisService()

    private(set) var status: Status = .uninitialized
    private(set) var kiwi: Kiwi?
    private var pendingWarmUpCompletions: [() -> Void] = []

    private init() {}

    var isAvailable: Bool {
        if case .ready = status {
            return true
        }

        return false
    }

    var isLoading: Bool {
        if case .loading = status {
            return true
        }

        return false
    }

    func warmUp(completion: (() -> Void)? = nil) {
        if let completion {
            pendingWarmUpCompletions.append(completion)
        }

        switch status {
        case .ready, .unavailable:
            drainPendingWarmUpCompletions()
            return
        case .loading:
            return
        case .uninitialized:
            break
        }

        status = .loading
        let bundle = Bundle.main

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loadedKiwi: Kiwi?
            var failureReason: String?

            do {
                let builder = try KiwiBuilder(bundle: bundle, modelDirectory: AppRuntimePaths.kiwiModelDirectory)
                loadedKiwi = try builder.build()
            } catch {
                failureReason = String(describing: error)
            }

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let loadedKiwi {
                    self.kiwi = loadedKiwi
                    self.status = .ready
                } else {
                    self.kiwi = nil
                    self.status = .unavailable(failureReason ?? "Unknown Kiwi warm-up error")
                }

                self.drainPendingWarmUpCompletions()
            }
        }
    }

    /// - Parameter composingTailStart: UTF16 offset (in `clause`) where the still-composing,
    ///   not-yet-committed tail begins (see `InputCompositionEngine.updateRealtimeAnalysis`'s
    ///   `rawClauseText`/`tailPreedit` split). Tokens that fall entirely at or after this offset
    ///   are excluded from context-association features (they can still change shape on every
    ///   keystroke — e.g. a bare jamo growing into a full syllable — and must not perturb an
    ///   already-settled earlier segment's preview). `nil` (the default) disables this exclusion,
    ///   treating the whole clause as stable — this reproduces the pre-fix behavior exactly.
    func analyzeClause(
        _ clause: String,
        hanjaService: HanjaDictionaryService,
        composingTailStart: Int? = nil
    ) -> [HanjaSegment] {
        analyzeClauseDetailed(clause, hanjaService: hanjaService, composingTailStart: composingTailStart).segments
    }

    /// Same analysis as `analyzeClause`, plus the clause-wide content-morpheme features the R1a
    /// session buffer needs (see `RealtimeClauseAnalysis`).
    /// - Parameter sessionInputs: session vocabulary/selection-prior snapshot (docs/plans/
    ///   hanja-context-scaling-plan.md §6 R1a), forwarded to `applyContextReranking`. `nil` (the
    ///   default) disables the session boost axis entirely, reproducing pre-R1a behavior exactly.
    func analyzeClauseDetailed(
        _ clause: String,
        hanjaService: HanjaDictionaryService,
        composingTailStart: Int? = nil,
        sessionInputs: HanjaSessionScoringInputs? = nil
    ) -> RealtimeClauseAnalysis {
        guard !clause.isEmpty, let kiwi else {
            return RealtimeClauseAnalysis(segments: [], clauseContentFeatures: [])
        }

        let candidateLookup: (String) -> [HanjaCandidate] = { key in
            let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
            return numericCandidates.isEmpty ? hanjaService.exactCandidates(for: key) : numericCandidates
        }

        // Step 6 — auto-convert word evidence gate (docs/plans/context-aware-hanja-conversion.md
        // §9). Fails open (nil gate = pre-step-6 behavior) when the word frequency table hasn't
        // loaded any rows, since there's nothing to distinguish word evidence from character
        // evidence with.
        let autoConvertGate: ((HanjaCandidate, POSTag) -> Bool)? = hanjaService.hasWordFrequencyData
            ? { candidate, tag in
                Self.hasAutoConvertWordEvidence(candidate, tag: tag, wordFrequency: hanjaService.wordFrequency(for:))
            }
            : nil

        // Step 7 — native-homograph gate (docs/plans/context-aware-hanja-conversion.md §10).
        let nativeHomographLookup: (String) -> Bool = hanjaService.isNativeHomographReading(_:)

        let associationStore = HanjaContextAssociationStore.shared
        return Self.analyzeClause(
            clause, kiwi: kiwi, candidateLookup: candidateLookup,
            hangulUsageLookup: hanjaService.hangulUsageCount(for:),
            dominantMap: hanjaService.dominantHanjaMap ?? [:],
            associationFeatureLookup: associationStore.isAvailable
                ? { associationStore.features(reading: $0, hanja: $1) } : nil,
            associationBiasLookup: associationStore.isAvailable
                ? { associationStore.bias(reading: $0, hanja: $1) } : nil,
            autoConvertGate: autoConvertGate,
            nativeHomographLookup: nativeHomographLookup,
            composingTailStart: composingTailStart, sessionInputs: sessionInputs
        )
    }

    /// Shared app/offline pipeline. Callers supply resource access, never analysis options or
    /// their own sequencing of segmentation, stable features, ranking and conversion gates.
    static func analyzeClause(
        _ clause: String,
        kiwi: Kiwi,
        candidateLookup uncachedCandidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int,
        dominantMap: [String: String],
        associationFeatureLookup: ((String, String) -> [String: Double]?)? = nil,
        associationBiasLookup: ((String, String) -> Double?)? = nil,
        autoConvertGate: ((HanjaCandidate, POSTag) -> Bool)? = nil,
        nativeHomographLookup: ((String) -> Bool)? = nil,
        composingTailStart: Int? = nil,
        sessionInputs: HanjaSessionScoringInputs? = nil
    ) -> RealtimeClauseAnalysis {
        guard !clause.isEmpty else {
            return RealtimeClauseAnalysis(segments: [], clauseContentFeatures: [])
        }
        // One synchronous analysis observes a fixed dictionary/usage snapshot. Keep this cache
        // local so edits to user entries or usage are visible on the very next keystroke.
        var candidatesByReading: [String: [HanjaCandidate]] = [:]
        func candidateLookup(_ reading: String) -> [HanjaCandidate] {
            if let cached = candidatesByReading[reading] { return cached }
            let candidates = uncachedCandidateLookup(reading)
            candidatesByReading[reading] = candidates
            return candidates
        }
        do {
            let kiwiStart = DispatchTime.now().uptimeNanoseconds
            let results = try kiwi.analyze(
                clause,
                topN: Self.realtimeAnalysisCandidateCount,
                options: Self.realtimeAnalysisMatchOptions
            )
            HanjaPerformance.record("kiwi_analysis", since: kiwiStart)
            let segmentStart = DispatchTime.now().uptimeNanoseconds
            let best = Self.bestRealtimeSegmentsWithWinningTokens(
                from: results,
                in: clause,
                candidateLookup: candidateLookup,
                hangulUsageLookup: hangulUsageLookup,
                autoConvertGate: autoConvertGate,
                nativeHomographLookup: nativeHomographLookup
            )

            HanjaPerformance.record("segmentation", since: segmentStart)
            let stableTokens = Self.stableWinningTokens(from: best.winningTokens, composingTailStart: composingTailStart)
            // R1a (docs/plans/hanja-context-scaling-plan.md §6): the commit-time session buffer
            // needs the clause's content-morpheme features regardless of association-table
            // availability, so — unlike the reranking pass below — this is computed unconditionally.
            let clauseContentFeatures = Self.clauseContentFeatures(from: stableTokens, excludingRangeOverlapping: nil)

            guard !dominantMap.isEmpty
            else {
                return RealtimeClauseAnalysis(segments: best.segments, clauseContentFeatures: clauseContentFeatures)
            }

            let rankingStart = DispatchTime.now().uptimeNanoseconds
            let segments = Self.applyContextReranking(
                to: best.segments,
                clause: clause,
                dominantMap: dominantMap,
                candidateLookup: candidateLookup,
                winningTokens: stableTokens,
                associationFeatureLookup: associationFeatureLookup,
                associationBiasLookup: associationBiasLookup,
                autoConvertGate: autoConvertGate,
                sessionInputs: sessionInputs
            )
            HanjaPerformance.record("reranking", since: rankingStart)
            return RealtimeClauseAnalysis(segments: segments, clauseContentFeatures: clauseContentFeatures)
        } catch {
            return RealtimeClauseAnalysis(segments: [], clauseContentFeatures: [])
        }
    }

    /// R1b (docs/plans/hanja-context-scaling-plan.md §6): analyzes a standalone text window (the
    /// document-context fetch's trailing pre-cursor text — see
    /// `InputCompositionEngine.fetchDocumentContextIfNeeded`) into the SAME feature space as
    /// `analyzeClauseDetailed`'s `clauseContentFeatures` — content-morpheme `form/TAG`, deduped,
    /// via the shared `isContextContentMorphemeTag` filter (the offline↔runtime feature-space
    /// contract). Same match options / topN as the realtime path. Kiwi unavailable, an empty/
    /// whitespace-only `text`, or a failed/empty analysis all quietly return `[]` — no throw, no
    /// retry, matching the fetch path's "quiet fallback" contract.
    func contentFeatures(for text: String) -> [String] {
        guard !text.isEmpty, let kiwi else {
            return []
        }

        do {
            let results = try kiwi.analyze(text, topN: 1, options: Self.realtimeAnalysisMatchOptions)
            guard let winner = results.max(by: { $0.score < $1.score }) else {
                return []
            }
            return Self.clauseContentFeatures(from: winner.tokens, excludingRangeOverlapping: nil)
        } catch {
            return []
        }
    }

    /// Composing-tail stability strip (see `analyzeClause`'s `composingTailStart` doc): drops any
    /// token that extends into the still-composing tail (`token.position + token.length >
    /// composingTailStart`), so it can never vote as a context-association feature. Mid-sentence
    /// tokens (fully before the tail) are untouched. `composingTailStart == nil` is a full no-op —
    /// this is what makes every pre-existing call site (topics untouched by this fix) behave
    /// exactly as before.
    static func stableWinningTokens(from tokens: [Token], composingTailStart: Int?) -> [Token] {
        guard let composingTailStart else {
            return tokens
        }
        return tokens.filter { $0.position + $0.length <= composingTailStart }
    }

    /// Post-processing step (step 4b — see docs/plans/context-aware-hanja-conversion.md §5) applied
    /// AFTER `bestRealtimeSegments` has already picked the winning tokenization. Resolves the
    /// clause's context dominant hanja once, then only re-ranks segments that already carry a
    /// non-nil `previewCandidate` — segments that were nil (preferHangul / non-auto-convert-eligible
    /// / not convertible) stay nil, preserving every eligibility rule already applied upstream.
    /// When `dominantMap` is empty this is a full no-op (context resolves to `[]` for every segment,
    /// `rankWithContext` returns `compareHanjaCandidate` order, `.first` is unchanged).
    /// - Parameters:
    ///   - winningTokens: the Kiwi tokens behind the winning tokenization (from
    ///     `bestRealtimeSegmentsWithWinningTokens`), used only to derive step-5c association
    ///     features. Defaults to `[]`, which combined with `associationFeatureLookup == nil`
    ///     (its default) reproduces step 4b exactly.
    ///   - associationFeatureLookup: `(reading, hanja) -> matched-feature weights`, backed by
    ///     `HanjaContextAssociationStore` in production. nil (the default) disables the
    ///     association axis entirely — the step-4b containment/charShare behavior is unchanged.
    /// - Parameter autoConvertGate: step 6 (docs/plans/context-aware-hanja-conversion.md §9),
    ///   applied to `reranked.first` the same way `makeRealtimeSegments` applies it to
    ///   `candidates.first`. `nil` (the default) is a full no-op, reproducing pre-step-6 behavior.
    ///
    /// Step 7 (docs/plans/context-aware-hanja-conversion.md §10): segments with
    /// `awaitsContextEvidence == true` (native-homograph gate suppressed their preview in
    /// `makeRealtimeSegments`) are the one exception to "nil stays nil" above — they're reranked
    /// like any other segment, and promoted to the first `autoConvertGate`-passing candidate in
    /// reranked order (gate-failing candidates are skipped for the promotion decision only; the
    /// candidate-panel order is untouched), and only if that candidate itself has positive
    /// context evidence (`HanjaContextRanker.contextEvidence(...).hasPositiveEvidence`). No such
    /// candidate, or reranking not reached at all (this function's own early-return above when
    /// both `context` and `clauseFeatures` are empty), leaves them hangul — the designed safe
    /// default.
    ///
    /// Source-compatibility overload: forwards a tag-agnostic step-6 gate into the tag-aware
    /// primary below (the tag is ignored, reproducing pre-NNP-axis gating exactly). Kept so the
    /// pre-existing test fixtures that inject `(HanjaCandidate) -> Bool` gates compile unchanged.
    static func applyContextReranking(
        to segments: [HanjaSegment],
        clause: String,
        dominantMap: [String: String],
        candidateLookup: (String) -> [HanjaCandidate],
        winningTokens: [Token] = [],
        associationFeatureLookup: ((String, String) -> [String: Double]?)? = nil,
        weights: HanjaContextRankingWeights = .default,
        autoConvertGate: @escaping (HanjaCandidate) -> Bool
    ) -> [HanjaSegment] {
        applyContextReranking(
            to: segments,
            clause: clause,
            dominantMap: dominantMap,
            candidateLookup: candidateLookup,
            winningTokens: winningTokens,
            associationFeatureLookup: associationFeatureLookup,
            weights: weights,
            autoConvertGate: { candidate, _ in autoConvertGate(candidate) }
        )
    }

    /// R2 (docs/plans/hanja-context-scaling-plan.md §7): this function now runs in three passes —
    /// PASS 1 is the same per-segment computation as before R2 (unchanged), PASS 2 is a new
    /// clause-global joint candidate search across segments with ≥2 candidates (see
    /// HanjaClauseJointSelection.swift), PASS 3 is the same gate/promotion logic as before R2
    /// (unchanged), fed PASS 2's re-ordered candidate list. When PASS 2 doesn't run (fewer than
    /// two eligible segments, no association table, or more eligible segments than
    /// `HanjaJointSelectionLimits.maxSegments`) every segment's `jointBoosts` stays `[:]` and the
    /// result is byte-for-byte identical to R1 — pinned by
    /// `RealtimeContextRankingTests`/`HanjaClauseJointSelectionTests`.
    /// - Parameter associationBiasLookup: D3 (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷
    ///   명세" §3 candidate-profile bias slot), `(reading, hanja) -> raw bias`, backed by
    ///   `HanjaContextAssociationStore.bias(reading:hanja:)` in production. `nil` (the default) is
    ///   a full no-op — every existing call site keeps this parameter's default, so this addition
    ///   is behavior-preserving. When non-nil, PASS 1 builds a per-segment bias dictionary and
    ///   forwards it to `rankWithContextScored`'s `biases:` — ranking only. PASS 3's promotion
    ///   gate keeps reading PASS 1's `state.scores` (the association axis alone, no bias mixed in)
    ///   exactly as before — bias must never make a zero-matched-feature candidate pass the
    ///   `awaitsContextEvidence` gate (see `HanjaContextRanker.rankWithContextScored`'s `biases`
    ///   doc for the full invariant rationale).
    static func applyContextReranking(
        to segments: [HanjaSegment],
        clause: String,
        dominantMap: [String: String],
        candidateLookup: (String) -> [HanjaCandidate],
        winningTokens: [Token] = [],
        associationFeatureLookup: ((String, String) -> [String: Double]?)? = nil,
        associationBiasLookup: ((String, String) -> Double?)? = nil,
        weights: HanjaContextRankingWeights = .default,
        autoConvertGate: ((HanjaCandidate, POSTag) -> Bool)? = nil,
        sessionInputs: HanjaSessionScoringInputs? = nil
    ) -> [HanjaSegment] {
        guard !segments.isEmpty else {
            return segments
        }

        let context = clauseContextDominantHanja(clause: clause, segments: segments, dominantMap: dominantMap)
        // Token feature strings do not depend on the target span. Build them once, then apply
        // each span's exclusion before deduplication (repeated words outside the span still count).
        let contentTokens = associationFeatureLookup != nil
            ? contentTokenFeatures(from: winningTokens)
            : []

        // R1a (docs/plans/hanja-context-scaling-plan.md §6): a non-empty session snapshot keeps
        // reranking running even when this clause alone has no context/association evidence —
        // otherwise a session-only boost could never surface for a clause with no other signal.
        guard !context.isEmpty || !contentTokens.isEmpty || !(sessionInputs?.isEmpty ?? true) else {
            return segments
        }

        // PASS 1 (분절별, R1과 완전히 동일한 계산): segmentFeatures / candidates / association
        // scores / session boosts / rankWithContextScored. `scores`는 PASS 3의 승격 게이트
        // (`contextEvidence`)가 그대로 다시 읽는다 — 결합 보너스는 거기 절대 섞이지 않는다(R2
        // 승격 게이트 불변, docs/plans/hanja-context-scaling-plan.md §7).
        var perSegment: [PerSegmentJointRerankState] = segments.map { segment in
            // Self-exclusion (mirrors the offline collector's span exclusion): the segment's own
            // surface must not vote for its own candidates.
            let segmentFeatures = associationFeatureLookup != nil
                ? clauseContentFeatures(from: contentTokens, excludingRangeOverlapping: segment.sourceRange)
                : []

            // Step 7 (docs/plans/context-aware-hanja-conversion.md §10): segments suppressed by
            // the native-homograph gate carry `previewCandidate == nil` too, but they still need
            // reranking run so a positive-evidence top candidate can be promoted below. Segments
            // nil for any OTHER reason (tag-ineligible / preferHangul / step-6 gate) stay nil.
            guard segment.previewCandidate != nil || segment.awaitsContextEvidence else {
                return PerSegmentJointRerankState(segmentFeatures: segmentFeatures, scores: [:], ranked: [], jointEligible: false)
            }

            let candidates = candidateLookup(segment.normalizedLookupKey)
            let scores = associationFeatureLookup.map {
                associationScores(for: candidates, contextFeatures: segmentFeatures, lookup: $0)
            } ?? [:]

            // R1a: session boosts are computed per-segment and folded into ranking only — never
            // into `contextEvidence`/the promotion gate below. Deliberately does not exclude
            // segmentFeatures already counted by the clause axis (see sessionContextBoosts doc).
            let sessionBoosts = sessionInputs.map {
                sessionContextBoosts(
                    for: candidates,
                    reading: segment.normalizedLookupKey,
                    session: $0,
                    lookup: associationFeatureLookup,
                    weights: weights
                )
            } ?? [:]

            // D3: per-candidate bias dictionary, ranking-only (see `associationBiasLookup`'s doc
            // above and `rankWithContextScored`'s `biases` parameter doc) — never folded into
            // `scores`, which PASS 3's promotion gate reads unchanged.
            var biases: [String: Double] = [:]
            if let associationBiasLookup {
                for candidate in candidates {
                    if let bias = associationBiasLookup(candidate.reading, candidate.value) {
                        biases[candidate.value] = bias
                    }
                }
            }

            let ranked = rankWithContextScored(
                candidates: candidates,
                contextDominantHanja: context,
                associationScores: scores,
                weights: weights,
                segmentTag: segment.tag,
                sessionBoosts: sessionBoosts,
                biases: biases
            )

            // R2 결합 참여 자격 (docs/plans/hanja-context-scaling-plan.md §7): 재랭킹 대상이면서
            // 후보가 2개 이상이고 숫자 분절이 아닌 것. 숫자 분절은 previewCandidate가 애초에
            // 별도 경로(makeNumericSegments)로 결정되므로 결합 탐색에 끼워도 의미가 없다.
            let isNumericSegment = NumericHanjaCandidateGenerator.normalizedDigits(from: segment.surface) != nil
            let jointEligible = candidates.count >= 2 && !isNumericSegment

            return PerSegmentJointRerankState(segmentFeatures: segmentFeatures, scores: scores, ranked: ranked, jointEligible: jointEligible)
        }

        // PASS 2 (클로즈 전역, R2 신규 — docs/plans/hanja-context-scaling-plan.md §7): 참여
        // 분절이 2개 이상이고 연관표가 탑재됐고 참여 분절 수가 상한 이내이고 가중치가 양수일
        // 때만 돈다. 그 외에는 이 블록 전체가 no-op이라 PASS 3은 PASS 1이 만든 `ranked` 순서를
        // 그대로 보고, 모든 `jointBoosts`가 `[:]`로 남아 R1과 완전히 동일한 결과가 나온다(동일성
        // 불변식 — RealtimeContextRankingTests/HanjaClauseJointSelectionTests가 고정).
        //
        // `weights.jointDomainConsistency > 0` 가드(2026-07-25, 파킹 결정과 함께 추가): 이게
        // 없으면 가중치를 0으로 낮춰도 유사도 행렬 구축(최대 90회 코사인)과
        // `selectJointAssignment`의 3^n 조합 탐색이 그대로 실행된다 — pairBonus가 매번
        // `similarity × 0 = 0`을 반환할 뿐 계산 자체는 스킵되지 않는다는 것을 R2-3 측정이
        // 발견했다(docs/plans/hanja-context-eval-baseline.md "R2 클로즈 안 결합 선택 측정" §
        // TASK 2의 "놀란 점" 문단). 이 가드가 있어야 `HanjaContextRankingWeights.default`의
        // 파킹(jointDomainConsistency = 0)이 계산 비용까지 0으로 만든다 — maxSegments=5 경계에서
        // p95 ~3.15ms였던 조합 탐색을 통째로 건너뛴다.
        let participatingIndices = perSegment.indices.filter { perSegment[$0].jointEligible }
        if weights.jointDomainConsistency > 0,
           let associationFeatureLookup,
           participatingIndices.count >= 2,
           participatingIndices.count <= HanjaJointSelectionLimits.maxSegments {
            let topK = HanjaJointSelectionLimits.candidatesPerSegment
            let topKPerParticipant: [[(candidate: HanjaCandidate, boost: Double)]] = participatingIndices.map {
                Array(perSegment[$0].ranked.prefix(topK))
            }
            let jointInputs: [HanjaJointSegmentInput] = topKPerParticipant.map { entries in
                HanjaJointSegmentInput(
                    boosts: entries.map(\.boost),
                    profiles: entries.map { associationFeatureLookup($0.candidate.reading, $0.candidate.value) ?? [:] }
                )
            }

            // 참여 분절 쌍(i < j)의 상위 후보 조합별 프로필 유사도를 한 번씩만 계산해 메모이즈
            // 한다(참여 분절 ≤5, 분절당 후보 ≤3이라 최대 90쌍 — 계획 §7-1 "가독성 우선" 권고).
            var similarity = [[[[Double]]]](repeating: [], count: jointInputs.count)
            for i in 0..<jointInputs.count {
                var rowsForI = [[[Double]]](repeating: [], count: jointInputs.count)
                for j in (i + 1)..<jointInputs.count {
                    var row = [[Double]](
                        repeating: [Double](repeating: 0, count: jointInputs[j].profiles.count),
                        count: jointInputs[i].profiles.count
                    )
                    for candidateI in 0..<jointInputs[i].profiles.count {
                        for candidateJ in 0..<jointInputs[j].profiles.count {
                            row[candidateI][candidateJ] = associationProfileSimilarity(
                                jointInputs[i].profiles[candidateI], jointInputs[j].profiles[candidateJ]
                            )
                        }
                    }
                    rowsForI[j] = row
                }
                similarity[i] = rowsForI
            }

            let pairBonusScale = weights.jointDomainConsistency * Double(weights.association)
            let pairBonus: (Int, Int, Int, Int) -> Double = { i, candidateI, j, candidateJ in
                guard i != j else { return 0 }
                let (lower, higher, lowerCandidate, higherCandidate) = i < j
                    ? (i, j, candidateI, candidateJ)
                    : (j, i, candidateJ, candidateI)
                return similarity[lower][higher][lowerCandidate][higherCandidate] * pairBonusScale
            }

            let chosen = selectJointAssignment(segments: jointInputs, pairBonus: pairBonus)

            for (position, segmentIndex) in participatingIndices.enumerated() {
                let entries = topKPerParticipant[position]
                var jointBoosts: [String: Double] = [:]
                for candidateIndex in 0..<entries.count {
                    var sum = 0.0
                    for otherPosition in 0..<participatingIndices.count where otherPosition != position {
                        sum += pairBonus(position, candidateIndex, otherPosition, chosen[otherPosition])
                    }
                    if sum > 0 {
                        jointBoosts[entries[candidateIndex].candidate.value] = sum
                    }
                }

                // 선택 후보를 맨 앞으로, 나머지는 기존 순서 유지 (계획 §7-1의 결합 탐색 결과를
                // PASS 3의 게이트/승격 로직이 그대로 소비할 수 있는 형태로 반영).
                let chosenIndex = chosen[position]
                var reordered = perSegment[segmentIndex].ranked
                if chosenIndex > 0, chosenIndex < entries.count {
                    let winner = reordered.remove(at: chosenIndex)
                    reordered.insert(winner, at: 0)
                }

                perSegment[segmentIndex].ranked = reordered
                perSegment[segmentIndex].jointBoosts = jointBoosts
            }
        }

        // PASS 3 (분절별, R1과 완전히 동일한 게이트/승격 로직 — 입력만 PASS 2가 재정렬한 ranked).
        return zip(segments, perSegment).map { segment, state in
            guard segment.previewCandidate != nil || segment.awaitsContextEvidence else {
                return segment.replacingContext(context, features: state.segmentFeatures, previewCandidate: nil)
            }

            let reranked = state.ranked.map(\.candidate)

            let previewCandidate: HanjaCandidate?
            if segment.awaitsContextEvidence {
                // Promotion target = the FIRST candidate in reranked order that passes the step-6
                // word-evidence gate — not blindly `reranked.first`. Rationale (고장/姑藏/故障): a
                // rare candidate whose dictionary features happen to match the clause (姑藏's
                // definition mentions 수도) can win the rerank yet fail the step-6 gate; it must
                // not block a gate-passing candidate right behind it (故障) from being considered.
                // Skipping is for this promotion decision only — the candidate-panel order
                // (realtimeCandidates(for:)) is untouched. The chosen candidate must then carry
                // positive context evidence OF ITS OWN (step-4 containment/dominance axis or
                // step-5 association axis > 0) — a skipped candidate's evidence never transfers.
                // R2's joint bonus is deliberately excluded from this check (`state.scores` is
                // PASS 1's un-joint-boosted association scores) — joint boosts affect ranking
                // only, never the promotion gate. No such candidate => stay hangul (safe default).
                let promotable = reranked.first { !failsAutoConvertGate($0, tag: segment.tag, gate: autoConvertGate) }
                if let promotable,
                   contextEvidence(for: promotable, contextDominantHanja: context, associationScores: state.scores, weights: weights).hasPositiveEvidence {
                    previewCandidate = promotable
                } else {
                    previewCandidate = nil
                }
            } else {
                // Numeric segments bypass the gate (mirrors makeRealtimeSegments); their
                // previewCandidate is already nil coming in (see makeNumericSegments), so this
                // branch only matters if that ever changes.
                let isNumericSegment = NumericHanjaCandidateGenerator.normalizedDigits(from: segment.surface) != nil
                previewCandidate = isNumericSegment || !failsAutoConvertGate(reranked.first, tag: segment.tag, gate: autoConvertGate)
                    ? reranked.first
                    : nil
            }
            return segment.replacingContext(context, features: state.segmentFeatures, previewCandidate: previewCandidate, jointBoosts: state.jointBoosts)
        }
    }

    /// PASS 1↔2↔3 통신용 스크래치 상태 (R2, docs/plans/hanja-context-scaling-plan.md §7): 순수
    /// 튜플 대신 이름 붙인 구조체로 둔 이유는 필드가 5개라 위치 인자로는 가독성이 떨어져서다.
    private struct PerSegmentJointRerankState {
        let segmentFeatures: [String]
        /// PASS 1의 연관 축 원점수 — PASS 3의 승격 게이트가 그대로 다시 읽는다(결합 보너스가
        /// 섞이지 않도록, R2 승격 게이트 불변).
        let scores: [String: Double]
        var ranked: [(candidate: HanjaCandidate, boost: Double)]
        let jointEligible: Bool
        var jointBoosts: [String: Double] = [:]
    }

    /// Whether `candidate` should be blocked from becoming a `previewCandidate` by the step-6
    /// auto-convert gate (docs/plans/context-aware-hanja-conversion.md §9). `gate == nil` never
    /// blocks (pre-step-6 behavior); `candidate == nil` (no top candidate) never blocks either —
    /// there is nothing to preview regardless. `tag` is the segment's POS tag, forwarded so the
    /// gate can apply the NNP proper-noun evidence axis (see `hasAutoConvertWordEvidence`).
    private static func failsAutoConvertGate(
        _ candidate: HanjaCandidate?,
        tag: POSTag,
        gate: ((HanjaCandidate, POSTag) -> Bool)?
    ) -> Bool {
        guard let gate, let candidate else {
            return false
        }
        return !gate(candidate, tag)
    }

    /// Content-morpheme features (`form/TAG`, deduped, order of first appearance) from `tokens`,
    /// dropping any token whose range overlaps `excludedRange` (self-exclusion for the target
    /// segment). `excludedRange == nil` keeps every content-morpheme token.
    private static func clauseContentFeatures(
        from tokens: [Token],
        excludingRangeOverlapping excludedRange: NSRange?
    ) -> [String] {
        clauseContentFeatures(from: contentTokenFeatures(from: tokens), excludingRangeOverlapping: excludedRange)
    }

    private static func contentTokenFeatures(from tokens: [Token]) -> [(range: NSRange, feature: String)] {
        tokens.compactMap { token in
            guard isContextContentMorphemeTag(token.tag) else { return nil }
            return (NSRange(location: token.position, length: token.length), "\(token.form)/\(token.tag.description)")
        }
    }

    private static func clauseContentFeatures(
        from tokens: [(range: NSRange, feature: String)],
        excludingRangeOverlapping excludedRange: NSRange?
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            if let excludedRange, rangesOverlap(token.range, excludedRange) { continue }
            guard seen.insert(token.feature).inserted else { continue }
            result.append(token.feature)
        }
        return result
    }

    /// Groups `segments` into eojeols by the space characters in `clause` between their
    /// `sourceRange`s (segments with no space in the gap belong to the same eojeol), concatenates
    /// each eojeol's segment surfaces in order to reconstruct the josa-stripped eojeol reading
    /// (e.g. 상하 + 수도 → "상하수도"), then resolves both eojeol readings and individual segment
    /// surfaces through `dominantMap` via `contextDominantHanja(forEojeolReadings:dominantMap:)`.
    static func clauseContextDominantHanja(
        clause: String,
        segments: [HanjaSegment],
        dominantMap: [String: String]
    ) -> [String] {
        guard !segments.isEmpty else {
            return []
        }

        let ordered = segments.sorted { $0.sourceRange.location < $1.sourceRange.location }

        var eojeolReadings: [String] = []
        var currentReading = ordered[0].surface
        var previousEnd = ordered[0].sourceRange.location + ordered[0].sourceRange.length

        for segment in ordered.dropFirst() {
            let gapLength = segment.sourceRange.location - previousEnd
            let gapContainsSpace: Bool = {
                guard gapLength > 0,
                      let gapRange = Range(NSRange(location: previousEnd, length: gapLength), in: clause)
                else {
                    return false
                }

                return clause[gapRange].contains(" ")
            }()

            if gapContainsSpace {
                eojeolReadings.append(currentReading)
                currentReading = segment.surface
            } else {
                currentReading += segment.surface
            }

            previousEnd = segment.sourceRange.location + segment.sourceRange.length
        }
        eojeolReadings.append(currentReading)

        let individualSurfaces = ordered.map(\.surface)
        return contextDominantHanja(
            forEojeolReadings: eojeolReadings + individualSurfaces,
            dominantMap: dominantMap
        )
    }

    static func bestRealtimeSegments(
        from results: [TokenResult],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 },
        autoConvertGate: ((HanjaCandidate, POSTag) -> Bool)? = nil,
        nativeHomographLookup: ((String) -> Bool)? = nil
    ) -> [HanjaSegment] {
        bestRealtimeSegmentsWithWinningTokens(
            from: results,
            in: clause,
            candidateLookup: candidateLookup,
            hangulUsageLookup: hangulUsageLookup,
            autoConvertGate: autoConvertGate,
            nativeHomographLookup: nativeHomographLookup
        ).segments
    }

    /// Same selection as `bestRealtimeSegments` (convertibleLength, then `TokenResult.score`
    /// tie-break), but also returns the winning analysis's raw tokens — step 5c needs them to
    /// derive clause content-morpheme features for association scoring, without duplicating the
    /// selection loop or changing `bestRealtimeSegments`'s public signature.
    ///
    /// Functional-span containment guard: the top-SCORE analysis's non-hanja-eligible tokens
    /// (josa/어미/punctuation — see `isRealtimeHanjaEligibleTag`) define "functional spans". When
    /// scoring convertibleLength for every candidate analysis (including the top one), a
    /// convertible segment earns credit only if its `sourceRange` is NOT fully contained within a
    /// single functional span. This stops a lower-scored analysis from "winning" purely because it
    /// mis-tags a josa as a hanja-eligible POS (e.g. 이/JKS on the top analysis vs 이/NR or 이/MM on
    /// an alternative) — the alternative's spurious segment is zeroed out, so the top (correct)
    /// analysis ties or wins on convertibleLength and the score tie-break keeps it.
    /// Known limitation: if an alternative analysis instead MERGES the josa into a larger token
    /// (e.g. a hypothetical 배관이/NNG as one token), the merged segment's range no longer matches
    /// any single functional span exactly, so this guard does not zero it. Accepted for now — no
    /// such dictionary entries exist today.
    static func bestRealtimeSegmentsWithWinningTokens(
        from results: [TokenResult],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 },
        autoConvertGate: ((HanjaCandidate, POSTag) -> Bool)? = nil,
        nativeHomographLookup: ((String) -> Bool)? = nil
    ) -> (segments: [HanjaSegment], winningTokens: [Token]) {
        guard let topScoreResult = results.max(by: { $0.score < $1.score }) else {
            return ([], [])
        }
        let functionalSpans = Self.functionalSpans(from: topScoreResult.tokens)

        var bestSegments: [HanjaSegment] = []
        var bestTokens: [Token] = []
        var bestConvertibleLength = -1
        var bestScore = -Float.greatestFiniteMagnitude

        for result in results {
            let segments = makeRealtimeSegments(
                from: result.tokens,
                in: clause,
                candidateLookup: candidateLookup,
                hangulUsageLookup: hangulUsageLookup,
                autoConvertGate: autoConvertGate,
                nativeHomographLookup: nativeHomographLookup
            )
            let convertibleLength = segments
                .filter(\.isConvertible)
                .reduce(0) { total, segment in
                    isRangeFullyContained(segment.sourceRange, inAnyOf: functionalSpans)
                        ? total
                        : total + segment.sourceRange.length
                }

            if convertibleLength > bestConvertibleLength
                || (convertibleLength == bestConvertibleLength && result.score > bestScore) {
                bestSegments = segments
                bestTokens = result.tokens
                bestConvertibleLength = convertibleLength
                bestScore = result.score
            }
        }

        return (bestSegments, bestTokens)
    }

    /// UTF-16 ranges of `tokens` whose tag is NOT hanja-eligible (josa/어미/punctuation…) — the
    /// "functional spans" used by the containment guard in `bestRealtimeSegmentsWithWinningTokens`.
    private static func functionalSpans(from tokens: [Token]) -> [NSRange] {
        tokens.compactMap { token in
            guard !isRealtimeHanjaEligibleTag(token.tag), token.length > 0 else {
                return nil
            }
            return NSRange(location: token.position, length: token.length)
        }
    }

    /// Whether `range` is fully contained within a single span in `spans` (not merely overlapping).
    private static func isRangeFullyContained(_ range: NSRange, inAnyOf spans: [NSRange]) -> Bool {
        spans.contains { span in
            range.location >= span.location && (range.location + range.length) <= (span.location + span.length)
        }
    }

    /// Source-compatibility overload: forwards a tag-agnostic step-6 gate into the tag-aware
    /// primary below (the tag is ignored, reproducing pre-NNP-axis gating exactly). Kept so the
    /// pre-existing test fixtures that inject `(HanjaCandidate) -> Bool` gates compile unchanged.
    static func makeRealtimeSegments(
        from tokens: [Token],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 },
        autoConvertGate: @escaping (HanjaCandidate) -> Bool,
        nativeHomographLookup: ((String) -> Bool)? = nil
    ) -> [HanjaSegment] {
        makeRealtimeSegments(
            from: tokens,
            in: clause,
            candidateLookup: candidateLookup,
            hangulUsageLookup: hangulUsageLookup,
            autoConvertGate: { candidate, _ in autoConvertGate(candidate) },
            nativeHomographLookup: nativeHomographLookup
        )
    }

    static func makeRealtimeSegments(
        from tokens: [Token],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 },
        autoConvertGate: ((HanjaCandidate, POSTag) -> Bool)? = nil,
        nativeHomographLookup: ((String) -> Bool)? = nil
    ) -> [HanjaSegment] {
        let tokenSegments: [HanjaSegment] = tokens.compactMap { token -> HanjaSegment? in
            guard isRealtimeHanjaEligibleTag(token.tag),
                  token.length > 0
            else {
                return nil
            }

            let sourceRange = NSRange(location: token.position, length: token.length)
            guard let stringRange = Range(sourceRange, in: clause) else {
                return nil
            }

            let surface = String(clause[stringRange])
            let normalizedDigits = NumericHanjaCandidateGenerator.normalizedDigits(from: surface)
            let normalizedLookupKey = normalizedDigits ?? surface
            let candidates = candidateLookup(normalizedLookupKey)
            let topHanjaUsage = candidates.first?.usageCount ?? 0
            let hangulUsage = hangulUsageLookup(normalizedLookupKey)
            let preferHangul = hangulUsage > 0 && hangulUsage >= topHanjaUsage
            let allowsAutoConversion = isRealtimeAutoConvertEligibleTag(token.tag)
            // Step 6 (docs/plans/context-aware-hanja-conversion.md §9): numeric surfaces bypass
            // the word-evidence gate entirely (numeric segments never preview auto-convert to
            // begin with — see makeNumericSegments).
            let topCandidateFailsGate = normalizedDigits != nil
                ? false
                : failsAutoConvertGate(candidates.first, tag: token.tag, gate: autoConvertGate)
            // Step 7 (docs/plans/context-aware-hanja-conversion.md §10): a segment "would auto
            // convert" under the pre-step-7 rules (tag-eligible + not preferHangul + step-6 gate
            // passed + a top candidate exists). Numeric keys bypass the homograph check entirely,
            // mirroring the step-6 numeric bypass above.
            let wouldAutoConvert = !preferHangul && allowsAutoConversion && !topCandidateFailsGate
                && candidates.first != nil
            // Personalization bypass: the user's own confirmation history is the strongest
            // possible evidence — a top candidate they've picked before (usageCount > 0) or
            // defined themselves (.userDefined) skips the homograph suppression entirely, so one
            // manual pick of e.g. 故障 makes 고장 auto-convert from then on.
            let hasPersonalizationEvidence = candidates.first.map {
                $0.usageCount > 0 || $0.source == .userDefined
            } ?? false
            let isFlaggedHomograph = normalizedDigits == nil
                && wouldAutoConvert
                && !hasPersonalizationEvidence
                && (nativeHomographLookup?(normalizedLookupKey) ?? false)
            let previewCandidate: HanjaCandidate? = (wouldAutoConvert && !isFlaggedHomograph) ? candidates.first : nil
            return HanjaSegment(
                sourceRange: sourceRange,
                surface: surface,
                normalizedLookupKey: normalizedLookupKey,
                tag: token.tag,
                isConvertible: !candidates.isEmpty,
                previewCandidate: previewCandidate,
                awaitsContextEvidence: isFlaggedHomograph
            )
        }

        let numericSegments = makeNumericSegments(
            in: clause,
            candidateLookup: candidateLookup
        )
        guard !numericSegments.isEmpty else {
            return tokenSegments
        }

        return (tokenSegments.filter { tokenSegment in
            !numericSegments.contains { numericSegment in
                rangesOverlap(tokenSegment.sourceRange, numericSegment.sourceRange)
            }
        } + numericSegments)
        .sorted {
            if $0.sourceRange.location != $1.sourceRange.location {
                return $0.sourceRange.location < $1.sourceRange.location
            }

            return $0.sourceRange.length > $1.sourceRange.length
        }
    }

    /// 사용자가 그은 경계(`boundaries`)로 소스를 빈틈없이 분할해 `[HanjaSegment]`를 만든다. Kiwi 토큰 불필요.
    /// 각 span은 표면형으로 사전/숫자 후보를 조회해 후보가 있으면 변환 가능으로 본다.
    /// 의도적으로 POS 태그 필터를 적용하지 않는다 — 사용자가 명시적으로 경계를 그었으므로,
    /// 평소 자동 변환에서 제외되던 표면형(예: 조사)도 후보가 있으면 변환 가능으로 노출한다(설계 4.1 절충).
    static func makeManualSegments(
        boundaries: [Int],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate]
    ) -> [HanjaSegment] {
        guard !clause.isEmpty else {
            return []
        }

        let n = inputUTF16Length(of: clause)
        let internalPoints = Set(boundaries.filter { $0 > 0 && $0 < n })
        let edges = [0] + internalPoints.sorted() + [n]

        var segments: [HanjaSegment] = []
        for i in 0..<(edges.count - 1) {
            let range = NSRange(location: edges[i], length: edges[i + 1] - edges[i])
            guard range.length > 0, let stringRange = Range(range, in: clause) else {
                continue
            }

            let surface = String(clause[stringRange])
            let normalizedDigits = NumericHanjaCandidateGenerator.normalizedDigits(from: surface)
            let normalizedLookupKey = normalizedDigits ?? surface
            let candidates = candidateLookup(normalizedLookupKey)
            let isNumeric = normalizedDigits != nil
            // 후보가 있으면 첫 후보를 프리뷰(태그 필터 미적용). 숫자는 기존 UX대로 아라비아 표기 유지.
            let previewCandidate = (isNumeric || candidates.isEmpty) ? nil : candidates.first
            segments.append(
                HanjaSegment(
                    sourceRange: range,
                    surface: surface,
                    normalizedLookupKey: normalizedLookupKey,
                    tag: isNumeric ? .sn : .nng,
                    isConvertible: !candidates.isEmpty,
                    previewCandidate: previewCandidate
                )
            )
        }

        return segments
    }

    /// The other half of the step-5a offline↔runtime morpheme-space contract (recorded in
    /// scripts/hanja-context/README.md): tags whose tokens count as CONTENT morphemes for
    /// context-association features — NNG, NNP, VV, VV-I, VA, VA-I, MAG, XR, feature key
    /// `form/TAG` (TAG = `POSTag.description`). The offline collector
    /// (scripts/hanja-context/collector) uses the identical set; step 5c will use this in the
    /// production re-ranking path and the offline app-settings harness.
    static func isContextContentMorphemeTag(_ tag: POSTag) -> Bool {
        switch tag {
        case .nng, .nnp, .vv, .vvi, .va, .vai, .mag, .xr:
            return true
        default:
            return false
        }
    }

    static func isRealtimeHanjaEligibleTag(_ tag: POSTag) -> Bool {
        switch tag {
        case .nng, .nnp, .nnb,
             .nr, .np, .sn,
             .vv, .vvi,
             .va, .vai,
             .vx, .vxi,
             .mm, .mag, .maj, .ic,
             .xpn, .xsn, .xsv, .xsa, .xsai, .xr:
            return true
        default:
            return false
        }
    }

    private static func makeNumericSegments(
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate]
    ) -> [HanjaSegment] {
        var segments: [HanjaSegment] = []
        var spanStart: String.Index?
        var spanContainsDigit = false

        func flushSpan(before end: String.Index) {
            guard let start = spanStart, spanContainsDigit else {
                spanStart = nil
                spanContainsDigit = false
                return
            }

            let surface = String(clause[start..<end])
            guard let normalizedLookupKey = NumericHanjaCandidateGenerator.normalizedDigits(from: surface) else {
                spanStart = nil
                spanContainsDigit = false
                return
            }

            let candidates = candidateLookup(normalizedLookupKey)
            if !candidates.isEmpty {
                let sourceRange = NSRange(start..<end, in: clause)
                segments.append(
                    HanjaSegment(
                        sourceRange: sourceRange,
                        surface: surface,
                        normalizedLookupKey: normalizedLookupKey,
                        tag: .sn,
                        isConvertible: true,
                        previewCandidate: nil
                    )
                )
            }

            spanStart = nil
            spanContainsDigit = false
        }

        var index = clause.startIndex
        while index < clause.endIndex {
            let character = clause[index]
            if character == "," || NumericHanjaCandidateGenerator.isNumericStartCharacter(character) {
                if spanStart == nil {
                    spanStart = index
                }
                if NumericHanjaCandidateGenerator.isNumericStartCharacter(character) {
                    spanContainsDigit = true
                }
            } else {
                flushSpan(before: index)
            }

            index = clause.index(after: index)
        }

        flushSpan(before: clause.endIndex)
        return segments
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
    }

    static func isRealtimeAutoConvertEligibleTag(_ tag: POSTag) -> Bool {
        switch tag {
        case .np, .ic, .vx, .vxi, .xsv, .xsa, .xsai, .xsn:
            return false
        default:
            return isRealtimeHanjaEligibleTag(tag)
        }
    }

    private func drainPendingWarmUpCompletions() {
        guard !pendingWarmUpCompletions.isEmpty else {
            return
        }

        let completions = pendingWarmUpCompletions
        pendingWarmUpCompletions.removeAll()
        for completion in completions {
            completion()
        }
    }
}
