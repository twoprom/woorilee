#!/usr/bin/env python3
"""Step D1 — seed coverage report + stratified review sheet
(docs/plans/hanja-context-scaling-plan.md §8-2/§8-3).

Reads extract_seeds.py's output (seeds/part-*.tsv + seeds/seed-extract-stats.json)
and writes two files, both under the same seeds/ directory:

  seed-coverage.md       -- the coverage report named in 계획 §8-2: totals by
                            level x source, the D1 gate table (three reading
                            populations vs the 145,000/154,221 thresholds),
                            per-reading and per-(reading,candidate) coverage
                            over inventory/targets.tsv, source_family
                            concentration, the full reject-counter table with
                            a standalone rejection waterfall, a Wilson
                            95%-interval sample-size note, and a purely
                            factual "관찰" section (no recommendations).

  seed-review-sheet.tsv  -- the 200-row stratified precision-inspection sheet
                            (계획 §8-2/§8-3) for the user to mark by hand.
                            `판정` is left empty. Stratified, fixed-seed
                            random sampling (see REVIEW_SEED /
                            REVIEW_ALLOCATION below); a stratum with fewer
                            rows than its quota contributes everything it has
                            and the shortfall is redistributed to the
                            paren_strict/비표적 (in_target_inventory=0) stratum.

STREAMING / MEMORY: this script never holds the full row set in memory. It
makes two streaming passes over seeds/part-*.tsv (each part file read line by
line, one Row parsed and discarded per iteration):
  pass 1 (`Aggregates.add`, in `compute_aggregates`) accumulates only bounded
    state — per (level,source) counters, a per-token-source dict of
    (page_id,sentence) -> small bitmask (bounded by DISTINCT sentence count,
    not row count), a per-reading count restricted to the 3,395 target
    readings, a have-seed set restricted to target-inventory (reading,hanja)
    pairs, a family->count dict, and per-review-stratum row counts.
  pass 2 (`sample_review_rows`) does fixed-seed reservoir sampling (Algorithm
    R) per review stratum, using the exact final quotas computed from pass
    1's stratum counts (so a stratum short of its quota is detected before
    sampling starts, and the shortfall is redistributed correctly) — memory
    is bounded by the ~200 sampled rows, never by the total row count.

Python 3.14 stdlib only. Does not touch docs/ or the plan document, does not
commit anything (per D1 part-2 instructions — the gate verdict and plan
게이트 단락 are written by the coordinator, not this script).

Usage:
    python3 scripts/hanja-context/build_seed_coverage.py
    python3 scripts/hanja-context/build_seed_coverage.py --seeds-dir <path> --out-dir <path>
"""
from __future__ import annotations

import argparse
import json
import math
import random
import resource
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Iterator, NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc
import extract_and_filter as ef

SEEDS_DIR = hc.WORK_DIR / "seeds"
EXTRACTOR_PATH = Path(__file__).resolve().parent / "extract_seeds.py"

COLS = [
    "level", "source", "reading", "hanja", "page_id", "family",
    "span_start", "span_len", "in_target_inventory", "is_ambiguous",
    "residual_hanja", "input_sentence", "evidence",
]
TOKEN_SOURCES = ("paren_strict", "paren_ext", "standalone")
TYPE_SOURCES = ("redirect", "title", "disambig", "dislink")

GATE_LITERAL = 145_000          # 계획 §8: literal constant (3 x 병기 48,366, old snapshot)
GATE_SAME_CORPUS = 154_221      # D1 part-2 coordinator instruction (a): 3 x 51,407 current-corpus baseline

PART1_TARGET_EXTRAPOLATION = 129_204     # D1 part-1 500MB x12.62, target-restricted distinct sentences
PART1_PAREN_STRICT_500MB_TGT_SENT = 9_545  # D1 part-1 500MB paren_strict distinct sentences, in_target=1
EXTRAPOLATION_FACTOR = 12.62

REVIEW_SEED = 20260725
DISPLAY_MAX_CHARS = 160

# Allocation order also fixes the 번호 draw order (see sample_review_rows).
# (stratum label, source, in_target_filter [unused directly, informational], quota)
REVIEW_ALLOCATION = [
    ("paren_strict(표적)", "paren_strict", "1", 40),
    ("paren_strict(비표적)", "paren_strict", "0", 45),
    ("paren_ext(표적)", "paren_ext", "1", 25),
    ("paren_ext(비표적)", "paren_ext", "0", 30),
    ("standalone", "standalone", None, 25),
    ("disambig", "disambig", None, 20),
    ("type_pool(dislink+redirect+title)", None, None, 15),
]
REDISTRIBUTE_TO = "paren_strict(비표적)"

