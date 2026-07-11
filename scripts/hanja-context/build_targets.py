#!/usr/bin/env python3
"""Step 5a JOB 2 — target-reading inventory.

Builds the list of ambiguous (non-dominant) readings the context-association
pipeline will collect signal for. See README.md for the full contract.

Step 7b extension (2026-07-10, 7a 게이트 통과 후): the FINAL flagged readings
from native-homograph/flagged-readings.tsv (고유어 동음이의어 게이트, rule
7a-final-v2) are FORCE-INCLUDED as targets — like the eval readings — so the
association table gains rows for them (구두:口頭 등, plan §10 7b). Everything
else (natural pool criteria, MAX_TARGETS cut, dominance ratio) is unchanged;
the target set is only ever extended. If the flag list file is absent,
behavior is identical to 5a.

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

FLAGGED_READINGS_TSV = hc.WORK_DIR / "native-homograph/flagged-readings.tsv"


def load_flagged_readings(path: Path = FLAGGED_READINGS_TSV) -> list[str]:
    """FINAL flagged readings (step 7a, rule 7a-final-v2), file order.
    Empty when the file does not exist (pre-7b behavior)."""
    if not path.exists():
        return []
    readings: list[str] = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            reading = line.split("\t", 1)[0]
            if reading:
                readings.append(reading)
    return readings


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

    flagged_readings = load_flagged_readings()
    already = natural_top_set | set(forced)
    forced_flagged = [r for r in flagged_readings if r not in already]

    final_readings = sorted(natural_top + forced + forced_flagged, key=lambda r: -total_freq(r))

    out_path = hc.INVENTORY_DIR / "targets.tsv"
    with out_path.open("w", encoding="utf-8") as f:
        f.write("# targets.tsv — step 5a JOB 2 output (문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §7 5a)\n")
        f.write("# Format: reading<TAB>total_freq<TAB>candidate1:freq1,candidate2:freq2,... (candidates sorted freq desc)\n")
        f.write(f"# Params: min_reading_length={MIN_READING_LENGTH} max_targets={MAX_TARGETS} dominance_ratio={hc.DOMINANCE_RATIO}\n")
        f.write(f"# Counts: natural_pool={len(natural_pool)} natural_top={len(natural_top)} forced_eval_readings={len(forced)} forced_flagged_readings={len(forced_flagged)} total_targets={len(final_readings)}\n")
        f.write(f"# eval_readings_total={len(eval_readings)} naturally_present={len(naturally_present)}: {','.join(naturally_present)}\n")
        f.write(f"# force_included_dominant_classified ({len(forced_dominant)}): {','.join(forced_dominant)}\n")
        f.write(f"# force_included_below_cutoff ({len(forced_below_cutoff)}): {','.join(forced_below_cutoff)}\n")
        if flagged_readings:
            f.write(f"# step7b_flagged_total={len(flagged_readings)} (rule 7a-final-v2, {FLAGGED_READINGS_TSV}); force_included_flagged ({len(forced_flagged)}): {','.join(forced_flagged)}\n")
        for reading in final_readings:
            candidates = deduped_by_reading.get(reading, [])
            f.write(f"{reading}\t{total_freq(reading)}\t{format_candidates(candidates, frequency)}\n")

    print(f"Wrote {len(final_readings)} targets to {out_path}")
    print(f"  natural pool (ambiguous, len>=2): {len(natural_pool)}; cut to top {len(natural_top)} by total decoded freq")
    print(f"  eval-27 coverage: {len(naturally_present)}/{len(eval_readings)} naturally present in top {MAX_TARGETS}")
    print(f"  force-included ({len(forced)}): {forced}")
    print(f"    - dominant-classified at ratio {hc.DOMINANCE_RATIO} ({len(forced_dominant)}): {forced_dominant}")
    print(f"    - below cutoff rank ({len(forced_below_cutoff)}): {forced_below_cutoff}")
    if flagged_readings:
        print(f"  step-7b flagged readings: {len(flagged_readings)} total, {len(forced_flagged)} newly force-included")
    return 0


if __name__ == "__main__":
    sys.exit(main())
