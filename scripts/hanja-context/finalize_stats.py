#!/usr/bin/env python3
"""Step 5a post-collect aggregation (문맥 기반 한자 변환 — plan §7 5a).

Reads the Swift collector's outputs under
/Volumes/Workbench/wooriHanjaModel/work/hanja-context/counts/ —
part-*.stats.json plus the merged {paren,anchor}-counts.tsv (and dict-counts.tsv
when the NIKL collect-defs pass has run) — and writes counts/collect-stats.json:
lines processed, anchor-hit / 병기-validated line counts, per-eval-27-series
token-level (reading, candidate) hit counts, distinct feature counts per eval
candidate, elapsed/rate, and top-N feature previews for the gate report.

Count aggregation in Python is explicitly allowed by the plan (§7 5a 작업 1);
morphological analysis stays in the Swift collector (kiwipiepy forbidden).

Usage: python3 scripts/hanja-context/finalize_stats.py
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

WOORILEE_ROOT = Path(__file__).resolve().parents[2]
WORK_DIR = WOORILEE_ROOT.parent / "wooriHanjaModel/work/hanja-context"
COUNTS_DIR = WORK_DIR / "counts"
EVAL_TSV = WOORILEE_ROOT / "eval/hanja-context-eval-set.tsv"

TOP_N = 10
# Gate-report preview pairs: 수도 3계열 + thin-signal watchlist.
PREVIEW_PAIRS = [
    ("수도", "水道"), ("수도", "修道"), ("수도", "首都"),
    ("장관", "壯觀"), ("연기", "煙氣"), ("연기", "延期"), ("국화", "國花"),
    ("선물", "膳物"), ("선물", "先物"), ("유산", "流産"), ("이상", "理想"), ("의사", "義士"),
]


def load_eval_pairs() -> tuple[list[str], list[tuple[str, str]]]:
    readings: list[str] = []
    pairs: list[tuple[str, str]] = []
    seen_r: set[str] = set()
    seen_p: set[tuple[str, str]] = set()
    with EVAL_TSV.open(encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            _, reading, answer = cols
            if reading not in seen_r:
                seen_r.add(reading)
                readings.append(reading)
            if (reading, answer) not in seen_p:
                seen_p.add((reading, answer))
                pairs.append((reading, answer))
    return readings, pairs


def main() -> int:
    eval_readings, eval_pairs = load_eval_pairs()

    # --- part stats ---
    part_stats = sorted(COUNTS_DIR.glob("part-*.stats.json"))
    if not part_stats:
        print("no part-*.stats.json found — run collect first", file=sys.stderr)
        return 1
    lines = anchor_hit_lines = paren_lines = 0
    elapsed = 0.0
    anchor_pair_lines: dict[str, int] = defaultdict(int)
    paren_pair_lines: dict[str, int] = defaultdict(int)
    for path in part_stats:
        stats = json.loads(path.read_text(encoding="utf-8"))
        lines += stats["lines"]
        anchor_hit_lines += stats["anchorHitLines"]
        paren_lines += stats["parenValidatedLines"]
        elapsed += stats["elapsedSec"]
        for key, value in stats["anchorPairLines"].items():
            anchor_pair_lines[key] += value
        for key, value in stats["parenPairLines"].items():
            paren_pair_lines[key] += value

    # --- merged counts: distinct features per pair + previews ---
    eval_reading_set = set(eval_readings)
    preview_set = set(PREVIEW_PAIRS)
    distinct_features: dict[str, dict[str, int]] = {"anchor": defaultdict(int), "paren": defaultdict(int), "dict": defaultdict(int)}
    tuple_counts: dict[str, int] = {}
    total_counts: dict[str, int] = {}
    previews: dict[str, dict[str, dict[str, int]]] = {s: defaultdict(dict) for s in ("anchor", "paren", "dict")}

    for signal in ("anchor", "paren", "dict"):
        merged = COUNTS_DIR / f"{signal}-counts.tsv"
        if not merged.exists():
            continue
        n_tuples = 0
        n_total = 0
        with merged.open(encoding="utf-8") as f:
            for raw in f:
                cols = raw.rstrip("\n").split("\t")
                if len(cols) != 4:
                    continue
                reading, hanja, feature, count_s = cols
                count = int(count_s)
                n_tuples += 1
                n_total += count
                pair_key = f"{reading}\t{hanja}"
                if reading in eval_reading_set:
                    distinct_features[signal][pair_key] += 1
                if (reading, hanja) in preview_set:
                    previews[signal][pair_key][feature] = count
        tuple_counts[signal] = n_tuples
        total_counts[signal] = n_total

    # --- eval-27 gate table ---
    gate_rows = []
    for reading, answer in eval_pairs:
        key = f"{reading}\t{answer}"
        gate_rows.append({
            "reading": reading,
            "candidate": answer,
            "anchor_hit_lines": anchor_pair_lines.get(key, 0),
            "paren_validated_lines": paren_pair_lines.get(key, 0),
            "distinct_features_anchor": distinct_features["anchor"].get(key, 0),
            "distinct_features_paren": distinct_features["paren"].get(key, 0),
            "distinct_features_dict": distinct_features["dict"].get(key, 0),
        })

    # --- previews: top-N by combined anchor+paren count (dict listed separately) ---
    preview_out = {}
    for reading, hanja in PREVIEW_PAIRS:
        key = f"{reading}\t{hanja}"
        combined: dict[str, int] = defaultdict(int)
        for signal in ("anchor", "paren"):
            for feature, count in previews[signal].get(key, {}).items():
                combined[feature] += count
        top_combined = sorted(combined.items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_N]
        top_dict = sorted(previews["dict"].get(key, {}).items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_N]
        preview_out[f"{reading}/{hanja}"] = {
            "top_wiki_anchor_plus_paren": [f"{f}:{c}" for f, c in top_combined],
            "top_dict": [f"{f}:{c}" for f, c in top_dict],
        }

    out = {
        "parts": len(part_stats),
        "lines_processed": lines,
        "anchor_hit_lines": anchor_hit_lines,
        "paren_validated_lines": paren_lines,
        "sum_part_elapsed_sec": round(elapsed, 1),
        "rate_lines_per_sec": round(lines / elapsed, 1) if elapsed else None,
        "merged_distinct_tuples": tuple_counts,
        "merged_total_counts": total_counts,
        "eval27_gate_table": gate_rows,
        "previews_top10": preview_out,
    }
    (COUNTS_DIR / "collect-stats.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # --- console tables ---
    print(f"lines={lines} anchorHitLines={anchor_hit_lines} parenLines={paren_lines} "
          f"elapsed={elapsed:.0f}s rate={lines / elapsed:.0f}/s" if elapsed else "")
    print(f"tuples={tuple_counts} totals={total_counts}")
    print("\nEVAL27| reading candidate anchorLines parenLines featAnchor featParen featDict")
    for row in gate_rows:
        print(f"EVAL27| {row['reading']} {row['candidate']} {row['anchor_hit_lines']} "
              f"{row['paren_validated_lines']} {row['distinct_features_anchor']} "
              f"{row['distinct_features_paren']} {row['distinct_features_dict']}")
    print()
    for pair, data in preview_out.items():
        print(f"TOP10| {pair} wiki: {', '.join(data['top_wiki_anchor_plus_paren'])}")
        if data["top_dict"]:
            print(f"TOP10| {pair} dict: {', '.join(data['top_dict'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
