// Offline evaluation harness for reading-only Hanja candidate ranking.
//     Copyright (C) 2026 Seungjin Lee.
//
// Mirrors HanjaDictionaryService.candidates(for:) (empty userEntries, empty usageCounts —
// reading-only, no personalization) against eval/hanja-context-eval-set.tsv and reports
// top1/top3 accuracy overall and per-series. See docs/plans/context-aware-hanja-conversion.md
// section 2 (단계 1 — 평가 하네스).

import Foundation
import LibHangul
import XCTest
@testable import woorilee

final class HanjaContextEvalTests: XCTestCase {
    private struct EvalRow { let sentence: String; let reading: String; let answer: String }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadRows() throws -> [EvalRow] {
        let url = repoRoot().appendingPathComponent("eval/hanja-context-eval-set.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [EvalRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // This harness is pinned to the 195 v1 rows for stage-to-stage comparability (the
            // EVAL| 81/195 and EVAL_CTX| 86/195 baselines). The step-5d v2 native-context rows
            // appended after this marker are measured by HanjaContextEvalV2Tests instead.
            if line.hasPrefix("# ---- v2") { break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 3, !c[0].isEmpty, !c[1].isEmpty, !c[2].isEmpty else { continue }
            rows.append(EvalRow(sentence: c[0], reading: c[1], answer: c[2]))
        }
        return rows
    }

    // Mirrors HanjaDictionaryService.makeSystemCandidates + candidates(for:)
    private func mergedCandidates(reading: String, table: HanjaTable, freq: HanjaFrequencyTable) -> [HanjaCandidate] {
        guard let list = LibHangul.searchHanja(table: table, key: reading) else { return [] }
        let seeds: [HanjaCandidateSeed] = (0..<list.getSize()).compactMap { i in
            guard let value = list.getNthValue(i) else { return nil }
            return HanjaCandidateSeed(reading: list.getNthKey(i) ?? reading, value: value,
                                      comment: list.getNthComment(i) ?? "", source: .system, baseRank: i)
        }
        let merged = mergeHanjaCandidates(userEntries: [], systemCandidates: seeds,
                                          usageCounts: [:], frequencyLookup: freq.frequency(for:))
        return merged.filter { $0.value != $0.reading }
    }

    private func rankedValues(reading: String, table: HanjaTable, freq: HanjaFrequencyTable) -> [String] {
        mergedCandidates(reading: reading, table: table, freq: freq).map(\.value)
    }

    func testBaselineTop1Top3() throws {
        let root = repoRoot()
        let table = try XCTUnwrap(LibHangul.loadHanjaTable(
            filename: root.appendingPathComponent("woorilee/data/hanja/hanja.txt").path))
        let freq = HanjaFrequencyTable(
            characterFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanja.txt")],
            wordFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanjaeo.txt")]
        )
        let rows = try loadRows()
        XCTAssertGreaterThanOrEqual(rows.count, 100, "eval set must have >= 100 rows")

        var top1 = 0, top3 = 0, notFound = 0
        var missing: [String] = []
        var per: [String: (n: Int, t1: Int, t3: Int)] = [:]
        // keep first-seen order of series for stable printing
        var order: [String] = []
        for row in rows {
            let vals = rankedValues(reading: row.reading, table: table, freq: freq)
            let rank = vals.firstIndex(of: row.answer).map { $0 + 1 }
            if per[row.reading] == nil { order.append(row.reading) }
            var s = per[row.reading] ?? (0, 0, 0); s.n += 1
            if let r = rank { if r == 1 { top1 += 1; s.t1 += 1 }; if r <= 3 { top3 += 1; s.t3 += 1 } }
            else { notFound += 1; missing.append("\(row.reading)/\(row.answer) :: \(row.sentence)") }
            per[row.reading] = s
        }
        let n = rows.count
        print("EVAL|version=v1 rows=\(n)")
        print("EVAL|overall top1=\(top1)/\(n) (\(pct(top1, n))) top3=\(top3)/\(n) (\(pct(top3, n))) notFound=\(notFound)")
        for k in order { let s = per[k]!; print("EVAL|series \(k) n=\(s.n) top1=\(s.t1) top3=\(s.t3)") }
        for m in missing { print("EVAL|MISSING \(m)") }
        XCTAssertEqual(notFound, 0, "answers not found in dictionary candidates: \(missing)")
    }

    private func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "0%" : String(format: "%.1f%%", 100.0 * Double(a) / Double(b)) }

    /// Kiwi-free context resolver for the eval harness: space-split the sentence into eojeols,
    /// then for each eojeol take the longest prefix that is a key in `dominantMap` (this strips
    /// trailing josa/endings, e.g. "수도원에서" → "수도원"). Mirrors what a real Kiwi-based
    /// resolver would hand `contextDominantHanja(forEojeolReadings:dominantMap:)` in step 4b,
    /// without requiring Kiwi here.
    ///
    /// Guard: when NOTHING was stripped (the matched prefix is the whole eojeol) and that eojeol
    /// is the target reading plus more characters, skip it. Without Kiwi's real segmentation, an
    /// eojeol like "사고가" (target reading 사고 + subject particle 가) is indistinguishable from
    /// the coincidentally real, unrelated dictionary word 사고가 (思考家) — including it as
    /// "context" self-contaminates the target word's own occurrence and wrongly boosts whichever
    /// candidate its dominant hanja happens to contain (regression found against 사고/事故 and
    /// 대전/大戰 while building this harness). A genuinely distinct longer word starting with the
    /// same syllables (e.g. "수도원에" → 수도원) always has a shorter matched prefix than the full
    /// eojeol, so it is unaffected by this guard.
    private func eojeolDominantHanja(sentence: String, targetReading: String, dominantMap: [String: String]) -> [String] {
        var readings: [String] = []
        for eojeol in sentence.split(separator: " ") {
            var longestPrefix: String?
            for length in stride(from: eojeol.count, through: 1, by: -1) {
                let prefix = String(eojeol.prefix(length))
                if dominantMap[prefix] != nil {
                    longestPrefix = prefix
                    break
                }
            }
            guard let matched = longestPrefix else { continue }
            if matched.count == eojeol.count, matched.hasPrefix(targetReading), matched != targetReading {
                continue
            }
            readings.append(matched)
        }
        return contextDominantHanja(forEojeolReadings: readings, dominantMap: dominantMap)
    }

