// Background warm-up of Kiwi morphological analyzer.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi

@MainActor
final class KiwiAnalysisService {
    private static let realtimeAnalysisCandidateCount = 3

    /// Kiwi match options for the realtime conversion path. Also one half of the step-5a
    /// offline↔runtime morpheme-space contract (see scripts/hanja-context/README.md): the offline
    /// corpus collector (scripts/hanja-context/collector) analyzes with exactly these options,
    /// and `KiwiOfflinePipelineConsistencyTests` pins the equivalence against its
    /// `dump-tokens` output.
    static let realtimeAnalysisMatchOptions: MatchOptions = [.allWithNormalizing, .joinNounPrefix, .joinNounSuffix]

    /// Step 6 — auto-convert word evidence gate threshold (docs/plans/context-aware-hanja-conversion.md
    /// §9). Decoded freq-hanjaeo.txt 하위값 실측: 고유어 충돌어(단자 훈음 후보 등) ≤104 — 牛李 92,
    /// 南無 104, 可知 102, 加持 88, 茄子 66 — vs 정당한 한자어 ≥1,516 — 口頭 1,516, 水道 2,106,
    /// 修道 2,737, 故障 7,492, 首都 11,750. 500 splits the two bands.
    static let autoConvertWordEvidenceThreshold = 500

