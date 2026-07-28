// replicate: reproduces the pre-registered 2026-07-25 measurements in 연구 문서 §3.6 — the
// stop-or-go gate for the K1 track (docs/plans/hanja-context-scaling-plan.md §12 K1a, item 2).
import CKiwi
import Foundation

struct ReplicateStats: Codable {
    var donor: String
    var aliasReading: String
    var aliasSenseId: Int
    var gapDefinition: String
    var contextGapWaterBill: Double?
    var contextGapCapital: Double?
    var contextOnlyNatsDelta: Double?
    var referenceWaterBillGap: Double
    var referenceCapitalGap: Double
    var referenceContextOnlyNats: Double
    var tokenScoreGapWaterBill: Double?
    var tokenScoreGapCapital: Double?
    var statsBorrowExactMatch: [String: Bool]
    var buildTimeBaselineSec: Double
    var buildTimeWithRegistrationsSec: Double
    var referenceBuildTimeBaselineSec: Double
    var referenceBuildTimeWithRegistrationsSec: Double
    var analysisLatencyMsPerSentenceTopN1: Double
    var referenceAnalysisLatencyRangeMs: [Double]
    var sentencesTimedForLatency: Int
}

/// Best (highest, i.e. least-negative) whole-parse log-probability among the topN candidates
/// whose `form` token resolves to each senseId. Unlike a token's own isolated LM score, the
/// whole-parse prob also reflects how the chosen sense shifts the probability of the tokens that
/// FOLLOW it (Kiwi's CoNg LM conditions later tokens on earlier ones) — this is what reproduces
/// the pre-registered gap numbers; the isolated per-token score does not (see tokenScoreGap*,
/// kept only as a diagnostic contrast).
func bestParseProbPerSense(_ results: [AnalysisResultRaw], form: String) -> [Int: Float] {
    var out: [Int: Float] = [:]
    for r in results {
        guard let tok = r.tokens.first(where: { $0.form == form }) else { continue }
        out[tok.senseId] = out[tok.senseId].map { Swift.max($0, r.prob) } ?? r.prob
    }
    return out
}

/// Per-sense representative TOKEN score (not whole-parse prob) — used only for the
/// statistics-borrowing check, where we want the morpheme's own LM statistics in isolation
/// (donor-borrowed stats should make 쑤도#s1 and 수도#s1 score identically at the token level,
/// regardless of parse-level propagation effects).
func bestTokenScorePerSense(_ results: [AnalysisResultRaw], form: String) -> [Int: Float] {
    var out: [Int: Float] = [:]
    for r in results {
        for t in r.tokens where t.form == form {
            out[t.senseId] = out[t.senseId].map { Swift.max($0, t.score) } ?? t.score
        }
    }
    return out
}

