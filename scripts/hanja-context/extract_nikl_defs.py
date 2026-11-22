#!/usr/bin/env python3
"""Step 5a supplement — NIKL dictionary 뜻풀이(definition) extraction.

User-approved supplement to the step 5a offline pipeline (문맥 기반 한자 변환,
docs/plans/context-aware-hanja-conversion.md §7 5a): extracts 국립국어원
dictionary definitions (뜻풀이) ONLY as a labeled context-signal source for
the hanja association table. 예문/examples are deliberately NOT extracted —
license + user decision (NIKL dictionaries are CC-BY-SA 2.0 KR, but example
sentences quote non-open publications; definitions are NIKL-authored).

Source (read-only git submodule — never modified):
    /Volumes/Workbench/wooriHanjaModel/data/korean-dict-nikl/
      stdict/    표준국어대사전  88 XML chunks (~656MB, 5,000 <item>/chunk)
      opendict/  우리말샘       24 XML chunks (~1.7GB, 50,000 <item>/chunk)

Verified structure (probed 2026-07-08 on stdict 005000/220000/436144.xml and
opendict 0050000/0600000/1198386.xml — element paths identical in all):
  - stdict: <original_language_info> ONLY at item/word_info/… — per-ENTRY
    (repeated for 혼종어 segments). <definition> ONLY at
    item/word_info/pos_info/comm_pattern_info/sense_info/definition
    (per-sense). => all senses of an entry share the entry-level hanja
    origin, so every definition of a validated entry is associated with
    its (reading, hanja) pair.
  - opendict: each <item> is a single (word, sense) row — exactly one
    <senseInfo> per item (0 multi-sense in 148,435 probed items).
    <original_language_info> per-entry under <wordInfo>. Only the DIRECT
    senseInfo/definition is taken; senseInfo/proverb_info/definition
    (definitions of proverbs attached to the sense, not of the headword)
    is excluded by using the direct-child path.
  - opendict/0300000.xml contains a literal U+001D control char inside a
    definition CDATA (XML-1.0-invalid; aborts expat mid-chunk), so every
    chunk is read through a byte-sanitizing wrapper that maps invalid
    control bytes to spaces; affected chunks are listed in the stats.

Per entry: clean the headword to a hangul-only reading r (strips homonym
digits, '-', '^', spaces, anything non-hangul); fast-reject unless r is a
target reading (inventory/targets.tsv). Collect contiguous CJK-ideograph
runs from the 한자-typed original_language field(s); the fields are noisy
(▽ markers, historic hangul split runs), so the concatenation of all runs
is also tried. Accept the first candidate h with len(h) == len(r) that is
in the target's candidate set (membership in targets.tsv also implies the
pair exists in woorilee/data/hanja/hanja.txt). Definitions are cleaned
(CDATA remnants + inner <sub>/<sup>-style tags stripped, whitespace
collapsed), dropped if < 5 chars, and exact (r, h, definition) duplicates
are skipped across sources (stdict processed first).

Run (smoke test on 1 chunk each first; the full pass takes a few minutes —
use Bash run_in_background and poll the log if launching from an agent):
    python3 scripts/hanja-context/extract_nikl_defs.py --limit-chunks 1
    python3 scripts/hanja-context/extract_nikl_defs.py

Writes:
    /Volumes/Workbench/wooriHanjaModel/work/hanja-context/nikl/definitions.tsv
    /Volumes/Workbench/wooriHanjaModel/work/hanja-context/nikl/nikl-stats.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc

NIKL_DATA_DIR = hc.WORKSPACE_ROOT / "data/korean-dict-nikl"
NIKL_OUT_DIR = hc.WORK_DIR / "nikl"
TARGETS_TSV = hc.INVENTORY_DIR / "targets.tsv"

MIN_DEFINITION_CHARS = 5

CJK_RUN_RE = re.compile(r"[一-鿿㐀-䶿]+")
NON_HANGUL_RE = re.compile(r"[^가-힣]+")
INNER_TAG_RE = re.compile(r"<[^<>]+>")
WHITESPACE_RE = re.compile(r"\s+")

# XML 1.0 forbids control chars < 0x20 except tab/LF/CR, even inside CDATA —
# opendict/0300000.xml has a literal U+001D in a definition (line 208356),
# which aborts expat mid-chunk. Replace such bytes with spaces while reading
# (safe for UTF-8: control bytes never occur inside multibyte sequences).
_SANITIZE_TABLE = bytes(
    0x20 if b < 0x20 and b not in (0x09, 0x0A, 0x0D) else b for b in range(256)
)


class _SanitizedXMLFile:
    """Read-only binary file wrapper for ET.iterparse that replaces
    XML-1.0-invalid control bytes with spaces. `dirty` records whether any
    byte was actually replaced."""

    def __init__(self, path: Path) -> None:
        self._file = open(path, "rb")
        self.dirty = False

    def read(self, size: int = -1) -> bytes:
        block = self._file.read(size)
        cleaned = block.translate(_SANITIZE_TABLE)
        if cleaned != block:
            self.dirty = True
        return cleaned

    def close(self) -> None:
        self._file.close()

# (source label, chunk dir, headword path, original_language_info path,
#  definition path) — paths are item-relative, verified per module docstring.
SOURCES: list[tuple[str, Path, str, str, str]] = [
    (
        "stdict",
        NIKL_DATA_DIR / "stdict",
        "word_info/word",
        "word_info/original_language_info",
        "word_info/pos_info/comm_pattern_info/sense_info/definition",
    ),
    (
        "opendict",
        NIKL_DATA_DIR / "opendict",
        "wordInfo/word",
        "wordInfo/original_language_info",
        "senseInfo/definition",
    ),
]

# (reading, candidate) pairs the user flagged as signal-thin in the wiki
# corpus pass — reported explicitly (수도 = all three main candidates).
THIN_WATCHLIST: list[tuple[str, str]] = [
    ("장관", "壯觀"),
    ("연기", "煙氣"),
    ("연기", "延期"),
    ("국화", "國花"),
    ("유산", "流産"),
    ("선물", "先物"),
    ("이상", "理想"),
    ("의사", "義士"),
    ("수도", "首都"),
    ("수도", "修道"),
    ("수도", "水道"),
]


def load_targets(path: Path = TARGETS_TSV) -> dict[str, list[str]]:
    """reading -> candidate hanja list, in targets.tsv order (freq desc)."""
    targets: dict[str, list[str]] = {}
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
                candidate, _, _freq = item.rpartition(":")
                if candidate:
                    candidates.append(candidate)
            targets[reading] = candidates
    return targets


def clean_definition(text: str) -> str:
    """Strip CDATA remnants and inner <sub>/<sup>-style tags, collapse
    whitespace."""
    t = text.replace("<![CDATA[", "").replace("]]>", "")
    t = INNER_TAG_RE.sub("", t)
    return WHITESPACE_RE.sub(" ", t).strip()


def hanja_origin_candidates(hanja_field_texts: list[str]) -> list[str]:
    """Candidate hanja strings from the 한자-typed original_language texts:
    every contiguous CJK run in document order, plus (when the runs are
    split — noise markers inside a field, or 혼종어-style multiple fields)
    the concatenation of all runs. Validation against targets.tsv gates
    correctness; this only widens recall on noisy fields."""
    runs: list[str] = []
    for text in hanja_field_texts:
        runs.extend(CJK_RUN_RE.findall(text))
    ordered = list(dict.fromkeys(runs))
    if len(runs) > 1:
        concatenated = "".join(runs)
        if concatenated not in ordered:
            ordered.append(concatenated)
    return ordered


def process_source(
    source: str,
    directory: Path,
    word_path: str,
    oli_path: str,
    defn_path: str,
    targets: dict[str, list[str]],
    seen_rows: set[tuple[str, str, str]],
    rows: list[tuple[str, str, str, str]],
    limit_chunks: int | None,
) -> dict:
    files = sorted(directory.glob("*.xml"))
    if limit_chunks is not None:
        files = files[:limit_chunks]
    stats = {
        "chunk_files": len(files),
        "parse_errors": [],
        "sanitized_chunks": [],
        "entries_scanned": 0,
        "hanja_typed_entries": 0,
        "target_reading_entries": 0,
        "validated_entries": 0,
        "validated_pairs": 0,
        "definition_rows_emitted": 0,
        "definitions_dropped_short": 0,
        "duplicate_rows_skipped": 0,
    }
    validated_pairs: set[tuple[str, str]] = set()
    started = time.monotonic()

    for index, path in enumerate(files, start=1):
        source_file = _SanitizedXMLFile(path)
        try:
            context = ET.iterparse(source_file, events=("start", "end"))
            _, root = next(context)
            for event, elem in context:
                if event != "end" or elem.tag != "item":
                    continue
                stats["entries_scanned"] += 1

                hanja_texts: list[str] = []
                for oli in elem.iterfind(oli_path):
                    lang_el = oli.find("language_type")
                    lang = (lang_el.text or "").strip() if lang_el is not None else ""
                    if lang != "한자":
                        continue
                    ol_el = oli.find("original_language")
                    if ol_el is None:
                        continue
                    text = "".join(ol_el.itertext())
                    if text:
                        hanja_texts.append(text)
                if hanja_texts:
                    stats["hanja_typed_entries"] += 1

                word_el = elem.find(word_path)
                word_text = "".join(word_el.itertext()) if word_el is not None else ""
                reading = NON_HANGUL_RE.sub("", word_text)
                candidates = targets.get(reading) if reading else None
                if candidates is not None:
                    stats["target_reading_entries"] += 1

                if candidates is not None and hanja_texts:
                    syllables = len(reading)
                    hanja = None
                    for candidate in hanja_origin_candidates(hanja_texts):
                        if len(candidate) == syllables and candidate in candidates:
                            hanja = candidate
                            break
                    if hanja is not None:
                        stats["validated_entries"] += 1
                        validated_pairs.add((reading, hanja))
                        for defn_el in elem.iterfind(defn_path):
                            cleaned = clean_definition("".join(defn_el.itertext()))
                            if len(cleaned) < MIN_DEFINITION_CHARS:
                                stats["definitions_dropped_short"] += 1
                                continue
                            key = (reading, hanja, cleaned)
                            if key in seen_rows:
                                stats["duplicate_rows_skipped"] += 1
                                continue
                            seen_rows.add(key)
                            rows.append((reading, hanja, source, cleaned))
                            stats["definition_rows_emitted"] += 1
                root.clear()
        except ET.ParseError as error:
            stats["parse_errors"].append(f"{path.name}: {error}")
        finally:
            source_file.close()
        if source_file.dirty:
            stats["sanitized_chunks"].append(path.name)
        elapsed = time.monotonic() - started
        print(
            f"[{source}] chunk {index}/{len(files)} {path.name} — "
            f"entries={stats['entries_scanned']} rows={stats['definition_rows_emitted']} "
            f"({elapsed:.0f}s)",
            flush=True,
        )

    stats["validated_pairs"] = len(validated_pairs)
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract NIKL dictionary definitions (뜻풀이 only) for target (reading, hanja) pairs."
    )
    parser.add_argument(
        "--limit-chunks",
        type=int,
        default=None,
        help="process only the first N XML chunks of each dictionary (smoke test)",
    )
    args = parser.parse_args()

    NIKL_OUT_DIR.mkdir(parents=True, exist_ok=True)
    targets = load_targets()

    seen_rows: set[tuple[str, str, str]] = set()
    rows: list[tuple[str, str, str, str]] = []
    source_stats: dict[str, dict] = {}
    for source, directory, word_path, oli_path, defn_path in SOURCES:
        source_stats[source] = process_source(
            source, directory, word_path, oli_path, defn_path,
            targets, seen_rows, rows, args.limit_chunks,
        )

    counts_by_pair: dict[tuple[str, str], int] = {}
    for reading, hanja, _source, _definition in rows:
        counts_by_pair[(reading, hanja)] = counts_by_pair.get((reading, hanja), 0) + 1
    rows_by_source = {
        source: sum(1 for _r, _h, s, _d in rows if s == source) for source in source_stats
    }
    total_dupes = sum(s["duplicate_rows_skipped"] for s in source_stats.values())
    total_short = sum(s["definitions_dropped_short"] for s in source_stats.values())

    out_tsv = NIKL_OUT_DIR / "definitions.tsv"
    with out_tsv.open("w", encoding="utf-8") as f:
        f.write(
            "# definitions.tsv — step 5a supplement: NIKL 뜻풀이 추출 "
            "(문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §7 5a)\n"
        )
        f.write(
            f"# Sources: {NIKL_DATA_DIR}/stdict (표준국어대사전, "
            f"{source_stats['stdict']['chunk_files']} chunks) + "
            f"{NIKL_DATA_DIR}/opendict (우리말샘, "
            f"{source_stats['opendict']['chunk_files']} chunks); "
            "license CC-BY-SA 2.0 KR; 뜻풀이(definitions) ONLY — "
            "예문/examples deliberately not extracted (license + user decision)\n"
        )
        f.write(f"# Extracted: {date.today().isoformat()} by scripts/hanja-context/extract_nikl_defs.py\n")
        f.write("# Format: reading<TAB>hanja<TAB>source<TAB>definition  (source ∈ stdict|opendict)\n")
        f.write(
            "# Rules: reading = headword stripped to hangul-only (homonym digits/-/^/spaces removed); "
            "hanja = contiguous CJK run(s) from 한자-typed original_language fields (run concatenation "
            "tried for noisy/split fields), run length == reading syllable count; (reading,hanja) must "
            "be a candidate pair in inventory/targets.tsv (implies presence in hanja.txt); definitions "
            f"cleaned (inner tags stripped, whitespace collapsed), dropped if <{MIN_DEFINITION_CHARS} chars; "
            "exact (reading,hanja,definition) duplicates skipped across sources (stdict first)\n"
        )
        f.write(
            f"# Counts: rows={len(rows)} stdict_rows={rows_by_source.get('stdict', 0)} "
            f"opendict_rows={rows_by_source.get('opendict', 0)} distinct_pairs={len(counts_by_pair)} "
            f"dupes_skipped={total_dupes} short_dropped={total_short}\n"
        )
        for reading, hanja, source, definition in rows:
            f.write(f"{reading}\t{hanja}\t{source}\t{definition}\n")

    eval_readings = hc.load_eval_readings()
    per_eval_series = {
        reading: {
            candidate: counts_by_pair.get((reading, candidate), 0)
            for candidate in targets.get(reading, [])
        }
        for reading in eval_readings
    }
    thin_watchlist = {
        f"{reading}/{hanja}": counts_by_pair.get((reading, hanja), 0)
        for reading, hanja in THIN_WATCHLIST
    }

    stats = {
        "generated": date.today().isoformat(),
        "script": "scripts/hanja-context/extract_nikl_defs.py",
        "limit_chunks": args.limit_chunks,
        "scope": "뜻풀이(definitions) only; 예문/examples deliberately excluded (license + user decision)",
        "structure_findings": {
            "stdict": (
                "original_language_info per-ENTRY (item/word_info/original_language_info only); "
                "definitions per-sense (item/word_info/pos_info/comm_pattern_info/sense_info/definition); "
                "all senses of an entry share the entry-level hanja origin"
            ),
            "opendict": (
                "each item is a single (word, sense) row — exactly one senseInfo per item; "
                "original_language_info per-ENTRY (item/wordInfo/original_language_info only); "
                "only direct senseInfo/definition extracted — senseInfo/proverb_info/definition excluded"
            ),
        },
        "sources": source_stats,
        "totals": {
            "definition_rows": len(rows),
            "rows_by_source": rows_by_source,
            "distinct_validated_pairs": len(counts_by_pair),
            "duplicate_rows_skipped": total_dupes,
            "definitions_dropped_short": total_short,
        },
        "per_eval_series_definition_counts": per_eval_series,
        "thin_watchlist_definition_counts": thin_watchlist,
        "thin_watchlist_zero": [pair for pair, count in thin_watchlist.items() if count == 0],
    }
    out_stats = NIKL_OUT_DIR / "nikl-stats.json"
    with out_stats.open("w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\nWrote {len(rows)} definition rows to {out_tsv}")
    print(f"Wrote stats to {out_stats}")
    for source, s in source_stats.items():
        print(
            f"  [{source}] scanned={s['entries_scanned']} hanja_typed={s['hanja_typed_entries']} "
            f"target_reading={s['target_reading_entries']} validated_entries={s['validated_entries']} "
            f"validated_pairs={s['validated_pairs']} rows={s['definition_rows_emitted']} "
            f"dupes={s['duplicate_rows_skipped']} short={s['definitions_dropped_short']} "
            f"parse_errors={len(s['parse_errors'])} sanitized_chunks={s['sanitized_chunks']}"
        )
    print("\nPer-eval-27-series definition counts per candidate:")
    for reading in eval_readings:
        parts = [f"{c}←{n}개" for c, n in per_eval_series.get(reading, {}).items()]
        print(f"  {reading}: {', '.join(parts)}")
    print("\nThin-watchlist definition counts:")
    for pair, count in thin_watchlist.items():
        flag = "  <-- STILL ZERO" if count == 0 else ""
        print(f"  {pair}: {count}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
