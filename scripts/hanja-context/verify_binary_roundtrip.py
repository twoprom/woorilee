#!/usr/bin/env python3
"""Step 0c binary roundtrip verifier (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세"
— "왕복 검증"). Three checks, stdlib only:

  1. Entry-set equality: every (reading, hanja, feature) triple recovered from
     `hanja-context.bin` matches EXACTLY the set recovered from `hanja-context.txt` — the same
     build's text output (encode_binary is constructed from the text's own merged lines, so this
     also transitively checks the writer never dropped/added an entry).
  2. Per-entry quantization error: |qw * readingScaleNats - raw_score| <= readingScaleNats
     (±1 reading-scale step), where raw_score is the TRUE pre-quantization float score —
     recomputed here by re-running the scoring pipeline (build_association_table's
     load_targets/compute_profile_df/build_master/render) with the exact params recorded in
     counts/association-stats.json for this build. This is independent of whatever
     `encode_binary` did internally: ground truth comes from re-deriving the score from the raw
     counts, and the reconstruction (qw * readingScaleNats) comes from an INDEPENDENTLY
     re-implemented binary reader below (not by calling encode_binary), so a bug in either the
     writer's rounding/clamping or its header/layout math would show up here.
  3. Header/CRC self-consistency: magic/version accepted, the payload CRC32 is independently
     recomputed (zlib.crc32 over bytes[32:]) and compared to the stored header value, and the
     four header counts (featureStringCount/readingCount/candidateProfileCount/
     featureEntryCount) match what was actually parsed out of the payload.

Exits nonzero and prints a summary (to stderr) on ANY mismatch.

Usage:
    python3 scripts/hanja-context/verify_binary_roundtrip.py
    python3 scripts/hanja-context/verify_binary_roundtrip.py \\
        --text /path/to/hanja-context.txt --binary /path/to/hanja-context.bin \\
        --stats /path/to/association-stats.json
"""
from __future__ import annotations

import argparse
import json
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
    candidate_profile_count_actual = 0
    feature_entry_count_actual = 0
    for reading, reading_scale_nats, candidate_count in reading_index:
        for _ in range(candidate_count):
            hanja = read_string()
            read_f32()  # bias — D3 slot, unused in 0c
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


def read_text_entry_set(path: Path) -> set[tuple[str, str, str]]:
    entries: set[tuple[str, str, str]] = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        reading, hanja, feats = bat.parse_association_line(raw_line)
        for feature, _weight in feats:
            entries.add((reading, hanja, feature))
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
                             "re-run to recompute ground-truth scores for check 2.")
    args = parser.parse_args()

    for path, label in ((args.text, "text"), (args.binary, "binary"), (args.stats, "stats")):
        if not path.exists():
            print(f"FAIL: {label} file not found: {path}", file=sys.stderr)
            return 1

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

    # Check 1 — entry-set equality vs the text file from the same build.
    print(f"reading {args.text} ...", file=sys.stderr)
    text_entries = read_text_entry_set(args.text)
    binary_entries = {(r, h, f) for r, h, f, _w, _s in parsed["entries"]}
    missing_in_binary = text_entries - binary_entries
    extra_in_binary = binary_entries - text_entries
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
        f"(text={len(text_entries)} binary={len(binary_entries)})",
        file=sys.stderr,
    )

    # Check 2 — per-entry quantization error vs the TRUE pre-quantization score (recomputed by
    # re-running the scoring pipeline — see recompute_ground_truth's docstring).
    print("recomputing ground-truth scores (re-running the scoring pipeline)...", file=sys.stderr)
    ground_truth = recompute_ground_truth(args.stats)
    checked = 0
    over_tolerance = 0
    missing_ground_truth = 0
    worst: tuple | None = None
    worst_ratio = 0.0
    for reading, hanja, feature, qw, reading_scale_nats in parsed["entries"]:
        key = (reading, hanja, feature)
        raw_score = ground_truth.get(key)
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
            f"check2 {missing_ground_truth} binary entries have no ground truth in the "
            "recomputed pipeline (params in stats.json likely stale vs the shipped .bin/.txt)"
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
