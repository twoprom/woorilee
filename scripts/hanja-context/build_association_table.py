#!/usr/bin/env python3
"""Step 5b association table builder (문맥 기반 한자 변환 — plan §7 5b).

Reads the merged step-5a raw counts under
`/Volumes/Workbench/wooriHanjaModel/work/hanja-context/counts/`
(`anchor-counts.tsv`, `paren-counts.tsv`, `dict-counts.tsv` — each
`reading<TAB>hanja<TAB>feature<TAB>count`, LC_ALL=C-sorted, unique triples)
and writes the bundleable association table
`woorilee/data/hanja/hanja-context.txt` plus
`counts/association-stats.json`.

No morphological analysis here — the feature space (`form/TAG`) was already
fixed by the step 5a Swift collector. This script is pure count math,
Python 3.14 stdlib only.

Scoring — smoothed within-reading log-odds contrast (informative Dirichlet
prior; Monroe/Colaresi/Quinn 2008 style), computed per (reading r, candidate
c, feature f):

    weighted(f, c)   = anchor_count + W_paren * paren_count + W_dict * dict_count
    survives(f, c)   iff anchor_count >= MIN_ANCHOR (5) OR paren_count >= 1
                         OR dict_count >= 1 OR colloc_count >= 1
                     (the raw-count-5 floor from the plan applies to the
                     anchor-only path; direct-label paren/dict signals are
                     exempt by design so thin candidates are not erased;
                     colloc = step-7b NIKL 파생어 연어 4th signal, flagged
                     readings only, weighted W_colloc like dict and EXEMPT
                     from the ubiquity ban per attested row — see
                     load_collocation_counts)
    n_c(f)           = weighted(f, c)               [0 if f did not survive for c]
    N_c              = sum over surviving f of n_c(f)
    n_r\\c(f)         = sum over OTHER candidates c' of n_c'(f)
    N_r\\c            = sum over OTHER candidates c' of N_c'
    V_r              = number of distinct surviving features in reading r
                       (pooled across all its candidates)
    score(f, c) = ln((n_c(f) + alpha) / (N_c + alpha*V_r))
                - ln((n_r\\c(f) + alpha) / (N_r\\c + alpha*V_r))

Only scores > 0 are kept (features equally or more associated with the
*rest* of the reading's candidates score <= 0 and drop out — this is what
prunes generic morphemes like 하/VV, 있/VV, 되/VV without a hand-curated
stoplist). Per candidate, keep the top M by the SELECTION metric

    utility(f, c) = score(f, c) * ln(1 + n_c(f))

— selection by pure score favors rare-but-perfect features (수돗물, 뱃길)
over common-but-still-discriminative ones (집, 물, 서울), yet runtime
context morphemes are everyday words, so selection weighs discriminativeness
by evidence mass. The EMITTED quantized weight stays the pure contrast
score; only which features are kept changes.

Eval-27 evidence floor (targeted 5b gate remedy): for readings in the eval
set (eval/hanja-context-eval-set.tsv), IN ADDITION to the top M by utility,
every surviving feature with weighted_count >= EVAL_FLOOR_COUNT (default 30)
AND score >= EVAL_FLOOR_MIN_SCORE (default ln 2 — at least 2x contrast odds)
is kept regardless of rank. Rationale: high-vocabulary candidates (水道 803 /
首都 2,083 surviving features) push common-but-correct probes (집 w=35,
관 w=67, 나라 w=66, 정부 w=140; scores 1.09..2.65) below any affordable
global M even under utility selection; the floor keeps exactly the "real
evidence + meaningfully associated" set for the series the plan gates on.
The min-score guard exists because barely-positive generics (하/VV 0.195,
있/VV 0.221, 되/VV 0.405 under 修道) also have huge counts — without it the
floor would resurrect exactly the features the contrast is meant to kill.
Non-eval readings are unaffected.

Ubiquity (IDF-style) filter for cross-domain-biased bare verbs (data-quality
fix, post-5b): the within-reading contrast above cannot catch a feature whose
corpus DOMAIN is skewed toward one candidate even though the morpheme itself
is topic-neutral — e.g. 나/VV survived under 수도:修道 (score>0, weighted=40)
because 修道-anchor sentences happen to be narrative prose while 水道-anchor
sentences are technical prose, not because 나/VV means anything about
monasteries. A GLOBAL ubiquity signal catches this: compute each feature's
PROFILE DOCUMENT FREQUENCY — the fraction of all post-survival, pre-prune
(reading, candidate) profiles (every candidate that would receive >=1
surviving feature, before top-M/eval-floor selection) in which the feature
appears at all. Bare generic verbs (하, 있, 되, 나, 오, 보, 들, ...) sit at
the top of this distribution.

Measured on the real corpus (docs/plans/hanja-context-5b-report.md 개정 3),
the DF distribution does NOT cleanly separate by feature identity alone:
나라/NNG (6.09%) and 정부/NNG (6.00%) — both required 首都 probes — sit
*above* 오/VV (6.04%), an audited offender, in raw DF. A single threshold
over ALL tags cannot drop 오/VV without also dropping 나라/NNG. It CAN be
done by TAG: every offending bare verb and every "discriminative rare verb"
counterexample in the audit (틀/VV, 얼/VV) is VV/VA-tagged, and no NNG/NNP
probe or thin-candidate feature is VV/VA-tagged. So the filter is scoped to
VV/VA(-I) tags only: drop VV/VA-tagged features whose ABSOLUTE profile DF
count is >= MAX_FEATURE_DF_COUNT (CLI --max-feature-df-count, 0 disables;
662 = the accepted 5b build's effective boundary — originally a fraction
0.039 of total profiles, converted to an absolute constant 2026-07-10 after
the 7b pool growth loosened the fractional boundary and re-admitted 나/VV
into 수도:修道); NNG/NNP/MAG features are never touched regardless of DF.
Banned features are excluded entirely from process_reading's by_candidate
build (before N_c/V_r/pooled_feature_total are computed), so they contribute
nothing to the contrast math either — equivalent to a computed stoplist.

Then linearly quantize score to 1..255 over the GLOBAL max score in the
final kept table (quantized values of 0 are dropped, not clamped to 1).

Output format: `읽기:한자:형태소=가중치,형태소=가중치,...`, one line per
(reading, candidate) pair with >=1 surviving+scored feature, sorted by
reading then hanja. Feature keys are `form/TAG`; `/` is safe (TAG never
contains `/`, so a Swift-side split on the *last* `/` recovers form/TAG even
when form itself embeds a slash). `:`, `,`, `=` (the table's own delimiters)
and literal `%` are percent-escaped in feature text before emission
(`%25`/`%3A`/`%2C`/`%3D`) — 449 of ~8.49M rows contain one of these three
characters (mostly unsplit movie/book titles tagged NNP).

Usage:
    python3 scripts/hanja-context/build_association_table.py
    python3 scripts/hanja-context/build_association_table.py --paren-weight 20 --dict-weight 20 --top-m 300
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from itertools import groupby
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hanja_common import WOORILEE_ROOT, WORK_DIR, EVAL_SET_TSV, load_eval_readings  # noqa: E402

COUNTS_DIR = WORK_DIR / "counts"
TARGETS_TSV = WORK_DIR / "inventory/targets.tsv"
ANCHOR_TSV = COUNTS_DIR / "anchor-counts.tsv"
PAREN_TSV = COUNTS_DIR / "paren-counts.tsv"
DICT_TSV = COUNTS_DIR / "dict-counts.tsv"

OUTPUT_TXT = WOORILEE_ROOT / "woorilee/data/hanja/hanja-context.txt"
STATS_JSON = COUNTS_DIR / "association-stats.json"

SIZE_CAP_BYTES = 8 * 1024 * 1024
ALPHA = 0.5
MIN_ANCHOR_SURVIVAL = 5
TOP_M_BASE = 300  # widest M we ever emit; smaller M values are prefixes of this
EVAL_FLOOR_COUNT = 30  # eval-27 evidence floor (0 disables)
EVAL_FLOOR_MIN_SCORE = math.log(2)  # floor also requires >= 2x contrast odds
# Ubiquity filter threshold — ABSOLUTE profile-DF count, VV/VA(-I)-tagged
# features only (0 disables). History: this was originally a FRACTION of
# total profiles (0.039). That made the effective cutoff depend on the size
# of the target pool: the step-7b target expansion grew total_profiles
# 16,974 -> 18,285, loosening the effective boundary 662 -> 714 and letting
# 나/VV(710)·가리키/VV(688) re-enter 수도:修道 — which regressed the flag
# sentence "우리 집 수도가 고장났다" to 修道 (user-verified regression,
# 2026-07-10). Fixed by user decision to the absolute constant 662 =
# ceil(0.039 * 16,974), the effective boundary of the accepted 5b build:
# on the 5b pool it reproduces the banned set EXACTLY (79/79 features,
# verified by recomputation over counts-5b-backup); on the 7b pool it bans
# 84 (all 79 retained + 갖추/그리/사/옮기/잡 — generic verbs whose DF grew
# with the pool), including 나/VV and 가리키/VV again.
MAX_FEATURE_DF_COUNT = 662
UBIQUITY_SCOPED_TAG_RE = re.compile(r"/(VV|VA)(-I)?$")

ESCAPE_MAP = {"%": "%25", ":": "%3A", ",": "%2C", "=": "%3D"}
ESCAPE_RE = re.compile("[%:,=]")


def escape_feature(feature: str) -> str:
    return ESCAPE_RE.sub(lambda m: ESCAPE_MAP[m.group()], feature)


def load_targets(path: Path = TARGETS_TSV) -> dict[str, tuple[int, list[str]]]:
    """reading -> (total_freq, [candidate hanja in freq-desc order])."""
    targets: dict[str, tuple[int, list[str]]] = {}
    with path.open(encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            reading, total_freq_s, cands_s = line.rstrip("\n").split("\t")
            cand_list = [item.rsplit(":", 1)[0] for item in cands_s.split(",")]
            targets[reading] = (int(total_freq_s), cand_list)
    return targets


def iter_triples(path: Path):
    with path.open(encoding="utf-8") as f:
        for line in f:
            reading, hanja, feature, count_s = line.rstrip("\n").split("\t")
            yield (reading, hanja, feature), int(count_s)


def merge_three(path_a: Path, path_p: Path, path_d: Path):
    """Streaming 3-way merge of the sorted count files, keyed by
    (reading, hanja, feature). Yields (key, anchor_count, paren_count,
    dict_count) in ascending key order, summing whichever streams have that
    key. All three input files are individually unique-key and LC_ALL=C
    sorted; Python str/tuple comparison of these UTF-8 strings agrees with
    byte-order sort (UTF-8 preserves code-point ordering)."""
    ia, ip, id_ = iter_triples(path_a), iter_triples(path_p), iter_triples(path_d)
    cur_a, cur_p, cur_d = next(ia, None), next(ip, None), next(id_, None)
    while cur_a is not None or cur_p is not None or cur_d is not None:
        min_key = min(x[0] for x in (cur_a, cur_p, cur_d) if x is not None)
        a_c = p_c = d_c = 0
        if cur_a is not None and cur_a[0] == min_key:
            a_c = cur_a[1]
            cur_a = next(ia, None)
        if cur_p is not None and cur_p[0] == min_key:
            p_c = cur_p[1]
            cur_p = next(ip, None)
        if cur_d is not None and cur_d[0] == min_key:
            d_c = cur_d[1]
            cur_d = next(id_, None)
        yield min_key, a_c, p_c, d_c


def iter_by_reading(path_a: Path, path_p: Path, path_d: Path):
    merged = merge_three(path_a, path_p, path_d)
    for reading, group in groupby(merged, key=lambda x: x[0][0]):
        yield reading, list(group)


def load_collocation_counts(path: Path) -> dict[str, dict[tuple[str, str], int]]:
    """4th signal (step 7b, 2026-07-10 사용자 승인): NIKL derived-verb
    collocations from build_collocation_counts.py — reading -> {(hanja,
    feature): count}. Dictionary-attested lexical evidence, restricted by
    construction to the FINAL flagged readings (7a-final-v2). Empty dict when
    the file is absent (behavior then identical to the 3-signal build).

    These rows are (a) survival-granting (like paren/dict direct labels) and
    (b) EXEMPT from the global ubiquity ban for their specific (reading,
    hanja, feature) — the ban exists to kill corpus-domain-biased generic
    verbs, but a dictionary-registered derivation (고장나다 → 고장:故障 +
    나/VV) is exactly the attested collocation the ban must not erase.
    They deliberately do NOT participate in compute_profile_df, so the
    banned set stays identical to the 3-signal build."""
    if not path.exists():
        return {}
    result: dict[str, dict[tuple[str, str], int]] = defaultdict(dict)
    with path.open(encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            reading, hanja, feature, count_s = line.rstrip("\n").split("\t")
            result[reading][(hanja, feature)] = int(count_s)
    return dict(result)


def compute_profile_df(w_paren: int, w_dict: int, min_anchor: int):
    """Second streaming pass over the merged counts (independent of
    build_master) computing each feature's PROFILE DOCUMENT FREQUENCY: the
    number of (reading, hanja) profiles — each an emitted candidate with >=1
    surviving feature, post-survival pre-prune, i.e. BEFORE the top-M/eval-
    floor selection and BEFORE the ubiquity filter itself (this pass is what
    the ubiquity filter is computed from) — in which the feature appears at
    least once. Returns (df_counts, total_profiles)."""
    df_counts: dict[str, int] = defaultdict(int)
    total_profiles = 0
    for _reading, rows in iter_by_reading(ANCHOR_TSV, PAREN_TSV, DICT_TSV):
        by_candidate: dict[str, set[str]] = defaultdict(set)
        for (_, hanja, feature), a, p, d in rows:
            if not (a >= min_anchor or p >= 1 or d >= 1):
                continue
            by_candidate[hanja].add(feature)
        for feats in by_candidate.values():
            if not feats:
                continue
            total_profiles += 1
            for f in feats:
                df_counts[f] += 1
    return df_counts, total_profiles


def process_reading(rows, w_paren: int, w_dict: int, min_anchor: int, alpha: float,
                    top_m_cap: int, floor: int = 0,
                    floor_min_score: float = EVAL_FLOOR_MIN_SCORE,
                    banned_features: frozenset[str] = frozenset(),
                    colloc: dict[tuple[str, str], int] = {},
                    w_colloc: int = 20):
    """rows: list of ((reading, hanja, feature), a, p, d) all for one reading.
    Returns (cand_features, cand_totals) or None if fewer than 2 candidates
    have any surviving feature (contrast requires >=2). cand_features maps
    hanja -> (prefix, extras): prefix = [(feature, score, weighted)] sorted
    desc by the SELECTION metric utility = score * ln(1 + weighted_count),
    sliced to top_m_cap (score is still the value emitted/quantized); extras
    = [(feature, score)] for utility rank >= top_m_cap whose weighted count
    >= floor AND score >= floor_min_score (only when floor > 0 — the eval-27
    evidence floor). cand_totals
    maps hanja -> N_c (total surviving weighted mass, pre-contrast,
    pre-prune — used later for the min-total-weighted-count cap-tightening
    step). banned_features (the ubiquity filter's VV/VA-tagged output) are
    excluded from by_candidate entirely, so they never enter N_c/V_r/
    pooled_feature_total either."""
    by_candidate: dict[str, dict[str, int]] = defaultdict(dict)
    consumed_colloc: set[tuple[str, str]] = set()
    for (_, hanja, feature), a, p, d in rows:
        k = colloc.get((hanja, feature), 0)
        if k:
            consumed_colloc.add((hanja, feature))
        if not (a >= min_anchor or p >= 1 or d >= 1 or k >= 1):
            continue
        if feature in banned_features and k == 0:
            # collocation-attested rows are exempt from the ubiquity ban
            continue
        by_candidate[hanja][feature] = a + w_paren * p + w_dict * d + w_colloc * k
    # collocation rows with no corpus/dict counterpart at all
    for (hanja, feature), k in colloc.items():
        if (hanja, feature) in consumed_colloc:
            continue
        by_candidate[hanja][feature] = w_colloc * k

    candidates_with_data = [c for c, feats in by_candidate.items() if feats]
    if len(candidates_with_data) < 2:
        return None

    n_c = {c: sum(by_candidate[c].values()) for c in candidates_with_data}
    n_total = sum(n_c.values())
    pooled_feature_total: dict[str, int] = defaultdict(int)
    for c in candidates_with_data:
        for f, w in by_candidate[c].items():
            pooled_feature_total[f] += w
    v_r = len(pooled_feature_total)

    cand_features: dict[str, tuple[list[tuple[str, float, int]], list[tuple[str, float]]]] = {}
    for c in candidates_with_data:
        nc = n_c[c]
        n_rest = n_total - nc
        denom_c = nc + alpha * v_r
        denom_rest = n_rest + alpha * v_r
        scored = []
        for f, n_c_f in by_candidate[c].items():
            n_rest_f = pooled_feature_total[f] - n_c_f
            score = math.log((n_c_f + alpha) / denom_c) - math.log((n_rest_f + alpha) / denom_rest)
            if score > 0:
                utility = score * math.log1p(n_c_f)
                scored.append((f, score, utility, n_c_f))
        scored.sort(key=lambda x: -x[2])
        if scored:
            prefix = [(f, score, w) for f, score, _, w in scored[:top_m_cap]]
            extras = (
                [(f, score) for f, score, _, w in scored[top_m_cap:]
                 if w >= floor and score >= floor_min_score]
                if floor > 0 else []
            )
            cand_features[c] = (prefix, extras)

    return cand_features, n_c


def build_master(w_paren: int, w_dict: int, min_anchor: int, alpha: float,
                 eval27_set: set[str], eval_floor: int,
                 banned_features: frozenset[str] = frozenset(),
                 colloc_by_reading: dict[str, dict[tuple[str, str], int]] = {},
                 w_colloc: int = 20):
    """One full streaming pass over the merged counts. Returns
    (master, n_c_all, dropped_single_candidate_readings) where master is
    reading -> hanja -> (prefix, extras): prefix = [(feature, score,
    weighted)] (<=TOP_M_BASE, desc by the selection utility, so any smaller
    M slice is a prefix), extras = eval-27 evidence-floor features beyond
    TOP_M_BASE (empty for non-eval readings). n_c_all is reading -> hanja ->
    N_c."""
    master: dict[str, dict[str, tuple[list[tuple[str, float, int]], list[tuple[str, float]]]]] = {}
    n_c_all: dict[str, dict[str, int]] = {}
    dropped: list[str] = []
    seen_readings: set[str] = set()
    for reading, rows in iter_by_reading(ANCHOR_TSV, PAREN_TSV, DICT_TSV):
        seen_readings.add(reading)
        floor = eval_floor if reading in eval27_set else 0
        result = process_reading(rows, w_paren, w_dict, min_anchor, alpha, TOP_M_BASE, floor,
                                 banned_features=banned_features,
                                 colloc=colloc_by_reading.get(reading, {}), w_colloc=w_colloc)
        if result is None:
            dropped.append(reading)
            continue
        cand_features, n_c = result
        master[reading] = cand_features
        n_c_all[reading] = n_c
    # readings whose ONLY signal is collocation rows (absent from all three
    # corpus/dict streams) still get processed
    for reading, colloc in colloc_by_reading.items():
        if reading in seen_readings:
            continue
        floor = eval_floor if reading in eval27_set else 0
        result = process_reading([], w_paren, w_dict, min_anchor, alpha, TOP_M_BASE, floor,
                                 banned_features=banned_features, colloc=colloc, w_colloc=w_colloc)
        if result is None:
            dropped.append(reading)
            continue
        cand_features, n_c = result
        master[reading] = cand_features
        n_c_all[reading] = n_c
    return master, n_c_all, dropped


def render(master, n_c_all, targets, eval27_set, m, min_total_weighted, freq_cutoff,
           eval_floor: int, eval_floor_min_score: float = EVAL_FLOOR_MIN_SCORE):
    """Assemble final (reading, hanja, feature, score) entries under the
    given cap-tightening params, quantize over the fresh global max, and
    return (lines, global_max, stats) or (None, None, stats) if empty.
    For eval-27 readings, features beyond the m-slice are still kept when
    their weighted count >= eval_floor AND score >= eval_floor_min_score
    (prefix carries weighted counts; the pre-computed extras beyond
    TOP_M_BASE, already floor-filtered, are always included)."""
    entries: list[tuple[str, str, str, float]] = []
    kept_readings: set[str] = set()
    kept_pairs: set[tuple[str, str]] = set()
    floor_added = 0
    for reading, cand_map in master.items():
        total_freq = targets[reading][0]
        is_eval = reading in eval27_set
        if not is_eval and total_freq < freq_cutoff:
            continue
        any_kept_for_reading = False
        for hanja, (prefix, extras) in cand_map.items():
            if n_c_all[reading][hanja] < min_total_weighted:
                continue
            kept: list[tuple[str, float]] = [(f, s) for f, s, _ in prefix[:m]]
            if is_eval and eval_floor > 0:
                floor_tail = [(f, s) for f, s, w in prefix[m:]
                              if w >= eval_floor and s >= eval_floor_min_score]
                kept.extend(floor_tail)
                kept.extend(extras)
                floor_added += len(floor_tail) + len(extras)
            if not kept:
                continue
            for feature, score in kept:
                entries.append((reading, hanja, feature, score))
            any_kept_for_reading = True
            kept_pairs.add((reading, hanja))
        if any_kept_for_reading:
            kept_readings.add(reading)

    if not entries:
        return None, None, {"readings": 0, "candidates": 0, "features": 0}

    global_max = max(e[3] for e in entries)
    lines_map: dict[tuple[str, str], list[tuple[str, int]]] = defaultdict(list)
    dropped_zero_quant = 0
    for reading, hanja, feature, score in entries:
        q = round(score / global_max * 255)
        if q <= 0:
            dropped_zero_quant += 1
            continue
        if q > 255:
            q = 255
        lines_map[(reading, hanja)].append((feature, q))

    lines = []
    n_features = 0
    for (reading, hanja), feats in sorted(lines_map.items()):
        feats_sorted = sorted(feats, key=lambda x: (-x[1], x[0]))
        n_features += len(feats_sorted)
        feat_str = ",".join(f"{escape_feature(f)}={w}" for f, w in feats_sorted)
        lines.append(f"{reading}:{hanja}:{feat_str}")

    stats = {
        "readings": len({k[0] for k in lines_map}),
        "candidates": len(lines_map),
        "features": n_features,
        "dropped_zero_quant": dropped_zero_quant,
        "eval_floor_added_features": floor_added,
    }
    return lines, global_max, stats


def build_header(params: dict, global_max: float, generated_at: str) -> list[str]:
    return [
        "# hanja-context.txt — step 5b association table (문맥 기반 한자 변환, "
        "docs/plans/context-aware-hanja-conversion.md §7 5b)",
        "# Corpus: kowiki pages-articles dump 2026-06-29 (https://dumps.wikimedia.org/kowiki/, "
        "CC BY-SA) via scripts/hanja-context/extract_and_filter.py + collector; "
        "NIKL 3사전 정의문 (사용자 승인, 재배포 없는 집계 통계만) via "
        "scripts/hanja-context/extract_nikl_defs.py; "
        f"4th signal (step 7b, 2026-07-10 사용자 승인): NIKL 파생어 연어 "
        f"(krdict RelatedForm 파생어 + stdict/opendict 용언 표제어, 플래그 읽기 한정, "
        f"w_colloc={params.get('w_colloc', 0)}, {params.get('colloc_tuples', 0)} tuples/"
        f"{params.get('colloc_readings', 0)} readings, ubiquity-ban EXEMPT — 사전 등재 근거) via "
        "scripts/hanja-context/build_collocation_counts.py.",
        "# Format: 읽기:한자:형태소=가중치,형태소=가중치,... (feature key = form/TAG; split "
        "Swift-side on the LAST '/' — TAG never contains '/'). One line per "
        "(reading, candidate) with >=1 surviving+scored feature. Sorted by reading then hanja.",
        "# Percent-escaping: feature text has '%' -> '%25', ':' -> '%3A', ',' -> '%2C', "
        "'=' -> '%3D' applied (in that single regex pass) before emission, since those "
        "three characters are this format's own delimiters. Decode with the reverse map "
        "in a single pass (order-independent — encoded tokens do not overlap).",
        f"# Signal combine: weighted(f,c) = anchor_count + W_paren*paren_count + "
        f"W_dict*dict_count, W_paren={params['w_paren']} W_dict={params['w_dict']}.",
        f"# Survival (per reading,candidate,feature triple): anchor_count >= {params['min_anchor']} "
        "OR paren_count >= 1 OR dict_count >= 1 (the raw-count floor applies to the anchor-only "
        "path; direct-label paren/dict signals are exempt by design so thin candidates survive).",
        f"# Score: smoothed within-reading log-odds contrast (alpha={params['alpha']}): "
        "score(f,c) = ln((n_c(f)+a)/(N_c+a*V_r)) - ln((n_r\\c(f)+a)/(N_r\\c+a*V_r)), "
        "n = weighted counts, r\\c = pooled OTHER candidates of the same reading, "
        "V_r = distinct surviving features of the reading. Only score>0 kept "
        "(prunes generic/non-discriminative features without a stoplist). Readings with "
        "<2 candidates carrying any surviving feature are dropped (contrast needs a contrast).",
        f"# Prune + quantize: top M={params['m']} features per candidate, SELECTED by "
        "utility(f,c) = score(f,c) * ln(1 + weighted_count) — evidence-mass-weighted "
        "selection so common-but-discriminative features (집, 물, 서울) are kept alongside "
        "rare-but-perfect ones; the EMITTED weight is still the pure contrast score. Linear "
        f"quantization of score to 1..255 over the GLOBAL max score in this table "
        f"(global_max={global_max:.6f} nats); quantized values of 0 are dropped (not clamped to 1).",
        f"# Eval-27 evidence floor: for the eval-set readings "
        f"(eval/hanja-context-eval-set.tsv), every surviving feature with weighted_count >= "
        f"{params['eval_floor']} AND score >= {params['eval_floor_min_score']:.6f} "
        "(= ln 2, at least 2x contrast odds) is kept in addition to the top M — common "
        "runtime words would otherwise fall below M for high-vocabulary candidates; the "
        "min-score guard keeps barely-positive generics (하/VV, 있/VV, 되/VV) out. "
        "Non-eval readings get the top M only.",
        f"# Cap-tightening applied (if any): min_total_weighted_count={params['min_total_weighted']}"
        f", non-eval27 total_freq cutoff={params['freq_cutoff']} (eval-27 readings from "
        "eval/hanja-context-eval-set.tsv are never dropped by the freq cutoff).",
        f"# Ubiquity (IDF-style) filter: VV/VA(-I)-tagged features with ABSOLUTE profile document "
        f"frequency >= {params['max_feature_df_count']} (out of {params['total_profiles']} "
        f"post-survival pre-prune candidate profiles) are banned globally before scoring "
        f"({params['banned_feature_count']} features banned) — catches cross-domain-biased bare "
        "generic verbs (하, 있, 되, 나, 오, 보, 들, ...) that pass the within-reading contrast "
        "only because the corpus happens to be domain-skewed per candidate. Scoped to VV/VA to "
        "avoid banning topical-noun probes that share similar raw DF (e.g. 나라/NNG, 정부/NNG). "
        "The cutoff is an absolute count (662 = the accepted 5b build's effective boundary, "
        "ceil(0.039 x 16,974)), NOT a fraction — a fractional cutoff loosens as the target pool "
        "grows, which re-admitted 나/VV into 수도:修道 during the 7b expansion (user-verified "
        "regression, fixed 2026-07-10).",
        f"# Generated: {generated_at} by scripts/hanja-context/build_association_table.py.",
        "#",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--paren-weight", type=int, default=20)
    parser.add_argument("--dict-weight", type=int, default=20)
    parser.add_argument("--min-anchor-survival", type=int, default=MIN_ANCHOR_SURVIVAL)
    parser.add_argument("--alpha", type=float, default=ALPHA)
    parser.add_argument("--top-m", type=int, default=TOP_M_BASE)
    parser.add_argument("--eval-floor-count", type=int, default=EVAL_FLOOR_COUNT,
                        help="eval-27 evidence floor: keep any surviving score>0 feature "
                             "with weighted_count >= this for eval-set readings (0 disables)")
    parser.add_argument("--max-feature-df-count", type=int, default=MAX_FEATURE_DF_COUNT,
                        help="ubiquity filter: drop VV/VA(-I)-tagged features whose ABSOLUTE "
                             "profile document frequency (number of post-survival, pre-prune "
                             "candidate profiles containing the feature) is >= this (0 disables). "
                             "Absolute, not a fraction — the cutoff must not loosen when the "
                             "target pool grows (see MAX_FEATURE_DF_COUNT comment). "
                             "NNG/NNP/MAG features are never affected regardless of DF.")
    parser.add_argument("--print-feature-df", type=int, default=0,
                        help="if >0, print the top-N features by profile DF (for threshold "
                             "tuning) to stderr and exit without writing any output")
    parser.add_argument("--size-cap-bytes", type=int, default=SIZE_CAP_BYTES)
    parser.add_argument("--output", type=Path, default=OUTPUT_TXT)
    parser.add_argument("--stats-output", type=Path, default=STATS_JSON)
    parser.add_argument("--colloc-counts", type=Path, default=COUNTS_DIR / "collocation-counts.tsv",
                        help="4th signal: NIKL derived-verb collocation counts "
                             "(build_collocation_counts.py output; flagged readings only; "
                             "ubiquity-ban exempt; absent file = 3-signal behavior)")
    parser.add_argument("--colloc-weight", type=int, default=20,
                        help="weight per collocation count (same scale as --dict-weight)")
    args = parser.parse_args()

    targets = load_targets()
    eval27 = set(load_eval_readings())
    print(f"targets={len(targets)} eval27={len(eval27)}", file=sys.stderr)

    print("computing profile document frequency (ubiquity filter pass, "
          "~8.49M rows)...", file=sys.stderr)
    df_counts, total_profiles = compute_profile_df(
        args.paren_weight, args.dict_weight, args.min_anchor_survival
    )
    print(f"total_profiles={total_profiles} distinct_features={len(df_counts)}", file=sys.stderr)

    if args.print_feature_df:
        for feat, cnt in sorted(df_counts.items(), key=lambda x: -x[1])[:args.print_feature_df]:
            print(f"{feat}\t{cnt}\t{cnt / total_profiles:.4%}", file=sys.stderr)
        return 0

    banned_features: frozenset[str] = frozenset()
    if args.max_feature_df_count > 0:
        banned_features = frozenset(
            f for f, cnt in df_counts.items()
            if UBIQUITY_SCOPED_TAG_RE.search(f) and cnt >= args.max_feature_df_count
        )
    print(
        f"ubiquity filter: {len(banned_features)} VV/VA(-I) features banned "
        f"(absolute profile DF >= {args.max_feature_df_count}; pool={total_profiles} profiles)",
        file=sys.stderr,
    )

    colloc_by_reading = load_collocation_counts(args.colloc_counts)
    colloc_tuples = sum(len(v) for v in colloc_by_reading.values())
    print(
        f"collocation signal: {colloc_tuples} tuples over {len(colloc_by_reading)} readings "
        f"from {args.colloc_counts}" if colloc_by_reading
        else f"collocation signal: none ({args.colloc_counts} absent/empty)",
        file=sys.stderr,
    )

    print("merging + scoring (single streaming pass over ~8.49M rows)...", file=sys.stderr)
    master, n_c_all, dropped_single_cand = build_master(
        args.paren_weight, args.dict_weight, args.min_anchor_survival, args.alpha,
        eval27, args.eval_floor_count, banned_features=banned_features,
        colloc_by_reading=colloc_by_reading, w_colloc=args.colloc_weight,
    )
    print(
        f"scored readings={len(master)} dropped(<2 candidates with surviving features)="
        f"{len(dropped_single_cand)}",
        file=sys.stderr,
    )

    # Cap-tightening ladder: M 300 -> 200 -> 100, then min-total-weighted-count,
    # then ascending total_freq cutoff among non-eval27 readings.
    tightening_log = []
    attempts = [
        {"m": args.top_m, "min_total_weighted": 0, "freq_cutoff": 0},
        {"m": 200, "min_total_weighted": 0, "freq_cutoff": 0},
        {"m": 100, "min_total_weighted": 0, "freq_cutoff": 0},
        {"m": 100, "min_total_weighted": 3, "freq_cutoff": 0},
    ]
    chosen = None
    lines = global_max = stats = None
    for params in attempts:
        lines, global_max, stats = render(
            master, n_c_all, targets, eval27, params["m"], params["min_total_weighted"],
            params["freq_cutoff"], args.eval_floor_count,
        )
        size = sum(len(line.encode("utf-8")) + 1 for line in lines) if lines else 0
        tightening_log.append({**params, "size_bytes": size})
        print(f"try M={params['m']} min_total_weighted={params['min_total_weighted']} "
              f"freq_cutoff={params['freq_cutoff']} -> size={size} bytes", file=sys.stderr)
        if size <= args.size_cap_bytes:
            chosen = params
            break

    if chosen is None:
        # Ascending total_freq cutoff among non-eval27 readings, binary search
        # over distinct total_freq thresholds until under cap.
        base_params = attempts[-1]
        non_eval_freqs = sorted(
            {targets[r][0] for r in master if r not in eval27}
        )
        lo, hi = 0, len(non_eval_freqs)
        best = None
        while lo < hi:
            mid = (lo + hi) // 2
            cutoff = non_eval_freqs[mid] + 1
            lines, global_max, stats = render(
                master, n_c_all, targets, eval27, base_params["m"],
                base_params["min_total_weighted"], cutoff, args.eval_floor_count,
            )
            size = sum(len(line.encode("utf-8")) + 1 for line in lines) if lines else 0
            if size <= args.size_cap_bytes:
                best = (cutoff, lines, global_max, stats, size)
                hi = mid
            else:
                lo = mid + 1
        if best is None:
            print("STOP: cap unreachable even after all tightening steps "
                  "(M->100, min_total_weighted>=3, dropping ALL non-eval27 readings).", file=sys.stderr)
            return 1
        cutoff, lines, global_max, stats, size = best
        chosen = {**base_params, "freq_cutoff": cutoff}
        tightening_log.append({**chosen, "size_bytes": size, "binary_search": True})

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = build_header(
        {**chosen, "w_paren": args.paren_weight, "w_dict": args.dict_weight,
         "min_anchor": args.min_anchor_survival, "alpha": args.alpha,
         "eval_floor": args.eval_floor_count,
         "eval_floor_min_score": EVAL_FLOOR_MIN_SCORE,
         "max_feature_df_count": args.max_feature_df_count, "total_profiles": total_profiles,
         "banned_feature_count": len(banned_features),
         "w_colloc": args.colloc_weight, "colloc_tuples": colloc_tuples,
         "colloc_readings": len(colloc_by_reading)},
        global_max, generated_at,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as f:
        for h in header:
            f.write(h + "\n")
        for line in lines:
            f.write(line + "\n")

    actual_size = args.output.stat().st_size
    print(f"wrote {args.output} size={actual_size} bytes params={chosen}", file=sys.stderr)

    stats_out = {
        "generated_at": generated_at,
        "params": {
            "w_paren": args.paren_weight,
            "w_dict": args.dict_weight,
            "min_anchor_survival": args.min_anchor_survival,
            "alpha": args.alpha,
            "eval_floor_count": args.eval_floor_count,
            "eval_floor_min_score": EVAL_FLOOR_MIN_SCORE,
            "selection_metric": "utility = score * ln(1 + weighted_count)",
            "max_feature_df_count": args.max_feature_df_count,
            "max_feature_df_count_rationale": "absolute cutoff fixed 2026-07-10 (= ceil(0.039 * 16974), the accepted 5b build's effective boundary); fractional cutoff loosened with pool growth and re-admitted 나/VV into 수도:修道",
            "ubiquity_scoped_tags": "VV, VA, VA-I, VV-I",
            "colloc_weight": args.colloc_weight,
            "colloc_counts_file": str(args.colloc_counts),
            "colloc_tuples": colloc_tuples,
            "colloc_readings": len(colloc_by_reading),
            "colloc_note": "NIKL 파생어 연어 (flagged readings only) — survival-granting, ubiquity-ban exempt per row; NOT in compute_profile_df (banned set independent)",
            **chosen,
        },
        "ubiquity_filter": {
            "total_profiles": total_profiles,
            "distinct_features": len(df_counts),
            "banned_feature_count": len(banned_features),
        },
        "size_bytes": actual_size,
        "size_cap_bytes": args.size_cap_bytes,
        "readings_kept": stats["readings"],
        "candidates_kept": stats["candidates"],
        "features_kept": stats["features"],
        "eval_floor_added_features": stats["eval_floor_added_features"],
        "dropped_zero_quant": stats["dropped_zero_quant"],
        "dropped_single_candidate_readings": len(dropped_single_cand),
        "tightening_log": tightening_log,
        "global_max_score_nats": global_max,
    }
    args.stats_output.write_text(json.dumps(stats_out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.stats_output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
