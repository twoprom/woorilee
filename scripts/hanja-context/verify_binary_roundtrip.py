#!/usr/bin/env python3
"""Step 0c binary roundtrip verifier (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세"
— "왕복 검증"), extended for D3's hybrid (corpus + trained) table (§10 축소 범위). Four checks,
stdlib only:

  1. Entry-set equality: every (reading, hanja, feature) triple recovered from
     `hanja-context.bin` matches EXACTLY the set recovered from `hanja-context.txt` — the same
     build's text output (encode_binary is constructed from the text's own merged lines, so this
     also transitively checks the writer never dropped/added an entry). Weight VALUES are
     deliberately excluded from this comparison (always were — see `read_text_entries`), and so is
     `bias` (D3 slot — no such field exists in the text format at all; check 4 below verifies bias
     on its own terms against `--model`, not against the text file).
  2. Per-entry quantization error: |qw * readingScaleNats - raw_score| <= readingScaleNats
     (±1 reading-scale step). `qw` is SIGNED (Int8, `struct` format `<b` — already sign-aware; no
     bug there) since D3 introduces genuinely negative learned weights, and the tolerance check
     below is generic over sign already (`abs(reconstructed - raw_score)`). What DOES change with
     `--model`: for a reading D3 trained (replaced wholesale, corpus+learned units never mixed —
     plan §10), `raw_score` ground truth cannot come from re-running the corpus scoring pipeline
     (that pipeline never produced these features) — it is instead reconstructed from the TEXT
     file's own signed weight for that entry times this build's `globalScaleNats` header field,
     i.e. exactly the same fallback `encode_binary` itself used when it built this table's D3
     portion (see build_d3_ranker.py's `cmd_export`). Every OTHER (untrained) reading keeps the
     original ground truth: re-running the scoring pipeline (build_association_table's
     load_targets/compute_profile_df/build_master/render) with the exact params recorded in
     counts/association-stats.json for this build. Either way, the reconstruction side
     (qw * readingScaleNats) comes from an INDEPENDENTLY re-implemented binary reader below (not by
     calling encode_binary), so a bug in either the writer's rounding/clamping or its header/layout
     math would show up here.
  3. Header/CRC self-consistency: magic/version accepted, the payload CRC32 is independently
     recomputed (zlib.crc32 over bytes[32:]) and compared to the stored header value, and the
     four header counts (featureStringCount/readingCount/candidateProfileCount/
     featureEntryCount) match what was actually parsed out of the payload.
  4. Bias (D3, new): every candidate profile's Float32 `bias` field, read from the binary, must —
     when `--model` (build_d3_ranker.py train's `model.json`) is given — match that reading's
     trained+clamped bias for TRAINED readings (within Float32 rounding of the same value) and be
     EXACTLY 0.0 for every other (untrained) reading; with no `--model` given, every candidate's
     bias must be exactly 0.0 (the pre-D3 invariant — every caller of this script before D3 gets
     byte-identical behavior, since the binary it points at also predates D3).

Exits nonzero and prints a summary (to stderr) on ANY mismatch.

Usage:
    python3 scripts/hanja-context/verify_binary_roundtrip.py
    python3 scripts/hanja-context/verify_binary_roundtrip.py \\
        --text /path/to/hanja-context.txt --binary /path/to/hanja-context.bin \\
        --stats /path/to/association-stats.json
    python3 scripts/hanja-context/verify_binary_roundtrip.py \\
        --text /path/to/hybrid.txt --binary /path/to/hybrid.bin \\
        --stats /path/to/association-stats.json --model /path/to/d3/model.json
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_association_table as bat  # noqa: E402


class BinaryFormatError(Exception):
    pass


def read_binary(path: Path) -> dict:
    """Independent re-implementation of the §0c binary reader (deliberately NOT calling anything
    in `encode_binary` — this is what makes checks 1-3 meaningful as a roundtrip test rather than
    a tautology)."""
    data = path.read_bytes()
    if len(data) < bat.BINARY_HEADER_SIZE:
        raise BinaryFormatError(f"file too short for header: {len(data)} bytes")

    (magic, version, _flags, stored_crc, feature_string_count, reading_count,
     candidate_profile_count, feature_entry_count, global_scale_nats) = struct.unpack(
        "<4sHHIIIIIf", data[:bat.BINARY_HEADER_SIZE]
    )
    if magic != bat.BINARY_MAGIC:
        raise BinaryFormatError(f"bad magic {magic!r} (expected {bat.BINARY_MAGIC!r})")
    if version != bat.BINARY_VERSION:
        raise BinaryFormatError(f"bad version {version} (expected {bat.BINARY_VERSION})")
    if global_scale_nats <= 0:
        raise BinaryFormatError(f"non-positive globalScaleNats {global_scale_nats}")

    payload = data[bat.BINARY_HEADER_SIZE:]
    actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
    if actual_crc != stored_crc:
        raise BinaryFormatError(f"CRC mismatch: header={stored_crc} actual={actual_crc}")

    pos = 0

    def read_u16() -> int:
        nonlocal pos
        (v,) = struct.unpack_from("<H", payload, pos)
        pos += 2
        return v

    def read_u32() -> int:
        nonlocal pos
        (v,) = struct.unpack_from("<I", payload, pos)
        pos += 4
        return v

    def read_i8() -> int:
        nonlocal pos
        (v,) = struct.unpack_from("<b", payload, pos)
        pos += 1
        return v

    def read_f32() -> float:
        nonlocal pos
        (v,) = struct.unpack_from("<f", payload, pos)
        pos += 4
        return v

    def read_string() -> str:
        nonlocal pos
        length = read_u16()
        if pos + length > len(payload):
            raise BinaryFormatError("truncated string")
        raw = payload[pos:pos + length]
        pos += length
        return raw.decode("utf-8")

    features = [read_string() for _ in range(feature_string_count)]

    # §2 — reading index: a FULLY SEPARATE contiguous block (name/scale/candidateCount for every
    # reading, in order) — no candidate data interleaved. §3 (candidate profiles) is a SEPARATE
    # block that follows, "grouped in §2's order" per the format spec — it is NOT
    # reading-index-then-that-reading's-candidates repeated; all of §2 comes first, then all of §3.
    reading_index: list[tuple[str, float, int]] = []
    for _ in range(reading_count):
        reading = read_string()
        reading_scale_nats = read_f32()
        if reading_scale_nats <= 0:
            raise BinaryFormatError(f"non-positive readingScaleNats for {reading!r}")
        candidate_count = read_u16()
        reading_index.append((reading, reading_scale_nats, candidate_count))

    # §3 — candidate profiles, consumed sequentially in §2's order.
    entries: list[tuple[str, str, str, int, float]] = []  # (reading, hanja, feature, qw, readingScaleNats)
    biases: dict[tuple[str, str], float] = {}  # (reading, hanja) -> Float32 bias (D3 slot)
    candidate_profile_count_actual = 0
    feature_entry_count_actual = 0
    for reading, reading_scale_nats, candidate_count in reading_index:
        for _ in range(candidate_count):
            hanja = read_string()
            biases[(reading, hanja)] = read_f32()  # bias — D3 slot (docs/plans/hanja-context-scaling-plan.md §10)
            entry_count = read_u32()
            feature_ids = [read_u32() for _ in range(entry_count)]
            weights = [read_i8() for _ in range(entry_count)]
            for fid, w in zip(feature_ids, weights):
                if not (0 <= fid < len(features)):
                    raise BinaryFormatError(f"feature id {fid} out of range (table has {len(features)})")
                entries.append((reading, hanja, features[fid], w, reading_scale_nats))
            candidate_profile_count_actual += 1
            feature_entry_count_actual += entry_count
    reading_count_actual = len(reading_index)

    if pos != len(payload):
        raise BinaryFormatError(f"trailing/undersized payload: consumed {pos} of {len(payload)} bytes")

    return {
        "global_scale_nats": global_scale_nats,
        "biases": biases,
        "declared": {
            "feature_string_count": feature_string_count,
            "reading_count": reading_count,
            "candidate_profile_count": candidate_profile_count,
            "feature_entry_count": feature_entry_count,
        },
        "actual": {
            "feature_string_count": len(features),
            "reading_count": reading_count_actual,
            "candidate_profile_count": candidate_profile_count_actual,
            "feature_entry_count": feature_entry_count_actual,
        },
        "entries": entries,
    }


def read_text_entries(path: Path) -> dict[tuple[str, str, str], int]:
    """(reading, hanja, feature) -> signed text weight, for every line in `path` (D3: the grid is
    now -255..255, but `int(weight_s)` already parsed negative values fine before this change —
    nothing here needed to change for sign per se; this function replaces the old
    `read_text_entry_set` so check 1 and check 2 share one parse instead of two, and so check 2 can
    look up a D3-trained entry's own signed text weight for its ground-truth reconstruction)."""
    entries: dict[tuple[str, str, str], int] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        reading, hanja, feats = bat.parse_association_line(raw_line)
        for feature, weight in feats:
            entries[(reading, hanja, feature)] = weight
    return entries


def recompute_ground_truth(stats_path: Path) -> dict[tuple[str, str, str], float]:
    """Re-runs the scoring pipeline with the exact params recorded for THIS build (counts/
    association-stats.json) to get TRUE pre-quantization float scores, independent of anything
    `encode_binary` computed — ground truth for check 2. Curated-override reconciliation mirrors
    `encode_binary` exactly (a feature whose FINAL post-curation weight differs from its
    pre-curation text weight has no true corpus score backing it; its ground truth is the
    reconstruction from the final weight, same fallback `encode_binary` uses)."""
    stats = json.loads(stats_path.read_text(encoding="utf-8"))
    params = stats["params"]

    targets = bat.load_targets()
    df_counts, _total_profiles = bat.compute_profile_df(
        params["w_paren"], params["w_dict"], params["min_anchor_survival"]
    )
    banned_features: frozenset[str] = frozenset()
    if params["max_feature_df_count"] > 0:
        banned_features = frozenset(
            f for f, cnt in df_counts.items()
            if bat.UBIQUITY_SCOPED_TAG_RE.search(f) and cnt >= params["max_feature_df_count"]
        )
    colloc_by_reading = bat.load_collocation_counts(Path(params["colloc_counts_file"]))
    master, n_c_all, _dropped = bat.build_master(
        params["w_paren"], params["w_dict"], params["min_anchor_survival"], params["alpha"],
        banned_features=banned_features, colloc_by_reading=colloc_by_reading,
        w_colloc=params["colloc_weight"],
    )
    lines_pre_curated, global_max, _stats, entries = bat.render(
        master, n_c_all, targets, params["m"], params["min_total_weighted"], params["freq_cutoff"]
    )
    if lines_pre_curated is None:
        raise BinaryFormatError("recomputed pipeline produced no entries — params mismatch?")
    entries_score = {(r, h, f): score for r, h, f, score in entries}

    lines_final = bat.merge_curated_overrides(lines_pre_curated)
    pre_curated_weight: dict[tuple[str, str, str], int] = {}
    for line in lines_pre_curated:
        reading, hanja, feats = bat.parse_association_line(line)
        for feature, weight in feats:
            pre_curated_weight[(reading, hanja, feature)] = weight

    ground_truth: dict[tuple[str, str, str], float] = {}
    for line in lines_final:
        reading, hanja, feats = bat.parse_association_line(line)
        for feature, weight in feats:
            key = (reading, hanja, feature)
            if pre_curated_weight.get(key) == weight and key in entries_score:
                ground_truth[key] = entries_score[key]
            else:
                ground_truth[key] = weight / 255 * global_max
    return ground_truth


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--text", type=Path, default=bat.OUTPUT_TXT)
    parser.add_argument("--binary", type=Path, default=bat.OUTPUT_BIN)
    parser.add_argument("--stats", type=Path, default=bat.STATS_JSON,
                        help="association-stats.json for THIS build — its recorded params are "
                             "re-run to recompute ground-truth scores for check 2, for every "
                             "reading NOT covered by --model.")
    parser.add_argument("--model", type=Path, default=None,
                        help="D3 build_d3_ranker.py train's model.json. When given, readings it "
                             "lists are treated as D3-trained: check 2's ground truth for their "
                             "entries comes from the text file's own signed weight (not the corpus "
                             "recompute), and check 4 verifies their bias against the model. Every "
                             "other reading is verified exactly as before (corpus recompute, "
                             "bias must be 0.0). Omit for a pre-D3 (pure corpus) table.")
    args = parser.parse_args()

    required = [(args.text, "text"), (args.binary, "binary"), (args.stats, "stats")]
    if args.model is not None:
        required.append((args.model, "model"))
    for path, label in required:
        if not path.exists():
            print(f"FAIL: {label} file not found: {path}", file=sys.stderr)
            return 1

    trained_readings: dict[str, dict] = {}
    if args.model is not None:
        d3_model = json.loads(args.model.read_text(encoding="utf-8"))
        trained_readings = d3_model["readings"]
        # Imported lazily (only when --model is used) purely to reuse BIAS_CLAMP's value instead of
        # duplicating the constant — no ranking/training logic from that module runs here.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import build_d3_ranker as d3r  # noqa: E402
        bias_clamp = d3r.BIAS_CLAMP
    else:
        bias_clamp = None

    print(f"reading {args.binary} ...", file=sys.stderr)
    try:
        parsed = read_binary(args.binary)
    except BinaryFormatError as exc:
        print(f"FAIL: binary format error: {exc}", file=sys.stderr)
        return 1

    failures: list[str] = []

    # Check 3 — header/CRC self-consistency (CRC itself already verified inside read_binary;
    # here we check the declared section counts against what was actually parsed).
    for key in ("feature_string_count", "reading_count", "candidate_profile_count", "feature_entry_count"):
        if parsed["declared"][key] != parsed["actual"][key]:
            failures.append(
                f"check3 header count mismatch: {key} declared={parsed['declared'][key]} "
                f"actual={parsed['actual'][key]}"
            )
    check3_ok = not any(f.startswith("check3") for f in failures)
    print(f"check3 (header/CRC self-consistency): {'PASS' if check3_ok else 'FAIL'}", file=sys.stderr)

    # Check 1 — entry-set equality vs the text file from the same build. Weight VALUES (and bias —
    # there is no bias field in the text format at all) are excluded from this comparison; only the
    # (reading, hanja, feature) triple has to match (unchanged in spirit from pre-D3 — see
    # `read_text_entries`'s own docstring for why this one parse now also feeds check 2).
    print(f"reading {args.text} ...", file=sys.stderr)
    text_entries = read_text_entries(args.text)
    text_entry_set = set(text_entries.keys())
    binary_entries = {(r, h, f) for r, h, f, _w, _s in parsed["entries"]}
    missing_in_binary = text_entry_set - binary_entries
    extra_in_binary = binary_entries - text_entry_set
    check1_ok = not missing_in_binary and not extra_in_binary
    if not check1_ok:
        failures.append(
            f"check1 entry-set mismatch: missing_in_binary={len(missing_in_binary)} "
            f"extra_in_binary={len(extra_in_binary)}"
        )
        for sample in list(missing_in_binary)[:10]:
            print(f"  missing_in_binary sample: {sample}", file=sys.stderr)
        for sample in list(extra_in_binary)[:10]:
            print(f"  extra_in_binary sample: {sample}", file=sys.stderr)
    print(
        f"check1 (entry-set equality): {'PASS' if check1_ok else 'FAIL'} "
        f"(text={len(text_entry_set)} binary={len(binary_entries)})",
        file=sys.stderr,
    )

    # Check 2 — per-entry quantization error vs the TRUE pre-quantization score. For a D3-TRAINED
    # reading (in trained_readings), ground truth is reconstructed from the text file's own signed
    # weight * this build's globalScaleNats header field — the exact fallback `encode_binary` used
    # when it wrote that entry (see build_d3_ranker.py's cmd_export); there IS no corpus score to
    # recompute for these entries (their features never existed in the corpus pipeline at all). For
    # every OTHER reading, ground truth is still the corpus recompute (re-running
    # load_targets/compute_profile_df/build_master/render with counts/association-stats.json's
    # recorded params) — unchanged from pre-D3 behavior.
    print("recomputing ground-truth scores (re-running the scoring pipeline)...", file=sys.stderr)
    corpus_ground_truth = recompute_ground_truth(args.stats)
    checked = 0
    over_tolerance = 0
    missing_ground_truth = 0
    worst: tuple | None = None
    worst_ratio = 0.0
    for reading, hanja, feature, qw, reading_scale_nats in parsed["entries"]:
        key = (reading, hanja, feature)
        if reading in trained_readings:
            text_weight = text_entries.get(key)
            raw_score = text_weight * parsed["global_scale_nats"] if text_weight is not None else None
        else:
            raw_score = corpus_ground_truth.get(key)
        if raw_score is None:
            missing_ground_truth += 1
            continue
        checked += 1
        reconstructed = qw * reading_scale_nats
        error = abs(reconstructed - raw_score)
        tolerance = reading_scale_nats
        if error > tolerance:
            over_tolerance += 1
            ratio = error / tolerance if tolerance > 0 else float("inf")
            if ratio > worst_ratio:
                worst_ratio = ratio
                worst = (key, error, tolerance, reconstructed, raw_score)
    if missing_ground_truth:
        failures.append(
            f"check2 {missing_ground_truth} binary entries have no ground truth (either "
            "counts/association-stats.json's params are stale vs the shipped .bin/.txt, or a "
            "D3-trained reading's entry has no matching text line — data corruption)"
        )
    check2_ok = over_tolerance == 0 and missing_ground_truth == 0
    if over_tolerance:
        failures.append(f"check2 quantization tolerance exceeded for {over_tolerance}/{checked} entries")
        if worst:
            print(f"  worst case: key={worst[0]} error={worst[1]:.6f} tolerance={worst[2]:.6f} "
                  f"reconstructed={worst[3]:.6f} raw_score={worst[4]:.6f}", file=sys.stderr)
    print(
        f"check2 (quantization tolerance +/-1 reading-scale step): {'PASS' if check2_ok else 'FAIL'} "
        f"(checked={checked} over_tolerance={over_tolerance} missing_ground_truth={missing_ground_truth})",
        file=sys.stderr,
    )

    # Check 4 (D3, new) — bias. Without --model, every candidate's bias must be exactly 0.0 (the
    # pre-D3 invariant). With --model, a TRAINED reading's candidates must match that reading's
    # clamped trained bias within Float32 rounding of the SAME value (both sides rounded through a
    # real float32 pack/unpack, then compared exactly — not an arbitrary epsilon); every other
    # candidate (untrained reading, or — defensively — a trained reading whose candidate is
    # missing from the model, which should never happen by construction) must still be exactly 0.0.
    bias_mismatches = 0
    bias_checked = 0
    bias_samples: list[str] = []
    for (reading, hanja), actual_bias in parsed["biases"].items():
        bias_checked += 1
        trained = trained_readings.get(reading)
        cand = trained["candidates"].get(hanja) if trained else None
        if cand is not None:
            # 조율자 수정 (2026-08-01): export가 bias를 nat에서 **피처와 같은 raw 단위**로
            # 환산(× 255 / global_max)한 뒤 클램프한다 — build_d3_ranker.py의 같은 날짜 주석
            # 참조. 검증도 같은 변환을 거쳐야 한다. global_max는 이진 헤더의 globalScaleNats
            # (= global_max / 255)에서 되돌린다.
            global_max = parsed["global_scale_nats"] * 255
            raw_unit_bias = cand["bias"] * 255 / global_max if global_max > 0 else 0.0
            raw_expected = max(-bias_clamp, min(bias_clamp, raw_unit_bias))
            expected_f32 = struct.unpack("<f", struct.pack("<f", raw_expected))[0]
            # 정확 비교가 아니라 허용오차 비교인 이유: 기대값을 만들려면 `global_max`가
            # 필요한데 이진 헤더에는 그걸 Float32로 나눈 `globalScaleNats`만 있다. 거기서
            # 되돌린 global_max는 export가 쓴 double 원본과 7번째 유효숫자에서 갈린다
            # (실측 예: -26.38279914855957 vs -26.382801055908203). 이건 값이 틀린 게
            # 아니라 헤더 왕복의 정밀도 한계이므로 상대오차로 판정한다.
            if not math.isclose(actual_bias, expected_f32, rel_tol=1e-6, abs_tol=1e-6):
                bias_mismatches += 1
                if len(bias_samples) < 10:
                    bias_samples.append(f"{(reading, hanja)}: actual={actual_bias} expected={expected_f32}")
        else:
            if actual_bias != 0.0:
                bias_mismatches += 1
                if len(bias_samples) < 10:
                    bias_samples.append(f"{(reading, hanja)}: actual={actual_bias} expected=0.0 (untrained)")
    check4_ok = bias_mismatches == 0
    if not check4_ok:
        failures.append(f"check4 bias mismatch for {bias_mismatches}/{bias_checked} candidate profiles")
        for sample in bias_samples:
            print(f"  bias mismatch sample: {sample}", file=sys.stderr)
    print(
        f"check4 (bias{' vs ' + str(args.model) if args.model else ' == 0.0 (no --model given)'}): "
        f"{'PASS' if check4_ok else 'FAIL'} (checked={bias_checked} mismatches={bias_mismatches})",
        file=sys.stderr,
    )

    print("---", file=sys.stderr)
    if failures:
        print(f"VERIFY FAILED: {len(failures)} issue(s)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print(
        f"VERIFY PASSED: entries={len(binary_entries)} readings={parsed['actual']['reading_count']} "
        f"candidates={parsed['actual']['candidate_profile_count']} "
        f"binary_size={args.binary.stat().st_size} text_size={args.text.stat().st_size}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
