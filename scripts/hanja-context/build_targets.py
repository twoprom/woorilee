#!/usr/bin/env python3
"""Step 5a JOB 2 — target-reading inventory.

Builds the list of ambiguous (non-dominant) readings the context-association
pipeline will collect signal for. See README.md for the full contract.

Run:
    python3 scripts/hanja-context/build_targets.py

Writes:
    /Volumes/Workbench/wooriHanjaModel/work/hanja-context/inventory/targets.tsv
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc

MIN_READING_LENGTH = 2
MAX_TARGETS = 3000


def format_candidates(candidates: list[str], frequency: dict[str, int]) -> str:
    ranked = sorted(candidates, key=lambda c: -frequency.get(c, 0))
    return ",".join(f"{c}:{frequency.get(c, 0)}" for c in ranked)


def main() -> int:
    hc.INVENTORY_DIR.mkdir(parents=True, exist_ok=True)

    lines = hc.read_dictionary_lines()
    raw_by_reading = hc.candidates_by_reading(lines)
    deduped_by_reading = hc.dedup_candidates_by_reading(raw_by_reading)
    frequency = hc.load_merged_frequency()
    dominant_map = hc.build_dominant_map(raw_by_reading, frequency)
    eval_readings = hc.load_eval_readings()

    def total_freq(reading: str) -> int:
        return sum(frequency.get(c, 0) for c in deduped_by_reading.get(reading, []))

    natural_pool = [
        reading
        for reading, cands in deduped_by_reading.items()
        if len(cands) >= 2
        and reading not in dominant_map
        and len(reading) >= MIN_READING_LENGTH
    ]
    natural_pool.sort(key=lambda r: -total_freq(r))
    natural_top = natural_pool[:MAX_TARGETS]
    natural_top_set = set(natural_top)

    forced = [r for r in eval_readings if r not in natural_top_set]
    forced_dominant = [r for r in forced if r in dominant_map]
    forced_below_cutoff = [r for r in forced if r not in dominant_map]
    naturally_present = [r for r in eval_readings if r in natural_top_set]

    final_readings = sorted(natural_top + forced, key=lambda r: -total_freq(r))

    out_path = hc.INVENTORY_DIR / "targets.tsv"
    with out_path.open("w", encoding="utf-8") as f:
        f.write("# targets.tsv — step 5a JOB 2 output (문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §7 5a)\n")
        f.write("# Format: reading<TAB>total_freq<TAB>candidate1:freq1,candidate2:freq2,... (candidates sorted freq desc)\n")
        f.write(f"# Params: min_reading_length={MIN_READING_LENGTH} max_targets={MAX_TARGETS} dominance_ratio={hc.DOMINANCE_RATIO}\n")
        f.write(f"# Counts: natural_pool={len(natural_pool)} natural_top={len(natural_top)} forced_eval_readings={len(forced)} total_targets={len(final_readings)}\n")
        f.write(f"# eval_readings_total={len(eval_readings)} naturally_present={len(naturally_present)}: {','.join(naturally_present)}\n")
        f.write(f"# force_included_dominant_classified ({len(forced_dominant)}): {','.join(forced_dominant)}\n")
        f.write(f"# force_included_below_cutoff ({len(forced_below_cutoff)}): {','.join(forced_below_cutoff)}\n")
        for reading in final_readings:
            candidates = deduped_by_reading.get(reading, [])
            f.write(f"{reading}\t{total_freq(reading)}\t{format_candidates(candidates, frequency)}\n")

    print(f"Wrote {len(final_readings)} targets to {out_path}")
    print(f"  natural pool (ambiguous, len>=2): {len(natural_pool)}; cut to top {len(natural_top)} by total decoded freq")
    print(f"  eval-27 coverage: {len(naturally_present)}/{len(eval_readings)} naturally present in top {MAX_TARGETS}")
    print(f"  force-included ({len(forced)}): {forced}")
    print(f"    - dominant-classified at ratio {hc.DOMINANCE_RATIO} ({len(forced_dominant)}): {forced_dominant}")
    print(f"    - below cutoff rank ({len(forced_below_cutoff)}): {forced_below_cutoff}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
