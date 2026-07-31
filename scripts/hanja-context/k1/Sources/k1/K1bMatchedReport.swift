// k1b-matched-report.md generation.
import Foundation

func writeK1bMatchedReport(
    sliceSize: Int, occurrenceCapPerReading: Int,
    sliceReadingsCount: Int, readingsWithOcc: Int, totalOccToVerify: Int,
    verified: Int, verifyElapsed: Double,
    matchedScored: [ScoredRow], droppedForNoMatchedBaseline: Int,
    eval31Group: SweepGroupStats, restGroup: SweepGroupStats,
    eval31Unconditional: (correct: Int, floorA: Int, floorBSum: Double, n: Int),
    restUnconditional: (correct: Int, floorA: Int, floorBSum: Double, n: Int),
    evalReadingsCount: Int,
    totalElapsed: Double
) throws {
    var md = "# K1b decisive matched-topN test + 31-reading eval-composition subset\n\n"
    md += String(format: "Coordinator follow-up after the topN sweep flagged a selection-effect risk. Cost: %d cached "
        + "occurrences re-verified at topN=300 in %.1fs, slice re-scored at topN=300 with matched baselines; "
        + "total wall time %.1fs. No corpus re-scan, no re-tuning.\n\n", totalOccToVerify, verifyElapsed, totalElapsed)

    // ================= Task A =================
    md += "## 1. Decisive test — matched-topN=300 baselines on the slice\n\n"
    md += String(format: "Re-estimated baselines from %d cached occurrences (cap %d/reading) across %d/%d slice "
        + "readings (the rest had 0 cached occurrences available). %d/%d slice rows retained a matched baseline "
        + "(%d dropped: gold pair had 0 verified occurrences at topN=300 in this small resample — a coverage "
        + "cost of subsampling, reported not hidden).\n\n",
        totalOccToVerify, occurrenceCapPerReading, readingsWithOcc, sliceReadingsCount,
        matchedScored.count, matchedScored.count + droppedForNoMatchedBaseline, droppedForNoMatchedBaseline)

    let n = matchedScored.count
    let surfaced = matchedScored.filter(\.goldSurfaced).count
    let correct = matchedScored.filter(\.correct).count
    let floorACorrect = matchedScored.filter(\.floorACorrect).count
    let floorBSum = matchedScored.map(\.floorBExpected).reduce(0, +)
    let conditioned = matchedScored.filter(\.goldSurfaced)
    let condCorrect = conditioned.filter(\.correct).count
    let condFloorA = conditioned.filter(\.floorACorrect).count
    let condFloorBSum = conditioned.map(\.floorBExpected).reduce(0, +)

    md += "| | n | surfaced | rate | K1 unconditional | K1 conditional | floorA unconditional | floorA conditional | floorB uncond. | floorB cond. |\n"
    md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
    md += String(format: "| **matched topN=300** | %d | %d | %.1f%% | %.1f%% | %.1f%% | %.1f%% | %.1f%% | %.1f%% | %.1f%% |\n",
        n, surfaced, n > 0 ? Double(surfaced) / Double(n) * 100 : 0,
        n > 0 ? Double(correct) / Double(n) * 100 : 0, surfaced > 0 ? Double(condCorrect) / Double(surfaced) * 100 : 0,
        n > 0 ? Double(floorACorrect) / Double(n) * 100 : 0, surfaced > 0 ? Double(condFloorA) / Double(surfaced) * 100 : 0,
        n > 0 ? floorBSum / Double(n) * 100 : 0, surfaced > 0 ? condFloorBSum / Double(surfaced) * 100 : 0)
    md += "\nFor reference, same slice, EARLIER measurements (`k1b-sweep-report.md`):\n\n"
    md += "| | n | surfaced | rate | K1 unconditional | K1 conditional |\n|---|---:|---:|---:|---:|---:|\n"
    md += "| topN=30 (matched, original) | 3550 | 1979 | 55.7% | 28.2% | 50.5% |\n"
    md += "| topN=300 scores / topN=30 baselines (MISMATCHED) | 3550 | 2698 | 76.0% | 28.2% | 37.1% |\n\n"

    md += "## 2. Binary read\n\n"
    if correct > Int(Double(n) * 0.289) && surfaced > 0 && condCorrect > condFloorA {
        md += String(format: "**K1 still beats the floor with matched centering.** Unconditional %.1f%% vs floor(a) "
            + "%.1f%%; conditional %.1f%% vs floor(a) conditional %.1f%%. The Part 1 advantage survives — this was "
            + "NOT purely a topN=30-baseline mismatch artifact. `pretokenized` is worth verifying as a path to "
            + "closing the remaining surfacing gap.\n\n",
            n > 0 ? Double(correct) / Double(n) * 100 : 0, n > 0 ? Double(floorACorrect) / Double(n) * 100 : 0,
            surfaced > 0 ? Double(condCorrect) / Double(surfaced) * 100 : 0, surfaced > 0 ? Double(condFloorA) / Double(surfaced) * 100 : 0)
    } else {
        md += String(format: "**K1 does NOT beat the floor once centering is matched.** Unconditional %.1f%% vs "
            + "floor(a) %.1f%%; conditional %.1f%% vs floor(a) conditional %.1f%%. The +14.6pp conditional "
            + "advantage reported in Part 1 was a **selection effect** — rows where the gold sense surfaces "
            + "easily are rows the LM already favoured, so conditioning on surfacing selected the rows K1 was "
            + "going to win anyway, not evidence of a real signal. **K1b is a negative result: the donor-alias "
            + "signal does not outperform the trivial frequency floor. `pretokenized` would only make more rows "
            + "surface without making K1 more likely to rank the surfaced gold sense first — it would not fix "
            + "this, so it is not worth verifying for this purpose.**\n\n",
            n > 0 ? Double(correct) / Double(n) * 100 : 0, n > 0 ? Double(floorACorrect) / Double(n) * 100 : 0,
            surfaced > 0 ? Double(condCorrect) / Double(surfaced) * 100 : 0, surfaced > 0 ? Double(condFloorA) / Double(surfaced) * 100 : 0)
    }

    md += "### by candidate count\n\n| bucket | n | surfaced | K1 cond. top1 | floorA cond. top1 |\n|---|---:|---:|---:|---:|\n"
    for bucket in candidateCountBucketOrder {
        let bucketRows = matchedScored.filter { candidateCountBucket($0.candidateCount) == bucket }
        guard !bucketRows.isEmpty else { continue }
        let bSurf = bucketRows.filter(\.goldSurfaced)
        let bCorrect = bSurf.filter(\.correct).count
        let bFloorA = bSurf.filter(\.floorACorrect).count
        md += String(format: "| %@ | %d | %d | %.1f%% | %.1f%% |\n", bucket, bucketRows.count, bSurf.count,
            bSurf.isEmpty ? 0 : Double(bCorrect) / Double(bSurf.count) * 100, bSurf.isEmpty ? 0 : Double(bFloorA) / Double(bSurf.count) * 100)
    }

    md += "\n### by donor source\n\n| source | n | surfaced | K1 cond. top1 | floorA cond. top1 |\n|---|---:|---:|---:|---:|\n"
    for source in ["anchor", "assoc", "nikl"] {
        let sourceRows = matchedScored.filter { $0.source == source }
        guard !sourceRows.isEmpty else { continue }
        let sSurf = sourceRows.filter(\.goldSurfaced)
        let sCorrect = sSurf.filter(\.correct).count
        let sFloorA = sSurf.filter(\.floorACorrect).count
        md += String(format: "| %@ | %d | %d | %.1f%% | %.1f%% |\n", source, sourceRows.count, sSurf.count,
            sSurf.isEmpty ? 0 : Double(sCorrect) / Double(sSurf.count) * 100, sSurf.isEmpty ? 0 : Double(sFloorA) / Double(sSurf.count) * 100)
    }

    // ================= Task B =================
    md += "\n## 3. Cheap test — 31-reading eval-composition subset\n\n"
    md += "The 258-row eval set covers \(evalReadingsCount) distinct readings (derived from the eval TSV itself). "
        + "Restricting holdout to rows on those SAME readings vs. the rest:\n\n"
    md += "| group | n | surfaced | surf. rate | K1 unconditional | K1 conditional | floorA unconditional | floorA conditional |\n"
    md += "|---|---:|---:|---:|---:|---:|---:|---:|\n"
    for (label, g, u) in [("31 eval readings", eval31Group, eval31Unconditional), ("rest of holdout", restGroup, restUnconditional)] {
        let surfRate = u.n > 0 ? Double(g.goldSurfaced) / Double(u.n) * 100 : 0
        let uncond = u.n > 0 ? Double(u.correct) / Double(u.n) * 100 : 0
        let cond = g.goldSurfaced > 0 ? Double(g.correctGivenSurfaced) / Double(g.goldSurfaced) * 100 : 0
        let floorAUncond = u.n > 0 ? Double(u.floorA) / Double(u.n) * 100 : 0
        let floorACond = g.goldSurfaced > 0 ? Double(g.floorACorrectGivenSurfaced) / Double(g.goldSurfaced) * 100 : 0
        md += String(format: "| %@ | %d | %d | %.1f%% | %.1f%% | %.1f%% | %.1f%% | %.1f%% |\n",
            label, u.n, g.goldSurfaced, surfRate, uncond, cond, floorAUncond, floorACond)
    }
    md += "\nFor reference: 258-row eval set (`k1b-gold-surfaced-diagnosis.md` §4): surfacing 70.8%, K1 conditional 12.3%.\n\n"

    let eval31Cond = eval31Group.goldSurfaced > 0 ? Double(eval31Group.correctGivenSurfaced) / Double(eval31Group.goldSurfaced) * 100 : 0
    let restCond = restGroup.goldSurfaced > 0 ? Double(restGroup.correctGivenSurfaced) / Double(restGroup.goldSurfaced) * 100 : 0
    md += "**Read**: "
    if eval31Cond <= restCond - 10 {
        md += String(format: "the 31-reading subset's conditional top1 (%.1f%%) collapses toward the 258-eval level "
            + "(12.3%%) relative to the rest of holdout (%.1f%%) — **reading-composition difficulty explains the "
            + "258-gap**: the eval set's 31 계열 are the hardest, most-confusable readings, and holdout-wide "
            + "numbers overstate performance on exactly the readings a real IME user would actually type.\n\n",
            eval31Cond, restCond)
    } else {
        md += String(format: "the 31-reading subset's conditional top1 (%.1f%%) is NOT meaningfully lower than the "
            + "rest of holdout (%.1f%%), and both remain far above the 258-eval's 12.3%% — reading-composition "
            + "difficulty does NOT explain the 258-gap either. The eval set's low score has some other cause not "
            + "yet identified (sentence style, eval-set construction, or something specific to those 258 hand-picked "
            + "sentences rather than to the readings themselves).\n\n", eval31Cond, restCond)
    }

    try md.write(to: Paths.outDir.appendingPathComponent("k1b-matched-report.md"), atomically: true, encoding: .utf8)
    print("wrote \(Paths.outDir.appendingPathComponent("k1b-matched-report.md").path)")
}