func runReplicate() throws {
    print("=== replicate ===")
    let donor = "상수도"
    let waterBillSentence = "수도 요금"
    let capitalSentence = "대한민국의 수도는 서울"
    let waterBillSentenceFake = "쑤도 요금"
    let capitalSentenceFake = "대한민국의 쑤도는 서울"

    // --- 1. warm-up build time: baseline vs with registrations ---
    let baselineStart = Date()
    _ = try KiwiBuilderRaw(modelPath: Paths.modelDir.path).build()
    let baselineElapsed = Date().timeIntervalSince(baselineStart)

    let regStart = Date()
    let builder = try KiwiBuilderRaw(modelPath: Paths.modelDir.path)
    let rc1 = builder.addAliasWordWithDef(alias: "수도", pos: "NNG", senseId: 1, dialect: 0, score: 0, origWord: donor)
    let rc2 = builder.addAliasWordWithDef(alias: "쑤도", pos: "NNG", senseId: 1, dialect: 0, score: 0, origWord: donor)
    guard rc1 == 0 else { fail(kiwiLastError("register 수도#s1 <- \(donor) failed (rc=\(rc1))").description) }
    guard rc2 == 0 else { fail(kiwiLastError("register 쑤도#s1 <- \(donor) failed (rc=\(rc2))").description) }
    let kiwi = try builder.build()
    let regElapsed = Date().timeIntervalSince(regStart)
    print(String(
        format: "build time: baseline=%.3fs withRegistrations=%.3fs (reference: baseline 1.07s, withReg 1.01s — no increase expected)",
        baselineElapsed, regElapsed))

    // --- 2. context gap ---
    let topNForSense: Int32 = 30
    let waterResults = try kiwi.analyze(waterBillSentence, topN: topNForSense, matchOptionsRaw: Contract.matchOptionsRaw)
    let capitalResults = try kiwi.analyze(capitalSentence, topN: topNForSense, matchOptionsRaw: Contract.matchOptionsRaw)

    let gapDefinition = "bestParseProb(수도#sense=0) - bestParseProb(수도#sense=1): the whole-candidate-parse "
        + "log-probability (kiwi_res_prob), max over the topN=\(topNForSense) candidates whose 수도 token "
        + "resolves to that sense — NOT the token's own isolated LM score (see tokenScoreGap* below, which "
        + "does not reproduce the reference numbers)."
    print("gap definition: \(gapDefinition)")

    let waterParseProbs = bestParseProbPerSense(waterResults, form: "수도")
    let capitalParseProbs = bestParseProbPerSense(capitalResults, form: "수도")
    print("water-bill context ('\(waterBillSentence)') 수도 per-sense best parse prob: \(waterParseProbs)")
    print("capital context ('\(capitalSentence)') 수도 per-sense best parse prob: \(capitalParseProbs)")

    var waterGap: Double?
    var capitalGap: Double?
    if let s0 = waterParseProbs[0], let s1 = waterParseProbs[1] { waterGap = Double(s0 - s1) }
    if let s0 = capitalParseProbs[0], let s1 = capitalParseProbs[1] { capitalGap = Double(s0 - s1) }
    if let waterGap { print(String(format: "water-bill gap = %.3f (reference 1.55)", waterGap)) }
    else { print("water-bill gap: could not find both sense=0 and sense=1 among topN candidates") }
    if let capitalGap { print(String(format: "capital gap = %.3f (reference 6.69)", capitalGap)) }
    else { print("capital gap: could not find both sense=0 and sense=1 among topN candidates") }
    if let waterGap, let capitalGap {
        print(String(format: "context-only delta = %.3f nats (reference ~5.1)", capitalGap - waterGap))
    }

    // Diagnostic contrast: the isolated per-token LM score gap (does NOT match the reference —
    // recorded here as a methodological note, not a second attempt at the same measurement).
    let waterTokenScores = bestTokenScorePerSense(waterResults, form: "수도")
    let capitalTokenScores = bestTokenScorePerSense(capitalResults, form: "수도")
    var tokenGapWater: Double?
    var tokenGapCapital: Double?
    if let s0 = waterTokenScores[0], let s1 = waterTokenScores[1] { tokenGapWater = Double(s0 - s1) }
    if let s0 = capitalTokenScores[0], let s1 = capitalTokenScores[1] { tokenGapCapital = Double(s0 - s1) }
    print("(diagnostic, NOT the reported gap) isolated token-score gap: water=\(tokenGapWater.map { String(format: "%.3f", $0) } ?? "n/a") "
        + "capital=\(tokenGapCapital.map { String(format: "%.3f", $0) } ?? "n/a") — differs from the whole-parse-prob "
        + "gap because the chosen sense also shifts the LM's conditional probability of the tokens that follow it.")

    // --- 3. statistics-borrowing check: 쑤도 (nonexistent form) registered against the SAME
    // donor must score identically to 수도#s1 in the same context, at the TOKEN level. ---
    let waterFakeResults = try kiwi.analyze(waterBillSentenceFake, topN: topNForSense, matchOptionsRaw: Contract.matchOptionsRaw)
    let capitalFakeResults = try kiwi.analyze(capitalSentenceFake, topN: topNForSense, matchOptionsRaw: Contract.matchOptionsRaw)
    let waterFakeTokenScores = bestTokenScorePerSense(waterFakeResults, form: "쑤도")
    let capitalFakeTokenScores = bestTokenScorePerSense(capitalFakeResults, form: "쑤도")

    print("statistics-borrowing check (쑤도#s1 vs 수도#s1 token score, same donor \(donor)):")
    var borrowMatches: [String: Bool] = [:]
    if let realS1 = waterTokenScores[1], let fakeS1 = waterFakeTokenScores[1] {
        let match = realS1 == fakeS1
        borrowMatches["water_bill_context"] = match
        print(String(format: "  water-bill: 수도#s1=%.6f 쑤도#s1=%.6f exactMatch=%@", realS1, fakeS1, match ? "YES" : "NO"))
    } else {
        print("  water-bill: could not find sense=1 for both forms among topN candidates")
    }
    if let realS1 = capitalTokenScores[1], let fakeS1 = capitalFakeTokenScores[1] {
        let match = realS1 == fakeS1
        borrowMatches["capital_context"] = match
        print(String(format: "  capital: 수도#s1=%.6f 쑤도#s1=%.6f exactMatch=%@", realS1, fakeS1, match ? "YES" : "NO"))
    } else {
        print("  capital: could not find sense=1 for both forms among topN candidates")
    }

    // --- 4. topN=1 latency, over the full eval set (registrations present, matching how this
    // kiwi instance would actually be used) ---
    let evalSentences = try dataLines(of: Paths.evalTSV).compactMap { line -> String? in
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard !cols.isEmpty, !cols[0].isEmpty else { return nil }
        return String(cols[0])
    }
    guard !evalSentences.isEmpty else { fail("eval TSV produced 0 sentences for latency measurement") }
    let latencyStart = Date()
    for sentence in evalSentences {
        _ = try kiwi.analyze(sentence, topN: Contract.topN, matchOptionsRaw: Contract.matchOptionsRaw)
    }
    let latencyElapsed = Date().timeIntervalSince(latencyStart)
    let msPerSentence = (latencyElapsed / Double(evalSentences.count)) * 1000
    print(String(
        format: "topN=1 analysis latency: %.4f ms/sentence over %d sentences (reference 0.18~0.22ms/sentence)",
        msPerSentence, evalSentences.count))

    try ensureOutDir()
    let stats = ReplicateStats(
        donor: donor,
        aliasReading: "수도",
        aliasSenseId: 1,
        gapDefinition: gapDefinition,
        contextGapWaterBill: waterGap,
        contextGapCapital: capitalGap,
        contextOnlyNatsDelta: (waterGap != nil && capitalGap != nil) ? (capitalGap! - waterGap!) : nil,
        referenceWaterBillGap: 1.55,
        referenceCapitalGap: 6.69,
        referenceContextOnlyNats: 5.1,
        tokenScoreGapWaterBill: tokenGapWater,
        tokenScoreGapCapital: tokenGapCapital,
        statsBorrowExactMatch: borrowMatches,
        buildTimeBaselineSec: baselineElapsed,
        buildTimeWithRegistrationsSec: regElapsed,
        referenceBuildTimeBaselineSec: 1.07,
        referenceBuildTimeWithRegistrationsSec: 1.01,
        analysisLatencyMsPerSentenceTopN1: msPerSentence,
        referenceAnalysisLatencyRangeMs: [0.18, 0.22],
        sentencesTimedForLatency: evalSentences.count
    )
    try writeJSON(stats, to: Paths.outDir.appendingPathComponent("replicate-stats.json"))
}
