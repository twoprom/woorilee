#!/usr/bin/env python3
"""Step D2 Task 1 — stratified reading selection for the dev/test label asset
(docs/plans/hanja-context-scaling-plan.md §9, docs/hanja-context-quality-scaling-research.md §5.1).

Selects 150 readings from inventory/targets.tsv, stratified over three axes
(3 x 3 x 2 = 18 cells):

    frequency band   head (global freq rank 1-100) / mid (101-500) / tail (501+)
    candidate count  c2 (exactly 2) / c34 (3-4) / c5p (5+)
    native-homograph flag   flag (reading is in flagged-readings.tsv, 482 rows) / noflag

Hard exclusion (never selected, never counted in any cell's population): every
reading that appears in eval/hanja-context-eval-set.tsv's 읽기 column (31
readings as of this writing) — the whole point of D2 is a dev/test asset that
does not overlap the existing curated eval set.

Judgment calls (see the script's own header comments in the output file, and
the D2 task report):
  - freq_rank is computed over the FULL targets.tsv population (3,395 rows,
    stable sort by (-total_freq, reading) to break ties deterministically)
    BEFORE the eval-set exclusion is applied. This keeps "head/mid/tail" a
    property of the inventory itself (unaffected by which 31 readings happen
    to already have curated eval rows), rather than shifting band boundaries
    depending on which readings are excludable. The eval exclusion is then
    applied as a separate filter on the SELECTABLE population.
  - 100 of the 3,395 target readings carry only 1 listed candidate in
    targets.tsv (dominance-forced entries — see targets.tsv's own header
    comment for `force_included_dominant_classified` etc.). These do not fit
    any of the three candidate-count buckets (c2/c34/c5p all require >=2) and
    are EXCLUDED from the stratification population entirely — a reading with
    a single candidate has no hanja-choice ambiguity for this label asset to
    exercise.
  - candidate count = the number of comma-separated `candidate:freq` entries
    in targets.tsv's 3rd column for that reading, counted as-is (no filtering
    by the listed freq, including any 0-freq tail entries already present in
    that file).

Allocation (§9 Task 1 spec): every non-empty cell gets min(3, population)
first; the remaining quota (150 - sum of those minimums) is apportioned
across cells proportional to population size via the largest-remainder
method (Hamilton apportionment), capped so no cell is ever asked for more
than its own population. Within a cell, candidates are drawn with
`random.Random(20260731)` from the cell's reading list SORTED BY READING
STRING FIRST (determinism independent of any upstream dict/set ordering) via
a single shared RNG consumed in a fixed cell-iteration order (band x bucket x
flag, in the order printed by the cell table) — re-running this script
reproduces byte-identical output.

Usage:
    python3 scripts/hanja-context/build_d2_readings.py
    python3 scripts/hanja-context/build_d2_readings.py --targets <path> --flagged <path> \\
        --eval-set <path> --out <path> --total 150 --seed 20260731
"""
from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc

TARGETS_TSV = hc.INVENTORY_DIR / "targets.tsv"
FLAGGED_TSV = hc.WORK_DIR / "native-homograph" / "flagged-readings.tsv"
D2_DIR = hc.WORK_DIR / "d2"
OUT_TSV = D2_DIR / "reading-selection.tsv"

SELECTION_SEED = 20260731
TOTAL_QUOTA = 150
MIN_PER_CELL = 3

BANDS = [("head", 1, 100), ("mid", 101, 500), ("tail", 501, None)]
BUCKETS = [("c2", 2, 2), ("c34", 3, 4), ("c5p", 5, None)]
FLAGS = ["flag", "noflag"]


class TargetRow:
    __slots__ = ("reading", "total_freq", "candidates_field", "cand_count")

    def __init__(self, reading: str, total_freq: int, candidates_field: str, cand_count: int) -> None:
        self.reading = reading
        self.total_freq = total_freq
        self.candidates_field = candidates_field
        self.cand_count = cand_count


def load_targets_raw(path: Path) -> list[TargetRow]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            reading, total_freq_str, candidates_field = cols
            cand_count = candidates_field.count(",") + 1 if candidates_field else 0
            rows.append(TargetRow(reading, int(total_freq_str), candidates_field, cand_count))
    return rows


