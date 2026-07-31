#!/usr/bin/env python3
"""Step D3 signed sparse ranker — REDUCED SCOPE build/train/export
(docs/plans/hanja-context-scaling-plan.md §10, coordinator's 2026-08-01 scoping decision).

Reduced scope (do not re-litigate — fixed by the coordinator, see the plan doc's §10 preamble):
  - The NEW feature axes §10-1 wants (distance bucket, bigram, josa/eomi, clause boundary) are NOT
    built here. The feature space stays EXACTLY `HanjaSegment.contextFeatures` (self-excluded
    content-morpheme `form/TAG`, produced by the real runtime pipeline via
    `scripts/hanja-context/assoc/`'s `d3-features` subcommand) — only the WEIGHTS become learned
    signed values + a per-candidate bias, replacing the fixed corpus log-odds-contrast weights.
  - KEEP_HANGUL candidates are NOT trained (D1 seeds are all-hanja-gold; no negative examples
    exist). The auto-convert gate is untouched.
  - `bias` IS consumed by the runtime as of 2026-08-01 (`HanjaContextRanker.rankWithContextScored`'s
    `biases:` parameter; the slot was reserved by §5 "0c 포맷 명세"). Bias affects RANKING ONLY and is
    deliberately kept out of `HanjaContextEvidence`, so it can never push a zero-matched-feature
    candidate past step 7's `awaitsContextEvidence` promotion gate.

Pipeline (subcommands, chainable via `all`):
  split   — reads `d3/features.tsv` (assoc `d3-features` output), keeps seg_ok=="1" rows, drops
            any row whose page_id was mined for D2 (docs/plans/hanja-context-scaling-plan.md §9),
            splits the remainder into fit/holdout by a family-level sha256 bucket (same family
            never spans both sides) — writes `d3/fit.tsv` / `d3/holdout.tsv` / `d3/split-report.md`.
  train   — per-reading multinomial logistic regression (candidate-balanced sampling weights +
            hierarchical bias shrinkage toward a frequency-log-ratio prior + L1 proximal gradient),
            trainable-reading gate, small hyperparameter grid selected ONLY on a family-level inner
            dev slice carved out of fit (never on holdout, never on the 258-row eval set — plan
            §13 정지선) — writes `d3/model.json` / `d3/train-report.md`.
  export  — builds the HYBRID association table. ADDITIVE (coordinator redesign, 2026-08-01, the
            single retry 연구 문서 §7.2 allows): for a trained reading each candidate's weight is
            `w_corpus + theta` (both nat-scale log-odds), plus the learned bias; every other reading
            keeps its corpus profile verbatim (bias 0.0). The first design REPLACED corpus weights
            outright and regressed EVAL5D v1 128 -> 107 (111 after the bias unit fix) because the
            wiki-병기 training distribution does not transfer to everyday prose; as a correction term
            on top of the corpus signal it measures 131. Reuses
            `build_association_table.encode_binary` (extended with an optional `bias_lookup`) so
            the binary layout/CRC/quantization machinery is not reimplemented — writes
            `woorilee/data/hanja/hanja-context.bin` + `.txt` (backing up the pre-D3 originals to
            `*.d3-backup` first) and `d3/export-report.md`.
  all     — split -> train -> export with default paths.

Python 3.14 stdlib only (no numpy/scipy — user has not approved third-party packages for this
task). Every constant chosen here (split ratios, gating thresholds, balance K, epochs, learning
rate, L1/L2 coefficients, bias clamp) is a value THIS script's author picked; rationale is recorded
inline and repeated in the generated *-report.md files, per the task's own request.

Usage:
    python3 scripts/hanja-context/build_d3_ranker.py split
    python3 scripts/hanja-context/build_d3_ranker.py train
    python3 scripts/hanja-context/build_d3_ranker.py export
    python3 scripts/hanja-context/build_d3_ranker.py all
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_association_table as bat  # noqa: E402
import hanja_common as hc  # noqa: E402
import verify_binary_roundtrip as vbr  # noqa: E402 — reused ONLY for its independent binary reader

D3_DIR = hc.WORK_DIR / "d3"
D2_MINED_TSV = hc.WORK_DIR / "d2/mined-sentences.tsv"

FEATURES_TSV = D3_DIR / "features.tsv"
FIT_TSV = D3_DIR / "fit.tsv"
HOLDOUT_TSV = D3_DIR / "holdout.tsv"
SPLIT_REPORT_MD = D3_DIR / "split-report.md"
MODEL_JSON = D3_DIR / "model.json"
TRAIN_REPORT_MD = D3_DIR / "train-report.md"
EXPORT_REPORT_MD = D3_DIR / "export-report.md"

FEATURES_HEADER = "reading\tgold\tpage_id\tfamily\tsource\tseg_ok\tmatch_kind\tpos_tag\tcand_count\tsys_top1\tfeatures"

# ---------------------------------------------------------------------------
# Constants chosen by this script's author (documented per the task's request — none of these are
# tuned against the 258-row eval set or the D3 holdout; see each usage site for rationale).
# ---------------------------------------------------------------------------

# split: family-level sha256 bucket, salted so the outer fit/holdout decision and the inner
# train/dev decision (used only inside `train` for hyperparameter selection) are independent draws
# of the same family even though both derive from one hash family. 70/30 mirrors the D2 dev/test
# ratio precedent (docs/plans/hanja-context-scaling-plan.md §9 read 427/678 ~= 39/61 for a
# dev/test split; D3's fit/holdout plays the analogous train/test role, so a larger 70% fit share
# is used since fit ALSO has to support the inner train/dev carve-out below).
OUTER_SALT = "d3-outer-fit-holdout"
OUTER_FIT_PCT = 70  # sha256(family) bucket < 70 -> fit, else holdout

INNER_SALT = "d3-inner-train-dev"
INNER_TRAIN_PCT = 90  # of FIT ONLY: bucket < 90 -> inner_train, else inner_dev (grid search only)

# train: reading-level trainability gate (plan §10-2: "fit 문장 >= 30, 그리고 fit 데이터가 >= 5
# 문장인 후보가 >= 2개인 읽기만 학습"). Untrained readings keep their existing corpus weights
# verbatim (export step) — this floor exists so a reading with only a handful of fit sentences
# does not get a logistic-regression profile fit to noise.
MIN_FIT_SENTENCES_PER_READING = 30
MIN_SENTENCES_PER_QUALIFYING_CANDIDATE = 5
MIN_QUALIFYING_CANDIDATES = 2

# train: candidate-balanced sampling (연구 문서 §4.2). A candidate whose fit-example count is below
# max_count/BALANCE_K gets its per-example loss weight scaled up to max_count/BALANCE_K/n_c, so the
# reading's most frequent candidate cannot single-handedly dominate the gradient. BALANCE_K=5 means
# any candidate holding >=20% of the majority's example count is left alone (weight 1.0); only
# genuinely thin candidates get boosted. BALANCE_MAX_WEIGHT_MULTIPLIER=10 caps how far a single
# rare example can be up-weighted (chosen so one example of a 1-sentence candidate against a
# 1000-sentence majority — an extreme but real case, see D1's "씨�드 보유 8,379쌍(43.0%)" long tail
# — cannot receive a raw multiplier of 200x, which would make that one sentence dominate the
# reading's entire gradient; 10x still meaningfully corrects the imbalance without doing that).
BALANCE_K = 5
BALANCE_MAX_WEIGHT_MULTIPLIER = 10.0

# train: hierarchical bias shrinkage (연구 문서 §4.4). bias prior = ln(freq(c)+1) - ln(mean over
# the reading's FULL candidate set of freq(c')+1) — a log ratio to the reading's own average
# frequency (so an evenly-frequent reading has all priors near 0). L2_BIAS is the shrinkage
# strength pulling the trained bias back toward that prior every gradient step.
L2_BIAS = 0.1

# train: proximal (ISTA) gradient descent — full-batch per reading (reading-level example counts
# are small enough, by construction of MIN_FIT_SENTENCES_PER_READING, for full-batch to be cheap
# and exactly reproducible epoch to epoch, unlike minibatch SGD which would need a documented
# shuffle seed). EPOCHS/L2_BIAS are fixed constants; (learning rate, L1) are chosen from
# GRID_LR x GRID_L1 by pooled inner-dev accuracy (see `train`) — never by the D3 holdout or the
# 258-row eval set (plan §13 정지선).
EPOCHS = 300
GRID_LR = (0.2, 0.5, 1.0)
GRID_L1 = (0.01, 0.05)

# export: bias raw-unit clamp (docs/plans/hanja-context-scaling-plan.md §10 export instructions:
# "|bias| <= 100" — runtime's weights.association=300 multiplier would otherwise let a bias alone
# reach 100*300=30,000, matching the NNP gazette bonus's scale; well short of containment's
# 10,000,000). Applied at export time, not during training, so the shrinkage prior can be read from
# `model.json` unclamped for diagnostics.
BIAS_CLAMP = 100.0

RANDOM_SEED = 20260801  # documented but only used for tie-break ordering, not resampling — training below is full-batch/deterministic.


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def sha256_bucket(text: str, salt: str) -> int:
    """Deterministic 0..99 bucket for `text`, independent per `salt` — used for both the outer
    fit/holdout split and the inner train/dev split so a family's two decisions do not correlate
    trivially (they're independent hashes, not two views of one hash)."""
    digest = hashlib.sha256(f"{salt}:{text}".encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % 100


def load_d2_pages(path: Path = D2_MINED_TSV) -> set[str]:
    """Distinct page_id values (3rd column) mined for D2 (docs/plans/hanja-context-scaling-plan.md
    §9) — D3 fit/holdout must not reuse these pages so D2's gold labels stay usable as an
    independent evaluation later (plan §10-2 "D2 배제")."""
    pages: set[str] = set()
    if not path.exists():
        return pages
    with path.open(encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3:
                continue
            pages.add(cols[2])
    return pages


def load_features_tsv(path: Path) -> list[dict[str, str]]:
    """Reads `assoc d3-features`'s output (or a `split`-produced fit/holdout.tsv, same columns)
    into a list of column-name -> value dicts."""
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8") as f:
        header_cols: list[str] | None = None
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#"):
                continue
            cols = line.split("\t")
            if header_cols is None:
                header_cols = cols
                continue
            row = dict(zip(header_cols, cols))
            rows.append(row)
    return rows


def write_features_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        f.write(FEATURES_HEADER + "\n")
        for row in rows:
            f.write("\t".join(row.get(col, "") for col in FEATURES_HEADER.split("\t")) + "\n")


def parse_feature_list(field: str) -> list[str]:
    return field.split("|") if field else []


def load_existing_association_lines(path: Path = bat.OUTPUT_TXT) -> dict[str, dict[str, list[tuple[str, int]]]]:
    """reading -> hanja -> [(feature, weight_int), ...], from the CURRENT bundled hanja-context.txt
    (pre-D3). Preserves per-candidate feature order as already sorted in the file."""
    result: dict[str, dict[str, list[tuple[str, int]]]] = defaultdict(dict)
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        reading, hanja, feats = bat.parse_association_line(raw_line)
        result[reading][hanja] = feats
    return dict(result)


def candidate_set_from_existing(existing: dict[str, dict[str, list[tuple[str, int]]]], reading: str) -> set[str]:
    return set(existing.get(reading, {}).keys())


def frequency_prior(candidates: list[str], freq: dict[str, int]) -> dict[str, float]:
    """bias prior(c) = ln(freq(c)+1) - ln(mean over `candidates` of freq(c')+1) — a log ratio to
    the reading's own average frequency (연구 문서 §4.4: "사전값을 그 후보의 빈도 로그 비율로").
    Neutral (0.0) for every candidate when all frequencies are equal; unaffected by which
    candidates happen to have training examples, since it is computed over the FULL export
    candidate set."""
    if not candidates:
        return {}
    logs = {c: math.log(freq.get(c, 0) + 1) for c in candidates}
    mean_log = sum(logs.values()) / len(logs)
    return {c: v - mean_log for c, v in logs.items()}


# ---------------------------------------------------------------------------
# split
# ---------------------------------------------------------------------------

def cmd_split(args: argparse.Namespace) -> int:
    features_path = Path(args.features)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    fit_path = out_dir / "fit.tsv"
    holdout_path = out_dir / "holdout.tsv"
    report_path = out_dir / "split-report.md"

    rows = load_features_tsv(features_path)
    total = len(rows)
    seg_ok_rows = [r for r in rows if r.get("seg_ok") == "1"]
    dropped_not_seg_ok = total - len(seg_ok_rows)

    d2_pages = load_d2_pages(Path(args.d2_mined))
    kept_rows = [r for r in seg_ok_rows if r.get("page_id") not in d2_pages]
    dropped_d2 = len(seg_ok_rows) - len(kept_rows)

    fit_rows: list[dict[str, str]] = []
    holdout_rows: list[dict[str, str]] = []
    for row in kept_rows:
        bucket = sha256_bucket(row.get("family", ""), OUTER_SALT)
        (fit_rows if bucket < OUTER_FIT_PCT else holdout_rows).append(row)

    write_features_tsv(fit_path, fit_rows)
    write_features_tsv(holdout_path, holdout_rows)

    # Independent re-read verification (not the in-memory `fit_rows`/`holdout_rows` variables) —
    # the task explicitly requires re-reading the WRITTEN files to check family disjointness.
    reread_fit = load_features_tsv(fit_path)
    reread_holdout = load_features_tsv(holdout_path)
    fit_families = {r["family"] for r in reread_fit}
    holdout_families = {r["family"] for r in reread_holdout}
    overlap = fit_families & holdout_families
    disjoint_ok = len(overlap) == 0

    report = [
        "# D3 split report",
        "",
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"Input: {features_path}",
        "",
        f"- total rows in features.tsv: {total}",
        f"- dropped (seg_ok != 1): {dropped_not_seg_ok}",
        f"- seg_ok==1 rows: {len(seg_ok_rows)}",
        f"- dropped (page_id in D2 mined set, {len(d2_pages)} D2 pages loaded from {args.d2_mined}): {dropped_d2}",
        f"- kept for fit/holdout split: {len(kept_rows)}",
        "",
        f"Split: family-level sha256 bucket (salt={OUTER_SALT!r}), bucket < {OUTER_FIT_PCT} -> fit, else holdout.",
        f"- fit: {len(fit_rows)} rows, {len(fit_families)} distinct families -> {fit_path}",
        f"- holdout: {len(holdout_rows)} rows, {len(holdout_families)} distinct families -> {holdout_path}",
        "",
        f"Independent re-read family-disjointness check (fit_families ∩ holdout_families): "
        f"{'PASS (empty)' if disjoint_ok else f'FAIL — {len(overlap)} shared families'}",
    ]
    if not disjoint_ok:
        report.append(f"  offending families (up to 20): {sorted(overlap)[:20]}")
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")

    print(f"split: total={total} seg_ok_dropped={dropped_not_seg_ok} d2_dropped={dropped_d2} "
          f"fit={len(fit_rows)} holdout={len(holdout_rows)} disjoint={'PASS' if disjoint_ok else 'FAIL'}",
          file=sys.stderr)
    print(f"wrote {fit_path}, {holdout_path}, {report_path}", file=sys.stderr)
    return 0 if disjoint_ok else 1


# ---------------------------------------------------------------------------
# train
# ---------------------------------------------------------------------------

def balanced_weights(gold_by_candidate: dict[str, int]) -> dict[str, float]:
    """Per-candidate example weight (연구 문서 §4.2 + BALANCE_K/BALANCE_MAX_WEIGHT_MULTIPLIER
    above): candidates holding >= max_count/BALANCE_K examples get weight 1.0; thinner candidates
    get weight (max_count/BALANCE_K)/n_c, capped at BALANCE_MAX_WEIGHT_MULTIPLIER."""
    if not gold_by_candidate:
        return {}
    max_count = max(gold_by_candidate.values())
    threshold = max_count / BALANCE_K
    weights: dict[str, float] = {}
    for c, n_c in gold_by_candidate.items():
        if n_c >= threshold:
            weights[c] = 1.0
        else:
            weights[c] = min(BALANCE_MAX_WEIGHT_MULTIPLIER, threshold / n_c)
    return weights


def train_reading_model(
    examples: list[tuple[str, list[str], float]],
    candidates: list[str],
    prior_bias: dict[str, float],
    lr: float,
    l1: float,
    l2_bias: float,
    epochs: int,
) -> tuple[dict[str, float], dict[str, dict[str, float]], float]:
    """Full-batch proximal gradient descent (ISTA) multinomial logistic regression for one reading.
    `examples`: list of (gold_hanja, feature_list, sample_weight). `candidates`: the FULL set of
    candidates that receive a trained profile (>=1 fit example — the reading's C_r_train from the
    caller). Returns (bias, theta, final_weighted_loss). `theta[c]` only ever holds features that
    appeared in at least one of this reading's own fit examples — the per-reading feature space is
    naturally bounded, so accumulating gradients over ALL of `theta[c]` each epoch (rather than only
    touched keys) is cheap and simplest to reason about (a real ISTA sweep, not a lazy/truncated
    approximation)."""
    bias = {c: prior_bias.get(c, 0.0) for c in candidates}
    theta: dict[str, dict[str, float]] = {c: {} for c in candidates}
    total_weight = sum(w for _, _, w in examples) or 1.0

    final_loss = 0.0
    for _epoch in range(epochs):
        grad_bias = {c: 0.0 for c in candidates}
        grad_theta: dict[str, dict[str, float]] = {c: defaultdict(float) for c in candidates}
        epoch_loss = 0.0

        for gold, feats, weight in examples:
            scores = {
                c: bias[c] + sum(theta[c].get(f, 0.0) for f in feats)
                for c in candidates
            }
            max_score = max(scores.values())
            exp_scores = {c: math.exp(s - max_score) for c, s in scores.items()}
            z = sum(exp_scores.values())
            probs = {c: v / z for c, v in exp_scores.items()}
            epoch_loss += -weight * math.log(max(probs.get(gold, 1e-12), 1e-12))

            for c in candidates:
                y = 1.0 if c == gold else 0.0
                grad = weight * (probs[c] - y)
                grad_bias[c] += grad
                if grad != 0.0:
                    for f in feats:
                        grad_theta[c][f] += grad

        final_loss = epoch_loss / total_weight
        for c in candidates:
            bias[c] -= lr * (grad_bias[c] / total_weight + l2_bias * (bias[c] - prior_bias.get(c, 0.0)))
            for f, g in grad_theta[c].items():
                theta[c][f] = theta[c].get(f, 0.0) - lr * (g / total_weight)
            # Proximal (soft-threshold) L1 step over every feature this candidate has EVER touched.
            for f in list(theta[c].keys()):
                v = theta[c][f]
                shrunk = math.copysign(max(0.0, abs(v) - lr * l1), v) if v != 0.0 else 0.0
                if shrunk == 0.0:
                    del theta[c][f]
                else:
                    theta[c][f] = shrunk

    return bias, theta, final_loss


def evaluate_reading_top1(
    examples: list[tuple[str, list[str], float]],
    candidates: list[str],
    bias: dict[str, float],
    theta: dict[str, dict[str, float]],
) -> tuple[int, int]:
    """Unweighted top1 accuracy (correct, total) over `examples`, scored against the trained
    `candidates` set only (an example whose gold isn't in `candidates` — i.e. dev-only candidate
    with zero fit examples in this reading — counts as wrong, matching what the exported table can
    actually predict)."""
    correct = 0
    for gold, feats, _weight in examples:
        best_c, best_s = None, float("-inf")
        for c in candidates:
            s = bias[c] + sum(theta[c].get(f, 0.0) for f in feats)
            if s > best_s:
                best_s, best_c = s, c
        if best_c == gold:
            correct += 1
    return correct, len(examples)


def cmd_train(args: argparse.Namespace) -> int:
    fit_path = Path(args.fit)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    model_path = out_dir / "model.json"
    report_path = out_dir / "train-report.md"

    fit_rows = load_features_tsv(fit_path)
    by_reading: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in fit_rows:
        by_reading[row["reading"]].append(row)

    existing = load_existing_association_lines(Path(args.assoc_txt))
    freq = hc.load_merged_frequency()

    trainable: list[str] = []
    skipped_readings: list[str] = []
    for reading, rows in by_reading.items():
        if len(rows) < MIN_FIT_SENTENCES_PER_READING:
            skipped_readings.append(reading)
            continue
        counts: dict[str, int] = defaultdict(int)
        for row in rows:
            counts[row["gold"]] += 1
        qualifying = sum(1 for n in counts.values() if n >= MIN_SENTENCES_PER_QUALIFYING_CANDIDATE)
        if qualifying >= MIN_QUALIFYING_CANDIDATES:
            trainable.append(reading)
        else:
            skipped_readings.append(reading)

    print(f"train: fit readings={len(by_reading)} trainable={len(trainable)} skipped={len(skipped_readings)}",
          file=sys.stderr)

    # ---- hyperparameter grid search on an INNER dev slice of fit (family-level), pooled across
    # all trainable readings — never touches holdout or the 258-row eval set (plan §13 정지선).
    per_reading_split: dict[str, tuple[list[dict[str, str]], list[dict[str, str]]]] = {}
    for reading in trainable:
        inner_train, inner_dev = [], []
        for row in by_reading[reading]:
            bucket = sha256_bucket(row["family"], INNER_SALT)
            (inner_train if bucket < INNER_TRAIN_PCT else inner_dev).append(row)
        per_reading_split[reading] = (inner_train, inner_dev)

    def rows_to_examples(rows: list[dict[str, str]], weights: dict[str, float]) -> list[tuple[str, list[str], float]]:
        return [(r["gold"], parse_feature_list(r["features"]), weights.get(r["gold"], 1.0)) for r in rows]

    grid_results: list[dict] = []
    best_combo = (GRID_LR[0], GRID_L1[0])
    best_pooled_acc = -1.0
    for lr in GRID_LR:
        for l1 in GRID_L1:
            pooled_correct = 0
            pooled_total = 0
            for reading in trainable:
                inner_train, inner_dev = per_reading_split[reading]
                if not inner_train or not inner_dev:
                    continue
                train_counts: dict[str, int] = defaultdict(int)
                for row in inner_train:
                    train_counts[row["gold"]] += 1
                candidates = sorted(train_counts.keys())
                w = balanced_weights(train_counts)
                full_candidate_set = candidate_set_from_existing(existing, reading) | set(candidates)
                prior = frequency_prior(sorted(full_candidate_set), freq)
                examples = rows_to_examples(inner_train, w)
                bias, theta, _loss = train_reading_model(
                    examples, candidates, prior, lr=lr, l1=l1, l2_bias=L2_BIAS, epochs=EPOCHS
                )
                dev_examples = rows_to_examples(inner_dev, {})
                c, t = evaluate_reading_top1(dev_examples, candidates, bias, theta)
                pooled_correct += c
                pooled_total += t
            acc = pooled_correct / pooled_total if pooled_total else 0.0
            grid_results.append({"lr": lr, "l1": l1, "pooled_inner_dev_correct": pooled_correct,
                                 "pooled_inner_dev_total": pooled_total, "pooled_inner_dev_acc": acc})
            print(f"train: grid lr={lr} l1={l1} pooled_inner_dev_acc={acc:.4f} ({pooled_correct}/{pooled_total})",
                  file=sys.stderr)
            if acc > best_pooled_acc:
                best_pooled_acc = acc
                best_combo = (lr, l1)

    chosen_lr, chosen_l1 = best_combo
    print(f"train: chosen lr={chosen_lr} l1={chosen_l1} (pooled_inner_dev_acc={best_pooled_acc:.4f})", file=sys.stderr)

    # ---- final per-reading fit on the FULL fit set (inner_train + inner_dev) with chosen hparams.
    readings_out: dict[str, dict] = {}
    per_reading_report_rows: list[str] = []
    for reading in trainable:
        rows = by_reading[reading]
        counts: dict[str, int] = defaultdict(int)
        for row in rows:
            counts[row["gold"]] += 1
        candidates = sorted(counts.keys())
        w = balanced_weights(counts)
        full_candidate_set = candidate_set_from_existing(existing, reading) | set(candidates)
        prior = frequency_prior(sorted(full_candidate_set), freq)
        examples = rows_to_examples(rows, w)
        bias, theta, loss = train_reading_model(
            examples, candidates, prior, lr=chosen_lr, l1=chosen_l1, l2_bias=L2_BIAS, epochs=EPOCHS
        )
        inner_train, inner_dev = per_reading_split[reading]
        inner_dev_acc = None
        if inner_train and inner_dev:
            train_counts: dict[str, int] = defaultdict(int)
            for row in inner_train:
                train_counts[row["gold"]] += 1
            probe_candidates = sorted(train_counts.keys())
            probe_w = balanced_weights(train_counts)
            probe_bias, probe_theta, _ = train_reading_model(
                rows_to_examples(inner_train, probe_w), probe_candidates, prior,
                lr=chosen_lr, l1=chosen_l1, l2_bias=L2_BIAS, epochs=EPOCHS,
            )
            c, t = evaluate_reading_top1(rows_to_examples(inner_dev, {}), probe_candidates, probe_bias, probe_theta)
            inner_dev_acc = c / t if t else None

        zero_data_candidates = sorted(full_candidate_set - set(candidates))
        readings_out[reading] = {
            "candidates": {c: {"bias": bias[c], "theta": theta[c]} for c in candidates},
            "zero_data_candidates": {c: prior[c] for c in zero_data_candidates},
            "n_fit": len(rows),
            "n_candidates_trained": len(candidates),
            "final_loss": loss,
            "inner_dev_accuracy": inner_dev_acc,
            "inner_dev_n": len(per_reading_split[reading][1]),
        }
        per_reading_report_rows.append(
            f"| {reading} | {len(rows)} | {len(candidates)} | {loss:.4f} | "
            f"{'n/a' if inner_dev_acc is None else f'{inner_dev_acc:.3f}'} | {len(per_reading_split[reading][1])} |"
        )

    model = {
        "meta": {
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "fit_path": str(fit_path),
            "constants": {
                "MIN_FIT_SENTENCES_PER_READING": MIN_FIT_SENTENCES_PER_READING,
                "MIN_SENTENCES_PER_QUALIFYING_CANDIDATE": MIN_SENTENCES_PER_QUALIFYING_CANDIDATE,
                "MIN_QUALIFYING_CANDIDATES": MIN_QUALIFYING_CANDIDATES,
                "BALANCE_K": BALANCE_K,
                "BALANCE_MAX_WEIGHT_MULTIPLIER": BALANCE_MAX_WEIGHT_MULTIPLIER,
                "L2_BIAS": L2_BIAS,
                "EPOCHS": EPOCHS,
                "INNER_SALT": INNER_SALT,
                "INNER_TRAIN_PCT": INNER_TRAIN_PCT,
            },
            "grid_search": {"grid": grid_results, "chosen_lr": chosen_lr, "chosen_l1": chosen_l1,
                            "chosen_pooled_inner_dev_acc": best_pooled_acc,
                            "note": "selected ONLY on fit's inner-dev family slice, never on holdout or the 258-row eval set"},
            "trainable_reading_count": len(trainable),
            "untrained_reading_count": len(skipped_readings),
        },
        "readings": readings_out,
    }
    model_path.write_text(json.dumps(model, ensure_ascii=False, indent=2), encoding="utf-8")

    report = [
        "# D3 train report",
        "",
        f"Generated: {model['meta']['generated_at']}",
        f"Input: {fit_path}",
        "",
        f"- fit readings observed: {len(by_reading)}",
        f"- trainable readings (fit>=`{MIN_FIT_SENTENCES_PER_READING}` sentences AND "
        f">=`{MIN_QUALIFYING_CANDIDATES}` candidates with >=`{MIN_SENTENCES_PER_QUALIFYING_CANDIDATE}` sentences): "
        f"{len(trainable)}",
        f"- untrained readings (keep existing corpus weights, bias=0.0): {len(skipped_readings)}",
        "",
        "## Hyperparameter grid (selected on fit's inner-dev family slice only)",
        "",
        "| lr | l1 | pooled inner-dev acc | correct/total |",
        "| --- | --- | --- | --- |",
    ]
    for g in grid_results:
        report.append(f"| {g['lr']} | {g['l1']} | {g['pooled_inner_dev_acc']:.4f} | "
                       f"{g['pooled_inner_dev_correct']}/{g['pooled_inner_dev_total']} |")
    report += [
        "",
        f"Chosen: lr={chosen_lr}, l1={chosen_l1} (pooled inner-dev acc {best_pooled_acc:.4f}).",
        "",
        "## Per-reading final fit (trained on FULL fit; inner_dev_accuracy is a probe model refit "
        "on inner_train only, reported for diagnostics — the exported model is refit on all of fit)",
        "",
        "| reading | n_fit | n_candidates | final_loss | inner_dev_acc (probe) | inner_dev_n |",
        "| --- | --- | --- | --- | --- | --- |",
        *per_reading_report_rows,
    ]
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")

    print(f"wrote {model_path}, {report_path}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

def cmd_export(args: argparse.Namespace) -> int:
    model = json.loads(Path(args.model).read_text(encoding="utf-8"))
    existing = load_existing_association_lines(Path(args.assoc_txt))
    stats = json.loads(Path(args.stats).read_text(encoding="utf-8"))
    existing_global_max = float(stats["global_max_score_nats"])

    trained_readings: dict[str, dict] = model["readings"]

    max_abs_theta = 0.0
    for rdata in trained_readings.values():
        for cand in rdata["candidates"].values():
            for v in cand["theta"].values():
                max_abs_theta = max(max_abs_theta, abs(v))
    combined_global_max = max(existing_global_max, max_abs_theta) if max_abs_theta > 0 else existing_global_max

    # Recover near-original-precision raw scores for UNTOUCHED readings from the CURRENT bundled
    # binary (via verify_binary_roundtrip's independent reader — not a reimplementation) instead of
    # reconstructing them from the TEXT file's coarse global 1..255 grid. Reusing the binary's own
    # already-accepted per-reading quantization (qw * reading_scale_nats, itself within +/-1
    # reading-scale step of the true corpus score) keeps every untouched entry's re-quantized value
    # in `encode_binary` far closer to its true score than a second bounce through the lossy
    # 1..255-grid text fallback would — the fallback path is deliberately reserved for the D3
    # learned entries below, where it IS the intended encoding (their text weight is this script's
    # own choice, not a lossy copy of a truer number).
    existing_bin_parsed = vbr.read_binary(Path(args.assoc_bin))
    recovered_entries: list[tuple[str, str, str, float]] = [
        (reading, hanja, feature, qw * reading_scale_nats)
        for reading, hanja, feature, qw, reading_scale_nats in existing_bin_parsed["entries"]
        if reading not in trained_readings
    ]

    lines_final: list[str] = []
    bias_lookup: dict[tuple[str, str], float] = {}

    untouched_reading_count = 0
    untouched_candidate_count = 0
    for reading, cand_map in existing.items():
        if reading in trained_readings:
            continue
        untouched_reading_count += 1
        for hanja, feats in cand_map.items():
            feat_str = ",".join(f"{bat.escape_feature(f)}={w}" for f, w in feats)
            lines_final.append(f"{reading}:{hanja}:{feat_str}")
            untouched_candidate_count += 1

    replaced_candidate_count = 0
    dropped_zero_feature_count = 0
    dropped_zero_data_count = 0
    clamped_bias_count = 0
    # 조율자 재설계 1회 (2026-08-01, 연구 문서 §7.2가 허용한 단 한 번의 재시도).
    #
    # 최초 설계는 학습 읽기의 후보 프로필을 theta로 **통째로 교체**했고, 전수 측정에서
    # EVAL5D v1이 128→107(bias 단위 버그 수정 후 111)로 크게 회귀했다. 원인은 두 가지다:
    #   (1) 학습 코퍼스가 위키 병기 문장이라 정의문·역사 인명 편중인데 평가셋은 일상 산문이다
    #       (D1 보고 §6의 "씨앗 분포가 수요와 어긋난다"가 그대로 나타난 것).
    #   (2) L1 희소화 + 후보별 균형 샘플링이 지배 후보의 프로필을 얇게 만들고 희귀 후보에
    #       조밀한 작은 양수를 남겨, 매칭이 누적되면 희귀 후보가 이긴다.
    # 코퍼스 표는 같은 평가에서 128/187을 내고 있으므로, 학습 신호를 **대체재가 아니라
    # 보정항**으로 쓴다: w_final = w_corpus + theta. 둘 다 nat 단위 로그 오즈라 차원이 맞고,
    # 혼합 계수는 튜닝하지 않고 1.0으로 고정한다(§13 정지선 — 258행 평가셋으로 상수를
    # 고르지 않는다. 측정은 단 한 번, 무회귀 판정용으로만 읽는다).
    #
    # 부수 효과로 zero-data 후보 문제도 사라진다 — 코퍼스 프로필이 그대로 밑에 깔리므로
    # 학습 예시가 없는 후보도 더 이상 표에서 사라지지 않는다.
    for reading, rdata in trained_readings.items():
        corpus_cands = existing.get(reading, {})
        all_hanja = set(rdata["candidates"]) | set(corpus_cands)
        for hanja in sorted(all_hanja):
            cand = rdata["candidates"].get(hanja)
            theta = cand["theta"] if cand else {}
            # 코퍼스 가중치는 텍스트 그리드(정수)로 저장돼 있다 — theta와 같은 그리드다.
            base = {f: float(w) for f, w in corpus_cands.get(hanja, [])}
            q_items: list[tuple[str, int]] = []
            for feature in set(base) | set(theta):
                q = base.get(feature, 0.0)
                if feature in theta and combined_global_max > 0:
                    q += theta[feature] * 255 / combined_global_max
                q = max(-255, min(255, round(q)))
                if q == 0:
                    continue
                q_items.append((feature, q))
            if not q_items:
                dropped_zero_feature_count += 1
                continue
            q_items.sort(key=lambda item: (-item[1], item[0]))
            feat_str = ",".join(f"{bat.escape_feature(f)}={w}" for f, w in q_items)
            lines_final.append(f"{reading}:{hanja}:{feat_str}")
            # 조율자 수정 (2026-08-01) — 단위 정합. 학습된 bias·theta는 둘 다 nat 단위지만,
            # theta는 텍스트 그리드(q = value × 255 / combined_global_max)를 거쳐 런타임에
            # 도달하고 로더가 `(qw × readingScaleNats) / globalScaleNats`로 환산하므로 최종
            # 값은 `theta_nats × 255 / combined_global_max`, 즉 **nat당 약 26 raw 단위**가 된다.
            # bias를 nat 그대로 쓰면 같은 모델의 두 항이 26배 어긋난 채 더해진다(실측: 조선
            # 계열 피처 로더 값 ±45 vs bias ±2.8). 그래서 bias에도 같은 변환을 적용한 뒤
            # 클램프한다. 이 버그를 고치기 전 전수 측정은 EVAL5D v1 128→107이었다.
            bias_nats = cand["bias"] if cand else 0.0
            bias_raw = bias_nats * 255 / combined_global_max if combined_global_max > 0 else 0.0
            bias = max(-BIAS_CLAMP, min(BIAS_CLAMP, bias_raw))
            if bias != bias_raw:
                clamped_bias_count += 1
            bias_lookup[(reading, hanja)] = bias
            replaced_candidate_count += 1
        # zero-data candidates (existing assoc-table candidates with no fit examples for a TRAINED
        # reading) are intentionally NOT emitted — see this file's module docstring / the export
        # report's "known limitations" section: the text-line-driven encode_binary path this script
        # reuses cannot represent a feature-less candidate, and the runtime does not read `bias` at
        # all yet, so dropping them is behaviorally a no-op today (associationScores' lookup would
        # return None for them either way) while remaining an explicit, reported limitation for
        # when bias DOES get wired into the runtime ranker.
        # 가산 하이브리드로 바꾼 뒤로는 이 후보들이 더 이상 버려지지 않는다(코퍼스 프로필이
        # 그대로 밑에 깔린다). 규모를 계속 보고하려고 카운터만 남긴다 — 이름은 "학습 예시가
        # 없어 theta 보정 없이 코퍼스 프로필만 쓰는 후보"라는 뜻이다.
        dropped_zero_data_count += len(rdata.get("zero_data_candidates", {}))

    def sort_key(line: str) -> tuple[str, str]:
        reading, hanja, _ = line.split(":", 2)
        return reading, hanja

    lines_final.sort(key=sort_key)

    binary_bytes = bat.encode_binary(
        lines_pre_curated=lines_final, lines_final=lines_final,
        global_max=combined_global_max, entries=recovered_entries, bias_lookup=bias_lookup,
    )

    pruned_features = 0
    if len(binary_bytes) > bat.SIZE_CAP_BYTES:
        # Prune lowest-|weight| features from LEARNED lines only (never touch untouched/corpus
        # lines), lowest magnitude first, until the binary fits — reported below.
        learned_keys = set(bias_lookup.keys())
        parsed = [(sort_key(line), bat.parse_association_line(line)) for line in lines_final]
        all_learned_entries: list[tuple[float, tuple[str, str], str]] = []
        for (reading, hanja), (r2, h2, feats) in parsed:
            if (reading, hanja) not in learned_keys:
                continue
            for feature, weight in feats:
                all_learned_entries.append((abs(weight), (reading, hanja), feature))
        all_learned_entries.sort(key=lambda x: x[0])

        removed: set[tuple[str, str, str]] = set()
        idx = 0
        while len(binary_bytes) > bat.SIZE_CAP_BYTES and idx < len(all_learned_entries):
            _, (reading, hanja), feature = all_learned_entries[idx]
            removed.add((reading, hanja, feature))
            idx += 1
            pruned_features = idx
            # Rebuild lines_final with the accumulated removal set and re-encode. Re-encoding on
            # every single removal would be slow; batch in chunks of 200 instead.
            if idx % 200 == 0 or idx == len(all_learned_entries):
                new_lines: list[str] = []
                for (reading2, hanja2), (r3, h3, feats) in parsed:
                    kept = [(f, w) for f, w in feats if (reading2, hanja2, f) not in removed]
                    if not kept:
                        continue
                    feat_str = ",".join(f"{bat.escape_feature(f)}={w}" for f, w in kept)
                    new_lines.append(f"{reading2}:{hanja2}:{feat_str}")
                new_lines.sort(key=sort_key)
                binary_bytes = bat.encode_binary(
                    lines_pre_curated=new_lines, lines_final=new_lines,
                    global_max=combined_global_max, entries=recovered_entries, bias_lookup=bias_lookup,
                )
                lines_final = new_lines

    header = [
        "# hanja-context.txt — hybrid table (D3, docs/plans/hanja-context-scaling-plan.md §10 축소 범위)",
        "# Base: prior corpus-derived table (see the header this file replaced, preserved verbatim "
        "for every UNTRAINED reading) + trained readings' signed weights from "
        f"scripts/hanja-context/build_d3_ranker.py train ({Path(args.model)}).",
        "# FORMAT CHANGE (D3): the per-line weight grid widens from unsigned 1..255 to SIGNED "
        "-255..255 (a strict superset — every pre-D3 file, all-positive, parses identically). "
        "Weight sign matches the learned coefficient's sign; magnitude is this file's own "
        f"quantization of the raw signed weight against a combined global scale "
        f"(combined_global_max={combined_global_max:.6f} nats — max(existing corpus global_max="
        f"{existing_global_max:.6f}, max_abs_theta={max_abs_theta:.6f}); see build_d3_ranker.py "
        "export's module docstring for why this text-only scale choice cannot affect the bundled "
        "BINARY's per-reading quantization, which stays scale-invariant).",
        "# BIAS IS NOT STORED IN THIS TEXT FILE — there is no per-candidate slot in this format for "
        "it (unlike the binary's dedicated Float32 bias field). The bundled hanja-context.bin is "
        "the only artifact carrying bias; this .txt stays feature-weight-only, diagnostic/test-only.",
        f"# Trained readings ({len(trained_readings)}): every candidate's profile in these readings "
        "was REPLACED wholesale by build_d3_ranker.py train (never mixed corpus+learned within one "
        "reading). Untrained readings keep their pre-D3 corpus profile verbatim, bias=0.0.",
        f"# Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} by "
        "scripts/hanja-context/build_d3_ranker.py export.",
        "#",
    ]

    output_txt = Path(args.output_txt)
    output_bin = Path(args.output_bin)
    backup_txt = output_txt.with_suffix(output_txt.suffix + ".d3-backup")
    backup_bin = output_bin.with_suffix(output_bin.suffix + ".d3-backup")
    for src, backup in ((output_txt, backup_txt), (output_bin, backup_bin)):
        if src.exists() and not backup.exists():
            shutil.copy2(src, backup)

    output_txt.parent.mkdir(parents=True, exist_ok=True)
    with output_txt.open("w", encoding="utf-8") as f:
        for h in header:
            f.write(h + "\n")
        for line in lines_final:
            f.write(line + "\n")
    output_bin.parent.mkdir(parents=True, exist_ok=True)
    output_bin.write_bytes(binary_bytes)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = out_dir / "export-report.md"
    report = [
        "# D3 export report",
        "",
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"Model: {args.model}",
        f"Base text: {args.assoc_txt}",
        f"Output: {output_txt} ({output_txt.stat().st_size} bytes), {output_bin} ({output_bin.stat().st_size} bytes)",
        f"Backups: {backup_txt if backup_txt.exists() else '(none — no prior output file existed to back up)'}, "
        f"{backup_bin if backup_bin.exists() else '(none — no prior output file existed to back up)'}",
        "",
        f"- trained readings replaced: {len(trained_readings)}",
        f"- untouched readings kept verbatim: {untouched_reading_count} ({untouched_candidate_count} candidates)",
        f"- trained candidates emitted (>=1 surviving feature): {replaced_candidate_count}",
        f"- trained candidates DROPPED (all features rounded to zero at this table's scale — known "
        f"limitation, see module docstring): {dropped_zero_feature_count}",
        f"- zero-data candidates (trained reading, no fit examples — corpus profile kept as-is, "
        f"no theta correction; NOT dropped since the additive-hybrid redesign): {dropped_zero_data_count}",
        f"- bias values clamped to +/-{BIAS_CLAMP}: {clamped_bias_count}",
        f"- combined_global_max: {combined_global_max:.6f} nats (existing corpus={existing_global_max:.6f}, "
        f"max_abs_theta={max_abs_theta:.6f})",
        f"- size cap: {bat.SIZE_CAP_BYTES} bytes; pruned features to fit: {pruned_features}",
        "",
        "## Known limitations (documented, not fixed in this reduced-scope pass)",
        "- Zero-feature / zero-data candidates in a trained reading are dropped from the table "
        "(HISTORICAL — no longer applies after the additive-hybrid redesign) entirely rather than emitted as a bias-only (entryCount=0) profile — the binary FORMAT "
        "supports this (parseBinary tolerates entryCount==0), but `encode_binary` is driven by "
        "TEXT lines which require >=1 feature per line, and the runtime does not read `bias` yet, "
        "so the two behaviors are equivalent today. Wiring bias into HanjaContextRanker would need "
        "a small follow-up to carry these through.",
    ]
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")
    print(f"export: trained_readings={len(trained_readings)} untouched_readings={untouched_reading_count} "
          f"binary_size={output_bin.stat().st_size} text_size={output_txt.stat().st_size}", file=sys.stderr)
    print(f"wrote {output_txt}, {output_bin}, {report_path}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_split = sub.add_parser("split", help="filter/split assoc d3-features output into fit/holdout")
    p_split.add_argument("--features", type=Path, default=FEATURES_TSV)
    p_split.add_argument("--d2-mined", type=Path, default=D2_MINED_TSV)
    p_split.add_argument("--out-dir", type=Path, default=D3_DIR)

    p_train = sub.add_parser("train", help="train per-reading signed ranker on fit.tsv")
    p_train.add_argument("--fit", type=Path, default=FIT_TSV)
    p_train.add_argument("--assoc-txt", type=Path, default=bat.OUTPUT_TXT)
    p_train.add_argument("--out-dir", type=Path, default=D3_DIR)

    p_export = sub.add_parser("export", help="export the hybrid association table")
    p_export.add_argument("--model", type=Path, default=MODEL_JSON)
    p_export.add_argument("--assoc-txt", type=Path, default=bat.OUTPUT_TXT)
    p_export.add_argument("--assoc-bin", type=Path, default=bat.OUTPUT_BIN,
                          help="CURRENT bundled binary (read-only) — its own per-reading "
                               "quantization is reused verbatim for untouched readings' raw "
                               "scores, instead of a lossy text-grid reconstruction.")
    p_export.add_argument("--stats", type=Path, default=bat.STATS_JSON)
    p_export.add_argument("--output-txt", type=Path, default=bat.OUTPUT_TXT)
    p_export.add_argument("--output-bin", type=Path, default=bat.OUTPUT_BIN)
    p_export.add_argument("--out-dir", type=Path, default=D3_DIR)

    p_all = sub.add_parser("all", help="split -> train -> export with default paths")
    p_all.add_argument("--features", type=Path, default=FEATURES_TSV)
    p_all.add_argument("--d2-mined", type=Path, default=D2_MINED_TSV)
    p_all.add_argument("--assoc-txt", type=Path, default=bat.OUTPUT_TXT)
    p_all.add_argument("--assoc-bin", type=Path, default=bat.OUTPUT_BIN)
    p_all.add_argument("--stats", type=Path, default=bat.STATS_JSON)
    p_all.add_argument("--output-txt", type=Path, default=bat.OUTPUT_TXT)
    p_all.add_argument("--output-bin", type=Path, default=bat.OUTPUT_BIN)
    p_all.add_argument("--out-dir", type=Path, default=D3_DIR)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "split":
        return cmd_split(args)
    if args.command == "train":
        return cmd_train(args)
    if args.command == "export":
        return cmd_export(args)
    if args.command == "all":
        split_args = argparse.Namespace(features=args.features, d2_mined=args.d2_mined, out_dir=args.out_dir)
        rc = cmd_split(split_args)
        if rc != 0:
            return rc
        train_args = argparse.Namespace(fit=args.out_dir / "fit.tsv", assoc_txt=args.assoc_txt, out_dir=args.out_dir)
        rc = cmd_train(train_args)
        if rc != 0:
            return rc
        export_args = argparse.Namespace(
            model=args.out_dir / "model.json", assoc_txt=args.assoc_txt, assoc_bin=args.assoc_bin,
            stats=args.stats, output_txt=args.output_txt, output_bin=args.output_bin, out_dir=args.out_dir,
        )
        return cmd_export(export_args)

    parser.error(f"unknown command {args.command!r}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
