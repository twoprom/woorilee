#!/usr/bin/env python3
"""Step D2 Task 4 — label sheet, labeling guide, safety set, assets report
(docs/plans/hanja-context-scaling-plan.md §9,
docs/hanja-context-quality-scaling-research.md §5.1/§5.3).

Reads Task 3's `d2/verified-sentences.tsv` (mined sentences + real Kiwi
segmentation/ranking results), Task 1's `d2/reading-selection.tsv`, and the
D1 seed corpus `seeds/part-*.tsv`. Writes four artifacts — labels themselves
are NOT filled in by this script (that is the user's job, per the plan):

  1. d2/label-sheet.tsv       -- seg_ok=1 rows only, <=6/reading, blank
                                  판정범주/주정답/허용집합 for the user to fill,
                                  10% marked 재라벨=1 (fixed seed) for the
                                  self-consistency re-label pass.
  2. docs/plans/hanja-context-d2-labeling-guide.md -- the 4-category (U/M/K/?)
                                  labeling instructions in Korean, with example
                                  sentences PULLED LIVE from verified-sentences.tsv
                                  (never hardcoded) — see `pick_guide_examples`.
  3. d2/safety-set.tsv        -- 3 layers (seed_gold / keep_hangul_native /
                                  nnp); seed_gold is immediately measurable
                                  without human labels (연구 문서 §5.3-3), the
                                  other two need review (요검수=1).
  4. d2/d2-assets-report.md   -- cell table, mining yield, segMiss rate, split
                                  sizes, safety-layer counts, disjointness
                                  summary, remaining labeling-effort estimate.

Judgment calls (documented here, not silently made):
  - Guide examples are selected programmatically, not hand-picked, so
    re-running this script after the full corpus mining pass regenerates the
    guide with full-corpus-quality examples instead of freezing whatever a
    smoke run happened to surface. "고유명사/연호/관직명/불교 용어처럼 관행상
    한자 표기" candidates = verified-sentences rows with `pos_tag=NNP` and
    `seg_ok=1` (proper-noun-tagged tokens are the closest programmatic proxy
    for this whole idiomatic-hanja group — the task only requires >=3
    examples for the GROUP, not one per named subtype). "현대 산문에서 한글이
    자연스러운" candidates reuse this script's own `keep_hangul_native`
    safety-layer definition (flagged native-homograph reading + zero hanja
    characters anywhere in the sentence) — the same, already-specified rule,
    not a second ad hoc heuristic.
  - safety-set's `유형=nnp` layer intentionally leaves `gold` BLANK (not
    pre-filled with `sys_top1`): an NNP tag can just as easily mean "foreign
    name, should stay Hangul" (a real example found in testing: 모세/Moses
    mistagged NNP with sys_top1=毛細) as "실제 고유명사, 한자 표기 관행" — pre-
    filling a system guess as "gold" for a `요검수=1` row risked being read as
    already-trustworthy. `유형=keep_hangul_native` DOES pre-fill
    `gold=KEEP_HANGUL`, per the task's own explicit instruction.
  - `요검수` is written as literal `0`/`1` (not blank/1) for a uniform
    always-present flag column.
  - Remaining labeling-effort estimate assumes 1-2 minutes/row (allowed-set
    judgment plus reading the marked sentence) — a documented assumption, not
    a measurement.

Usage:
    python3 scripts/hanja-context/build_d2_sheets.py
    python3 scripts/hanja-context/build_d2_sheets.py --verified-sentences <path> \\
        --reading-selection <path> --seeds-dir <path> --out-dir <path> --guide-out <path>
"""
from __future__ import annotations

import argparse
import random
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc
import extract_seeds as es

D2_DIR = hc.WORK_DIR / "d2"
SEEDS_DIR = hc.WORK_DIR / "seeds"
FLAGGED_TSV = hc.WORK_DIR / "native-homograph" / "flagged-readings.tsv"
VERIFIED_TSV = D2_DIR / "verified-sentences.tsv"
READING_SELECTION_TSV = D2_DIR / "reading-selection.tsv"
GUIDE_OUT = hc.WOORILEE_ROOT / "docs/plans/hanja-context-d2-labeling-guide.md"
DISJOINTNESS_REPORT = D2_DIR / "disjointness-report.md"

SHEET_SEED = 20260731
LABEL_SHEET_MAX_PER_READING = 6
RELABEL_FRACTION = 0.10
SAFETY_SEED_GOLD_TARGET = 1000
MINING_MAX_PER_READING = 8  # must match build_d2_mining.py's --max-per-reading default
GUIDE_EXAMPLES_PER_GROUP = 5
SEED_COLS = 13
TYPE_SOURCES_EXCLUDED = {"redirect", "title", "dislink"}  # D1' decision — see module docstring's sibling note in the plan (disambig kept)

