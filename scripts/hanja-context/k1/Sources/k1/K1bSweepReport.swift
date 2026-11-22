// k1b-sweep-report.md generation (docs/plans/hanja-context-scaling-plan.md §12 K1b follow-up).
import Foundation

func writeK1bSweepReport(
    holdoutTotalScored: Int,
    defGroup: SweepGroupStats, nonDefGroup: SweepGroupStats,
    sliceSize: Int, capPerBucket: Int,
    sweepTable: [String: [Int32: (n: Int, surfaced: Int, correct: Int)]],
    overallByTopN: [Int32: (n: Int, surfaced: Int, correct: Int)],
    msPerRowByTopN: [Int32: Double],
    baseElapsed: Double, totalElapsed: Double
) throws {
    var md = "# K1b topN sweep + definitional-subset split\n\n"
    md += "Follow-up to `k1b-gold-surfaced-diagnosis.md`. Reuses cached `baseline-stats.tsv` (estimated "
        + "at topN=30) — no corpus re-scan. Fresh holdout re-score at topN=30 took "
        + String(format: "%.1fs", baseElapsed) + "; total wall time " + String(format: "%.1fs", totalElapsed)
        + " (see §3 for the per-topN slice cost) — nowhere near the ~17-minute full pass.\n\n"

    // ================= Task 2 =================
    md += "## 1. Task 2 — definitional-sentence subset\n\n"
    md += "**Heuristic (conservative, as specified)**: target span at/near sentence start "
        + "(`span_start <= 5`, scalar/character offset) AND the sentence (after stripping trailing "
        + "punctuation) ends in one of `이다 / 이었다 / 였다 / 말한다 / 뜻한다`. Applied to all "
        + "\(holdoutTotalScored) scored holdout rows.\n\n"
    let total = defGroup.n + nonDefGroup.n
    md += "| group | n | % of scored | gold_surfaced | surfaced rate | K1 top1 (cond.) | floorA top1 (cond.) | floorB (cond., analytic) |\n"
    md += "|---|---:|---:|---:|---:|---:|---:|---:|\n"
    for (label, g) in [("definitional", defGroup), ("non-definitional", nonDefGroup)] {
        let surfRate = g.n > 0 ? Double(g.goldSurfaced) / Double(g.n) * 100 : 0
        let k1Top1 = g.goldSurfaced > 0 ? Double(g.correctGivenSurfaced) / Double(g.goldSurfaced) * 100 : 0
        let floorATop1 = g.goldSurfaced > 0 ? Double(g.floorACorrectGivenSurfaced) / Double(g.goldSurfaced) * 100 : 0
        let floorB = g.goldSurfaced > 0 ? g.floorBSumGivenSurfaced / Double(g.goldSurfaced) * 100 : 0
        md += String(format: "| %@ | %d | %.1f%% | %d | %.1f%% | %.1f%% | %.1f%% | %.1f%% |\n",
            label, g.n, Double(g.n) / Double(total) * 100, g.goldSurfaced, surfRate, k1Top1, floorATop1, floorB)
    }
    md += "\nFor reference: full holdout (both groups combined) K1 top1 conditional = 43.2% at 55.7% surfacing "
        + "(`k1b-gold-surfaced-diagnosis.md` §1-2); 258-row eval conditional = 12.3% at 70.8% surfacing (same doc §4).\n\n"

    let nonDefK1Top1 = nonDefGroup.goldSurfaced > 0 ? Double(nonDefGroup.correctGivenSurfaced) / Double(nonDefGroup.goldSurfaced) * 100 : 0
    let defK1Top1 = defGroup.goldSurfaced > 0 ? Double(defGroup.correctGivenSurfaced) / Double(defGroup.goldSurfaced) * 100 : 0
    md += "**Read**: "
    if nonDefK1Top1 <= 20 {
        md += String(format: "non-definitional top1 (%.1f%%) falls close to the 258-eval level (12.3%%) — "
            + "this supports the hypothesis that D1-seed holdout's 43.2%% is inflated by easy definitional "
            + "sentences, and the eval set's 12.3%% is closer to a real-world expectation than the unconditional "
            + "holdout number.\n\n", nonDefK1Top1)
    } else if nonDefK1Top1 < defK1Top1 - 5 {
        md += String(format: "non-definitional top1 (%.1f%%) is meaningfully lower than definitional (%.1f%%), "
            + "consistent with the hypothesis's DIRECTION, but still well above the 258-eval's 12.3%% — "
            + "definitional-sentence ease explains PART of the gap, not all of it. Something else about the "
            + "258-row eval set (composition, sentence length, topic mix) likely also contributes.\n\n",
            nonDefK1Top1, defK1Top1)
    } else {
        md += String(format: "non-definitional top1 (%.1f%%) is NOT meaningfully lower than definitional (%.1f%%) "
            + "— the hypothesis does NOT hold as stated. The 258-eval gap has some other cause, not (primarily) "
            + "definitional-sentence ease.\n\n", nonDefK1Top1, defK1Top1)
    }
    md += "**Hand-check precision**: see `definitional-handcheck-sample.tsv` (40 flagged-definitional + 20 "
        + "flagged-non-definitional rows, file order) — graded by the agent directly (same self-grading "
        + "limitation as D1's precision check: the party that built the heuristic is scoring its own output, "
        + "weaker evidence than independent review). **[FILLED IN AFTER MANUAL READ — see chat report, this "
        + "line is a placeholder in the auto-generated file]**\n\n"

    // ================= Task 1 =================
    md += "## 2. Task 1 — topN sweep (surfacing rate, the primary output)\n\n"
    md += String(format: "Candidate-count-stratified slice: **%d rows** (cap %d/bucket, deterministic first-N "
        + "in file order per bucket — every band represented, none swamped by 3-5/6-10).\n\n", sliceSize, capPerBucket)
    md += "| candidate count | n | surfaced@30 | rate@30 | surfaced@100 | rate@100 | surfaced@300 | rate@300 |\n"
    md += "|---|---:|---:|---:|---:|---:|---:|---:|\n"
    for bucket in candidateCountBucketOrder {
        guard let byTopN = sweepTable[bucket] else { continue }
        let e30 = byTopN[30] ?? (0, 0, 0)
        let e100 = byTopN[100] ?? (0, 0, 0)
        let e300 = byTopN[300] ?? (0, 0, 0)
        md += String(format: "| %@ | %d | %d | %.1f%% | %d | %.1f%% | %d | %.1f%% |\n", bucket, e30.n,
            e30.surfaced, e30.n > 0 ? Double(e30.surfaced) / Double(e30.n) * 100 : 0,
            e100.surfaced, e100.n > 0 ? Double(e100.surfaced) / Double(e100.n) * 100 : 0,
            e300.surfaced, e300.n > 0 ? Double(e300.surfaced) / Double(e300.n) * 100 : 0)
    }
    md += "\n**Overall (unweighted slice average — NOT population-representative since small bands are "
        + "over-sampled relative to their true holdout share; read the per-bucket rows above, not this row, "
        + "as the finding)**:\n\n| topN | n | surfaced | rate |\n|---|---:|---:|---:|\n"
    for topN: Int32 in [30, 100, 300] {
        guard let e = overallByTopN[topN] else { continue }
        md += String(format: "| %d | %d | %d | %.1f%% |\n", topN, e.n, e.surfaced, e.n > 0 ? Double(e.surfaced) / Double(e.n) * 100 : 0)
    }

    md += "\n### Saturation read\n\n"
    let bands11to20 = sweepTable["11-20"] ?? [:]
    let bands21plus = sweepTable["21+"] ?? [:]
    func rate(_ e: (n: Int, surfaced: Int, correct: Int)?) -> Double { guard let e, e.n > 0 else { return 0 }; return Double(e.surfaced) / Double(e.n) * 100 }
    let r11_30 = rate(bands11to20[30]), r11_100 = rate(bands11to20[100]), r11_300 = rate(bands11to20[300])
    let r21_30 = rate(bands21plus[30]), r21_100 = rate(bands21plus[100]), r21_300 = rate(bands21plus[300])
    md += String(format: "11-20 band: %.1f%% (topN=30) -> %.1f%% (topN=100) -> %.1f%% (topN=300). "
        + "21+ band: %.1f%% -> %.1f%% -> %.1f%%.\n\n", r11_30, r11_100, r11_300, r21_30, r21_100, r21_300)
    let bestHighBand = max(r11_300, r21_300)
    if bestHighBand >= 90 {
        md += "Surfacing **saturates near/above 90%** by topN=300 in the previously-worst bands — enumeration "
            + "alone recovers most of the gap. The offline-teacher path needs no new API; `pretokenized` is "
            + "avoidable for this purpose.\n\n"
    } else if bestHighBand - min(r11_30, r21_30) >= 15 {
        md += "Surfacing **improves substantially but plateaus short of ~90%** — enumeration recovers part of "
            + "the gap but not all of it. Raising topN is a legitimate free lever to combine with, but "
            + "`pretokenized` is likely still needed to close the remainder for the highest-candidate-count "
            + "readings.\n\n"
    } else {
        md += "Surfacing **does not meaningfully improve** with topN in the worst bands — enumeration alone is "
            + "NOT sufficient. This points toward `pretokenized` (or another non-enumeration mechanism) as "
            + "necessary, not just preferable, for the high-candidate-count tail.\n\n"
    }

    md += "### Indicative accuracy at topN=100/300 (NOT a headline)\n\n"
    md += "**Computed against topN=30 baselines** (`baseline-stats.tsv` was accumulated at topN=30 — more "
        + "occurrences would verify and more senses would surface at higher topN, shifting the true means). "
        + "This mixes a topN=30-fitted centering with topN=100/300 scores and is reported only as a rough "
        + "indicator, never as a clean result.\n\n| topN | n | correct (indicative) | rate |\n|---|---:|---:|---:|\n"
    for topN: Int32 in [30, 100, 300] {
        guard let e = overallByTopN[topN] else { continue }
        md += String(format: "| %d | %d | %d | %.1f%% |\n", topN, e.n, e.correct, e.n > 0 ? Double(e.correct) / Double(e.n) * 100 : 0)
    }

    md += "\n### Cost (for pricing the full re-measurement)\n\n| topN | ms/row |\n|---|---:|\n"
    for topN: Int32 in [30, 100, 300] {
        guard let ms = msPerRowByTopN[topN] else { continue }
        md += String(format: "| %d | %.3f |\n", topN, ms)
    }
    if let ms30 = msPerRowByTopN[30], let ms300 = msPerRowByTopN[300] {
        let fullHoldout = 23986.0
        md += String(format: "\nProjected full-holdout (%d rows) cost: topN=30 ~%.0fs (measured directly above), "
            + "topN=300 ~%.0fs if re-scanning ALL rows at topN=300 (this run only swept the stratified slice).\n",
            Int(fullHoldout), ms30 * fullHoldout / 1000, ms300 * fullHoldout / 1000)
    }

    try md.write(to: Paths.outDir.appendingPathComponent("k1b-sweep-report.md"), atomically: true, encoding: .utf8)
    print("wrote \(Paths.outDir.appendingPathComponent("k1b-sweep-report.md").path)")
}
