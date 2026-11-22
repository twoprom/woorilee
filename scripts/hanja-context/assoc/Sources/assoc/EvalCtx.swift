// Reproduces woorileeTests/HanjaContextEvalTests.testContextRankingTop1Top3 EXACTLY.
//     Copyright (C) 2026 Seungjin Lee.
//
// This is the Task 1 hard-gate target ("reproduce the app's EVAL_CTX top1 count exactly"). The
// row-loading/candidate-merging/eojeol-splitting glue below is a line-for-line port of the TEST
// FILE's own private helpers (not app source under woorilee/ — the test itself defines
// `eojeolDominantHanja` as a Kiwi-free approximation, see its doc comment) so that calling
// `rankWithContext`/`buildDominantHanjaMap`/`contextDominantHanja` (real app source, symlinked)
// reproduces the identical ranking. No ranking math lives in this file.
import Foundation

@MainActor
enum EvalCtx {
    /// Line-for-line port of HanjaContextEvalTests.eojeolDominantHanja (test-only glue, not app
    /// source) — see that function's doc comment for the self-contamination guard rationale.
    private static func eojeolDominantHanja(sentence: String, targetReading: String, dominantMap: [String: String]) -> [String] {
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

    static func run() throws {
        let rows = try EvalSetLoader.loadV1()
        guard rows.count >= 100 else {
            print("EVAL_CTX|ERROR rows.count=\(rows.count) < 100")
            return
        }

        var top1 = 0, top3 = 0, notFound = 0
        var missing: [String] = []
        var per: [String: (n: Int, t1: Int, t3: Int)] = [:]
        var order: [String] = []
        var flagshipRanks: [String: Int] = [:]
        var rowDetails: [String] = []

        for row in rows {
            let candidates = Fixtures.candidateLookup(row.reading)
            let context = eojeolDominantHanja(sentence: row.sentence, targetReading: row.reading, dominantMap: Fixtures.dominantMap)
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
            rowDetails.append("EVAL_CTX_ROW|reading=\(row.reading) answer=\(row.answer) rank=\(rank.map(String.init) ?? "notFound") :: \(row.sentence)")
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
        for line in rowDetails { print(line) }
    }
}
