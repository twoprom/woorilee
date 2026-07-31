#!/usr/bin/env python3
"""Dumps example rows per 2x2 cell for the K1b Part 2 report, plus per-source breakdowns for every
cell (not just K1-only) for a fuller picture."""
DIR = "/Volumes/Workbench/wooriHanjaModel/work/hanja-context/k1/part2"


def load_tsv(path):
    rows = []
    header = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
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
    hi = {name: i for i, name in enumerate(h_hold)}
    mi = {name: i for i, name in enumerate(h_meta)}
    ai = {name: i for i, name in enumerate(h_assoc)}

    joined = []
    for idx in range(n):
        hold, meta, assoc = r_hold[idx], r_meta[idx], r_assoc[idx]
        joined.append({
            "reading": hold[hi["reading"]], "gold": hold[hi["hanja"]],
            "sentence": hold[hi["input_sentence"]], "source": hold[hi["source"]],
            "donor": hold[hi["donor"]], "page_id": hold[hi["page_id"]],
            "k1_predicted": meta[mi["k1_predicted"]], "k1_correct": meta[mi["k1_correct"]] == "true",
            "gold_surfaced": meta[mi["gold_surfaced"]] == "true",
            "assoc_predicted": assoc[ai["predicted"]], "assoc_correct": assoc[ai["top1_correct"]] == "true",
            "assoc_segment_found": assoc[ai["segment_found"]] == "true",
            "assoc_match_kind": assoc[ai["match_kind"]],
        })

    def cell(k1_ok, assoc_ok):
        return [r for r in joined if r["k1_correct"] == k1_ok and r["assoc_correct"] == assoc_ok]

    both_right = cell(True, True)
    assoc_only = cell(False, True)
    k1_only = cell(True, False)
    both_wrong = cell(False, False)

    for label, rows in [("both_right", both_right), ("assoc_only", assoc_only), ("k1_only", k1_only), ("both_wrong", both_wrong)]:
        by_src = {}
        for r in rows:
            by_src.setdefault(r["source"], 0)
            by_src[r["source"]] += 1
        print(f"{label}: n={len(rows)} by_source={by_src}")

    print("\n=== K1-only cell: ALL rows (source, donor, reading, gold, k1_pred, assoc_pred, sentence) ===")
    for r in k1_only:
        print(f"[{r['source']}] donor={r['donor']} reading={r['reading']} gold={r['gold']} "
              f"k1={r['k1_predicted']} assoc={r['assoc_predicted']} surfaced={r['gold_surfaced']} :: {r['sentence']}")

    print("\n=== both_wrong cell: first 15 examples ===")
    for r in both_wrong[:15]:
        print(f"[{r['source']}] donor={r['donor']} reading={r['reading']} gold={r['gold']} "
              f"k1={r['k1_predicted']} assoc={r['assoc_predicted']} surfaced={r['gold_surfaced']} :: {r['sentence']}")

    print("\n=== assoc_only cell: first 10 examples (association correct, K1 wrong) ===")
    for r in assoc_only[:10]:
        print(f"[{r['source']}] donor={r['donor']} reading={r['reading']} gold={r['gold']} "
              f"k1={r['k1_predicted']} assoc={r['assoc_predicted']} surfaced={r['gold_surfaced']} :: {r['sentence']}")

    # Corpus-overlap sanity check: for assoc_correct rows, does the gold hanja value itself literally
    # appear elsewhere in the sentence (leak) or does the donor word literally co-occur?
    print("\n=== corpus-overlap spot check: does the DONOR word literally appear in the sentence for assoc-correct rows? ===")
    donor_literal_count = 0
    for r in joined:
        if r["assoc_correct"] and r["donor"] and r["donor"] in r["sentence"]:
            donor_literal_count += 1
    assoc_correct_n = sum(1 for r in joined if r["assoc_correct"])
    print(f"assoc-correct rows where the donor word appears literally in the SAME sentence: "
          f"{donor_literal_count}/{assoc_correct_n} ({100*donor_literal_count/assoc_correct_n:.1f}%)")

    print(f"\nassoc segment_found=false count: {sum(1 for r in joined if not r['assoc_segment_found'])}")
    print(f"assoc match_kind breakdown: "
          f"span={sum(1 for r in joined if r['assoc_match_kind']=='span')} "
          f"name-fallback={sum(1 for r in joined if r['assoc_match_kind']=='name-fallback')} "
          f"none={sum(1 for r in joined if r['assoc_match_kind']=='none')}")


if __name__ == "__main__":
    main()
