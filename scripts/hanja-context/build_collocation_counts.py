#!/usr/bin/env python3
"""Step 7b supplement — NIKL derived-verb collocation extraction (4th signal
source; 문맥 기반 한자 변환, docs/plans/context-aware-hanja-conversion.md §10
단계 7 / 7b, 2026-07-10 사용자 승인).

Goal: give thin-profile flagged readings (e.g. 고장:故障, whose association
profile is NIKL-definition-only) the decisive collocating-verb features that
the corpus signals miss and the global ubiquity filter bans (나/VV for
"고장나다"). Dictionary-attested derivation is lexical evidence, so these
rows are exempted from the ubiquity ban when merged (build_association_table
--colloc handling).

Sources (read-only NIKL submodule, CC-BY-SA 2.0 KR; headword/원어/품사/파생어
관계만 — 뜻풀이·예문 미접근):
  1. krdict (한국어기초사전, LMF) — PRIMARY. Verified 2026-07-10: stdict and
     opendict do NOT list noun+verb derived forms like 고장나다 as headwords
     at all ("고장(이) 나다" is phrase-only there, attested only inside
     license-restricted 예문). krdict encodes them as <RelatedForm
     type=파생어 writtenForm=고장나다> on the PARENT noun entry (goreul lemma
     고장, feat origin=故障). The derived form's own LexicalEntry (id 18858)
     is absent from this dump, so its POS is unresolvable — tag is assigned
     by heuristic: VA if stem in {없, 같}, else VV (recorded per row in the
     stats JSON; a wrong tag can only cause a silently-never-matching
     feature, never a wrong conversion).
  2. stdict + opendict — SECONDARY: 용언 headwords whose normalized form is
     R + remainder(ends 다) with 한자-typed 원어 == C (e.g. 사과-드리다,
     원어 謝過--). POS comes from the entry itself.

Rules (both paths):
  - R must be a FINAL flagged reading (native-homograph/flagged-readings.tsv,
    rule 7a-final-v2); C must be one of R's gate-passing candidates. Only
    flagged readings gain rows — non-flagged profiles stay untouched.
  - stem = remainder minus final 다; empty stems dropped.
  - light-verb stems {하, 되, 시키, 당하, 받} excluded (attach to nearly
    every Sino-Korean noun — no discriminating evidence).
  - suffixal-derivation stems {스럽, 롭, 답, 찮} excluded — Kiwi tags these
    XSA/XSN, which is outside the content-morpheme feature space
    (NNG/NNP/VV/VV-I/VA/VA-I/MAG/XR), so such features could never match a
    runtime context morpheme (dead weight in the table).
  - Kiwi-space note: simple 다-stripping yields the dictionary stem = Kiwi
    lemma, but IRREGULAR stems are tagged VV-I/VA-I at runtime while this
    extractor emits VV/VA (e.g. a hypothetical 짓-derived row would emit
    짓/VV, runtime says 짓/VV-I → silent no-match, lost coverage only).
    고장나다 → 고장/NNG + 나/VV is confirmed by the existing offline probe
    (plan §10 실측); further per-row verification is out of scope and the
    limitation is recorded here and in the stats JSON.

Run (woorilee repo root):
    python3 scripts/hanja-context/build_collocation_counts.py

Writes (/Volumes/Workbench/wooriHanjaModel/work/hanja-context/native-homograph/):
    collocation-counts.tsv   reading<TAB>hanja<TAB>feature<TAB>count (LC_ALL=C sorted)
    collocation-stats.json
"""
from __future__ import annotations

import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc
from extract_nikl_defs import CJK_RUN_RE, _SanitizedXMLFile

NIKL_DATA_DIR = hc.WORKSPACE_ROOT / "data/korean-dict-nikl"
OUT_DIR = hc.WORK_DIR / "native-homograph"
FLAGGED_TSV = OUT_DIR / "flagged-readings.tsv"

STRUCTURAL_MARK_RE = re.compile(r"[0-9\-\^\s·ㆍ]+")
NON_SYLLABLE_RE = re.compile(r"[^가-힣]")

LIGHT_VERB_STEMS = {"하", "되", "시키", "당하", "받"}
SUFFIXAL_STEMS = {"스럽", "롭", "답", "찮"}
ADJECTIVE_STEMS = {"없", "같"}  # krdict POS heuristic: these stems tag VA, everything else VV
POS_TO_TAG = {"동사": "VV", "형용사": "VA"}

WORD_SOURCES = [
    ("stdict", NIKL_DATA_DIR / "stdict", "word_info/word", "word_info/original_language_info",
     "word_info/word_unit", "단어", "word_info/pos_info/pos"),
    ("opendict", NIKL_DATA_DIR / "opendict", "wordInfo/word", "wordInfo/original_language_info",
     "wordInfo/word_unit", "어휘", "senseInfo/pos"),
]


