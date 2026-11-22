#!/usr/bin/env python3
"""K1b Part 2 -- the 2x2 complementarity table (calc §12 K1b gate) for the 31-reading
eval-composition holdout subset. Joins (positionally, by row index -- all three files were
produced from the SAME 717-row extract in the SAME order, see extract_31series_subset.py):
  - 31series-holdout.tsv       (reading, gold hanja, span/sentence, donor source)
  - 31series-k1-meta.tsv       (K1's predicted/correct/gold_surfaced, from holdout-scored.tsv +
                                 diagnose-holdout-scored.tsv)
  - 31series-assoc-scored.tsv  (the offline association-ranker's predicted/rank/top1_correct, from
                                 `assoc score-holdout` -- the REAL app HanjaContextRanker +
                                 KiwiAnalysisService pipeline, compiled app source, not reimplemented)
"""
import sys

DIR = "/Volumes/Workbench/wooriHanjaModel/work/hanja-context/k1/part2"


def load_tsv(path, skip_comment_prefixes=("#",)):
    rows = []
    header = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if any(line.startswith(p) for p in skip_comment_prefixes):
                continue
            c = line.rstrip("\n").split("\t")
            if header is None:
                header = c
                continue
            rows.append(c)
    return header, rows


def main():
    h_hold, r_hold = load_tsv(f"{DIR}/31series-holdout.tsv")
    h_meta, r_meta = load_tsv(f"{DIR}/31series-k1-meta.tsv")
    h_assoc, r_assoc = load_tsv(f"{DIR}/31series-assoc-scored.tsv")

    n = len(r_hold)
    assert len(r_meta) == n and len(r_assoc) == n, f"row count mismatch: {len(r_hold)} {len(r_meta)} {len(r_assoc)}"

    hi = {name: i for i, name in enumerate(h_hold)}
    mi = {name: i for i, name in enumerate(h_meta)}
    ai = {name: i for i, name in enumerate(h_assoc)}

    joined = []
    for idx in range(n):
        hold = r_hold[idx]
        meta = r_meta[idx]
        assoc = r_assoc[idx]
        # Sanity: reading + gold hanja must match across all three at this position.
        assert hold[hi["reading"]] == meta[mi["reading"]] == assoc[ai["reading"]], f"reading mismatch at row {idx}"
        assert hold[hi["hanja"]] == meta[mi["gold_hanja"]] == assoc[ai["hanja"]], f"gold hanja mismatch at row {idx}"

        row = {
            "reading": hold[hi["reading"]],
            "gold": hold[hi["hanja"]],
            "sentence": hold[hi["input_sentence"]],
            "source": hold[hi["source"]],  # donor source: anchor/assoc/nikl
            "donor": hold[hi["donor"]],
            "k1_predicted": meta[mi["k1_predicted"]],
            "k1_correct": meta[mi["k1_correct"]] == "true",
            "gold_surfaced": meta[mi["gold_surfaced"]] == "true",
            "assoc_segment_found": assoc[ai["segment_found"]] == "true",
            "assoc_predicted": assoc[ai["predicted"]],
            "assoc_correct": assoc[ai["top1_correct"]] == "true",
            "assoc_match_kind": assoc[ai["match_kind"]],
        }
        joined.append(row)

    def table(rows, label):
        both_right = sum(1 for r in rows if r["k1_correct"] and r["assoc_correct"])
        assoc_only = sum(1 for r in rows if not r["k1_correct"] and r["assoc_correct"])
        k1_only = sum(1 for r in rows if r["k1_correct"] and not r["assoc_correct"])
        both_wrong = sum(1 for r in rows if not r["k1_correct"] and not r["assoc_correct"])
        total = len(rows)
        print(f"\n=== {label} (n={total}) ===")
        print(f"{'':20s} {'K1 정답':>12s} {'K1 오답':>12s}")
        print(f"{'연관표 정답':20s} {both_right:5d} ({100*both_right/total:5.1f}%) {assoc_only:5d} ({100*assoc_only/total:5.1f}%)")
        print(f"{'연관표 오답':20s} {k1_only:5d} ({100*k1_only/total:5.1f}%) {both_wrong:5d} ({100*both_wrong/total:5.1f}%)")
        print(f"K1 top1 accuracy:    {sum(1 for r in rows if r['k1_correct'])}/{total} ({100*sum(1 for r in rows if r['k1_correct'])/total:.1f}%)")
        print(f"assoc top1 accuracy: {sum(1 for r in rows if r['assoc_correct'])}/{total} ({100*sum(1 for r in rows if r['assoc_correct'])/total:.1f}%)")
        print(f"both-wrong rate:     {both_wrong}/{total} ({100*both_wrong/total:.1f}%)")
        return dict(both_right=both_right, assoc_only=assoc_only, k1_only=k1_only, both_wrong=both_wrong, total=total)

    all_stats = table(joined, "ALL 717 rows (unconditioned -- K1 counted wrong when gold never surfaced)")
    surfaced = [r for r in joined if r["gold_surfaced"]]
    surfaced_stats = table(surfaced, "gold_surfaced == true subset (K1 could structurally compete)")

    not_surfaced = [r for r in joined if not r["gold_surfaced"]]
    print(f"\n(gold_surfaced == false: n={len(not_surfaced)}, "
          f"k1_correct among these: {sum(1 for r in not_surfaced if r['k1_correct'])} "
          f"[should be 0 if K1 structurally cannot pick an unsurfaced sense], "
          f"assoc_correct among these: {sum(1 for r in not_surfaced if r['assoc_correct'])})")

    # K1-only breakdown by donor source.
    print("\n=== K1-only cell (연관표 오답, K1 정답) by donor source, ALL 717 rows ===")
    k1_only_rows = [r for r in joined if r["k1_correct"] and not r["assoc_correct"]]
    by_source = {}
    for r in k1_only_rows:
        by_source.setdefault(r["source"], []).append(r)
    for src in sorted(by_source):
        print(f"  {src}: {len(by_source[src])}")

    print(f"\ntotal K1-only rows: {len(k1_only_rows)}")

    not_found = sum(1 for r in joined if not r["assoc_segment_found"])
    print(f"\n(data-quality caveat: assoc segment_found=false for {not_found}/{len(joined)} rows -- "
          f"assoc scored those as wrong by construction, no candidate rank was computable)")

    return joined, k1_only_rows


if __name__ == "__main__":
    main()