VERIFIED_HEADER = [
    "id", "reading", "page_id", "page_title", "split", "span_start", "span_len", "sentence",
    "seg_ok", "pos_tag", "cand_count", "candidates", "sys_top1", "auto_convert",
]

CRITERIA_SUMMARY = """\
# 판정 기준 요약 (전문은 docs/plans/hanja-context-d2-labeling-guide.md)
# U = 유일 정답 (문맥상 이 한자만 옳다)
# M = 복수 허용 (여러 한자 표기가 모두 자연스럽다 — 주정답 1개 + 허용집합 전체를 ,로 구분해 기입)
# K = 한글 유지가 자연스러움 (한자로 바꾸면 오히려 부자연스럽거나, 외래어/고유명사처럼 관행상 한글로 쓴다)
# ? = 판단 불가 (문맥이 불충분하거나 전문 지식 필요)
# 병기(한글(漢字)) 관행은 그 자체로 "한자 변환이 옳다"의 근거가 아니다 — 일반 산문에서 그 자리에
# 한자를 실제로 쓸 것인가로 판단한다. 자세한 기준·예시는 라벨링 지침 문서를 먼저 읽어라.
"""


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------
def load_verified_sentences(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        first = True
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            if first:
                first = False
                if line.startswith("#") or line.split("\t")[0] == "id":
                    continue
            if line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != len(VERIFIED_HEADER):
                continue
            rows.append(dict(zip(VERIFIED_HEADER, cols)))
    return rows


def load_reading_selection_rows(path: Path) -> list[dict]:
    cols_names = ["reading", "total_freq", "freq_rank", "band", "cand_count", "cand_bucket", "native_flag", "cell", "candidates"]
    rows = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != len(cols_names):
                continue
            rows.append(dict(zip(cols_names, cols)))
    return rows


def load_flagged_readings(path: Path) -> set[str]:
    flagged = set()
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if cols and cols[0]:
                flagged.add(cols[0])
    return flagged


def mark_span(sentence: str, span_start: int, span_len: int) -> str:
    return sentence[:span_start] + "⟦" + sentence[span_start:span_start + span_len] + "⟧" + sentence[span_start + span_len:]


# ---------------------------------------------------------------------------
# Output 1 — label-sheet.tsv
# ---------------------------------------------------------------------------
def build_label_sheet(verified_rows: list[dict], cap_per_reading: int, seed: int) -> list[dict]:
    by_reading: dict[str, list[dict]] = defaultdict(list)
    for r in verified_rows:
        if r["seg_ok"] == "1":
            by_reading[r["reading"]].append(r)

    rng = random.Random(seed)
    selected: list[dict] = []
    for reading in sorted(by_reading.keys()):
        pool = sorted(by_reading[reading], key=lambda r: r["id"])
        if len(pool) <= cap_per_reading:
            chosen = pool
        else:
            chosen = rng.sample(pool, k=cap_per_reading)
            chosen.sort(key=lambda r: r["id"])
        selected.extend(chosen)
    return selected


def write_label_sheet(selected: list[dict], out_path: Path, seed: int) -> int:
    n = len(selected)
    n_relabel = round(n * RELABEL_FRACTION)
    relabel_rng = random.Random(seed)
    relabel_numbers = set(relabel_rng.sample(range(1, n + 1), k=min(n_relabel, n))) if n > 0 else set()

    header_cols = ["번호", "판정범주", "주정답", "허용집합", "읽기", "표시문장", "후보목록", "POS", "split", "page_id", "id", "재라벨"]
    with out_path.open("w", encoding="utf-8") as f:
        f.write(CRITERIA_SUMMARY)
        f.write(f"# seed={seed} 총 {n}행, cap={LABEL_SHEET_MAX_PER_READING}/읽기, 재라벨 표본={len(relabel_numbers)}행({RELABEL_FRACTION*100:.0f}%)\n")
        f.write("\t".join(header_cols) + "\n")
        for i, row in enumerate(selected, start=1):
            display = mark_span(row["sentence"], int(row["span_start"]), int(row["span_len"]))
            cols = [
                str(i), "", "", "", row["reading"], display, row["candidates"], row["pos_tag"],
                row["split"], row["page_id"], row["id"], "1" if i in relabel_numbers else "",
            ]
            sanitized = [c.replace("\t", " ").replace("\n", " ").replace("\r", " ") for c in cols]
            f.write("\t".join(sanitized) + "\n")
    return n


# ---------------------------------------------------------------------------
# Output 2 — labeling guide (examples pulled live from verified_rows)
# ---------------------------------------------------------------------------
def pick_guide_examples(verified_rows: list[dict], flagged_readings: set[str]) -> tuple[list[dict], list[dict]]:
    idiomatic_pool = [r for r in verified_rows if r["pos_tag"] == "NNP" and r["seg_ok"] == "1"]
    idiomatic_pool.sort(key=lambda r: (r["reading"], r["id"]))
    idiomatic: list[dict] = []
    seen_readings: set[str] = set()
    for r in idiomatic_pool:
        if r["reading"] in seen_readings:
            continue
        seen_readings.add(r["reading"])
        idiomatic.append(r)
        if len(idiomatic) >= GUIDE_EXAMPLES_PER_GROUP:
            break

    # 조율자 수정 (2026-07-31): 원래 규칙("고유어 동음이의 플래그 읽기 + 문장에 한자 0개")은
    # K 범주의 예시로 부적합했다 — 전수 실행에서 뽑힌 고승·공중·녹음·단지·대동은 전부 한자어
    # 뜻으로 쓰인 자리라, 지침을 읽는 라벨러가 K를 과대 적용하게 만든다. "문장에 한자가 없다"는
    # 위키 문체의 성질이지 그 자리가 고유어라는 신호가 아니다.
    #
    # 대신 **부사(MAG)** 를 쓴다: 돌연·절대·진작처럼 부사로 굳어진 자리는 한자어 어원이 있어도
    # 현대 산문에서 한자를 쓰지 않는 것이 규범에 가까워, K 범주가 겨냥하는 바로 그 유형이다.
    # 태그 하나에 기대는 대리 지표인 것은 마찬가지이므로 지침 문서의 캐비엇은 유지한다.
    hangul_pool = [
        r for r in verified_rows
        if r["pos_tag"] == "MAG" and r["seg_ok"] == "1"
    ]
    hangul_pool.sort(key=lambda r: (r["reading"], r["id"]))
    hangul_natural: list[dict] = []
    seen_readings2: set[str] = set()
    for r in hangul_pool:
        if r["reading"] in seen_readings2:
            continue
        seen_readings2.add(r["reading"])
        hangul_natural.append(r)
        if len(hangul_natural) >= GUIDE_EXAMPLES_PER_GROUP:
            break

    # 세 번째 그룹: 현행 시스템이 실제로 자동 변환까지 하는데 그 1위가 의심스러운 자리.
    # 라벨러에게 "이 평가가 무엇을 잡으려는 것인가"를 보여주는 가장 값싼 방법이고,
    # safety set의 keep_hangul_native/nnp 층이 왜 사람 확인을 요구하는지도 같이 설명한다.
    risk_pool = [
        r for r in verified_rows
        if r["seg_ok"] == "1" and r.get("auto_convert") == "1" and r["reading"] in flagged_readings
    ]
    risk_pool.sort(key=lambda r: (r["reading"], r["id"]))
    risky: list[dict] = []
    seen_readings3: set[str] = set()
    for r in risk_pool:
        if r["reading"] in seen_readings3:
            continue
        seen_readings3.add(r["reading"])
        risky.append(r)
        if len(risky) >= GUIDE_EXAMPLES_PER_GROUP:
            break

    return idiomatic, hangul_natural, risky


def format_example(r: dict) -> str:
    display = mark_span(r["sentence"], int(r["span_start"]), int(r["span_len"]))
    return f"- **{r['reading']}** (page_id={r['page_id']}, 시스템 1위 예측={r['sys_top1'] or '(없음)'}): {display}"


def write_labeling_guide(
    idiomatic: list[dict], hangul_natural: list[dict], risky: list[dict], out_path: Path
) -> None:
    lines = []
    lines.append("# D2 라벨링 지침 — 허용 집합(acceptable set) 4범주\n")
    lines.append(
        "이 문서는 `docs/plans/hanja-context-scaling-plan.md` §9(단계 D2)와 "
        "`docs/hanja-context-quality-scaling-research.md` §5.1이 요구하는 라벨 지침을 "
        "실제 작업 절차로 풀어 쓴 것이다. `d2/label-sheet.tsv`를 채울 때 이 문서를 기준으로 삼는다.\n"
    )
    lines.append("## 1. 4범주 정의\n")
    lines.append(
        "각 행마다 `판정범주` 열에 아래 네 기호 중 하나를 적는다.\n\n"
        "- **U (유일 정답)** — 이 문맥에서는 `주정답` 한 개만 옳다. 다른 후보로 바꾸면 의미가 달라지거나 "
        "부자연스럽다. `허용집합`은 비워 둔다.\n"
        "- **M (복수 허용)** — 이 문맥에서 두 개 이상의 한자 표기가 모두 자연스럽다(예: 격식체/약식체 차이, "
        "동의어 관계, 필자에 따라 갈릴 만한 표기). `주정답`에 그래도 가장 무난한 한 개를 지정하고, "
        "`허용집합`에는 주정답을 포함해 허용 가능한 후보 전체를 `,`로 구분해 적는다.\n"
        "- **K (한글 유지가 자연스러움)** — 어떤 후보로 바꾸어도 이 문맥에서는 한글 표기가 더 자연스럽다. "
        "고유명사의 외래어 표기, 조사/어미가 붙은 고유어, 굳어진 부사 등이 흔한 사례다. `주정답`/`허용집합`은 "
        "비워 두거나 `KEEP_HANGUL`이라고 적는다.\n"
        "- **? (판단 불가)** — 문맥이 너무 짧거나, 전문 지식이 없으면 판단할 수 없거나, 표시문장 자체가 "
        "비문·발췌 조각이라 판단 근거가 부족하다. `주정답`/`허용집합`은 비워 둔다.\n"
    )
    lines.append("## 2. 허용 집합 표기법\n")
    lines.append(
        "`M`으로 판정한 행은 `주정답` 열에 한자 하나만 쓰고, `허용집합` 열에는 주정답을 포함한 전체 허용 "
        "목록을 `,`로 구분해 쓴다. 예: 주정답=`對偶`, 허용집합=`對偶,對偶對`. `U`/`K`/`?`는 `허용집합`을 "
        "비워 둔다(주정답 하나 = 허용집합 전체이므로 중복 기입하지 않는다).\n"
    )
    lines.append("## 3. 병기(併記) 관행 처리 기준 — 반드시 지킬 것\n")
    lines.append(
        "위키백과 문체는 `대한민국(大韓民國)`처럼 처음 등장하는 한자어에 한자를 병기하는 관행이 있다. "
        "**이 병기가 존재한다는 사실 자체는 \"이 자리에 한자 변환이 옳다\"의 근거가 아니다.** "
        "(실제로 이 평가의 채굴 문장에는 대상 읽기의 병기가 전혀 없다 — 채굴 단계의 누설 방지 필터가 "
        "정답 한자가 문장에 그대로 노출된 문장을 미리 제외했기 때문이다. 그래도 다른 위키 특유의 서지·인용 "
        "관행에는 계속 유의해야 한다.) 판정 기준은 항상 하나다: **일반적인 현대 한국어 산문에서, 이 자리에 "
        "필자가 실제로 한자를 쓸 것인가?** 위키 백과사전 특유의 격식(초출 표제어 병기, 학술 인용, 서지 "
        "표기)에 이끌려 `U`나 `M`으로 과대 판정하지 말 것 — 그런 협소한 관행만으로 한자가 붙는 자리라면 "
        "오히려 `K`나 `?`에 가깝다.\n"
    )
    lines.append("## 4. 예시 — 관행상 한자 표기가 자연스러운 유형 (고유명사·연호·관직명·불교 용어 등)\n")
    lines.append(
        "아래는 작업 2(`build_d2_mining.py`)가 실제로 채굴한 문장에서 뽑았다 "
        "(`pos_tag=NNP`이고 세그멘테이션이 정확히 맞은 행 — 고유명사류 표기 관행의 대리 지표). "
        "**주의**: `NNP` 태그는 기계적 대리 지표일 뿐 정답이 아니다 — 예를 들어 외국인 인명(모세, 조조처럼 "
        "실제로는 성경 인물·영단어 이름 등을 가리키는 경우)도 `NNP`로 잡히지만 그 경우엔 오히려 한글 유지가 "
        "맞다. 아래 목록도 라벨러가 문장을 직접 읽고 판단해야 하며, 태그만 보고 자동으로 `U`/`M`을 주면 안 "
        "된다.\n"
    )
    if len(idiomatic) < 3:
        lines.append(
            f"**경고**: 현재 verified-sentences.tsv에서 이 조건을 만족하는 서로 다른 읽기가 {len(idiomatic)}개뿐이다 "
            "(스모크 표본 규모 제한 가능성 — 전수 실행 후 이 문서를 재생성하면 예시가 보강된다).\n"
        )
    for r in idiomatic:
        lines.append(format_example(r))
    lines.append("")
    lines.append("## 5. 예시 — 현대 산문에서 한글이 자연스러운 유형 (K)\n")
    lines.append(
        "아래는 채굴 문장 중 Kiwi가 **부사(`MAG`)** 로 태깅한 자리에서 뽑았다. 부사로 굳어진 자리는 "
        "한자어 어원이 있어도(突然·絶對·眞作 등) 현대 산문에서 한자를 쓰지 않는 것이 규범에 가까워 "
        "`K`가 겨냥하는 전형이다. **주의**: 이것도 태그 하나에 기댄 대리 지표다 — 같은 형태가 문맥에 "
        "따라 명사로 쓰이면 판정이 달라진다. 최종 판정은 항상 문장을 직접 읽고 내린다.\n\n"
        "`K`가 적용되는 다른 전형: 외국 인명·지명의 한글 표기(모세, 조조 등 — 한국 한자음 후보가 "
        "따로 있어도 그 자리에서는 한글이 맞다), 조사·어미가 붙은 고유어, 외래어.\n"
    )
    if len(hangul_natural) < 3:
        lines.append(
            f"**경고**: 현재 verified-sentences.tsv에서 이 조건을 만족하는 서로 다른 읽기가 {len(hangul_natural)}개뿐이다 "
            "(스모크 표본 규모 제한 가능성 — 전수 실행 후 이 문서를 재생성하면 예시가 보강된다).\n"
        )
    for r in hangul_natural:
        lines.append(format_example(r))
    lines.append("")
    lines.append("## 5b. 이 평가가 잡으려는 것 — 현행 시스템이 실제로 자동 변환하는 위험한 자리\n")
    lines.append(
        "아래는 현행 시스템이 이 문장에서 **자동 변환까지 수행**하는 행 중, 읽기가 고유어 동음이의 "
        "플래그 목록에 있는 것을 뽑았다. `시스템 1위 예측`이 문맥상 틀렸다면 그것이 바로 이 라벨 자산이 "
        "측정하려는 오변환이다. 라벨을 채울 때 \"시스템이 뭐라고 했는가\"에 끌려가지 말고 문장만 보고 "
        "판정하라 — 시스템 예측 열은 참고용으로만 실었다.\n"
    )
    for r in risky:
        lines.append(format_example(r))
    lines.append("")
    lines.append("## 6. 라벨러 자기 일치도 측정 절차\n")
    lines.append(
        "라벨러가 1인이므로 라벨러 간 일치도 대신 **자기 일치도(self-consistency)**로 대체한다 "
        "(연구 문서 §5.1의 \"표본의 10% 이상을 이중 라벨\" 요구를 시차 재라벨로 충족).\n\n"
        f"1. `label-sheet.tsv`의 `재라벨` 열이 `1`인 행({int(RELABEL_FRACTION*100)}%, "
        f"seed={SHEET_SEED}로 고정 표집)이 재라벨 대상이다.\n"
        "2. 1차 라벨링을 전부 마친 뒤, **최소 2주가 지난 다음** 재라벨 대상 행만 다시 판정한다 — "
        "1차 판정 결과를 보지 않고 표시문장만 보고 새로 판정한다(1차 결과는 재라벨 완료 후에만 대조).\n"
        "3. 일치도 = 재라벨 대상 중 판정범주(및 M 행의 주정답)가 1차와 동일한 비율. 범주별로도 따로 "
        "집계한다 — 특히 `M`처럼 다의적인 범주는 일치도가 낮게 나올 수 있으며, 그 경우 지표에서 "
        "따로 표시하고 모델 오류로 오인하지 않는다(연구 문서 §5.1).\n"
        "4. 일치도가 낮은 범주가 있으면 이 지침 문서의 해당 절을 보완하고, 전체 라벨을 다시 하지 않아도 "
        "되도록 애매한 사례 유형을 이 문서에 추가한다.\n"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Output 3 — safety-set.tsv
# ---------------------------------------------------------------------------
def iter_seed_rows(seeds_dir: Path):
    for part in sorted(seeds_dir.glob("part-*.tsv")):
        with part.open(encoding="utf-8") as f:
            for line in f:
                if line.startswith("# format:") or not line.strip():
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) != SEED_COLS:
                    continue
                yield cols


def build_safety_seed_gold(seeds_dir: Path, d2_pages: set[str], target: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    reservoir: list[dict] = []
    seen_count = 0
    for cols in iter_seed_rows(seeds_dir):
        level, source, reading, hanja, page_id, _family, span_start, span_len, in_target, _amb, _resid, input_sentence, evidence = cols
        if level == "type" and source in TYPE_SOURCES_EXCLUDED:
            continue
        if in_target != "1":
            continue
        if page_id in d2_pages:
            continue
        if level == "token":
            display = mark_span(input_sentence, int(span_start), int(span_len))
        else:  # disambig — no input_sentence/span (type-level row); fall back to its evidence line
            display = evidence
        row = dict(유형="seed_gold", 요검수="0", 읽기=reading, gold=hanja, 표시문장=display, page_id=page_id, 출처=f"seed:{source}")
        seen_count += 1
        if len(reservoir) < target:
            reservoir.append(row)
        else:
            j = rng.randint(0, seen_count - 1)
            if j < target:
                reservoir[j] = row
    return reservoir


def build_safety_keep_hangul_native(verified_rows: list[dict], flagged_readings: set[str]) -> list[dict]:
    out = []
    for r in verified_rows:
        if r["reading"] not in flagged_readings:
            continue
        if es.HANJA_RUN_RE.search(r["sentence"]):
            continue
        display = mark_span(r["sentence"], int(r["span_start"]), int(r["span_len"]))
        out.append(dict(유형="keep_hangul_native", 요검수="1", 읽기=r["reading"], gold="KEEP_HANGUL", 표시문장=display, page_id=r["page_id"], 출처="mined"))
    return out


def build_safety_nnp(verified_rows: list[dict]) -> list[dict]:
    out = []
    for r in verified_rows:
        if r["pos_tag"] != "NNP":
            continue
        display = mark_span(r["sentence"], int(r["span_start"]), int(r["span_len"]))
        out.append(dict(유형="nnp", 요검수="1", 읽기=r["reading"], gold="", 표시문장=display, page_id=r["page_id"], 출처="mined"))
    return out


def write_safety_set(rows: list[dict], out_path: Path, counts_by_type: dict[str, int], target: int) -> None:
    header_cols = ["유형", "요검수", "읽기", "gold", "표시문장", "page_id", "출처"]
    immediately_measurable = counts_by_type.get("seed_gold", 0)
    with out_path.open("w", encoding="utf-8") as f:
        f.write("# format: d2-safety-set v1 유형<TAB>요검수<TAB>읽기<TAB>gold<TAB>표시문장<TAB>page_id<TAB>출처\n")
        f.write(f"# seed_gold target={target}, 실제={counts_by_type.get('seed_gold', 0)}\n")
        for t in ("seed_gold", "keep_hangul_native", "nnp"):
            f.write(f"# 유형={t}: {counts_by_type.get(t, 0)}건 (요검수={'0' if t == 'seed_gold' else '1'})\n")
        f.write(
            f"# 즉시 측정 가능한 양성 건수(요검수=0, 사람 라벨 없이 자동 채점 가능): {immediately_measurable}건 "
            f"(연구 문서 §5.3-3 목표 1,000건 이상 {'충족' if immediately_measurable >= 1000 else '미달'})\n"
        )
        f.write("\t".join(header_cols) + "\n")
        for row in rows:
            cols = [row[c] for c in header_cols]
            sanitized = [c.replace("\t", " ").replace("\n", " ").replace("\r", " ") for c in cols]
            f.write("\t".join(sanitized) + "\n")


# ---------------------------------------------------------------------------
# Output 4 — d2-assets-report.md
# ---------------------------------------------------------------------------
def build_assets_report(
    selection_rows: list[dict], verified_rows: list[dict], label_sheet_rows: list[dict],
    safety_counts: dict[str, int], disjointness_report_path: Path,
) -> str:
    lines = ["# D2 자산 구축 보고서 (d2-assets-report.md)\n"]

    # Cell table (recomputed straight from reading-selection.tsv's data rows).
    cell_counts: dict[str, int] = defaultdict(int)
    for r in selection_rows:
        cell_counts[r["cell"]] += 1
    lines.append("## 선정 셀 표 (읽기 수)\n")
    lines.append("| cell | 선정 읽기 수 |")
    lines.append("|---|---:|")
    for cell in sorted(cell_counts):
        lines.append(f"| {cell} | {cell_counts[cell]} |")
    lines.append(f"| **합계** | **{len(selection_rows)}** |")

    # Mining yield per reading.
    mined_count_by_reading: dict[str, int] = defaultdict(int)
    for r in verified_rows:
        mined_count_by_reading[r["reading"]] += 1
    selected_readings = [r["reading"] for r in selection_rows]
    under_quota = {r: mined_count_by_reading.get(r, 0) for r in selected_readings if mined_count_by_reading.get(r, 0) < MINING_MAX_PER_READING}
    zero_mined = [r for r in selected_readings if mined_count_by_reading.get(r, 0) == 0]
    lines.append("\n## 채굴 수율\n")
    lines.append(f"- 채굴된 문장 총수(verified-sentences.tsv 행 수): {len(verified_rows):,}")
    lines.append(f"- 선정 읽기 {len(selected_readings)}개 중 정원({MINING_MAX_PER_READING}/읽기) 미달: {len(under_quota)}개")
    lines.append(f"- 선정 읽기 중 채굴 0건: {len(zero_mined)}개")
    if zero_mined:
        lines.append(f"  - 0건 읽기 목록: {', '.join(sorted(zero_mined))}")
    if under_quota:
        under_quota_str = ", ".join(f"{r}:{c}" for r, c in sorted(under_quota.items()))
        lines.append(f"  - 미달 읽기별 채굴 수: {under_quota_str}")

    # segMiss rate.
    seg_ok_counts: dict[str, int] = defaultdict(int)
    for r in verified_rows:
        seg_ok_counts[r["seg_ok"]] += 1
    total_verified = len(verified_rows)
    seg_miss_n = seg_ok_counts.get("segMiss", 0)
    seg_mismatch_n = seg_ok_counts.get("0", 0)
    seg_ok_n = seg_ok_counts.get("1", 0)
    lines.append("\n## segMiss율 (연구 문서 §5.2)\n")
    lines.append(f"- 전체 채굴 문장: {total_verified:,}")
    if total_verified:
        lines.append(f"- seg_ok=1 (분절 정확): {seg_ok_n:,} ({seg_ok_n/total_verified*100:.1f}%)")
        lines.append(f"- seg_ok=0 (읽기는 잡혔으나 span 불일치): {seg_mismatch_n:,} ({seg_mismatch_n/total_verified*100:.1f}%)")
        lines.append(f"- segMiss (읽기 자체를 세그먼트로 못 잡음): {seg_miss_n:,} ({seg_miss_n/total_verified*100:.1f}%)")

    # split sizes.
    split_counts_all: dict[str, int] = defaultdict(int)
    for r in verified_rows:
        split_counts_all[r["split"]] += 1
    split_counts_sheet: dict[str, int] = defaultdict(int)
    for r in label_sheet_rows:
        split_counts_sheet[r["split"]] += 1
    lines.append("\n## split 크기\n")
    lines.append(f"- 전체 채굴 문장: dev={split_counts_all.get('dev', 0):,} test={split_counts_all.get('test', 0):,}")
    lines.append(f"- label-sheet (seg_ok=1, cap 적용 후): dev={split_counts_sheet.get('dev', 0):,} test={split_counts_sheet.get('test', 0):,}")

    # safety layer counts.
    lines.append("\n## safety 유형별 건수\n")
    for t in ("seed_gold", "keep_hangul_native", "nnp"):
        lines.append(f"- {t}: {safety_counts.get(t, 0):,}건")
    lines.append(
        f"- 즉시 측정 가능한 양성 건수(seed_gold, 사람 라벨 불필요): {safety_counts.get('seed_gold', 0):,}건 "
        f"(목표 {SAFETY_SEED_GOLD_TARGET:,}건 이상 — {'충족' if safety_counts.get('seed_gold', 0) >= SAFETY_SEED_GOLD_TARGET else '미달'})"
    )

    # disjointness (from Task 2's report, if available).
    lines.append("\n## 불겹침 검증 결과 (작업 2 산출)\n")
    if disjointness_report_path.exists():
        text = disjointness_report_path.read_text(encoding="utf-8")
        for line in text.splitlines():
            if "위반" in line or "D1_pages" in line or "D1_families" in line:
                lines.append(line)
    else:
        lines.append(f"- {disjointness_report_path} 없음 — build_d2_mining.py를 먼저 실행할 것.")

    # remaining labeling effort estimate.
    n_label_rows = len(label_sheet_rows)
    lines.append("\n## 사용자 라벨링에 남은 작업량 추정\n")
    lines.append(
        f"- label-sheet.tsv 행 수: {n_label_rows:,}"
    )
    lines.append(
        "- 가정(실측 아님): 표시문장 확인 + 허용집합 판단에 행당 1~2분 (짧은 문장·U 판정이면 더 빠르고, "
        "M 판정으로 허용집합을 여러 개 나열해야 하면 더 걸린다)."
    )
    lo_min, hi_min = n_label_rows * 1, n_label_rows * 2
    lines.append(
        f"- 1차 라벨링 추정: {lo_min:,}~{hi_min:,}분 ({lo_min/60:.1f}~{hi_min/60:.1f}시간)"
    )
    n_relabel = round(n_label_rows * RELABEL_FRACTION)
    lines.append(
        f"- 재라벨(10%, {n_relabel:,}행, 2주 이상 시차 필요) 추가: {n_relabel*1:,}~{n_relabel*2:,}분 "
        f"({n_relabel*1/60:.1f}~{n_relabel*2/60:.1f}시간)"
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verified-sentences", type=Path, default=VERIFIED_TSV)
    parser.add_argument("--reading-selection", type=Path, default=READING_SELECTION_TSV)
    parser.add_argument("--seeds-dir", type=Path, default=SEEDS_DIR)
    parser.add_argument("--flagged", type=Path, default=FLAGGED_TSV)
    parser.add_argument("--out-dir", type=Path, default=D2_DIR)
    parser.add_argument("--guide-out", type=Path, default=GUIDE_OUT)
    parser.add_argument("--disjointness-report", type=Path, default=DISJOINTNESS_REPORT)
    parser.add_argument("--label-sheet-max-per-reading", type=int, default=LABEL_SHEET_MAX_PER_READING)
    parser.add_argument("--safety-seed-gold-target", type=int, default=SAFETY_SEED_GOLD_TARGET)
    parser.add_argument("--seed", type=int, default=SHEET_SEED)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    label_sheet_out = args.out_dir / "label-sheet.tsv"
    safety_set_out = args.out_dir / "safety-set.tsv"
    assets_report_out = args.out_dir / "d2-assets-report.md"

    print(f"loading {args.verified_sentences} ...")
    verified_rows = load_verified_sentences(args.verified_sentences)
    print(f"verified_rows={len(verified_rows)}")

    print(f"loading {args.reading_selection} ...")
    selection_rows = load_reading_selection_rows(args.reading_selection)
    print(f"selection_rows={len(selection_rows)}")

    print(f"loading {args.flagged} ...")
    flagged_readings = load_flagged_readings(args.flagged)
    print(f"flagged_readings={len(flagged_readings)}")

    # ---- Output 1: label-sheet.tsv ----
    label_sheet_rows = build_label_sheet(verified_rows, args.label_sheet_max_per_reading, args.seed)
    n_label = write_label_sheet(label_sheet_rows, label_sheet_out, args.seed)
    print(f"wrote {label_sheet_out}: {n_label} rows")

    # ---- Output 2: labeling guide ----
    idiomatic, hangul_natural, risky = pick_guide_examples(verified_rows, flagged_readings)
    write_labeling_guide(idiomatic, hangul_natural, risky, args.guide_out)
    print(f"wrote {args.guide_out}: idiomatic={len(idiomatic)} hangul_natural={len(hangul_natural)} risky={len(risky)}")
    if len(idiomatic) < 3 or len(hangul_natural) < 3:
        print(
            f"WARNING: guide example pools below the >=3 target "
            f"(idiomatic={len(idiomatic)}, hangul_natural={len(hangul_natural)}) — "
            f"likely a smoke-scale --verified-sentences input; re-run after the full corpus mining pass.",
            file=sys.stderr,
        )

    # ---- Output 3: safety-set.tsv ----
    d2_pages = {r["page_id"] for r in verified_rows}
    seed_gold_rows = build_safety_seed_gold(args.seeds_dir, d2_pages, args.safety_seed_gold_target, args.seed)
    keep_hangul_rows = build_safety_keep_hangul_native(verified_rows, flagged_readings)
    nnp_rows = build_safety_nnp(verified_rows)
    all_safety_rows = seed_gold_rows + keep_hangul_rows + nnp_rows
    safety_counts = {
        "seed_gold": len(seed_gold_rows),
        "keep_hangul_native": len(keep_hangul_rows),
        "nnp": len(nnp_rows),
    }
    write_safety_set(all_safety_rows, safety_set_out, safety_counts, args.safety_seed_gold_target)
    print(f"wrote {safety_set_out}: {safety_counts}")

    # ---- Output 4: d2-assets-report.md ----
    report_text = build_assets_report(selection_rows, verified_rows, label_sheet_rows, safety_counts, args.disjointness_report)
    assets_report_out.write_text(report_text, encoding="utf-8")
    print(f"wrote {assets_report_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
