#!/usr/bin/env python3
"""Curated override 확장 작업 목록 생성 (D1 보고 §9 제안서의 우선순위 1구간).

`curated-association-overrides.txt`를 사람이 채울 때 **어느 읽기부터** 손댈지를
데이터로 정한다. D1 보고 §9가 규정한 우선순위를 그대로 구현한다:

  빈도 상위 N개 표적 읽기 중, 씨앗(D1) 보유 후보가 1개 이하이고 D3가 학습하지도
  못한 읽기 — 코퍼스도 학습도 신호를 못 주는 구간이라 curated 말고는 채울 방법이
  없다.

각 행에 후보 목록(빈도순)과 현행 연관표가 그 후보에 실제로 가진 피처 수를 함께
실어서, 작업자가 "이 후보에 증거가 정말 없는가"를 파일 안에서 바로 확인할 수 있게
한다. **형태소 후보를 자동으로 제안하지 않는다** — 그것이 사람 판단을 요구하는
부분이고, 자동 제안은 D1이 이미 확인한 코퍼스 편향을 그대로 재생산한다.

Usage:
    python3 scripts/hanja-context/build_curated_worklist.py
    python3 scripts/hanja-context/build_curated_worklist.py --top-n 500 --out <path>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc  # noqa: E402

TARGETS_TSV = hc.WORK_DIR / "inventory/targets.tsv"
SEEDS_DIR = hc.WORK_DIR / "seeds"
MODEL_JSON = hc.WORK_DIR / "d3/model.json"
ASSOC_TXT = hc.WOORILEE_ROOT / "woorilee/data/hanja/hanja-context.txt"
CURATED_TXT = Path(__file__).resolve().with_name("curated-association-overrides.txt")
OUT_MD = hc.WORK_DIR / "curated-worklist.md"


def load_targets(path: Path) -> list[tuple[str, int, list[tuple[str, int]]]]:
    rows = []
    for line in path.open(encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 3:
            continue
        cands = []
        for item in cols[2].split(","):
            if ":" not in item:
                continue
            h, f = item.rsplit(":", 1)
            cands.append((h, int(f)))
        rows.append((cols[0], int(cols[1]), cands))
    rows.sort(key=lambda r: -r[1])
    return rows


def load_seed_pairs(seeds_dir: Path) -> set[tuple[str, str]]:
    """(reading, hanja) pairs that have at least one token-level seed."""
    pairs: set[tuple[str, str]] = set()
    for part in sorted(seeds_dir.glob("part-*.tsv")):
        for line in part.open(encoding="utf-8"):
            if line.startswith("#"):
                continue
            c = line.rstrip("\n").split("\t")
            if len(c) < 4 or c[0] != "token":
                continue
            pairs.add((c[2], c[3]))
    return pairs


def load_assoc_feature_counts(path: Path) -> dict[tuple[str, str], int]:
    counts: dict[tuple[str, str], int] = {}
    for line in path.open(encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        try:
            reading, hanja, feats = line.rstrip("\n").split(":", 2)
        except ValueError:
            continue
        counts[(reading, hanja)] = len([x for x in feats.split(",") if x])
    return counts


def load_curated_readings(path: Path) -> set[str]:
    done: set[str] = set()
    if not path.exists():
        return done
    for line in path.open(encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        done.add(line.split(":", 1)[0])
    return done


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--targets", type=Path, default=TARGETS_TSV)
    ap.add_argument("--seeds-dir", type=Path, default=SEEDS_DIR)
    ap.add_argument("--model", type=Path, default=MODEL_JSON)
    ap.add_argument("--assoc-txt", type=Path, default=ASSOC_TXT)
    ap.add_argument("--curated", type=Path, default=CURATED_TXT)
    ap.add_argument("--out", type=Path, default=OUT_MD)
    ap.add_argument("--top-n", type=int, default=500, help="빈도 상위 몇 개 읽기를 후보 모집단으로 볼지")
    args = ap.parse_args()

    targets = load_targets(args.targets)
    seed_pairs = load_seed_pairs(args.seeds_dir)
    assoc_counts = load_assoc_feature_counts(args.assoc_txt)
    curated_done = load_curated_readings(args.curated)
    trained = set(json.loads(args.model.read_text(encoding="utf-8"))["readings"]) if args.model.exists() else set()

    head = targets[: args.top_n]
    total_target_freq = sum(f for _r, f, _c in targets)
    head_freq = sum(f for _r, f, _c in head)

    rows = []
    for reading, freq, cands in head:
        if reading in trained or reading in curated_done:
            continue
        seeded = [h for h, _f in cands if (reading, h) in seed_pairs]
        if len(seeded) > 1:
            continue
        rows.append((reading, freq, cands, seeded))

    lines = [
        "# curated override 확장 작업 목록",
        "",
        "생성: `scripts/hanja-context/build_curated_worklist.py` (D1 보고 §9 우선순위 1구간).",
        "",
        f"- 표적 읽기 전체: {len(targets):,}개, 총 디코딩 빈도 {total_target_freq:,}",
        f"- 빈도 상위 {args.top_n}개가 점유하는 표적 빈도: {head_freq / total_target_freq * 100:.1f}%",
        f"- D3가 학습한 읽기: {len(trained)}개 (이 목록에서 제외 — 학습 신호가 이미 있다)",
        f"- 이미 curated에 있는 읽기: {len(curated_done)}개 (제외)",
        f"- **남은 작업 대상: {len(rows)}개 읽기**",
        "",
        "선정 규칙: 빈도 상위 구간 ∩ (D1 씨앗 보유 후보 ≤ 1) ∩ (D3 미학습) ∩ (curated 미작성).",
        "코퍼스도 학습도 신호를 줄 수 없는 구간이라 사람이 쓰는 것 말고는 채울 방법이 없다.",
        "",
        "`피처수`는 현행 연관표가 그 후보에 실제로 갖고 있는 형태소 수다 — 0이면 그 후보는",
        "문맥 증거가 전혀 없어 빈도순으로만 정렬된다는 뜻이다.",
        "",
        "작성 형식(`curated-association-overrides.txt`): `읽기:한자:형태소/품사=가중치,...`",
        "가중치는 최종 UInt8(1~255). 같은 읽기의 **다른 후보와 공기하지 않는 형태소만** 고른다",
        "— 겹치는 형태소를 넣으면 그 후보를 이기려고 가중치를 올리는 군비경쟁이 된다.",
        "",
        "| # | 읽기 | 빈도 | 씨앗 보유 후보 | 후보(빈도, 현행 피처수) |",
        "| ---: | --- | ---: | --- | --- |",
    ]
    for i, (reading, freq, cands, seeded) in enumerate(rows, 1):
        cand_str = " · ".join(
            f"{h}({f:,}, 피처{assoc_counts.get((reading, h), 0)})" for h, f in cands[:6]
        )
        if len(cands) > 6:
            cand_str += f" … +{len(cands) - 6}"
        lines.append(f"| {i} | **{reading}** | {freq:,} | {', '.join(seeded) if seeded else '없음'} | {cand_str} |")

    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {args.out}: {len(rows)} readings (top-{args.top_n} pool, "
          f"{len(trained)} trained / {len(curated_done)} already-curated excluded)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