    /// Whether `candidate` has word-level evidence for auto-conversion (step 6). Gates
    /// `previewCandidate` only — `isConvertible` (candidate-panel access) is untouched by this.
    static func hasAutoConvertWordEvidence(
        _ candidate: HanjaCandidate,
        wordFrequency: (String) -> Int,
        threshold: Int = autoConvertWordEvidenceThreshold
    ) -> Bool {
        candidate.source == .userDefined
            || candidate.usageCount > 0
            || wordFrequency(candidate.value) >= threshold
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
        guard !clause.isEmpty, let kiwi else {
            return []
        }

        let candidateLookup: (String) -> [HanjaCandidate] = { key in
            let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
            return numericCandidates.isEmpty ? hanjaService.exactCandidates(for: key) : numericCandidates
        }

        // Step 6 — auto-convert word evidence gate (docs/plans/context-aware-hanja-conversion.md
        // §9). Fails open (nil gate = pre-step-6 behavior) when the word frequency table hasn't
        // loaded any rows, since there's nothing to distinguish word evidence from character
        // evidence with.
        let autoConvertGate: ((HanjaCandidate) -> Bool)? = hanjaService.hasWordFrequencyData
            ? { candidate in
                Self.hasAutoConvertWordEvidence(candidate, wordFrequency: hanjaService.wordFrequency(for:))
            }
            : nil

        // Step 7 — native-homograph gate (docs/plans/context-aware-hanja-conversion.md §10).
        let nativeHomographLookup: (String) -> Bool = hanjaService.isNativeHomographReading(_:)

        do {
            let results = try kiwi.analyze(
                clause,
                topN: Self.realtimeAnalysisCandidateCount,
                options: Self.realtimeAnalysisMatchOptions
            )
            let best = Self.bestRealtimeSegmentsWithWinningTokens(
                from: results,
                in: clause,
                candidateLookup: candidateLookup,
                hangulUsageLookup: hanjaService.hangulUsageCount(for:),
                autoConvertGate: autoConvertGate,
                nativeHomographLookup: nativeHomographLookup
            )

            guard HanjaSettingsStore.shared.useContextHanjaRanking,
                  let dominantMap = hanjaService.dominantHanjaMap,
                  !dominantMap.isEmpty
            else {
                return best.segments
            }

            // Step 5c — corpus association scoring (docs/plans/context-aware-hanja-conversion.md
            // §7 5c). Passed only when the store finished loading; nil otherwise keeps this
            // identical to step 4b's containment-only reranking.
            let associationStore = HanjaContextAssociationStore.shared
            let associationFeatureLookup: ((String, String) -> [String: UInt8]?)? = associationStore.isAvailable
                ? { reading, hanja in associationStore.features(reading: reading, hanja: hanja) }
                : nil

            return Self.applyContextReranking(
                to: best.segments,
                clause: clause,
                dominantMap: dominantMap,
                candidateLookup: candidateLookup,
                winningTokens: Self.stableWinningTokens(from: best.winningTokens, composingTailStart: composingTailStart),
                associationFeatureLookup: associationFeatureLookup,
                autoConvertGate: autoConvertGate
            )
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
    static func applyContextReranking(
        to segments: [HanjaSegment],
        clause: String,
        dominantMap: [String: String],
        candidateLookup: (String) -> [HanjaCandidate],
        winningTokens: [Token] = [],
        associationFeatureLookup: ((String, String) -> [String: UInt8]?)? = nil,
        weights: HanjaContextRankingWeights = .default,
        autoConvertGate: ((HanjaCandidate) -> Bool)? = nil
    ) -> [HanjaSegment] {
        guard !segments.isEmpty else {
            return segments
        }

        let context = clauseContextDominantHanja(clause: clause, segments: segments, dominantMap: dominantMap)
        let clauseFeatures = associationFeatureLookup != nil
            ? clauseContentFeatures(from: winningTokens, excludingRangeOverlapping: nil)
            : []

        guard !context.isEmpty || !clauseFeatures.isEmpty else {
            return segments
        }

        return segments.map { segment in
            // Self-exclusion (mirrors the offline collector's span exclusion): the segment's own
            // surface must not vote for its own candidates.
            let segmentFeatures = associationFeatureLookup != nil
                ? clauseContentFeatures(from: winningTokens, excludingRangeOverlapping: segment.sourceRange)
                : []

            // Step 7 (docs/plans/context-aware-hanja-conversion.md §10): segments suppressed by
            // the native-homograph gate carry `previewCandidate == nil` too, but they still need
            // reranking run so a positive-evidence top candidate can be promoted below. Segments
            // nil for any OTHER reason (tag-ineligible / preferHangul / step-6 gate) stay nil.
            guard segment.previewCandidate != nil || segment.awaitsContextEvidence else {
                return segment.replacingContext(context, features: segmentFeatures, previewCandidate: nil)
            }

            let candidates = candidateLookup(segment.normalizedLookupKey)
            let scores = associationFeatureLookup.map {
                associationScores(for: candidates, contextFeatures: segmentFeatures, lookup: $0)
            } ?? [:]

            let reranked = rankWithContext(
                candidates: candidates,
                contextDominantHanja: context,
                associationScores: scores,
                weights: weights
            )

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
                // No such candidate => stay hangul (safe default).
                let promotable = reranked.first { !failsAutoConvertGate($0, gate: autoConvertGate) }
                if let promotable,
                   contextEvidence(for: promotable, contextDominantHanja: context, associationScores: scores, weights: weights).hasPositiveEvidence {
                    previewCandidate = promotable
                } else {
                    previewCandidate = nil
                }
            } else {
                // Numeric segments bypass the gate (mirrors makeRealtimeSegments); their
                // previewCandidate is already nil coming in (see makeNumericSegments), so this
                // branch only matters if that ever changes.
                let isNumericSegment = NumericHanjaCandidateGenerator.normalizedDigits(from: segment.surface) != nil
                previewCandidate = isNumericSegment || !failsAutoConvertGate(reranked.first, gate: autoConvertGate)
                    ? reranked.first
                    : nil
            }
            return segment.replacingContext(context, features: segmentFeatures, previewCandidate: previewCandidate)
        }
    }

    /// Whether `candidate` should be blocked from becoming a `previewCandidate` by the step-6
    /// auto-convert gate (docs/plans/context-aware-hanja-conversion.md §9). `gate == nil` never
    /// blocks (pre-step-6 behavior); `candidate == nil` (no top candidate) never blocks either —
    /// there is nothing to preview regardless.
    private static func failsAutoConvertGate(
        _ candidate: HanjaCandidate?,
        gate: ((HanjaCandidate) -> Bool)?
    ) -> Bool {
        guard let gate, let candidate else {
            return false
        }
        return !gate(candidate)
    }

    /// Content-morpheme features (`form/TAG`, deduped, order of first appearance) from `tokens`,
    /// dropping any token whose range overlaps `excludedRange` (self-exclusion for the target
    /// segment). `excludedRange == nil` keeps every content-morpheme token.
    private static func clauseContentFeatures(
        from tokens: [Token],
        excludingRangeOverlapping excludedRange: NSRange?
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            guard isContextContentMorphemeTag(token.tag) else { continue }
            let tokenRange = NSRange(location: token.position, length: token.length)
            if let excludedRange, rangesOverlap(tokenRange, excludedRange) { continue }

            let feature = "\(token.form)/\(token.tag.description)"
            guard !seen.contains(feature) else { continue }
            seen.insert(feature)
            result.append(feature)
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
        autoConvertGate: ((HanjaCandidate) -> Bool)? = nil,
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
        autoConvertGate: ((HanjaCandidate) -> Bool)? = nil,
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

    static func makeRealtimeSegments(
        from tokens: [Token],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 },
        autoConvertGate: ((HanjaCandidate) -> Bool)? = nil,
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
                : failsAutoConvertGate(candidates.first, gate: autoConvertGate)
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
    /// production re-ranking path. Not referenced by the realtime path yet — additive only.
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
