#!/usr/bin/env python3
"""Step R1c JOB 1 — document/session replay sample builder (문맥 기반 한자 변환,
docs/plans/hanja-context-scaling-plan.md §6 R1c 1).

This is the DATA-PREP half of R1c only. It extracts a stratified sample of
Wikipedia *documents* (grouped by page ID) from the already-filtered step-5a
corpus, where a target reading R first appears disambiguated by a validated
"한글(漢字)" gloss and then reappears at least once later in the same
document WITHOUT a gloss. The Swift replay harness (separate, later step)
consumes the output TSV to measure whether R1a's session vocabulary/prior
actually improves ranking on that bare reappearance — this script only
produces the fixture, it does not do any Kiwi analysis or ranking.

Python 3.14 stdlib only (repo convention, see scripts/hanja-context/README.md).

Inputs:
  - `/Volumes/Workbench/wooriHanjaModel/work/hanja-context/filtered/part-*.txt`
    (format v2: `종류<TAB>페이지ID<TAB>문장`; a page's lines are always
    contiguous within one part file — 0b invariant, see extract_and_filter.py).
  - `eval/hanja-context-eval-set.tsv` column 2 (읽기) — target reading pool.
  - `woorilee/data/hanja/hanja.txt` — candidate hanja set per reading.

*** Reading-pool discrepancy (flagged, please confirm) ***
r1c-spec.md's own §1 text says the eval-set yields "31계열" — which is what
you get by taking ALL distinct 읽기 values across the ENTIRE current eval
file (v1 + v2 + v3 marker sections combined; verified: 31). However, this
implementer's task instructions explicitly said to use only the v1 section
(rows before the first "# ---- v2" comment marker), which yields 27 —
matching the "eval-27" figure used everywhere else in the plan/research
docs. The v2 section (native-homograph 문맥 없는 sentences) and v3 section
(구두/고장/사과/감기/지금 — etymology-based auto-conversion promote/suppress
rows for the 고유어 동음이의어 게이트, a DIFFERENT mechanism from ranked
candidate disambiguation) are not part of the "ambiguous hanja reading with
several ranked candidates" pool R1a/R1c is about. This script defaults to
the v1-only 27-reading pool per that explicit instruction; the discrepancy
is recorded here and in the output file's header comment for the
coordinator to confirm or override.

Usage:
    python3 scripts/hanja-context/build_session_replay_set.py
    python3 scripts/hanja-context/build_session_replay_set.py --verify

Writes:
    eval/hanja-context-session-replay.tsv
        pageID<TAB>seq<TAB>role<TAB>reading<TAB>answer<TAB>sentence
        (role in {context, first, later}; context rows leave reading/answer blank)
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc

MAX_DOCS_PER_READING = 30
MAX_TOTAL_DOCS = 500
TRAILING_SENTENCES = 2

OUTPUT_TSV = hc.WOORILEE_ROOT / "eval/hanja-context-session-replay.tsv"

V2_MARKER_PREFIX = "# ---- v2"

# Same Hanja unicode ranges as extract_and_filter.py's PAREN_FULL_RE (CJK
# Unified Ideographs U+4E00-U+9FFF + Extension A U+3400-U+4DBF). Captures the
# preceding hangul run too, so callers can validate the trailing-suffix
# reading against hanja.txt exactly like the 5a filter does.
PAREN_FULL_RE = re.compile(r"([가-힣]+)\(([一-鿿㐀-䶿]+)\)")

# Same char class, no preceding-hangul capture — used to strip EVERY
# parenthesized all-Hanja group from a replay sentence, regardless of which
# reading (if any) it was disambiguating. This is both the "no answer leak"
# rule and a "bare input" approximation (real IME users never type the gloss).
HANJA_PAREN_RE = re.compile(r"\([一-鿿㐀-䶿]+\)")


def load_v1_eval_readings(path: Path) -> list[str]:
    """Distinct 읽기 (column 2) values from the v1 section of the eval set
    ONLY — rows before the first '# ---- v2' marker comment. First-occurrence
    order. See the module docstring's "reading-pool discrepancy" note for why
    this stops at the marker instead of reading the whole file."""
    seen: set[str] = set()
    order: list[str] = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if line.startswith(V2_MARKER_PREFIX):
                break
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            reading = cols[1]
            if reading not in seen:
                seen.add(reading)
                order.append(reading)
    return order


def compute_paren_hits(
    sentence: str, candidates: dict[str, set[str]], target_reading_set: set[str]
) -> list[tuple[str, str]]:
    """All VALID (reading, hanja) glosses in `sentence`, restricted to our
    target reading pool: the trailing suffix of the parenthesized hangul run
    (same length as the hanja run) must equal a target reading, and the hanja
    run must be one of that reading's hanja.txt candidates. Mirrors the
    'paren' validation in extract_and_filter.py's classify_sentence exactly."""
    hits: list[tuple[str, str]] = []
    for m in PAREN_FULL_RE.finditer(sentence):
        hangul_run, hanja_str = m.group(1), m.group(2)
        if len(hangul_run) < len(hanja_str):
            continue
        suffix = hangul_run[-len(hanja_str):]
        if suffix in target_reading_set and hanja_str in candidates.get(suffix, ()):
            hits.append((suffix, hanja_str))
    return hits