CRITERION_COMMENT = """\
# 판정 기준 — 각 행에 O / X / ? 중 하나를 적어 주세요.
# O = 표시된 ⟦span⟧ 자리에 들어갈 정답 한자가 '정답한자' 열의 값이 맞고, 표시문장 안에
#     정답이 그대로 노출돼 있지 않다.
# X = 정답한자가 문맥상 틀렸다 / span이 잘못 잡혔다 / 정답이 문장에 누설돼 있다 /
#     한국어 문장이 아니다(서지 인용·한문 인용·마크업 잔재 등).
# ? = 판단 불가.
# 주의: '이 씨앗이 학습에 유용한가'는 판정 대상이 아닙니다. 고유명사·연호처럼 뻔한
#       항목이라도 추출이 정확하면 O입니다. 유용성은 별도 지표로 따로 집계합니다.
"""


class Row(NamedTuple):
    level: str
    source: str
    reading: str
    hanja: str
    page_id: str
    family: str
    span_start: int
    span_len: int
    in_target: int
    is_ambiguous: int
    residual_hanja: int
    input_sentence: str
    evidence: str


def iter_rows(seeds_dir: Path) -> Iterator[Row]:
    """Stream Row records one at a time — never materializes a list of all
    rows. Each line is parsed and immediately yielded/discarded by the
    caller."""
    for part in sorted(seeds_dir.glob("part-*.tsv")):
        with part.open(encoding="utf-8") as f:
            for line in f:
                if line.startswith("# format:") or not line.strip():
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) != len(COLS):
                    continue
                yield Row(
                    level=cols[0], source=cols[1], reading=cols[2], hanja=cols[3],
                    page_id=cols[4], family=cols[5],
                    span_start=int(cols[6]), span_len=int(cols[7]),
                    in_target=int(cols[8]), is_ambiguous=int(cols[9]),
                    residual_hanja=int(cols[10]),
                    input_sentence=cols[11], evidence=cols[12],
                )


def stratum_label_for(r: Row) -> str | None:
    if r.source == "paren_strict":
        return "paren_strict(표적)" if r.in_target == 1 else "paren_strict(비표적)"
    if r.source == "paren_ext":
        return "paren_ext(표적)" if r.in_target == 1 else "paren_ext(비표적)"
    if r.source == "standalone":
        return "standalone"
    if r.source == "disambig":
        return "disambig"
    if r.source in ("dislink", "redirect", "title"):
        return "type_pool(dislink+redirect+title)"
    return None


# ---------------------------------------------------------------------------
# Pass 1 — bounded-memory aggregation
# ---------------------------------------------------------------------------

class Aggregates:
    def __init__(self, target_readings_set: set[str], target_pairs_set: set[tuple[str, str]]) -> None:
        self.totals: dict[tuple[str, str], dict[str, int]] = defaultdict(lambda: defaultdict(int))
        # per token source: (page_id, input_sentence) -> bitmask (1=any row tgt1, 2=any row amb1, 4=any row resid0)
        self.sentence_flags: dict[str, dict[tuple[str, str], int]] = {s: {} for s in TOKEN_SOURCES}
        self.count_by_reading: dict[str, int] = defaultdict(int)   # restricted to target_readings_set
        self.have_pair: set[tuple[str, str]] = set()               # restricted to target_pairs_set
        self.family_counts: dict[str, int] = defaultdict(int)
        self.available_count: dict[str, int] = defaultdict(int)   # review-sheet stratum -> row count
        self.total_rows = 0
        self.target_readings_set = target_readings_set
        self.target_pairs_set = target_pairs_set

    def add(self, r: Row) -> None:
        self.total_rows += 1
        d = self.totals[(r.level, r.source)]
        d["rows"] += 1
        if r.in_target:
            d["tgt1_rows"] += 1
        if r.is_ambiguous:
            d["amb1_rows"] += 1

        if r.level == "token":
            if r.residual_hanja == 0:
                d["resid0_rows"] += 1
            skey = (r.page_id, r.input_sentence)
            flags = self.sentence_flags[r.source].get(skey, 0)
            if r.in_target:
                flags |= 1
            if r.is_ambiguous:
                flags |= 2
            if r.residual_hanja == 0:
                flags |= 4
            self.sentence_flags[r.source][skey] = flags

            if r.reading in self.target_readings_set:
                self.count_by_reading[r.reading] += 1
            if (r.reading, r.hanja) in self.target_pairs_set:
                self.have_pair.add((r.reading, r.hanja))

        self.family_counts[r.family] += 1

        stratum = stratum_label_for(r)
        if stratum is not None:
            self.available_count[stratum] += 1


