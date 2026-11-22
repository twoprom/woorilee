#!/usr/bin/env python3
"""K1b Part 2 join step 1: extract the 31-reading eval-composition subset (status=="scored") from
the K1 holdout artifacts, preserving row order throughout so downstream files can be re-joined
purely positionally (see the K1b Task 1/Task 2 investigation: composite content keys
(reading,hanja,page_id,family) are NOT unique across holdout.tsv -- 21% of rows collide -- but the
three files [holdout.tsv, holdout-scored.tsv, diagnose-holdout-scored.tsv] are independently
verified 1:1 positional across all 23,986 rows).

Writes two files, same row order, same 717-row (or whatever the current count is) length:
  1. 31series-holdout.tsv    -- K1 measure/holdout.tsv format (reading..input_sentence), for
                                  feeding into `assoc score-holdout` (the offline association-ranker
                                  harness).
  2. 31series-k1-meta.tsv    -- K1's own predicted/correct/gold_surfaced/status/donor/source for the
                                  SAME rows in the SAME order, to be zipped positionally against
                                  assoc's own score-holdout output later.
"""
import sys

READINGS_31 = set("감기 감정 경기 고장 공사 구두 국화 대전 무기 방화 부정 사고 사과 선물 성인 소화 "
                   "수도 시장 연기 유산 의사 이상 인상 장관 전기 정도 조선 지금 지방 표지 화상".split())

HOLDOUT = "/Volumes/Workbench/wooriHanjaModel/work/hanja-context/k1/measure/holdout.tsv"
HOLDOUT_SCORED = "/Volumes/Workbench/wooriHanjaModel/work/hanja-context/k1/holdout-scored.tsv"
DIAGNOSE_SCORED = "/Volumes/Workbench/wooriHanjaModel/work/hanja-context/k1/diagnose-holdout-scored.tsv"

OUT_DIR = "/Volumes/Workbench/wooriHanjaModel/work/hanja-context/k1/part2"


def load_holdout(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            c = line.rstrip("\n").split("\t")
            if c[0] == "reading":  # literal header row (no # prefix) in holdout.tsv only
                continue
            rows.append(c)
    return rows


def load_plain(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            rows.append(line.rstrip("\n").split("\t"))
    return rows


def main():
    holdout = load_holdout(HOLDOUT)
    scored = load_plain(HOLDOUT_SCORED)
    diag = load_plain(DIAGNOSE_SCORED)

    assert len(holdout) == len(scored) == len(diag), (
        f"row count mismatch: holdout={len(holdout)} scored={len(scored)} diag={len(diag)}"
    )
    n = len(holdout)

    # Re-verify positional correspondence before trusting the join (cheap, whole-file).
    for i in range(n):
        h = holdout[i]
        s = scored[i]
        d = diag[i]
        if h[0] != s[0] or h[1] != s[1] or h[6] != s[13] or h[7] != s[12]:
            sys.exit(f"holdout/scored mismatch at row {i}: {h[:2]} {h[6:8]} vs {s[0:2]} {s[12:14]}")
        if s[0] != d[0] or s[1] != d[1] or s[2] != d[2] or s[10] != d[11]:
            sys.exit(f"scored/diagnose mismatch at row {i}: {s[0:3]} {s[10]} vs {d[0:3]} {d[11]}")

    selected = []
    for i in range(n):
        reading = holdout[i][0]
        status = scored[i][2]
        if reading in READINGS_31 and status == "scored":
            selected.append(i)

    print(f"total holdout rows: {n}")
    print(f"31-series rows (any status): {sum(1 for i in range(n) if holdout[i][0] in READINGS_31)}")
    print(f"31-series rows with status=='scored': {len(selected)}")

    with open(f"{OUT_DIR}/31series-holdout.tsv", "w", encoding="utf-8") as f:
        f.write("# 31-series (eval-composition) subset of K1 measure/holdout.tsv, status=='scored' only\n")
        f.write("reading\thanja\tsense_id\tdonor\tdonor_pos\tsource\tfamily\tpage_id\tspan_start\tspan_len\tinput_sentence\n")
        for i in selected:
            f.write("\t".join(holdout[i]) + "\n")

    with open(f"{OUT_DIR}/31series-k1-meta.tsv", "w", encoding="utf-8") as f:
        f.write("# K1's own per-row outcome for the SAME rows/order as 31series-holdout.tsv\n")
        f.write("reading\tgold_hanja\tk1_status\tk1_predicted\tk1_correct\tk1_no_surface_miss\tgold_surfaced\t"
                "floorA_predicted\tfloorA_correct\tfloorB_expected\tsource\tdonor\tcandidate_count\tpage_id\tfamily\n")
        for i in selected:
            s = scored[i]
            d = diag[i]
            # s: reading candidate status predicted correct no_surface_miss floorA_predicted floorA_correct floorB_expected source donor candidate_count page_id family
            # d: reading candidate status predicted correct no_surface_miss gold_surfaced floorA_predicted floorA_correct floorB_expected source donor candidate_count
            f.write("\t".join([
                s[0], s[1], s[2], s[3], s[4], s[5], d[6],
                s[6], s[7], s[8], s[9], s[10], s[11], s[12], s[13],
            ]) + "\n")

    print(f"wrote {OUT_DIR}/31series-holdout.tsv and 31series-k1-meta.tsv ({len(selected)} rows each)")


if __name__ == "__main__":
    main()
