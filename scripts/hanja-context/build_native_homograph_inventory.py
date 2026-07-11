#!/usr/bin/env python3
"""Step 7a — 고유어 동음이의어 플래그 인벤토리 (문맥 기반 한자 변환,
docs/plans/context-aware-hanja-conversion.md §10 단계 7 / §7 5a 파이프라인 재사용).

Builds the user-review gate report for step 7: among readings that already
pass the step 6 auto-convert word-evidence gate (docs §9 — top hanja
candidate has decoded word-table frequency >= 500, so it *would* preview
automatically), which readings also have a non-hanja-origin (고유어/외래어/
혼종어) NIKL headword with the SAME reading — i.e. readings where
auto-conversion risks clobbering a native-Korean homograph (flag case: 구두
"신발" vs 口頭 1,516; non-flag case: 지금/只今 33,017, no native homograph).

Inputs (read-only):
    woorilee/data/hanja/hanja.txt              읽기:한자:주석 dictionary lines
    woorilee/data/hanja/freq-hanjaeo.txt        한자:빈도 (빈도 = class*1e6 + decoded_freq)
    woorilee/data/hanja/hanja-context.txt       기존 5b 연관표 (존재 여부 확인용)
    /Volumes/Workbench/wooriHanjaModel/data/korean-dict-nikl/{stdict,opendict}/*.xml
        국립국어원 표준국어대사전(88 chunks)·우리말샘(24 chunks) — read-only git
        submodule, CC-BY-SA 2.0 KR. Only <word>, <word_type>, <pos> fields are
        read (뜻풀이/예문/미디어는 손대지 않는다 — 이번 단계에 불필요).
    /Volumes/Workbench/wooriHanjaModel/work/hanja-context/filtered/part-*.txt
        5a 위키백과 필터 통과 문장 (병기 근사치 샘플링 소스; 있으면 사용, 없으면
        건너뛰고 그 사실을 보고).

Method:
    1. Gate-passed readings: for each 읽기 in hanja.txt, if >=1 candidate 한자
       has decoded freq-hanjaeo (value % 1_000_000) >= GATE_THRESHOLD (500,
       matching the step 6 gate constant), the reading is gate-passed. Only
       freq-hanjaeo.txt is consulted (word-table only, per step 6 design —
       NOT the char+word merged table `hanja_common.load_merged_frequency`).
       1-syllable readings never appear in freq-hanjaeo.txt, so they drop out
       automatically.
    2. NIKL scan: single streaming pass per source (stdict then opendict,
       reusing extract_nikl_defs.py's control-byte sanitizer for the known
       opendict/0300000.xml XML-1.0-invalid byte). For every <item>, normalize
       the headword by stripping STRUCTURAL markers only (homonym digits, '-',
       '^', spaces, middle dots — see STRUCTURAL_MARK_RE; entries whose
       normalized form still contains non-syllable chars like jamo are
       rejected, not truncated) and fast-reject unless the result is a
       gate-passed reading. Read <word_type> directly (고유어/외래어/
       한자어/혼종어 — a first-class NIKL field, more reliable than inferring
       origin from <original_language_info> CJK-run heuristics); keep only
       고유어/외래어/혼종어 (한자어 and missing/other word_type are dropped —
       한자어 is the Sino-Korean homograph itself, not a native collision).
       Restrict to word_unit == 단어(stdict)/어휘(opendict) (single lexical entries) — 구/속담/관용구
       (~18% of stdict items) are phrase-length headwords that could only
       coincidentally collapse to a short reading after stripping spaces;
       excluded to cut noise, count logged in stats for transparency (not a
       silent drop — see summary JSON `word_unit_excluded`).
       NOTE: stdict and opendict use DIFFERENT literal values for the
       "single lexical entry" word_unit — stdict says 단어, opendict says
       어휘 (구/속담/관용구 are the phrase-type values in both). Both are
       accepted (see SINGLE_WORD_UNIT below); this was caught mid-run
       (opendict emitted 0/1.2M rows on the wrong single value) and fixed
       before the reported run.
    3. Row classification: each surviving row is "basis" (POS in the
       conversion-eligible class AND >=1 standard sense — see ELIGIBLE_POS /
       NONSTANDARD_SENSE_TYPES) or "reference" (matched but not basis; kept
       in the TSV for user review). A reading is FLAGGED iff it is
       gate-passed AND has >=1 BASIS row — per plan §10 설계 1 ("품사가 변환
       적격 계열"). Without this, 지금 would be wrongly flagged by the bound
       root 지금01('지금거리다'의 어근, 품사 없음) and a 방언 adverb row.
    4. Auxiliary stats (matched readings only — the full gate-passed set is
       ~19,870 readings, too large for O(N*freq_words) anchor/paren scans):
       - anchor count: per gate-passing candidate c, count of freq-hanjaeo.txt
         words w with len(w) > len(c) and c in w (substring containment,
         no dominance check — cheaper approximation of build_anchors.py's
         anchor concept, per task instructions).
       - paren approx: per gate-passing candidate c, count of literal
         "reading(c" occurrences in a BYTE-BUDGETED SAMPLE of
         work/hanja-context/filtered/part-*.txt (see PAREN_SAMPLE_BUDGET_BYTES
         — sampling is declared, not silently partial).
       - assoc_table_present: whether `reading:` appears as a line prefix in
         the existing woorilee/data/hanja/hanja-context.txt (5b output).

Reproducibility: run from the woorilee repo root —
    python3 scripts/hanja-context/build_native_homograph_inventory.py
    python3 scripts/hanja-context/build_native_homograph_inventory.py --limit-chunks 1   # smoke test

Writes (into /Volumes/Workbench/wooriHanjaModel/work/hanja-context/native-homograph/):
    inventory.tsv   — one row per (flagged reading, NIKL headword)
    summary.json    — counts, etymology breakdown, flag-check for 구두/지금, timing
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
from extract_nikl_defs import _SanitizedXMLFile  # reuse verified byte-sanitizing XML reader

# Headword normalization. extract_nikl_defs.py strips EVERYTHING non-hangul
# (NON_HANGUL_RE), which is fine there because a validated (reading, hanja)
# pair must also exist in targets.tsv. Here the reading match alone decides,
# so that blanket strip creates FALSE homographs: 'ㄱㄴㄷ-차례' would collapse
# to '차례' although it is read 기역니은디귿차례. Strip only STRUCTURAL
# markers (homonym digits, '-', '^', spaces, middle dots); if anything other
# than complete hangul syllables remains (jamo, latin, ...), the entry's
# reading is not the plain syllable string — reject it (counted in stats).
STRUCTURAL_MARK_RE = re.compile(r"[0-9\-\^\s·ㆍ]+")
NON_SYLLABLE_RE = re.compile(r"[^가-힣]")

NIKL_DATA_DIR = hc.WORKSPACE_ROOT / "data/korean-dict-nikl"
OUT_DIR = hc.WORK_DIR / "native-homograph"
FILTERED_DIR = hc.FILTERED_DIR
HANJA_CONTEXT_TXT = hc.WOORILEE_ROOT / "woorilee/data/hanja/hanja-context.txt"

GATE_THRESHOLD = 500  # mirrors the step 6 auto-convert word-evidence gate T (docs §9)

# (source label, chunk dir, headword path, word_type path, word_unit path, pos path, sense-type path)
# sense-type ("일반어"/"방언"/"옛말"/"북한어"/...) is a risk-assessment signal for
# the 7a user review — NOT a definition/example field (license-safe scope
# unchanged). Added mid-run after the smoke test surfaced common Sino-Korean
# readings (e.g. 가능/可能) flagged solely because of a RARE dialectal 고유어
# sense (가능 방언 = '가늠') — see build_native_homograph_inventory report.
SOURCES: list[tuple[str, Path, str, str, str, str, str]] = [
    ("stdict", NIKL_DATA_DIR / "stdict", "word_info/word", "word_info/word_type", "word_info/word_unit", "word_info/pos_info/pos", "word_info/pos_info/comm_pattern_info/sense_info/type"),
    ("opendict", NIKL_DATA_DIR / "opendict", "wordInfo/word", "wordInfo/word_type", "wordInfo/word_unit", "senseInfo/pos", "senseInfo/type"),
]

NATIVE_WORD_TYPES = {"고유어", "외래어", "혼종어"}

# ---- Flag-basis filters.
#
# RULE VERSION 7a-final-v2 (2026-07-10 사용자 확정 — 7a 게이트 통과, plan §10
# 7a "게이트 통과" 블록). 초판(v1) 게이트 보고 대비 사용자 확정 완화 규칙:
#   1. 정밀화: basis 근거를 "stdict + 고유어 + 일반어(의미유형) + 변환 적격
#      품사" 행으로 한정 (opendict 단독·외래어 단독·혼종어 귀화형 근거 제외).
#   2. 빈도 우세 예외: 읽기의 게이트 통과 후보 최대 하위값 >= 15,000이면
#      비플래그 (여자 40,668 / 시장 29,694 / 정치 28,903 / 이유 28,096 등
#      초고빈도 한자어는 자동 변환 유지).
#   3. 무신호(앵커·병기·연관표 전부 0) 읽기도 위 두 규칙을 통과하면 플래그
#      유지 (한글 유지가 안전 기본값; usageCount 개인화 경로 존재).
#
# POS: runtime eligibility is KiwiAnalysisService.isRealtimeAutoConvertEligibleTag
# (NNG/NNP/NNB/NR/SN/VV/VA/MM/MAG/MAJ/XPN/XR eligible; NP/IC/VX/XS* excluded).
# Mapped to NIKL POS labels: nouns/수사/부사/관형사/용언 count; 대명사(NP)·
# 감탄사(IC)·조사·어미·접사·보조용언 don't; "품사 없음" (stdict's label for
# bound 어근, e.g. 지금01 = '지금거리다'의 어근) doesn't — a bound root is never
# typed as a standalone word, and counting it would flag 지금/只今, the explicit
# non-flag case in plan §10. A multi-POS row counts if ANY of its POS is eligible.
ELIGIBLE_POS = {"명사", "의존 명사", "의존명사", "수사", "부사", "관형사", "동사", "형용사"}

# v1 sense rule (kept ONLY for the v1->v2 exclusion breakdown in the summary):
# a row whose EVERY sense was 방언/옛말/북한어/고어 did not flag in v1. v2 is
# stricter — it requires an explicit 일반어 sense.
NONSTANDARD_SENSE_TYPES = {"방언", "옛말", "북한어", "고어"}

# v2 빈도 우세 예외: readings whose top gate-passing candidate has decoded word
# freq >= this are never flagged.
FREQ_DOMINANCE_EXEMPT = 15_000

RULE_VERSION = "7a-final-v2"


def row_is_flag_basis_v1(pos_joined: str, sense_types_joined: str) -> bool:
    """Initial gate-report rule (eligible POS + not-all-nonstandard senses,
    any source/etymology). Kept only to decompose v1->v2 exclusions."""
    pos_ok = any(p in ELIGIBLE_POS for p in pos_joined.split("|") if p)
    sense_values = [t for t in sense_types_joined.split("|") if t]
    sense_ok = (not sense_values) or any(t not in NONSTANDARD_SENSE_TYPES for t in sense_values)
    return pos_ok and sense_ok


def row_is_flag_basis(source: str, word_type: str, pos_joined: str, sense_types_joined: str) -> bool:
    """v2 정밀화 rule: stdict + 고유어 + 일반어 sense + conversion-eligible POS."""
    if source != "stdict" or word_type != "고유어":
        return False
    if not any(p in ELIGIBLE_POS for p in pos_joined.split("|") if p):
        return False
    return "일반어" in {t for t in sense_types_joined.split("|") if t}


# "single lexical entry" word_unit value, per source — stdict/opendict use
# different literals for the same concept (구/속담/관용구 are phrase types in
# both; verified by direct XML probe on both submodule dirs).
SINGLE_WORD_UNIT = {"stdict": "단어", "opendict": "어휘"}

PAREN_SAMPLE_BUDGET_BYTES = 100_000_000  # ~100MB of ~433MB filtered corpus (~23%), declared sample


def load_word_only_frequency(path: Path = hc.FREQ_HANJAEO_TXT) -> dict[str, int]:
    """한자 -> decoded frequency (value % 1_000_000), word table ONLY (no char-table
    merge) — mirrors the step 6 gate's "단어표 전용 조회" rule exactly."""
    freq: dict[str, int] = {}
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            sep = line.find(":")
            if sep == -1:
                continue
            key = line[:sep]
            try:
                value = int(line[sep + 1 :]) % 1_000_000
            except ValueError:
                continue
            if key not in freq or value > freq[key]:
                freq[key] = value
    return freq