def compute_aggregates(seeds_dir: Path, target_readings_set: set[str], target_pairs_set: set[tuple[str, str]]) -> Aggregates:
    agg = Aggregates(target_readings_set, target_pairs_set)
    for r in iter_rows(seeds_dir):
        agg.add(r)
    return agg


def finalize_totals_summary(agg: Aggregates) -> dict:
    summary: dict[str, dict] = {}
    for level, sources in (("token", TOKEN_SOURCES), ("type", TYPE_SOURCES)):
        for source in sources:
            d = agg.totals.get((level, source), {})
            n_rows = d.get("rows", 0)
            if level == "token":
                flags_map = agg.sentence_flags[source]
                distinct = len(flags_map)
                tgt1_sent = sum(1 for v in flags_map.values() if v & 1)
                resid0_sent = sum(1 for v in flags_map.values() if v & 4)
                summary[source] = dict(
                    rows=n_rows, distinct=distinct,
                    tgt1_rows=d.get("tgt1_rows", 0), tgt1_sent=tgt1_sent,
                    amb1_rows=d.get("amb1_rows", 0),
                    resid0_rows=d.get("resid0_rows", 0), resid0_sent=resid0_sent,
                )
            else:
                summary[source] = dict(rows=n_rows, tgt1_rows=d.get("tgt1_rows", 0), amb1_rows=d.get("amb1_rows", 0))

    # Token-level totals: union of (page_id,sentence) across all 3 token sources.
    # A given original sentence's paren_strict/paren_ext/standalone rows all
    # share the identical final input_sentence text (extract_seeds.py builds
    # one s_final per source sentence), so the same key correctly unions.
    combined: dict[tuple[str, str], int] = {}
    for source in TOKEN_SOURCES:
        for skey, flags in agg.sentence_flags[source].items():
            combined[skey] = combined.get(skey, 0) | flags
    total_rows = sum(summary[s]["rows"] for s in TOKEN_SOURCES)
    summary["_token_totals_"] = dict(
        rows=total_rows,
        distinct_any=len(combined),
        distinct_target=sum(1 for v in combined.values() if v & 1),
        distinct_ambiguous=sum(1 for v in combined.values() if v & 2),
    )
    return summary


# ---------------------------------------------------------------------------
# Wilson score interval
# ---------------------------------------------------------------------------

def wilson_half_width(p_hat: float, n: int, z: float = 1.96) -> float:
    """Half-width of the Wilson 95% score interval for a point estimate
    p_hat over n trials (continuous p_hat, not requiring an integer
    numerator)."""
    denom = 1 + z * z / n
    margin = z * math.sqrt(p_hat * (1 - p_hat) / n + z * z / (4 * n * n))
    return margin / denom


# ---------------------------------------------------------------------------
# Section builders (consume the bounded aggregates, not raw rows)
# ---------------------------------------------------------------------------

