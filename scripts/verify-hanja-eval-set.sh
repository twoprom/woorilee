#!/usr/bin/env python3
"""Verify eval/hanja-context-eval-set.tsv against woorilee/data/hanja/hanja.txt.

For every data row (문장, 읽기, 정답한자), asserts that "읽기:정답한자:" exists as a
line prefix in hanja.txt. Prints total rows, per-series (읽기) counts, and any
failing rows. Exits non-zero if any row fails or the row count is below 100.
"""

import sys
from pathlib import Path

MIN_ROWS = 100

REPO_ROOT = Path(__file__).resolve().parent.parent
EVAL_SET_PATH = REPO_ROOT / "eval/hanja-context-eval-set.tsv"
DICTIONARY_PATH = REPO_ROOT / "woorilee/data/hanja/hanja.txt"


def load_rows(path):
    rows = []
    with path.open(encoding="utf-8") as f:
        for line_number, raw_line in enumerate(f, start=1):
            line = raw_line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            columns = line.split("\t")
            if len(columns) != 3:
                print(f"MALFORMED line {line_number}: expected 3 tab-separated columns, got {len(columns)}: {line!r}")
                continue
            sentence, reading, answer = columns
            rows.append((line_number, sentence, reading, answer))
    return rows


def load_dictionary_keys(path):
    """Return the set of "읽기:한자:" prefixes present in hanja.txt."""
    keys = set()
    with path.open(encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split(":")
            if len(parts) < 2:
                continue
            keys.add(f"{parts[0]}:{parts[1]}:")
    return keys


def main():
    if not EVAL_SET_PATH.exists():
        print(f"Eval set not found: {EVAL_SET_PATH}", file=sys.stderr)
        return 1
    if not DICTIONARY_PATH.exists():
        print(f"Dictionary not found: {DICTIONARY_PATH}", file=sys.stderr)
        return 1

    rows = load_rows(EVAL_SET_PATH)
    dictionary_keys = load_dictionary_keys(DICTIONARY_PATH)

    per_series = {}
    failures = []
    for line_number, sentence, reading, answer in rows:
        per_series[reading] = per_series.get(reading, 0) + 1
        expected_key = f"{reading}:{answer}:"
        if expected_key not in dictionary_keys:
            failures.append((line_number, reading, answer, sentence))

    print(f"Total data rows: {len(rows)}")
    print("Per-series counts:")
    for reading in sorted(per_series):
        print(f"  {reading}: {per_series[reading]}")

    if failures:
        print(f"\nFAILING ROWS ({len(failures)}):")
        for line_number, reading, answer, sentence in failures:
            print(f"  line {line_number}: {reading}:{answer} not found in dictionary :: {sentence}")

    ok = True
    if failures:
        ok = False
    if len(rows) < MIN_ROWS:
        print(f"\nRow count {len(rows)} is below minimum required {MIN_ROWS}.")
        ok = False

    if ok:
        print(f"\nOK: all {len(rows)} rows verified against {DICTIONARY_PATH}.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