def build_gate_passed(
    dedup_by_reading: dict[str, list[str]], word_freq: dict[str, int], threshold: int = GATE_THRESHOLD
) -> dict[str, list[tuple[str, int]]]:
    """reading -> [(candidate, decoded_freq), ...] (freq desc), candidates with
    decoded word-table freq >= threshold only. Reading omitted if none qualify."""
    result: dict[str, list[tuple[str, int]]] = {}
    for reading, candidates in dedup_by_reading.items():
        passing = [(c, word_freq.get(c, 0)) for c in candidates if word_freq.get(c, 0) >= threshold]
        if passing:
            passing.sort(key=lambda t: -t[1])
            result[reading] = passing
    return result


def scan_nikl(
    gate_passed: dict[str, list[tuple[str, int]]],
    limit_chunks: int | None,
) -> tuple[list[tuple[str, str, str, str, str, str]], dict]:
    """Returns (rows, stats). rows = (reading, headword, word_type, pos_joined, source, sense_types_joined),
    restricted to gate_passed readings, NATIVE_WORD_TYPES, single-entry word_unit (SINGLE_WORD_UNIT)."""
    rows: list[tuple[str, str, str, str, str, str]] = []
    seen: set[tuple[str, str, str]] = set()  # (reading, headword, source) dedup
    stats = {
        "sources": {},
        "word_unit_excluded": 0,  # matched reading+native word_type but word_unit != 단어/어휘
        "word_type_missing_or_other": 0,  # matched reading, no usable word_type (incl. 한자어)
        "non_syllable_headword_rejected": 0,  # jamo/latin in headword, residual syllables matched a gate reading
    }

    for source, directory, word_path, wt_path, wu_path, pos_path, type_path in SOURCES:
        files = sorted(directory.glob("*.xml"))
        if limit_chunks is not None:
            files = files[:limit_chunks]
        source_stats = {
            "chunk_files": len(files),
            "parse_errors": [],
            "sanitized_chunks": [],
            "entries_scanned": 0,
            "reading_matches": 0,
            "rows_emitted": 0,
        }
        started = time.monotonic()
        for index, path in enumerate(files, start=1):
            source_file = _SanitizedXMLFile(path)
            try:
                context = ET.iterparse(source_file, events=("start", "end"))
                _, root = next(context)
                for event, elem in context:
                    if event != "end" or elem.tag != "item":
                        continue
                    source_stats["entries_scanned"] += 1

                    word_el = elem.find(word_path)
                    word_text = "".join(word_el.itertext()) if word_el is not None else ""
                    reading = STRUCTURAL_MARK_RE.sub("", word_text)
                    if not reading:
                        continue
                    if NON_SYLLABLE_RE.search(reading):
                        # Pronounced non-syllable chars (jamo/latin/...) — the
                        # headword's actual reading is not this syllable string
                        # ('ㄱㄴㄷ차례' is read 기역니은디귿차례, not 차례).
                        # Counted only when the residual syllable part would
                        # have matched a gate-passed reading (the interesting cases).
                        if NON_SYLLABLE_RE.sub("", reading) in gate_passed:
                            stats["non_syllable_headword_rejected"] += 1
                        continue
                    if reading not in gate_passed:
                        continue
                    source_stats["reading_matches"] += 1

                    wt_el = elem.find(wt_path)
                    word_type = (wt_el.text or "").strip() if wt_el is not None else ""
                    if word_type not in NATIVE_WORD_TYPES:
                        stats["word_type_missing_or_other"] += 1
                        continue

                    wu_el = elem.find(wu_path)
                    word_unit = (wu_el.text or "").strip() if wu_el is not None else ""
                    if word_unit != SINGLE_WORD_UNIT[source]:
                        stats["word_unit_excluded"] += 1
                        continue

                    pos_values = []
                    for pos_el in elem.iterfind(pos_path):
                        text = (pos_el.text or "").strip()
                        if text and text not in pos_values:
                            pos_values.append(text)
                    pos_joined = "|".join(pos_values)

                    sense_type_values = []
                    for type_el in elem.iterfind(type_path):
                        text = (type_el.text or "").strip()
                        if text and text not in sense_type_values:
                            sense_type_values.append(text)
                    sense_types_joined = "|".join(sense_type_values)

                    key = (reading, word_text, source)
                    if key in seen:
                        continue
                    seen.add(key)
                    rows.append((reading, word_text, word_type, pos_joined, source, sense_types_joined))
                    source_stats["rows_emitted"] += 1
                root.clear()
            except ET.ParseError as error:
                source_stats["parse_errors"].append(f"{path.name}: {error}")
            finally:
                source_file.close()
            if source_file.dirty:
                source_stats["sanitized_chunks"].append(path.name)
            elapsed = time.monotonic() - started
            print(
                f"[{source}] chunk {index}/{len(files)} {path.name} — "
                f"entries={source_stats['entries_scanned']} rows={source_stats['rows_emitted']} "
                f"({elapsed:.0f}s)",
                flush=True,
            )
        stats["sources"][source] = source_stats

    return rows, stats