def strip_answer_leak(sentence: str) -> str:
    """Remove EVERY parenthesized all-Hanja group (not just the one for this
    document's active reading) and collapse whitespace left behind."""
    stripped = HANJA_PAREN_RE.sub("", sentence)
    return " ".join(stripped.split())


def iter_pages(filtered_dir: Path):
    """Yield (pageID, [sentence, ...]) for every page across all
    filtered/part-*.txt files, in sorted-filename order. A page's lines are
    guaranteed contiguous within a single part file (step-0b invariant), so a
    simple "pageID changed" transition is sufficient to group pages without
    buffering the whole corpus."""
    part_paths = sorted(filtered_dir.glob("part-*.txt"))
    current_page_id: str | None = None
    current_sentences: list[str] = []
    for part_path in part_paths:
        with part_path.open(encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                cols = line.split("\t", 2)
                if len(cols) != 3:
                    continue
                _kind, page_id, sentence = cols
                if page_id != current_page_id:
                    if current_page_id is not None:
                        yield current_page_id, current_sentences
                    current_page_id = page_id
                    current_sentences = []
                current_sentences.append(sentence)
    if current_page_id is not None:
        yield current_page_id, current_sentences


def analyze_reading_for_page(
    sentences: list[str], hits: list[list[tuple[str, str]]], reading: str
) -> tuple[int, str, list[int]] | None:
    """Returns (first_index, answer, later_indices) if this page qualifies
    `reading` for the replay set (a validated gloss followed by >=1 bare
    reappearance), else None. `first_index` is the first sentence with a
    valid `reading(H)` gloss; `later_indices` are ALL subsequent sentences
    that contain `reading` as a raw substring AND carry no valid gloss for
    `reading` themselves (a sentence with even a different-candidate gloss
    for the SAME reading is excluded from `later`, conservatively, since it
    is not a "bare" reappearance)."""
    first_index = None
    answer = None
    for i, sentence_hits in enumerate(hits):
        for suffix, hanja_str in sentence_hits:
            if suffix == reading:
                first_index = i
                answer = hanja_str
                break
        if first_index is not None:
            break
    if first_index is None:
        return None

    later_indices = []
    for j in range(first_index + 1, len(sentences)):
        if reading not in sentences[j]:
            continue
        if any(suffix == reading for suffix, _ in hits[j]):
            continue
        later_indices.append(j)
    if not later_indices:
        return None
    return first_index, answer, later_indices


def build_replay_rows(
    filtered_dir: Path,
    target_readings: list[str],
    candidates: dict[str, set[str]],
    max_docs_per_reading: int,
    max_total_docs: int,
    trailing_sentences: int,
) -> tuple[list[tuple[str, int, str, str, str, str]], dict]:
    """Streams filtered/part-*.txt page by page, selecting up to
    `max_docs_per_reading` documents per reading (round-robin: each
    qualifying page is assigned to whichever qualifying reading currently
    has the fewest assigned docs, tie-broken by target_readings order) up to
    `max_total_docs` total. Each selected document is attributed to exactly
    ONE reading (the page may textually qualify for more than one target
    reading, but — to keep per-document session replay unambiguous and the
    implementation simple — only the reading it gets assigned to produces
    first/later rows for that document; this is a deliberate simplification,
    noted in the report)."""
    target_reading_set = set(target_readings)
    doc_counts = {r: 0 for r in target_readings}
    reading_first_sentence_count = {r: 0 for r in target_readings}
    reading_later_sentence_count = {r: 0 for r in target_readings}
    reading_context_sentence_count = {r: 0 for r in target_readings}
    total_docs = 0
    total_context_sentences = 0
    pages_scanned = 0
    rows: list[tuple[str, int, str, str, str, str]] = []

    for page_id, sentences in iter_pages(filtered_dir):
        if total_docs >= max_total_docs:
            break
        pages_scanned += 1

        hits = [compute_paren_hits(s, candidates, target_reading_set) for s in sentences]

        qualifying: list[tuple[str, tuple[int, str, list[int]]]] = []
        for r in target_readings:
            if doc_counts[r] >= max_docs_per_reading:
                continue
            result = analyze_reading_for_page(sentences, hits, r)
            if result is not None:
                qualifying.append((r, result))
        if not qualifying:
            continue

        # Round-robin: assign this page to whichever qualifying reading is
        # currently least-filled (ties broken by fixed target_readings order).
        qualifying.sort(key=lambda item: (doc_counts[item[0]], target_readings.index(item[0])))
        reading, (first_index, answer, later_indices) = qualifying[0]
        doc_counts[reading] += 1
        total_docs += 1

        later_set = set(later_indices)
        last_target_index = max(first_index, later_indices[-1])
        cutoff = min(last_target_index + trailing_sentences, len(sentences) - 1)

        seq = 0
        for idx in range(0, cutoff + 1):
            seq += 1
            if idx == first_index:
                role = "first"
            elif idx in later_set:
                role = "later"
            else:
                role = "context"

            if role in ("first", "later"):
                reading_col, answer_col = reading, answer
                if role == "first":
                    reading_first_sentence_count[reading] += 1
                else:
                    reading_later_sentence_count[reading] += 1
            else:
                reading_col, answer_col = "", ""
                reading_context_sentence_count[reading] += 1
                total_context_sentences += 1

            sentence_out = strip_answer_leak(sentences[idx])
            rows.append((page_id, seq, role, reading_col, answer_col, sentence_out))

    stats = {
        "total_docs": total_docs,
        "pages_scanned": pages_scanned,
        "doc_counts": doc_counts,
        "reading_first_sentence_count": reading_first_sentence_count,
        "reading_later_sentence_count": reading_later_sentence_count,
        "reading_context_sentence_count": reading_context_sentence_count,
        "total_context_sentences": total_context_sentences,
        "total_first_sentences": sum(reading_first_sentence_count.values()),
        "total_later_sentences": sum(reading_later_sentence_count.values()),
    }
    return rows, stats


def write_output(
    path: Path,
    rows: list[tuple[str, int, str, str, str, str]],
    target_readings: list[str],
    stats: dict,
    params: dict,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        f.write(
            "# hanja-context-session-replay v1 — R1c 문서 단위 시뮬레이션 평가 표본 "
            "(docs/plans/hanja-context-scaling-plan.md §6 R1c 1)\n"
        )
        f.write("# 생성: scripts/hanja-context/build_session_replay_set.py\n")
        f.write(
            "# Format: pageID<TAB>seq<TAB>role<TAB>reading<TAB>answer<TAB>sentence "
            "(real tabs, UTF-8). role in {context,first,later}; context rows leave "
            "reading/answer blank. seq is 1-based, restarts per pageID.\n"
        )
        f.write(
            f"# Params: max_docs_per_reading={params['max_docs_per_reading']} "
            f"max_total_docs={params['max_total_docs']} "
            f"trailing_sentences={params['trailing_sentences']} "
            f"target_readings={len(target_readings)}\n"
        )
        f.write(
            "# NOTE (reading-pool discrepancy, flagged for coordinator confirmation): "
            "target reading pool = distinct col-2 값 from eval/hanja-context-eval-set.tsv's "
            "v1 section ONLY (rows before the first '# ---- v2' marker) = 27 series "
            "(matches the 'eval-27' figure used elsewhere in the plan). r1c-spec.md's own "
            "§1 text says '31계열', which is what the WHOLE file (v1+v2+v3, no split) "
            "yields — the extra 4 (지금/구두/고장/감기) are v3 native-homograph "
            "etymology-gate rows, a separate promote/suppress mechanism, not ranked "
            "candidate disambiguation. Defaulted to v1-only per explicit task "
            "instructions; see script docstring.\n"
        )
        f.write(
            "# NOTE (one-reading-per-document simplification): a page may textually "
            "qualify for multiple target readings, but each selected document is "
            "attributed to exactly one reading (the round-robin-assigned one) — no "
            "multi-reading documents in this output.\n"
        )
        f.write(f"# Target readings ({len(target_readings)}): {','.join(target_readings)}\n")
        f.write(
            f"# Docs: total={stats['total_docs']} pages_scanned={stats['pages_scanned']} "
            f"context_sentences={stats['total_context_sentences']} "
            f"first_sentences={stats['total_first_sentences']} "
            f"later_sentences={stats['total_later_sentences']}\n"
        )
        per_reading = ", ".join(
            f"{r}={stats['doc_counts'][r]}docs/"
            f"{stats['reading_first_sentence_count'][r]}first/"
            f"{stats['reading_later_sentence_count'][r]}later"
            for r in target_readings
        )
        f.write(f"# Per-reading distribution: {per_reading}\n")
        for page_id, seq, role, reading, answer, sentence in rows:
            f.write(f"{page_id}\t{seq}\t{role}\t{reading}\t{answer}\t{sentence}\n")


def verify_output(path: Path) -> bool:
    """Independent re-read of the written TSV (not reusing in-memory rows)
    checking the 3 properties the R1c spec requires of this fixture:
      (a) every `later` row's reading appears as a raw substring of its sentence
      (b) no row's sentence retains a parenthesized all-Hanja group (no answer leak)
      (c) for every (pageID, reading), the `first` row's seq precedes every
          `later` row's seq in the same document
    Prints VERIFY|... lines and returns True iff all three pass."""
    rows: list[tuple[str, str, str, str, str, str]] = []
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t", 5)
            if len(cols) != 6:
                print(f"VERIFY|FAIL malformed row (expected 6 cols, got {len(cols)}): {line[:80]!r}", file=sys.stderr)
                continue
            rows.append(tuple(cols))  # type: ignore[arg-type]

    later_ok = True
    later_failures: list[tuple[str, str]] = []
    leak_ok = True
    leak_failures: list[tuple[str, str]] = []
    for page_id, seq, role, reading, _answer, sentence in rows:
        if role == "later" and reading not in sentence:
            later_ok = False
            later_failures.append((page_id, seq))
        if HANJA_PAREN_RE.search(sentence):
            leak_ok = False
            leak_failures.append((page_id, seq))

    first_seq: dict[tuple[str, str], int] = {}
    for page_id, seq, role, reading, _answer, _sentence in rows:
        if role == "first":
            first_seq[(page_id, reading)] = int(seq)

    order_ok = True
    order_failures: list[tuple[str, str]] = []
    for page_id, seq, role, reading, _answer, _sentence in rows:
        if role == "later":
            key = (page_id, reading)
            if key not in first_seq or int(seq) <= first_seq[key]:
                order_ok = False
                order_failures.append((page_id, seq))

    print(
        f"VERIFY|(a) later.reading substring present in sentence: "
        f"{'PASS' if later_ok else 'FAIL'} ({len(later_failures)} failures / "
        f"{sum(1 for r in rows if r[2] == 'later')} later rows)"
    )
    print(
        f"VERIFY|(b) no hanja-paren leak remains in any sentence: "
        f"{'PASS' if leak_ok else 'FAIL'} ({len(leak_failures)} failures / {len(rows)} rows)"
    )
    print(
        f"VERIFY|(c) first.seq < later.seq for every (pageID,reading): "
        f"{'PASS' if order_ok else 'FAIL'} ({len(order_failures)} failures)"
    )

    all_pass = later_ok and leak_ok and order_ok
    if not all_pass:
        if later_failures:
            print(f"VERIFY|  sample (a) failures: {later_failures[:5]}", file=sys.stderr)
        if leak_failures:
            print(f"VERIFY|  sample (b) failures: {leak_failures[:5]}", file=sys.stderr)
        if order_failures:
            print(f"VERIFY|  sample (c) failures: {order_failures[:5]}", file=sys.stderr)
    return all_pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--filtered-dir", type=Path, default=hc.FILTERED_DIR)
    parser.add_argument("--hanja-txt", type=Path, default=hc.HANJA_TXT)
    parser.add_argument("--eval-set", type=Path, default=hc.EVAL_SET_TSV)
    parser.add_argument("--output", type=Path, default=OUTPUT_TSV)
    parser.add_argument("--max-docs-per-reading", type=int, default=MAX_DOCS_PER_READING)
    parser.add_argument("--max-total-docs", type=int, default=MAX_TOTAL_DOCS)
    parser.add_argument("--trailing-sentences", type=int, default=TRAILING_SENTENCES)
    parser.add_argument(
        "--verify", action="store_true",
        help="After writing, independently re-read the output file and run the 3 "
             "self-checks (later-reading-present, no-paren-leak, first-before-later); "
             "exit nonzero on any failure.",
    )
    args = parser.parse_args()

    target_readings = load_v1_eval_readings(args.eval_set)
    lines = hc.read_dictionary_lines(args.hanja_txt)
    raw_by_reading = hc.candidates_by_reading(lines)
    deduped_by_reading = hc.dedup_candidates_by_reading(raw_by_reading)
    candidates = {r: set(deduped_by_reading.get(r, [])) for r in target_readings}

    print(f"Target readings (v1 eval-set section, {len(target_readings)}): {', '.join(target_readings)}")
    missing = [r for r in target_readings if not candidates.get(r)]
    if missing:
        print(f"WARNING: no hanja.txt candidates found for: {missing}", file=sys.stderr)

    start = time.monotonic()
    rows, stats = build_replay_rows(
        args.filtered_dir,
        target_readings,
        candidates,
        args.max_docs_per_reading,
        args.max_total_docs,
        args.trailing_sentences,
    )
    elapsed = time.monotonic() - start

    params = {
        "max_docs_per_reading": args.max_docs_per_reading,
        "max_total_docs": args.max_total_docs,
        "trailing_sentences": args.trailing_sentences,
    }
    write_output(args.output, rows, target_readings, stats, params)

    print(
        f"Wrote {len(rows)} rows ({stats['total_docs']} docs) to {args.output} "
        f"in {elapsed:.1f}s (scanned {stats['pages_scanned']} pages)"
    )
    print(
        f"  sentences: context={stats['total_context_sentences']} "
        f"first={stats['total_first_sentences']} later={stats['total_later_sentences']}"
    )
    print("  per-reading (docs / first-sentences / later-sentences):")
    for r in target_readings:
        print(
            f"    {r}: docs={stats['doc_counts'][r]} "
            f"first={stats['reading_first_sentence_count'][r]} "
            f"later={stats['reading_later_sentence_count'][r]}"
        )

    if args.verify:
        ok = verify_output(args.output)
        if not ok:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