def load_flagged(path: Path = FLAGGED_TSV) -> dict[str, list[str]]:
    flagged: dict[str, list[str]] = {}
    with path.open(encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 2:
                continue
            cands = [item.rpartition(":")[0] for item in cols[1].split(",") if item.rpartition(":")[0]]
            flagged[cols[0]] = cands
    return flagged


def stem_of(reading: str, derived_norm: str) -> str | None:
    """remainder-minus-다 stem, or None if the derived form doesn't qualify."""
    if not derived_norm.startswith(reading) or not derived_norm.endswith("다"):
        return None
    remainder = derived_norm[len(reading):]
    if len(remainder) < 2:  # need at least stem(1) + 다
        return None
    return remainder[:-1]


class Collector:
    def __init__(self) -> None:
        self.counts: dict[tuple[str, str, str], int] = {}
        self.seen: dict[tuple[str, str, str], set[str]] = {}
        self.rows_detail: list[dict] = []
        self.light_excluded = 0
        self.suffixal_excluded = 0

    def add(self, reading: str, hanja: str, stem: str, tag: str, headword_norm: str,
            source: str, pos_basis: str) -> None:
        if stem in LIGHT_VERB_STEMS:
            self.light_excluded += 1
            return
        if stem in SUFFIXAL_STEMS:
            self.suffixal_excluded += 1
            return
        feature = f"{stem}/{tag}"
        key = (reading, hanja, feature)
        heads = self.seen.setdefault(key, set())
        if headword_norm in heads:
            return
        heads.add(headword_norm)
        self.counts[key] = self.counts.get(key, 0) + 1
        self.rows_detail.append({
            "reading": reading, "hanja": hanja, "feature": feature,
            "headword": headword_norm, "source": source, "pos_basis": pos_basis,
        })


def scan_krdict(flagged: dict[str, list[str]], col: Collector) -> int:
    """PRIMARY path: parent noun entries (lemma==R, origin==C) with
    RelatedForm type=파생어. Returns entries scanned."""
    scanned = 0
    for path in sorted((NIKL_DATA_DIR / "krdict").glob("*.xml")):
        sf = _SanitizedXMLFile(path)
        try:
            context = ET.iterparse(sf, events=("start", "end"))
            _, root = next(context)
            for event, elem in context:
                if event != "end" or elem.tag != "LexicalEntry":
                    continue
                scanned += 1
                lemma_el = elem.find("Lemma/feat[@att='writtenForm']")
                lemma = lemma_el.get("val", "") if lemma_el is not None else ""
                reading = STRUCTURAL_MARK_RE.sub("", lemma)
                cands = flagged.get(reading)
                if cands is None:
                    root.clear()
                    continue
                origin_el = elem.find("feat[@att='origin']")
                origin = origin_el.get("val", "") if origin_el is not None else ""
                hanja = "".join(CJK_RUN_RE.findall(origin))
                if hanja not in cands or len(hanja) != len(reading):
                    root.clear()
                    continue
                for rel in elem.iterfind("RelatedForm"):
                    type_el = rel.find("feat[@att='type']")
                    if type_el is None or type_el.get("val") != "파생어":
                        continue
                    wf_el = rel.find("feat[@att='writtenForm']")
                    wf = STRUCTURAL_MARK_RE.sub("", wf_el.get("val", "")) if wf_el is not None else ""
                    if not wf or NON_SYLLABLE_RE.search(wf):
                        continue
                    stem = stem_of(reading, wf)
                    if not stem:
                        continue
                    tag = "VA" if stem in ADJECTIVE_STEMS else "VV"
                    col.add(reading, hanja, stem, tag, wf, "krdict",
                            f"heuristic({'VA-stem' if tag == 'VA' else 'default-VV'})")
                root.clear()
        finally:
            sf.close()
    return scanned


def scan_word_sources(flagged: dict[str, list[str]], col: Collector) -> int:
    """SECONDARY path: stdict/opendict 용언 headwords R+remainder with
    한자 원어 == C. Returns entries scanned."""
    by_first: dict[str, list[str]] = {}
    for r in flagged:
        by_first.setdefault(r[0], []).append(r)
    scanned = 0
    for source, directory, wpath, opath, wupath, single_unit, pospath in WORD_SOURCES:
        for path in sorted(directory.glob("*.xml")):
            sf = _SanitizedXMLFile(path)
            try:
                context = ET.iterparse(sf, events=("start", "end"))
                _, root = next(context)
                for event, elem in context:
                    if event != "end" or elem.tag != "item":
                        continue
                    scanned += 1
                    w_el = elem.find(wpath)
                    word_text = "".join(w_el.itertext()) if w_el is not None else ""
                    norm = STRUCTURAL_MARK_RE.sub("", word_text)
                    if len(norm) < 3 or NON_SYLLABLE_RE.search(norm) or not norm.endswith("다"):
                        continue
                    readings = [r for r in by_first.get(norm[0], []) if norm.startswith(r) and len(norm) > len(r)]
                    if not readings:
                        continue
                    wu_el = elem.find(wupath)
                    if wu_el is None or (wu_el.text or "").strip() != single_unit:
                        continue
                    pos_values = {(p.text or "").strip() for p in elem.iterfind(pospath)}
                    tags = [POS_TO_TAG[p] for p in pos_values if p in POS_TO_TAG]
                    if not tags:
                        continue
                    hanja_runs: list[str] = []
                    for oli in elem.iterfind(opath):
                        lt = oli.find("language_type")
                        if lt is None or (lt.text or "").strip() != "한자":
                            continue
                        ol = oli.find("original_language")
                        if ol is not None:
                            hanja_runs.extend(CJK_RUN_RE.findall("".join(ol.itertext())))
                    if not hanja_runs:
                        continue
                    hanja = "".join(hanja_runs)
                    for r in readings:
                        if hanja not in flagged[r] or len(hanja) != len(r):
                            continue
                        stem = stem_of(r, norm)
                        if not stem:
                            continue
                        for tag in tags:
                            col.add(r, hanja, stem, tag, norm, source, f"entry-pos({','.join(sorted(pos_values))})")
                root.clear()
            finally:
                sf.close()
        print(f"[{source}] scanned — cumulative tuples={len(col.counts)}", flush=True)
    return scanned


def main() -> int:
    t0 = time.monotonic()
    flagged = load_flagged()
    col = Collector()

    krdict_scanned = scan_krdict(flagged, col)
    print(f"[krdict] scanned {krdict_scanned} entries — tuples so far={len(col.counts)}", flush=True)
    word_scanned = scan_word_sources(flagged, col)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_tsv = OUT_DIR / "collocation-counts.tsv"
    with out_tsv.open("w", encoding="utf-8") as f:
        f.write("# collocation-counts.tsv — step 7b NIKL derived-verb collocation counts (4th signal, 2026-07-10 사용자 승인)\n")
        f.write(f"# Sources: {NIKL_DATA_DIR}/krdict (한국어기초사전 LMF, PRIMARY — parent-entry RelatedForm type=파생어; "
                "derived POS heuristic VA iff stem in {없,같} else VV) + stdict/opendict 용언 headwords (entry POS). "
                "표제어/원어/품사/파생어 관계만 사용 — 뜻풀이·예문 미접근.\n")
        f.write("# Rule: R = FINAL flagged reading (7a-final-v2), C = R's gate candidate, 원어 한자 == C; "
                "derived form = R + stem + 다; light verbs {하,되,시키,당하,받} and suffixal stems {스럽,롭,답,찮} excluded. "
                "Count = distinct derived headwords per (R, C, feature).\n")
        f.write(f"# Generated: {date.today().isoformat()} by scripts/hanja-context/build_collocation_counts.py\n")
        f.write(f"# Counts: tuples={len(col.counts)} light_excluded={col.light_excluded} suffixal_excluded={col.suffixal_excluded}\n")
        for (r, c, feat), n in sorted(col.counts.items(), key=lambda kv: (kv[0][0].encode(), kv[0][1].encode(), kv[0][2].encode())):
            f.write(f"{r}\t{c}\t{feat}\t{n}\n")

    per_reading: dict[str, int] = {}
    for (r, _c, _f), n in col.counts.items():
        per_reading[r] = per_reading.get(r, 0) + n
    stats = {
        "generated": date.today().isoformat(),
        "script": "scripts/hanja-context/build_collocation_counts.py",
        "flagged_readings": len(flagged),
        "krdict_entries_scanned": krdict_scanned,
        "word_source_items_scanned": word_scanned,
        "tuples": len(col.counts),
        "readings_with_collocations": len(per_reading),
        "light_verb_excluded": col.light_excluded,
        "suffixal_excluded": col.suffixal_excluded,
        "flag_check": {"고장_故障_나/VV": col.counts.get(("고장", "故障", "나/VV"), 0)},
        "per_reading_counts": dict(sorted(per_reading.items(), key=lambda kv: -kv[1])),
        "rows": col.rows_detail,
        "kiwi_space_notes": [
            "고장나다 → 고장/NNG + 나/VV confirmed by the existing offline dump-tokens probe (plan §10 실측 전제)",
            "krdict derived POS is heuristic (derived LexicalEntry ids absent from dump); wrong tag => silent no-match only",
            "irregular stems would need VV-I/VA-I to match runtime; emitted plain VV/VA (lost coverage, never wrong conversion)",
        ],
        "source_finding": (
            "stdict/opendict do NOT headword noun+verb derived forms (고장나다 absent; phrase-only, "
            "attested only in license-restricted 예문); krdict RelatedForm(파생어) is the usable NIKL encoding"
        ),
        "elapsed_seconds": round(time.monotonic() - t0, 1),
    }
    out_json = OUT_DIR / "collocation-stats.json"
    with out_json.open("w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"Wrote {len(col.counts)} tuples ({len(per_reading)} readings) to {out_tsv}")
    print(f"Wrote stats to {out_json}")
    print(f"고장:故障 나/VV count = {stats['flag_check']['고장_故障_나/VV']}")
    print(f"Elapsed: {time.monotonic()-t0:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