def compute_anchor_counts(candidates: list[str], freq_words: list[str]) -> dict[str, int]:
    """candidate -> count of freq_words properly containing it as a substring
    (len(w) > len(c) and c in w). No dominance check (per task scope — coarse
    signal-sufficiency approximation, not the precise build_anchors.py anchor set)."""
    counts = {c: 0 for c in candidates}
    for c in candidates:
        n = 0
        for w in freq_words:
            if len(w) > len(c) and c in w:
                n += 1
        counts[c] = n
    return counts


def compute_paren_approx(
    patterns: list[tuple[str, str]], sample_files: list[Path]
) -> tuple[dict[tuple[str, str], int], int]:
    """(reading, candidate) -> count of literal "reading(candidate" occurrences
    across sample_files. Returns (counts, total_bytes_sampled)."""
    counts = {p: 0 for p in patterns}
    literal = {p: f"{p[0]}({p[1]}" for p in patterns}
    total_bytes = 0
    for path in sample_files:
        text = path.read_text(encoding="utf-8")
        total_bytes += len(text.encode("utf-8"))
        for p, lit in literal.items():
            n = text.count(lit)
            if n:
                counts[p] += n
    return counts, total_bytes


def load_assoc_table_readings(path: Path = HANJA_CONTEXT_TXT) -> set[str]:
    if not path.exists():
        return set()
    readings: set[str] = set()
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            sep = line.find(":")
            if sep == -1:
                continue
            readings.add(line[:sep])
    return readings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--limit-chunks", type=int, default=None,
        help="process only the first N XML chunks per NIKL source (smoke test)",
    )
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    t_start = time.monotonic()

    print("Loading hanja.txt + freq-hanjaeo.txt, building gate-passed reading set...", flush=True)
    lines = hc.read_dictionary_lines()
    raw_by_reading = hc.candidates_by_reading(lines)
    dedup_by_reading = hc.dedup_candidates_by_reading(raw_by_reading)
    word_freq = load_word_only_frequency()
    gate_passed = build_gate_passed(dedup_by_reading, word_freq)
    print(f"  gate-passed readings: {len(gate_passed)} (threshold={GATE_THRESHOLD})", flush=True)

    print("Scanning NIKL (stdict then opendict) for non-hanja-origin homographs...", flush=True)
    nikl_rows, nikl_stats = scan_nikl(gate_passed, args.limit_chunks)
    print(f"  NIKL rows matching gate-passed readings + native word_type + single-entry word_unit: {len(nikl_rows)}", flush=True)

    matched_readings = sorted({r for r, *_ in nikl_rows})
    v1_flagged = {
        r for r, _h, _wt, pos_joined, _s, sense_types in nikl_rows
        if row_is_flag_basis_v1(pos_joined, sense_types)
    }
    v2_basis_readings = {
        r for r, _h, wt, pos_joined, source, sense_types in nikl_rows
        if row_is_flag_basis(source, wt, pos_joined, sense_types)
    }
    freq_exempt_readings = sorted(
        r for r in v2_basis_readings if gate_passed[r][0][1] >= FREQ_DOMINANCE_EXEMPT
    )
    flagged_readings = sorted(v2_basis_readings - set(freq_exempt_readings))
    lost_basis_readings = sorted(v1_flagged - v2_basis_readings)
    reference_only_readings = sorted(set(matched_readings) - set(flagged_readings))
    print(
        f"  matched readings: {len(matched_readings)} — v1 flagged: {len(v1_flagged)}, "
        f"v2 basis: {len(v2_basis_readings)}, freq-exempt(>= {FREQ_DOMINANCE_EXEMPT}): {len(freq_exempt_readings)}, "
        f"FINAL flagged: {len(flagged_readings)}",
        flush=True,
    )

    print("Computing anchor counts (matched readings' gate-passing candidates)...", flush=True)
    freq_words = list(word_freq.keys())
    matched_candidates = sorted({c for r in matched_readings for c, _f in gate_passed[r]})
    anchor_counts = compute_anchor_counts(matched_candidates, freq_words)

    print("Computing paren-literal approximation (sampled filtered corpus)...", flush=True)
    sample_files: list[Path] = []
    sampled_bytes_budget = 0
    if FILTERED_DIR.exists():
        for p in sorted(FILTERED_DIR.glob("part-*.txt")):
            if sampled_bytes_budget >= PAREN_SAMPLE_BUDGET_BYTES:
                break
            sample_files.append(p)
            sampled_bytes_budget += p.stat().st_size
    patterns = [(r, c) for r in matched_readings for c, _f in gate_passed[r]]
    t_paren_start = time.monotonic()
    if sample_files:
        paren_counts, sampled_bytes_actual = compute_paren_approx(patterns, sample_files)
    else:
        paren_counts, sampled_bytes_actual = {p: 0 for p in patterns}, 0
    paren_elapsed = time.monotonic() - t_paren_start

    corpus_total_bytes = sum(p.stat().st_size for p in FILTERED_DIR.glob("part-*.txt")) if FILTERED_DIR.exists() else 0

    print("Checking existing hanja-context.txt association-table presence...", flush=True)
    assoc_readings = load_assoc_table_readings()

    # ---- inventory.tsv ----
    out_tsv = OUT_DIR / "inventory.tsv"
    with out_tsv.open("w", encoding="utf-8") as f:
        f.write(
            "# inventory.tsv — step 7a 고유어 동음이의어 플래그 인벤토리 "
            "(문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §10 단계 7 / 7a)\n"
        )
        f.write(
            f"# Inputs: {hc.HANJA_TXT}, {hc.FREQ_HANJAEO_TXT}, {HANJA_CONTEXT_TXT}, "
            f"{NIKL_DATA_DIR}/stdict (표준국어대사전, {nikl_stats['sources']['stdict']['chunk_files']} chunks), "
            f"{NIKL_DATA_DIR}/opendict (우리말샘, {nikl_stats['sources']['opendict']['chunk_files']} chunks), "
            f"{FILTERED_DIR} ({len(sample_files)}/{len(list(FILTERED_DIR.glob('part-*.txt'))) if FILTERED_DIR.exists() else 0} files sampled, "
            f"{sampled_bytes_actual/1e6:.1f}MB of {corpus_total_bytes/1e6:.1f}MB — paren approx is a SAMPLE, not exhaustive)\n"
        )
        f.write(f"# Generated: {date.today().isoformat()} by scripts/hanja-context/build_native_homograph_inventory.py\n")
        f.write(
            "# Gate: reading has >=1 hanja candidate with decoded freq-hanjaeo.txt "
            f"(word-table ONLY, value % 1_000_000) >= {GATE_THRESHOLD} (mirrors step 6 T). "
            "Match: NIKL headword with the same normalized reading, word_type in {고유어,외래어,혼종어}, word_unit==단어(stdict)/어휘(opendict).\n"
        )
        f.write(
            f"# Rule version {RULE_VERSION} (2026-07-10 사용자 확정, 7a 게이트 통과): "
            "basis = stdict + 고유어 + 일반어(의미유형) + 변환 적격 품사(명사/의존명사/수사/부사/관형사/동사/형용사); "
            "reference = matched but not basis. "
            f"A reading is FLAGGED iff it has >=1 basis row AND its top gate-passing candidate freq < {FREQ_DOMINANCE_EXEMPT} (빈도 우세 예외).\n"
        )
        f.write(
            "# Format: 읽기<TAB>행_분류(basis|reference)<TAB>게이트_통과_한자어(cand:freq,...)<TAB>NIKL_표제어<TAB>어원_분류<TAB>품사<TAB>출처_사전"
            "<TAB>앵커_수(cand:count,...)<TAB>병기_근사_SAMPLE(cand:count,...)<TAB>연관표_존재<TAB>의미유형(일반어/방언/옛말/북한어/...)\n"
        )
        f.write(
            f"# Counts: matched_readings={len(matched_readings)} v1_flagged={len(v1_flagged)} "
            f"v2_basis={len(v2_basis_readings)} freq_exempt={len(freq_exempt_readings)} "
            f"FINAL_flagged={len(flagged_readings)} nikl_rows={len(nikl_rows)}\n"
        )
        for reading, headword, word_type, pos_joined, source, sense_types in nikl_rows:
            row_class = "basis" if row_is_flag_basis(source, word_type, pos_joined, sense_types) else "reference"
            gate_field = ",".join(f"{c}:{fr}" for c, fr in gate_passed[reading])
            anchor_field = ",".join(f"{c}:{anchor_counts.get(c, 0)}" for c, _fr in gate_passed[reading])
            paren_field = ",".join(f"{c}:{paren_counts.get((reading, c), 0)}" for c, _fr in gate_passed[reading])
            assoc_present = "yes" if reading in assoc_readings else "no"
            f.write(
                f"{reading}\t{row_class}\t{gate_field}\t{headword}\t{word_type}\t{pos_joined}\t{source}\t"
                f"{anchor_field}\t{paren_field}\t{assoc_present}\t{sense_types}\n"
            )

    # ---- flagged-readings.tsv (최종 플래그 목록 — 7b 표적 확장 + 7c 번들 자원의 원천) ----
    basis_rows = [
        row for row in nikl_rows if row_is_flag_basis(row[4], row[2], row[3], row[5])
    ]
    basis_headwords_by_reading: dict[str, list[str]] = {}
    for r, headword, _wt, _p, _s, _t in basis_rows:
        basis_headwords_by_reading.setdefault(r, []).append(headword)
    out_flags = OUT_DIR / "flagged-readings.tsv"
    with out_flags.open("w", encoding="utf-8") as f:
        f.write(
            "# flagged-readings.tsv — step 7a FINAL flagged-reading list "
            "(문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §10 7a 게이트 통과 확정)\n"
        )
        f.write(
            f"# Rule version: {RULE_VERSION} — (1) basis 근거 = stdict+고유어+일반어+변환 적격 품사 행; "
            f"(2) 빈도 우세 예외: top gate candidate decoded freq >= {FREQ_DOMINANCE_EXEMPT} 이면 비플래그; "
            "(3) 무신호 읽기도 (1)(2) 통과 시 플래그 유지.\n"
        )
        f.write(f"# Generated: {date.today().isoformat()} by: python3 scripts/hanja-context/build_native_homograph_inventory.py\n")
        f.write("# Format: 읽기<TAB>게이트_통과_한자어(cand:freq,...)<TAB>basis_표제어(,로 연결)\n")
        f.write(f"# Counts: flagged={len(flagged_readings)}\n")
        for reading in flagged_readings:
            gate_field = ",".join(f"{c}:{fr}" for c, fr in gate_passed[reading])
            heads = ",".join(dict.fromkeys(basis_headwords_by_reading.get(reading, [])))
            f.write(f"{reading}\t{gate_field}\t{heads}\n")

    # ---- summary.json ----
    etymology_reading_counts: dict[str, int] = {}
    for et in NATIVE_WORD_TYPES:
        etymology_reading_counts[et] = len({r for r, _h, wt, _p, _s, _t in basis_rows if wt == et})
    etymology_row_counts: dict[str, int] = {}
    for et in NATIVE_WORD_TYPES:
        etymology_row_counts[et] = sum(1 for _r, _h, wt, _p, _s, _t in basis_rows if wt == et)

    total_elapsed = time.monotonic() - t_start
    summary = {
        "generated": date.today().isoformat(),
        "script": "scripts/hanja-context/build_native_homograph_inventory.py",
        "rule_version": RULE_VERSION,
        "limit_chunks": args.limit_chunks,
        "gate_threshold": GATE_THRESHOLD,
        "freq_dominance_exempt_threshold": FREQ_DOMINANCE_EXEMPT,
        "gate_passed_reading_count": len(gate_passed),
        "matched_reading_count": len(matched_readings),
        "exclusion_breakdown": {
            "v1_flagged": len(v1_flagged),
            "lost_basis_under_refinement": len(lost_basis_readings),
            "v2_basis": len(v2_basis_readings),
            "freq_exempt": len(freq_exempt_readings),
            "freq_exempt_readings": freq_exempt_readings,
            "final_flagged": len(flagged_readings),
        },
        "flagged_reading_count": len(flagged_readings),
        "reference_only_reading_count": len(reference_only_readings),
        "nikl_row_count": len(nikl_rows),
        "basis_row_count": len(basis_rows),
        "etymology_reading_counts_basis": etymology_reading_counts,
        "etymology_row_counts_basis": etymology_row_counts,
        "nikl_scan_stats": nikl_stats,
        "paren_sample": {
            "files_sampled": [p.name for p in sample_files],
            "bytes_sampled": sampled_bytes_actual,
            "bytes_total_corpus": corpus_total_bytes,
            "sample_fraction": (sampled_bytes_actual / corpus_total_bytes) if corpus_total_bytes else None,
            "elapsed_seconds": round(paren_elapsed, 1),
            "note": "SAMPLE, not exhaustive — declared per task scope (문서 요청: 파일이 크면 샘플링)",
        },
        "flag_check": {
            "must_flag": {"구두": "구두" in flagged_readings},
            "must_not_flag": {
                r: r not in flagged_readings
                for r in ("지금", "여자", "시장", "정치", "이유", "도시", "차례")
            },
            "구두_gate_candidates": gate_passed.get("구두"),
            "지금_gate_candidates": gate_passed.get("지금"),
        },
        "total_elapsed_seconds": round(total_elapsed, 1),
    }
    out_json = OUT_DIR / "summary.json"
    with out_json.open("w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(
        f"\nWrote {len(nikl_rows)} rows ({len(flagged_readings)} FINAL flagged / "
        f"{len(reference_only_readings)} reference-only readings) to {out_tsv}"
    )
    print(f"Wrote final flag list to {out_flags}")
    print(f"Wrote summary to {out_json}")
    print(f"Exclusion breakdown: v1={len(v1_flagged)} -> 정밀화 제외 {len(lost_basis_readings)} -> "
          f"v2 basis {len(v2_basis_readings)} -> 빈도 우세 제외 {len(freq_exempt_readings)} -> "
          f"FINAL {len(flagged_readings)}")
    print(f"must_flag: {summary['flag_check']['must_flag']}")
    print(f"must_not_flag (True = correctly excluded): {summary['flag_check']['must_not_flag']}")
    print(f"Total elapsed: {total_elapsed:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