def load_flagged_readings(path: Path) -> set[str]:
    flagged = set()
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if not cols or not cols[0]:
                continue
            flagged.add(cols[0])
    return flagged


def band_for_rank(rank: int) -> str | None:
    for name, lo, hi in BANDS:
        if rank >= lo and (hi is None or rank <= hi):
            return name
    return None


def bucket_for_count(count: int) -> str | None:
    for name, lo, hi in BUCKETS:
        if count >= lo and (hi is None or count <= hi):
            return name
    return None


def largest_remainder_apportionment(remaining_quota: int, weights: dict[str, int], caps: dict[str, int]) -> dict[str, int]:
    """Hamilton apportionment of `remaining_quota` seats across the keys of
    `weights`, proportional to weight, each key capped at `caps[key]`.
    Deterministic tie-break for the remainder round: larger weight first,
    then key string ascending."""
    result = {k: 0 for k in weights}
    active = {k: w for k, w in weights.items() if caps.get(k, 0) > 0}
    remaining = remaining_quota

    while remaining > 0 and active:
        total_weight = sum(active.values())
        if total_weight <= 0:
            break
        raw = {k: remaining * w / total_weight for k, w in active.items()}
        floors = {k: min(int(raw[k]), caps[k] - result[k]) for k in active}
        for k, f in floors.items():
            result[k] += f
        remaining -= sum(floors.values())
        if remaining <= 0:
            break
        # Largest-remainder round: sort by fractional remainder desc, then
        # weight desc, then key asc — assign 1 seat at a time, skipping any
        # key already at its cap.
        remainders = sorted(
            active.keys(),
            key=lambda k: (-(raw[k] - int(raw[k])), -weights[k], k),
        )
        progressed = False
        for k in remainders:
            if remaining <= 0:
                break
            if result[k] < caps[k]:
                result[k] += 1
                remaining -= 1
                progressed = True
        # Recompute active set (drop keys that hit their cap) for the next
        # loop iteration, in case `remaining` is still > 0 (can happen if
        # total_weight rounds every key's floor down to the same value and
        # the single remainder pass above still leaves seats unassigned
        # because every key was already at cap except a few).
        active = {k: w for k, w in weights.items() if result[k] < caps.get(k, 0)}
        if not progressed and remaining > 0 and not active:
            break
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--targets", type=Path, default=TARGETS_TSV)
    parser.add_argument("--flagged", type=Path, default=FLAGGED_TSV)
    parser.add_argument("--eval-set", type=Path, default=hc.EVAL_SET_TSV)
    parser.add_argument("--out", type=Path, default=OUT_TSV)
    parser.add_argument("--total", type=int, default=TOTAL_QUOTA)
    parser.add_argument("--seed", type=int, default=SELECTION_SEED)
    args = parser.parse_args()

    args.out.parent.mkdir(parents=True, exist_ok=True)

    all_rows = load_targets_raw(args.targets)
    flagged_readings = load_flagged_readings(args.flagged)
    eval_readings = set(hc.load_eval_readings(args.eval_set))

    # freq_rank over the FULL population (see module docstring judgment call).
    ranked = sorted(all_rows, key=lambda r: (-r.total_freq, r.reading))
    freq_rank: dict[str, int] = {r.reading: i + 1 for i, r in enumerate(ranked)}

    # Build the selectable population: exclude eval readings and single-candidate rows.
    cells: dict[str, list[TargetRow]] = {}
    excluded_eval = 0
    excluded_single_candidate = 0
    for row in all_rows:
        if row.reading in eval_readings:
            excluded_eval += 1
            continue
        bucket = bucket_for_count(row.cand_count)
        if bucket is None:
            excluded_single_candidate += 1
            continue
        band = band_for_rank(freq_rank[row.reading])
        assert band is not None  # every rank 1..N falls in exactly one band
        flag = "flag" if row.reading in flagged_readings else "noflag"
        cell_key = f"{band}_{bucket}_{flag}"
        cells.setdefault(cell_key, []).append(row)

    cell_order = [
        f"{band}_{bucket}_{flag}"
        for band, _lo, _hi in BANDS
        for bucket, _clo, _chi in BUCKETS
        for flag in FLAGS
    ]

    populations = {k: len(cells.get(k, [])) for k in cell_order}
    nonempty = {k: v for k, v in populations.items() if v > 0}

    initial = {k: min(MIN_PER_CELL, v) for k, v in nonempty.items()}
    assigned_so_far = sum(initial.values())
    remaining_quota = args.total - assigned_so_far
    if remaining_quota < 0:
        print(
            f"ERROR: {len(nonempty)} non-empty cells x min {MIN_PER_CELL} = {assigned_so_far} "
            f"already exceeds --total={args.total}. Lower MIN_PER_CELL or raise --total.",
            file=sys.stderr,
        )
        return 1

    caps = {k: nonempty[k] - initial[k] for k in nonempty}  # remaining room per cell
    extra = largest_remainder_apportionment(remaining_quota, weights=nonempty, caps=caps)

    final_quota = {k: initial[k] + extra.get(k, 0) for k in nonempty}
    total_final = sum(final_quota.values())

    rng = random.Random(args.seed)
    selected_by_cell: dict[str, list[TargetRow]] = {}
    for cell_key in cell_order:
        quota = final_quota.get(cell_key, 0)
        if quota <= 0:
            continue
        pool = sorted(cells[cell_key], key=lambda r: r.reading)
        chosen = rng.sample(pool, k=quota)
        chosen.sort(key=lambda r: r.reading)
        selected_by_cell[cell_key] = chosen

    # Output, grouped by cell (matches cell_order), reading ascending within cell.
    header_lines = [
        "# format: d2-reading-selection v1 reading<TAB>total_freq<TAB>freq_rank<TAB>band<TAB>cand_count<TAB>cand_bucket<TAB>native_flag<TAB>cell<TAB>candidates",
        f"# seed={args.seed} total_quota={args.total} min_per_cell={MIN_PER_CELL} selected={total_final}",
        f"# excluded: eval_set_readings={excluded_eval} single_candidate_readings={excluded_single_candidate} "
        f"(neither counted in any cell population)",
        "# cell population/allocation table (band_bucket_flag -> population, initial(min3-capped), extra(largest-remainder), final):",
    ]
    for cell_key in cell_order:
        pop = populations[cell_key]
        if pop == 0:
            header_lines.append(f"#   {cell_key}: population=0 (empty, skipped)")
            continue
        header_lines.append(
            f"#   {cell_key}: population={pop} initial={initial[cell_key]} "
            f"extra={extra.get(cell_key, 0)} final={final_quota[cell_key]}"
        )
    header_lines.append(f"# TOTAL: population={sum(populations.values())} selected={total_final}")

    with args.out.open("w", encoding="utf-8") as f:
        for line in header_lines:
            f.write(line + "\n")
        for cell_key in cell_order:
            for row in selected_by_cell.get(cell_key, []):
                band = band_for_rank(freq_rank[row.reading])
                bucket = bucket_for_count(row.cand_count)
                flag = "flag" if row.reading in flagged_readings else "noflag"
                cols = [
                    row.reading, str(row.total_freq), str(freq_rank[row.reading]), band,
                    str(row.cand_count), bucket, flag, cell_key, row.candidates_field,
                ]
                f.write("\t".join(cols) + "\n")

    print(f"seed={args.seed} total_quota={args.total} min_per_cell={MIN_PER_CELL} selected={total_final}")
    print(f"excluded: eval_set_readings={excluded_eval} single_candidate_readings={excluded_single_candidate}")
    print(f"{'cell':32s} {'population':>10s} {'initial':>8s} {'extra':>6s} {'final':>6s}")
    for cell_key in cell_order:
        pop = populations[cell_key]
        if pop == 0:
            print(f"{cell_key:32s} {0:>10d} {'-':>8s} {'-':>6s} {'-':>6s}")
            continue
        print(f"{cell_key:32s} {pop:>10d} {initial[cell_key]:>8d} {extra.get(cell_key, 0):>6d} {final_quota[cell_key]:>6d}")
    print(f"{'TOTAL':32s} {sum(populations.values()):>10d} {'':>8s} {'':>6s} {total_final:>6d}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
