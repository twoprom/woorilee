"""Shared helpers for the step 5a offline data pipeline (문맥 기반 한자 변환).

Mirrors, byte-for-byte in behavior, two pieces of runtime Swift logic so the
offline target/anchor inventories agree with what the app actually does:

- `HanjaFrequencyTable(characterFrequencyURLs:wordFrequencyURLs:)` in
  woorilee/HanjaDictionaryService.swift — merged frequency table (character
  file raw + word file decoded via `% 1_000_000`, duplicate key -> max).
- `buildDominantHanjaMap` in woorilee/HanjaContextRanker.swift — reading ->
  dominant hanja (dominant iff exactly one candidate, or top decoded freq >=
  dominanceRatio * runner-up, with runner-up 0 counting as dominant).

See scripts/hanja-context/README.md for the full pipeline contract.
"""
from __future__ import annotations

from pathlib import Path

WOORILEE_ROOT = Path(__file__).resolve().parents[2]
WORKSPACE_ROOT = WOORILEE_ROOT.parent / "wooriHanjaModel"

HANJA_TXT = WOORILEE_ROOT / "woorilee/data/hanja/hanja.txt"
FREQ_HANJA_TXT = WOORILEE_ROOT / "woorilee/data/hanja/freq-hanja.txt"
FREQ_HANJAEO_TXT = WOORILEE_ROOT / "woorilee/data/hanja/freq-hanjaeo.txt"
EVAL_SET_TSV = WOORILEE_ROOT / "eval/hanja-context-eval-set.tsv"

WORK_DIR = WORKSPACE_ROOT / "work/hanja-context"
INVENTORY_DIR = WORK_DIR / "inventory"
FILTERED_DIR = WORK_DIR / "filtered"

DOMINANCE_RATIO = 5


def read_dictionary_lines(path: Path = HANJA_TXT) -> list[str]:
    """Non-comment, non-blank lines of hanja.txt, whitespace-stripped."""
    lines = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            lines.append(line)
    return lines


def parse_reading_hanja(line: str) -> tuple[str, str] | None:
    """Split a hanja.txt data line into (reading, hanja), ignoring the comment
    field. Mirrors buildDominantHanjaMap's "first colon, second colon, ignore
    the rest" parse — a colon inside the comment does not create a 4th field."""
    parts = line.split(":", 2)
    if len(parts) < 2:
        return None
    reading, hanja = parts[0], parts[1]
    if not reading or not hanja:
        return None
    return reading, hanja


def candidates_by_reading(lines: list[str]) -> dict[str, list[str]]:
    """reading -> RAW (non-deduped) list of hanja values, in file order.

    Kept non-deduped on purpose to exactly mirror buildDominantHanjaMap's
    `candidatesByReading` (built directly from dictionary lines, one append
    per line, no dedup)."""
    result: dict[str, list[str]] = {}
    for line in lines:
        parsed = parse_reading_hanja(line)
        if parsed is None:
            continue
        reading, hanja = parsed
        result.setdefault(reading, []).append(hanja)
    return result


def dedup_candidates_by_reading(raw: dict[str, list[str]]) -> dict[str, list[str]]:
    """reading -> deduped candidate hanja list, first-occurrence order.

    This is a separate view from `candidates_by_reading`'s raw output — used
    for target/anchor candidate lists, never for the dominance calculation."""
    result: dict[str, list[str]] = {}
    for reading, values in raw.items():
        seen: set[str] = set()
        deduped: list[str] = []
        for value in values:
            if value not in seen:
                seen.add(value)
                deduped.append(value)
        result[reading] = deduped
    return result


def load_merged_frequency(
    char_path: Path = FREQ_HANJA_TXT, word_path: Path = FREQ_HANJAEO_TXT
) -> dict[str, int]:
    """Merged frequency table: char file raw + word file decoded (`% 1_000_000`),
    duplicate key -> max. Mirrors `HanjaFrequencyTable(characterFrequencyURLs:wordFrequencyURLs:)`.

    Every key in freq-hanja.txt is a single hanja character; multi-character
    words only ever come from freq-hanjaeo.txt, so this single merged table
    also serves as the "decoded word freq" lookup anchors.py needs (no
    separate freq-hanjaeo-only table required)."""
    merged: dict[str, int] = {}

    def ingest(path: Path, decode: bool) -> None:
        with path.open(encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.rstrip("\n")
                if not line:
                    continue
                sep = line.find(":")
                if sep == -1:
                    continue
                key = line[:sep]
                value_str = line[sep + 1 :]
                try:
                    parsed = int(value_str)
                except ValueError:
                    continue
                value = parsed % 1_000_000 if decode else parsed
                if key not in merged or value > merged[key]:
                    merged[key] = value

    ingest(char_path, decode=False)
    ingest(word_path, decode=True)
    return merged


def build_dominant_map(
    raw_candidates_by_reading: dict[str, list[str]],
    frequency: dict[str, int],
    dominance_ratio: int = DOMINANCE_RATIO,
) -> dict[str, str]:
    """reading -> dominant hanja. Mirrors `buildDominantHanjaMap` in
    woorilee/HanjaContextRanker.swift exactly: dominant iff exactly one
    candidate, or top decoded freq >= dominance_ratio * runner-up freq (with
    runner-up 0 counting as dominant). Operates on the RAW (non-deduped)
    per-reading list, same as the Swift function."""
    result: dict[str, str] = {}
    for reading, values in raw_candidates_by_reading.items():
        if len(values) == 1:
            result[reading] = values[0]
            continue
        ranked = sorted(values, key=lambda v: -frequency.get(v, 0))
        top_freq = frequency.get(ranked[0], 0)
        runner_up_freq = frequency.get(ranked[1], 0)
        if runner_up_freq == 0 or top_freq >= dominance_ratio * runner_up_freq:
            result[reading] = ranked[0]
    return result


def load_eval_readings(path: Path = EVAL_SET_TSV) -> list[str]:
    """Distinct 읽기 column values from the eval set, first-occurrence order."""
    seen: set[str] = set()
    order: list[str] = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            reading = cols[1]
            if reading not in seen:
                seen.add(reading)
                order.append(reading)
    return order