    // Step 4a (사전 내부 문맥 신호, MEASUREMENT ONLY — see
    // docs/plans/context-aware-hanja-conversion.md §5). This test measures rankWithContext +
    // buildDominantHanjaMap against the eval set using the Kiwi-free eojeol-prefix resolver above.
    // Nothing here is wired into the production input path; that is step 4b.
    func testContextRankingTop1Top3() throws {
        let root = repoRoot()
        let table = try XCTUnwrap(LibHangul.loadHanjaTable(
            filename: root.appendingPathComponent("woorilee/data/hanja/hanja.txt").path))
        let freq = HanjaFrequencyTable(
            characterFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanja.txt")],
            wordFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanjaeo.txt")]
        )
        let dictionaryText = try String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja.txt"), encoding: .utf8)
        let dominantMap = buildDominantHanjaMap(
            dictionaryLines: dictionaryText.split(separator: "\n", omittingEmptySubsequences: true),
            frequency: freq.frequency(for:)
        )

        let rows = try loadRows()
        XCTAssertGreaterThanOrEqual(rows.count, 100, "eval set must have >= 100 rows")

        var top1 = 0, top3 = 0, notFound = 0
        var missing: [String] = []
        var per: [String: (n: Int, t1: Int, t3: Int)] = [:]
        var baselinePer: [String: Int] = [:] // series -> baseline top1 count, for the improvement comparison
        var order: [String] = []
        var flagshipRanks: [String: Int] = [:] // answer -> rank, for the three 수도 flagship rows

        for row in rows {
            let candidates = mergedCandidates(reading: row.reading, table: table, freq: freq)
            let baselineRank = candidates.map(\.value).firstIndex(of: row.answer).map { $0 + 1 }
            if let r = baselineRank, r == 1 { baselinePer[row.reading, default: 0] += 1 }

            let context = eojeolDominantHanja(sentence: row.sentence, targetReading: row.reading, dominantMap: dominantMap)
            let ranked = rankWithContext(candidates: candidates, contextDominantHanja: context, weights: .default)
            let rank = ranked.map(\.value).firstIndex(of: row.answer).map { $0 + 1 }

            if row.reading == "수도" {
                if row.sentence.contains("상하수도") { flagshipRanks["水道"] = rank }
                if row.sentence.contains("수도원") { flagshipRanks["修道"] = rank }
                if row.sentence.contains("대한민국") { flagshipRanks["首都"] = rank }
            }

            if per[row.reading] == nil { order.append(row.reading) }
            var s = per[row.reading] ?? (0, 0, 0); s.n += 1
            if let r = rank { if r == 1 { top1 += 1; s.t1 += 1 }; if r <= 3 { top3 += 1; s.t3 += 1 } }
            else { notFound += 1; missing.append("\(row.reading)/\(row.answer) :: \(row.sentence)") }
            per[row.reading] = s
        }

        let n = rows.count
        print("EVAL_CTX|version=v1 rows=\(n)")
        print("EVAL_CTX|overall top1=\(top1)/\(n) (\(pct(top1, n))) top3=\(top3)/\(n) (\(pct(top3, n))) notFound=\(notFound)")
        for k in order {
            let s = per[k]!
            print("EVAL_CTX|series \(k) n=\(s.n) top1=\(s.t1) top3=\(s.t3)")
        }
        for m in missing { print("EVAL_CTX|MISSING \(m)") }

        for (answer, rank) in ["水道", "修道", "首都"].map({ ($0, flagshipRanks[$0]) }) {
            print("EVAL_CTX|flagship reading=수도 answer=\(answer) rank=\(rank.map(String.init) ?? "notFound")")
        }

        let improved = order.filter { (per[$0]!.t1) > (baselinePer[$0] ?? 0) }
        print("EVAL_CTX|improved series=\(improved.joined(separator: ","))")

        XCTAssertEqual(notFound, 0, "answers not found in dictionary candidates: \(missing)")
        XCTAssertGreaterThan(top1, 81, "context ranking must strictly improve top1 over the 81/195 baseline")
        XCTAssertGreaterThanOrEqual(top3, 177, "context ranking must not regress top3 below the 177/195 step-2 baseline")
        XCTAssertEqual(flagshipRanks["水道"], 1, "상하수도 sentence must rank 水道 first")
        XCTAssertEqual(flagshipRanks["修道"], 1, "수도원 sentence must rank 修道 first")
        XCTAssertEqual(flagshipRanks["首都"], 1, "대한민국 sentence must rank 首都 first")
    }
}
