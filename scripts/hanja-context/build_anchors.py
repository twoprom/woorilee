#!/usr/bin/env python3
"""Step 5a JOB 3 — anchor-word inventory.

For every (target_reading, candidate_hanja) pair in targets.tsv, finds
dictionary words that properly contain the candidate as a substring, whose
own reading is dominant for that exact word, and that have decoded word
frequency >= 1. These are the "친척 단어" (e.g. 상수도/하수도/수도관 -> 水道)
whose context will later stand in for the ambiguous target itself
(distant supervision — see README.md and plan §7 5a).

Run:
    python3 scripts/hanja-context/build_anchors.py
    (requires inventory/targets.tsv from build_targets.py)

Writes:
    /Volumes/Workbench/wooriHanjaModel/work/hanja-context/inventory/anchors.tsv
"""
from __future__ import annotations

import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc

MIN_ANCHOR_WORD_FREQ = 1


def parse_targets_tsv(path: Path) -> dict[str, list[tuple[str, int]]]:
    targets: dict[str, list[tuple[str, int]]] = {}
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            reading, _total_freq, candidates_field = cols
            candidates = []
            for item in candidates_field.split(","):
                candidate, _, freq_str = item.rpartition(":")
                candidates.append((candidate, int(freq_str)))
            targets[reading] = candidates
    return targets


def percentile(sorted_values: list[int], p: float) -> float:
    if not sorted_values:
        return 0.0
    k = (len(sorted_values) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_values) - 1)
    if f == c:
        return float(sorted_values[f])
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


def main() -> int:
    hc.INVENTORY_DIR.mkdir(parents=True, exist_ok=True)
    targets_path = hc.INVENTORY_DIR / "targets.tsv"
    targets = parse_targets_tsv(targets_path)

    lines = hc.read_dictionary_lines()
    raw_by_reading = hc.candidates_by_reading(lines)
    frequency = hc.load_merged_frequency()
    dominant_map = hc.build_dominant_map(raw_by_reading, frequency)

    pairs: list[tuple[str, str]] = []
    for line in lines:
        parsed = hc.parse_reading_hanja(line)
        if parsed is not None:
            pairs.append(parsed)

    # candidate hanja string -> set of target readings it belongs to (normally
    # singleton, but a hanja spelling could in principle carry >1 reading).
    candidate_to_readings: dict[str, set[str]] = {}
    for reading, cand_list in targets.items():
        for candidate, _freq in cand_list:
            candidate_to_readings.setdefault(candidate, set()).add(reading)
    candidate_set = set(candidate_to_readings.keys())
    candidate_lengths = sorted({len(c) for c in candidate_set}, reverse=True)

    seen_rows: set[tuple[str, str, str, str]] = set()
    anchor_rows: list[tuple[str, str, str, str, int]] = []
    for r_w, h_w in pairs:
        n = len(h_w)
        if n < 2:
            continue
        if dominant_map.get(r_w) != h_w:
            continue
        anchor_freq = frequency.get(h_w, 0)
        if anchor_freq < MIN_ANCHOR_WORD_FREQ:
            continue
        for length in candidate_lengths:
            if length >= n:
                continue
            for start in range(0, n - length + 1):
                sub = h_w[start : start + length]
                readings_for_sub = candidate_to_readings.get(sub)
                if not readings_for_sub:
                    continue
                for target_reading in readings_for_sub:
                    key = (target_reading, sub, r_w, h_w)
                    if key in seen_rows:
                        continue
                    seen_rows.add(key)
                    anchor_rows.append((target_reading, sub, r_w, h_w, anchor_freq))

    anchor_rows.sort(key=lambda row: (row[0], -row[4]))

    out_path = hc.INVENTORY_DIR / "anchors.tsv"
    with out_path.open("w", encoding="utf-8") as f:
        f.write("# anchors.tsv — step 5a JOB 3 output (문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §7 5a)\n")
        f.write("# Format: target_reading<TAB>candidate_hanja<TAB>anchor_reading<TAB>anchor_hanja<TAB>anchor_freq\n")
        f.write(f"# Gate: anchor_hanja properly contains candidate_hanja as substring, dominant_map[anchor_reading]==anchor_hanja, anchor word decoded freq >= {MIN_ANCHOR_WORD_FREQ}\n")
        f.write(f"# Counts: total_anchor_rows={len(anchor_rows)} distinct_targets_with_anchors={len({row[0] for row in anchor_rows})}\n")
        for row in anchor_rows:
            f.write("\t".join(str(v) for v in row) + "\n")

    # Per-(target_reading, candidate) anchor counts, over the FULL universe from targets.tsv
    # (so 0-anchor candidates are visible too).
    counts_by_pair: dict[tuple[str, str], int] = {}
    for target_reading, candidate, _r_w, _h_w, _freq in anchor_rows:
        key = (target_reading, candidate)
        counts_by_pair[key] = counts_by_pair.get(key, 0) + 1

    all_pairs: list[tuple[str, str]] = [
        (reading, candidate) for reading, cand_list in targets.items() for candidate, _freq in cand_list
    ]
    all_counts = [counts_by_pair.get(pair, 0) for pair in all_pairs]
    zero_pairs = [pair for pair, count in zip(all_pairs, all_counts) if count == 0]
    sorted_counts = sorted(all_counts)

    print(f"Wrote {len(anchor_rows)} anchor rows to {out_path}")
    print(f"Total (target_reading, candidate) pairs: {len(all_pairs)}; with 0 anchors: {len(zero_pairs)}")
    print(f"Anchor-count distribution per candidate: median={statistics.median(sorted_counts):.1f} p90={percentile(sorted_counts, 0.9):.1f} max={sorted_counts[-1] if sorted_counts else 0}")

    eval_readings = hc.load_eval_readings()
    print("\nPer-eval-27-series anchor counts per candidate:")
    for reading in eval_readings:
        cand_list = targets.get(reading, [])
        parts = [f"{c}←{counts_by_pair.get((reading, c), 0)}개" for c, _freq in cand_list]
        print(f"  {reading}: {', '.join(parts)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