def build_identity_section(stats: dict) -> str:
    lines = []
    lines.append("## 코퍼스 정체 · 추출기 파라미터\n")
    lines.append(f"- 파일: `{stats['corpus_path']}` — 한국어 위키백과 `pages-articles` 덤프의 압축 해제본, "
                  f"{stats['corpus_size_bytes']:,} bytes.")
    lines.append("- 덤프 출처: https://dumps.wikimedia.org/kowiki/ (`kowiki-latest-pages-articles.xml.bz2`), 파일 날짜 2026-06-29.")
    lines.append("- 포맷: MediaWiki export-0.11 — 모든 태그가 네임스페이스 한정. `dbname` kowiki, `generator` MediaWiki 1.47.0-wmf.4.")
    lines.append("- 라이선스: CC BY-SA. 산출물은 문장 단위 발췌·집계이며 출처(한국어 위키백과)를 명기한다.")
    lines.append(f"- 추출 실행: limit_bytes={stats['limit_bytes']} limit_pages={stats['limit_pages']} "
                  f"completed_fully={stats['completed_fully']} elapsed={stats['elapsed_sec']:.1f}s")
    v = stats["vocab"]
    lines.append(f"- 어휘: hanja_pairs={v['hanja_pairs']:,} sub_lexicon={v['sub_lexicon']:,} "
                  f"ambiguous_readings={v['ambiguous_readings']:,} target_readings={v['target_readings']:,}")

    repo_root = EXTRACTOR_PATH.resolve().parents[2]
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo_root, capture_output=True, text=True, check=True
        ).stdout.strip()
    except Exception:
        head = "unknown"
    try:
        file_commit = subprocess.run(
            ["git", "log", "-1", "--format=%H", "--", str(EXTRACTOR_PATH.relative_to(repo_root))],
            cwd=repo_root, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        file_commit = ""
    try:
        sha = subprocess.run(
            ["shasum", "-a", "256", str(EXTRACTOR_PATH)], capture_output=True, text=True, check=True
        ).stdout.split()[0]
    except Exception:
        sha = "unknown"
    lines.append(f"- 리포 HEAD: `{head}`")
    if file_commit:
        lines.append(f"- `extract_seeds.py` 최종 커밋: `{file_commit}`")
    else:
        lines.append(
            f"- `extract_seeds.py`는 아직 커밋되지 않은 작업 트리 파일이다 (D1은 커밋하지 않는 것이 지침). "
            f"재현성 참조용 SHA-256: `{sha}`"
        )
    return "\n".join(lines) + "\n"


def build_totals_section(summary: dict) -> str:
    lines = ["## 종류·출처별 합계\n"]
    lines.append(
        "| level | source | rows | distinct_sentences | tgt=1 rows | tgt=1 sent | amb=1 rows | resid0 rows | resid0 sent |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for level, sources in (("token", TOKEN_SOURCES), ("type", TYPE_SOURCES)):
        for source in sources:
            s = summary[source]
            if level == "token":
                lines.append(
                    f"| token | {source} | {s['rows']:,} | {s['distinct']:,} | {s['tgt1_rows']:,} | {s['tgt1_sent']:,} | "
                    f"{s['amb1_rows']:,} | {s['resid0_rows']:,} | {s['resid0_sent']:,} |"
                )
            else:
                lines.append(
                    f"| type | {source} | {s['rows']:,} | – | {s['tgt1_rows']:,} | – | {s['amb1_rows']:,} | – | – |"
                )
    t = summary["_token_totals_"]
    lines.append("")
    lines.append(
        f"토큰 레벨 합계 (paren_strict+paren_ext+standalone): rows={t['rows']:,}, "
        f"distinct sentences (union, 임의 읽기)={t['distinct_any']:,}, "
        f"distinct sentences (in_target_inventory=1)={t['distinct_target']:,}, "
        f"distinct sentences (is_ambiguous=1)={t['distinct_ambiguous']:,}"
    )
    return "\n".join(lines) + "\n"


def build_gate_section(summary: dict) -> str:
    t = summary["_token_totals_"]
    populations = [
        ("target-reading-restricted distinct sentences (in_target_inventory=1) — **게이트 지표**", t["distinct_target"]),
        ("dictionary-ambiguous distinct sentences (is_ambiguous=1)", t["distinct_ambiguous"]),
        ("unrestricted distinct sentences (임의 읽기)", t["distinct_any"]),
    ]
    lines = ["## D1 게이트 표\n"]
    lines.append(f"게이트 상수: 계획 §8 문헌 값 **{GATE_LITERAL:,}**, 동일 코퍼스 재계산 **3 × 51,407 = {GATE_SAME_CORPUS:,}**.\n")
    lines.append("| population | distinct sentences | vs 145,000 | vs 154,221 |")
    lines.append("|---|---:|---:|---:|")
    for label, n in populations:
        lines.append(
            f"| {label} | {n:,} | {n / GATE_LITERAL * 100:.1f}% | {n / GATE_SAME_CORPUS * 100:.1f}% |"
        )
    return "\n".join(lines) + "\n"


def build_extrapolation_section(summary: dict) -> str:
    t = summary["_token_totals_"]
    realized_all = t["distinct_target"]
    ratio_all = realized_all / PART1_TARGET_EXTRAPOLATION

    paren_strict_realized = summary["paren_strict"]["tgt1_sent"]
    paren_strict_extrap = PART1_PAREN_STRICT_500MB_TGT_SENT * EXTRAPOLATION_FACTOR
    ratio_paren_strict = paren_strict_realized / paren_strict_extrap

    lines = ["## 외삽 정직성 점검 (500MB → 전체 코퍼스)\n"]
    lines.append("### 전체 토큰 레벨 (target-restricted distinct sentences)\n")
    lines.append(f"- 500MB 조각 실측: {PART1_PAREN_STRICT_500MB_TGT_SENT + 0:,} (paren_strict만; 아래 별도 행 참조), "
                  f"×{EXTRAPOLATION_FACTOR} 외삽치 (3개 토큰 소스 합): {PART1_TARGET_EXTRAPOLATION:,}")
    lines.append(f"- 전체 코퍼스 실측: {realized_all:,}")
    lines.append(f"- **실측/외삽 비율: {ratio_all:.3f}** ({'외삽이 낙관적이었다 (실측이 더 작다)' if ratio_all < 1 else '외삽이 비관적이었다 (실측이 더 크다)'})")
    lines.append("\n### paren_strict 단독 (표적 읽기만, 코퍼스 앞쪽 편향을 가장 깨끗하게 보여줄 지표)\n")
    lines.append(f"- 500MB 조각 실측 (D1 part-1 계산 앵커): {PART1_PAREN_STRICT_500MB_TGT_SENT:,}")
    lines.append(f"- ×{EXTRAPOLATION_FACTOR} 외삽치: {paren_strict_extrap:,.0f}")
    lines.append(f"- 전체 코퍼스 실측: {paren_strict_realized:,}")
    lines.append(f"- **실측/외삽 비율: {ratio_paren_strict:.3f}**")
    lines.append(
        "\n코퍼스가 page id 순서라 앞쪽 500MB 조각이 더 오래되고 길고 한자 주석이 많은 문서 쪽으로 치우칠 수 있다는 "
        "우려가 있었다 — 위 두 비율이 그 편향의 실측 크기다. 1.0보다 유의하게 작으면 우려가 사실로 확인된 것이다."
    )
    return "\n".join(lines) + "\n", ratio_all, ratio_paren_strict, realized_all


def build_per_reading_section(count_by_reading: dict[str, int], target_readings: list[str]) -> str:
    counts = [(reading, count_by_reading.get(reading, 0)) for reading in target_readings]
    total = len(counts)
    n_ge1 = sum(1 for _, c in counts if c >= 1)
    n_ge5 = sum(1 for _, c in counts if c >= 5)
    n_ge20 = sum(1 for _, c in counts if c >= 20)
    n_ge100 = sum(1 for _, c in counts if c >= 100)
    n_zero = sum(1 for _, c in counts if c == 0)

    lines = ["## 읽기별 커버리지 (표적 읽기 {:,}개 기준)\n".format(total)]
    lines.append(f"- ≥1 seed: {n_ge1:,} ({n_ge1/total*100:.1f}%)")
    lines.append(f"- ≥5 seed: {n_ge5:,} ({n_ge5/total*100:.1f}%)")
    lines.append(f"- ≥20 seed: {n_ge20:,} ({n_ge20/total*100:.1f}%)")
    lines.append(f"- ≥100 seed: {n_ge100:,} ({n_ge100/total*100:.1f}%)")
    lines.append(f"- **0 seed**: {n_zero:,} ({n_zero/total*100:.1f}%)")

    sorted_desc = sorted(counts, key=lambda kv: (-kv[1], kv[0]))
    top30 = sorted_desc[:30]
    bottom30 = sorted(counts, key=lambda kv: (kv[1], kv[0]))[:30]

    lines.append("\n### 상위 30 (읽기: seed 수)\n")
    lines.append(", ".join(f"{r}:{c:,}" for r, c in top30))
    lines.append("\n### 하위 30 (읽기: seed 수)\n")
    lines.append(", ".join(f"{r}:{c:,}" for r, c in bottom30))
    return "\n".join(lines) + "\n"


def build_per_candidate_section(have_pair: set[tuple[str, str]], targets: dict[str, list[tuple[str, int]]]) -> str:
    total_pairs = 0
    covered_pairs = 0
    for reading, candidates in targets.items():
        for candidate, _freq in candidates:
            total_pairs += 1
            if (reading, candidate) in have_pair:
                covered_pairs += 1

    lines = ["## (읽기,후보) 쌍 커버리지\n"]
    lines.append(
        f"표적 인벤토리의 (읽기,후보) 쌍 총 {total_pairs:,}개 중 **{covered_pairs:,}개 ({covered_pairs/total_pairs*100:.1f}%)**"
        f"가 token-level seed를 1개 이상 확보했다."
    )
    lines.append(
        "\n이 수치가 읽기별 랭커를 실제로 학습시킬 수 있는지를 결정한다 — "
        "한 읽기의 후보 중 seed가 없는 후보는 그 방향으로는 전혀 학습 신호가 없다는 뜻이다."
    )
    return "\n".join(lines) + "\n"


def build_family_section(family_counts: dict[str, int]) -> str:
    total = sum(family_counts.values())
    n_families = len(family_counts)
    sorted_families = sorted(family_counts.items(), key=lambda kv: -kv[1])

    top1pct_n = max(1, math.ceil(n_families * 0.01))
    top1pct_sum = sum(c for _, c in sorted_families[:top1pct_n])

    lines = ["## source_family 집중도\n"]
    lines.append(f"- 고유 family 수: {n_families:,}, 전체 seed(모든 level·source 합): {total:,}")
    lines.append(
        f"- 상위 1% family({top1pct_n:,}개)가 전체 seed의 {top1pct_sum/total*100:.1f}%를 차지한다 "
        f"({top1pct_sum:,}/{total:,})"
    )
    lines.append("\n### 상위 20 family\n")
    lines.append("| family | seeds |")
    lines.append("|---|---:|")
    for family, c in sorted_families[:20]:
        lines.append(f"| {family} | {c:,} |")
    return "\n".join(lines) + "\n"


def build_reject_section(stats: dict) -> str:
    c = stats["counters"]
    lines = ["## 리젝트(거부) 사유 전체 표\n"]
    lines.append("| counter | count |")
    lines.append("|---|---:|")
    for k in sorted(c):
        lines.append(f"| {k} | {c[k]:,} |")

    # Standalone waterfall, in the order guards are actually applied in code
    # (find_standalone_candidates then apply_leak_guard).
    steps = [
        ("전체 후보 (한자 연쇄, 모든 최대 run)", 0),
        ("- 괄호류 안 (in_bracket)", c.get("standalone_reject_in_bracket", 0)),
        ("- sub_lexicon 미등재 (not_in_lexicon)", c.get("standalone_reject_not_in_lexicon", 0)),
        ("- 부분일치만 존재 (partial_match)", c.get("standalone_reject_partial_match", 0)),
        ("- 비모호 읽기 (not_ambiguous)", c.get("standalone_reject_not_ambiguous", 0)),
        ("- 한국어 문맥 비율 미달 (korean_ratio)", c.get("standalone_reject_korean_ratio", 0)),
        ("- 인접 문자 가드 (adjacency)", c.get("standalone_reject_adjacency", 0)),
        ("- 가나 문자 존재 (kana)", c.get("standalone_reject_kana", 0)),
        ("- 정답 한자 잔존 (leak_gold)", c.get("standalone_reject_leak_gold", 0)),
        ("- 동일 읽기 다른 한자 잔존 (leak_same_reading)", c.get("standalone_reject_leak_same_reading", 0)),
        ("- 제목에 정답 한자 포함 (leak_title)", c.get("standalone_reject_leak_title", 0)),
        ("- 인접 중복 노출 (leak_adjacent, D1 part-2 일반화 가드)", c.get("standalone_reject_leak_adjacent", 0)),
    ]
    emitted = c.get("emit_standalone", 0)
    total_candidates = emitted + sum(v for _, v in steps[1:])
    steps[0] = (steps[0][0], total_candidates)

    lines.append("\n### standalone 폭포(waterfall)\n")
    lines.append("| 단계 | 이 단계에서 소실 | 남은 후보 |")
    lines.append("|---|---:|---:|")
    remaining = total_candidates
    lines.append(f"| {steps[0][0]} | – | {remaining:,} |")
    for label, loss in steps[1:]:
        remaining -= loss
        lines.append(f"| {label} | {loss:,} | {remaining:,} |")
    lines.append(f"| **최종 emit_standalone** | – | {emitted:,} |")
    consistency = "OK (일치)" if remaining == emitted else f"MISMATCH: waterfall={remaining:,} vs emit_standalone={emitted:,}"
    lines.append(f"\n(내부 정합성 체크: {consistency})")
    return "\n".join(lines) + "\n"


def build_wilson_section(allocation_used: dict[str, int]) -> str:
    lines = ["## 표본 크기 근거 (Wilson 95% 구간)\n"]
    lines.append(
        "연구 문서 §11은 표본 크기 근거 없이 정밀도 수준을 주장하는 것을 금지한다. "
        "아래는 각 층(stratum) 표본 크기 n이 점추정 97%에서 실제로 보장하는 Wilson 95% 구간 반폭이다 "
        "(표본 크기를 바꾸자는 제안이 아니라 산술만 제시한다)."
    )
    lines.append("\n| stratum | n | Wilson 95% half-width (p̂=0.97) | 구간 |")
    lines.append("|---|---:|---:|---|")
    for label, n in allocation_used.items():
        if n <= 0:
            continue
        hw = wilson_half_width(0.97, n)
        lo, hi = max(0.0, 0.97 - hw), min(1.0, 0.97 + hw)
        lines.append(f"| {label} | {n} | ±{hw*100:.1f}%p | [{lo*100:.1f}%, {hi*100:.1f}%] |")
    total_n = sum(allocation_used.values())
    if total_n > 0:
        hw = wilson_half_width(0.97, total_n)
        lines.append(f"| **전체 (200행 합)** | {total_n} | ±{hw*100:.1f}%p | [{max(0,0.97-hw)*100:.1f}%, {min(100,(0.97+hw)*100):.1f}%] |")
    lines.append(
        "\n각 층 표본(n=15~45)은 개별 층의 정밀도를 ±10~13%p 수준까지만 좁힐 수 있고, "
        "전체 200행을 하나의 모집단으로 합쳐야 ±2~3%p대 구간이 나온다. "
        "따라서 이 시트로는 '전체 seed 정밀도 97%'와 같은 단일 수치를 층별로 유의하게 나누어 보증할 수 없다."
    )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Pass 2 — stratified reservoir sampling (Algorithm R, fixed seed)
# ---------------------------------------------------------------------------

def truncate_centered(sentence: str, span_start: int, span_len: int, max_chars: int = DISPLAY_MAX_CHARS) -> str:
    marked = sentence[:span_start] + "⟦" + sentence[span_start:span_start + span_len] + "⟧" + sentence[span_start + span_len:]
    marked_span_start = span_start + 1
    marked_span_end = span_start + 1 + span_len
    total_len = len(marked)
    if total_len <= max_chars:
        return marked
    span_center = (marked_span_start + marked_span_end) // 2
    half = max_chars // 2
    win_start = max(0, span_center - half)
    win_end = win_start + max_chars
    if win_end > total_len:
        win_end = total_len
        win_start = max(0, win_end - max_chars)
    if win_start > marked_span_start:
        win_start = marked_span_start
    if win_end < marked_span_end:
        win_end = marked_span_end
    prefix = "…" if win_start > 0 else ""
    suffix = "…" if win_end < total_len else ""
    return prefix + marked[win_start:win_end] + suffix


def display_sentence(r: Row) -> str:
    if r.level == "token":
        return truncate_centered(r.input_sentence, r.span_start, r.span_len)
    text = f"{r.reading} ↔ {r.hanja}"
    if len(text) > DISPLAY_MAX_CHARS:
        text = text[:DISPLAY_MAX_CHARS - 1] + "…"
    return text


def compute_final_quotas(agg: Aggregates) -> dict[str, int]:
    quotas = {label: quota for label, _s, _t, quota in REVIEW_ALLOCATION}
    shortfall = 0
    for label in list(quotas):
        available = agg.available_count.get(label, 0)
        if available < quotas[label]:
            shortfall += quotas[label] - available
            quotas[label] = available
    room = agg.available_count.get(REDISTRIBUTE_TO, 0) - quotas[REDISTRIBUTE_TO]
    quotas[REDISTRIBUTE_TO] += max(0, min(shortfall, room))
    return quotas


def sample_review_rows(seeds_dir: Path, quotas: dict[str, int], seed: int) -> list[dict]:
    """Second streaming pass: Algorithm-R reservoir sampling per stratum with
    the FINAL (post-redistribution) quotas fixed for the whole pass — never
    holds more than sum(quotas) (<=200) rows in memory."""
    rng = random.Random(seed)
    reservoirs: dict[str, list[Row]] = {label: [] for label in quotas}
    seen_count: dict[str, int] = defaultdict(int)

    for r in iter_rows(seeds_dir):
        label = stratum_label_for(r)
        if label is None or quotas.get(label, 0) <= 0:
            continue
        k = quotas[label]
        seen_count[label] += 1
        n = seen_count[label]
        reservoir = reservoirs[label]
        if len(reservoir) < k:
            reservoir.append(r)
        else:
            j = rng.randint(0, n - 1)
            if j < k:
                reservoir[j] = r

    review_rows: list[dict] = []
    seq = 0
    for label, _source, _tgt, _quota in REVIEW_ALLOCATION:
        for r in reservoirs[label]:
            seq += 1
            review_rows.append(dict(
                번호=seq,
                판정="",
                출처=r.source,
                표적여부="표적" if r.in_target == 1 else "비표적",
                읽기=r.reading,
                정답한자=r.hanja,
                표시문장=display_sentence(r),
                원문근거=r.evidence,
                잔여한자수=r.residual_hanja,
                페이지ID=r.page_id,
                family=r.family,
            ))
    review_rows.sort(key=lambda d: (d["출처"], d["번호"]))
    return review_rows


def write_review_sheet(review_rows: list[dict], quotas: dict[str, int], out_path: Path) -> None:
    header_cols = ["번호", "판정", "출처", "표적여부", "읽기", "정답한자", "표시문장", "원문근거", "잔여한자수", "페이지ID", "family"]
    with out_path.open("w", encoding="utf-8") as f:
        f.write(CRITERION_COMMENT)
        alloc_str = " ".join(f"{label}={quotas[label]}" for label, *_ in REVIEW_ALLOCATION)
        f.write(f"# seed={REVIEW_SEED} 실제 배정: {alloc_str} (총 {len(review_rows)}행)\n")
        f.write("\t".join(header_cols) + "\n")
        for row in review_rows:
            values = [str(row[c]) for c in header_cols]
            sanitized = [v.replace("\t", " ").replace("\n", " ").replace("\r", " ") for v in values]
            f.write("\t".join(sanitized) + "\n")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def peak_rss_mb() -> float:
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS reports bytes; Linux reports KB.
    divisor = 1024 * 1024 if sys.platform == "darwin" else 1024
    return ru / divisor


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seeds-dir", type=Path, default=SEEDS_DIR)
    parser.add_argument("--out-dir", type=Path, default=None)
    args = parser.parse_args()
    out_dir = args.out_dir or args.seeds_dir

    stats_path = args.seeds_dir / "seed-extract-stats.json"
    stats = json.loads(stats_path.read_text(encoding="utf-8"))

    targets = ef.load_targets(hc.INVENTORY_DIR / "targets.tsv")
    target_readings = list(targets.keys())
    target_readings_set = set(target_readings)
    target_pairs_set = {(reading, cand) for reading, cands in targets.items() for cand, _freq in cands}

    print(f"[{time.strftime('%H:%M:%S')}] pass 1/2: streaming aggregation over {args.seeds_dir} ...")
    agg = compute_aggregates(args.seeds_dir, target_readings_set, target_pairs_set)
    print(f"[{time.strftime('%H:%M:%S')}] pass 1/2 done: {agg.total_rows:,} rows streamed "
          f"(peak RSS so far: {peak_rss_mb():.1f} MB)")

    summary = finalize_totals_summary(agg)

    identity_md = build_identity_section(stats)
    totals_md = build_totals_section(summary)
    gate_md = build_gate_section(summary)
    extrapolation_md, ratio_all, ratio_paren_strict, realized_all = build_extrapolation_section(summary)
    per_reading_md = build_per_reading_section(agg.count_by_reading, target_readings)
    per_candidate_md = build_per_candidate_section(agg.have_pair, targets)
    family_md = build_family_section(agg.family_counts)
    reject_md = build_reject_section(stats)

    quotas = compute_final_quotas(agg)
    print(f"[{time.strftime('%H:%M:%S')}] pass 2/2: streaming reservoir sampling for review sheet "
          f"(quotas: {quotas}) ...")
    review_rows = sample_review_rows(args.seeds_dir, quotas, REVIEW_SEED)
    write_review_sheet(review_rows, quotas, out_dir / "seed-review-sheet.tsv")
    print(f"[{time.strftime('%H:%M:%S')}] pass 2/2 done: {len(review_rows)} review rows written "
          f"(peak RSS so far: {peak_rss_mb():.1f} MB)")

    wilson_md = build_wilson_section(quotas)

    observations = ["## 관찰\n"]
    observations.append(f"- target-restricted distinct sentence 총량은 {realized_all:,}로, "
                         f"계획 §8 문헌 상수 145,000의 {realized_all/GATE_LITERAL*100:.1f}%, "
                         f"동일 코퍼스 재계산 154,221의 {realized_all/GATE_SAME_CORPUS*100:.1f}%다.")
    t = summary["_token_totals_"]
    observations.append(f"- unrestricted distinct sentence 총량은 {t['distinct_any']:,}로 target-restricted 대비 "
                         f"{t['distinct_any']/realized_all:.2f}배다.")
    observations.append(f"- 500MB→전체 외삽 대비 실측 비율(전체 토큰 레벨)은 {ratio_all:.3f}, paren_strict 단독은 "
                         f"{ratio_paren_strict:.3f}다.")
    observations.append(f"- standalone 리젝트 가드 중 D1 part-2에서 일반화한 leak_adjacent 가드가 "
                         f"{stats['counters'].get('standalone_reject_leak_adjacent', 0):,}건을 걸러냈다.")
    observations.append(f"- 본 스크립트의 실측 peak RSS: {peak_rss_mb():.1f} MB (전체 seed TSV 총합 "
                         f"{sum(f.stat().st_size for f in args.seeds_dir.glob('part-*.tsv'))/1e6:.1f} MB, "
                         f"두 차례의 스트리밍 패스로 처리 — 행 전체를 메모리에 적재하지 않는다).")
    observations_md = "\n".join(observations) + "\n"

    md_parts = [
        "# D1 씨앗 커버리지 보고서 (seed-coverage.md)\n",
        identity_md, totals_md, gate_md, extrapolation_md,
        per_reading_md, per_candidate_md, family_md, reject_md, wilson_md, observations_md,
    ]
    (out_dir / "seed-coverage.md").write_text("\n".join(md_parts), encoding="utf-8")

    print(f"[{time.strftime('%H:%M:%S')}] wrote {out_dir / 'seed-coverage.md'}")
    print(f"[{time.strftime('%H:%M:%S')}] wrote {out_dir / 'seed-review-sheet.tsv'} (quotas: {quotas})")
    print(f"[{time.strftime('%H:%M:%S')}] FINAL peak RSS: {peak_rss_mb():.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
