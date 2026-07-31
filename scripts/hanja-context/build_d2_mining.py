#!/usr/bin/env python3
"""Step D2 Task 2 — mine dev/test candidate sentences for the 150 readings
build_d2_readings.py selected, disjoint from the D1 seed corpus
(docs/plans/hanja-context-scaling-plan.md §9-1,
docs/hanja-context-quality-scaling-research.md §5.1).

WHY THE RAW WIKI DUMP AND NOT filtered/part-*.txt: `filtered/part-*.txt` rows
are `kind<TAB>sentence` (extract_and_filter.py's v2 format is `kind<TAB>page_id
<TAB>sentence` but even that lacks the PAGE TITLE) — this script needs the
page TITLE to check the family-disjointness rule below, so it streams the XML
dump itself, reusing extract_seeds.py's own scan/filter machinery (same
sentence splitter, same title/id/redirect tag constants) rather than
reimplementing them. `extract_seeds.main()` is import-guarded
(`if __name__ == "__main__"`), so `import extract_seeds as es` has no
side effects.

DISJOINTNESS CONTRACT (계획 §9-1 "D1 씨앗과 겹치지 않는 문장" + 연구 문서 §5.1
document/family unoverlap):
  1. Stream every seeds/part-*.tsv row (both `token` and `type` level) once,
     collecting D1_pages = {col 5 page_id} and D1_families = {col 6 family}
     (seeds-v2 format — see extract_seeds.py's FORMAT_HEADER).
  2. A candidate mining page P (title T, id ID) is excluded ENTIRELY (no
     sentence from it is ever considered) iff ID is in D1_pages OR
     "t:"+T is in D1_families.
  3. VERIFIED FACT (checked directly against extract_seeds.py's emitter code,
     not assumed): for TOKEN-level seed rows, `family` is always exactly
     "t:" + the SOURCE page's own title (see `process_sentence`'s caller in
     `main()`: `family = "t:" + title`, passed straight through to every
     `emitter.emit_token(...)` call for that page). So on the token axis,
     family IS the page identity — rule 2's family clause never fires beyond
     what the page_id clause already catches for token-sourced seeds. It is
     the TYPE-level sources (specifically `redirect`, whose family is the
     REDIRECT TARGET's title — see `process_redirect_page`: `family = "t:" +
     strip_disambiguator(redirect_target)`) that can name a family belonging
     to a page other than the one that emitted the seed row. That's exactly
     the case rule 2's family clause exists for: a hanja-redirect page (e.g.
     "水道" redirecting to "수도") emits a `redirect` seed row whose own
     page_id is the *redirect page's* id, but whose family is "t:수도" — the
     ARTICLE's title — so the article page must also be excluded from mining
     even though its own page_id never appears as a `redirect` row's page_id.
     `disambig`/`dislink`/`title` type rows all use "t:" + their OWN page's
     title (self-family, same as token rows) — only `redirect` differs.

MINING FILTER (per selected reading, per candidate sentence — length 20-160
chars, already passed extract_and_filter.split_sentences's own >=10-char +
"contains hangul" filter upstream):
  - The reading must appear VERBATIM (as Hangul) as a substring.
  - BOUNDARY APPROXIMATION (provisional — see note below): before the match
    must be the sentence start or a space/punctuation character; after the
    match must be the sentence end, a space/punctuation character, OR the
    leading character of a josa/eomi from the fixed list ("은","는","이","가",
    "을","를","의","에서","와","과","로","도","만","부터","까지","처럼","보다",
    "라고","이나","이라") — concatenating that list reads exactly
    "은는이가을를의에서와과로도만부터까지처럼보다라고이나이라" (the string named in
    the task spec), and JOSA_EOMI_LEADING_CHARS below is the set of each
    word's FIRST character. This is a Python-only, Kiwi-free approximation
    of "the match is a standalone word here, not a substring of a longer
    word" — it can both under- and over-accept (e.g. it cannot see that a
    following character starts an unrelated word rather than a suffix).
    THIS APPROXIMATION IS PROVISIONAL: Task 3's Swift `assoc d2-verify` runs
    the real Kiwi segmentation over every mined sentence and its `seg_ok`
    column is the FINAL judgment of whether the reading was actually
    segmented as a standalone token at the expected span — Task 4's label
    sheet only uses `seg_ok=1` rows. This filter's only job is to keep the
    mining pass's candidate pool small and mostly-sane before Kiwi ever runs.
  - LEAK GUARD (two independent checks, either one rejects the sentence for
    that reading): (a) none of the reading's OWN candidate hanja strings
    (from build_d2_readings.py's `candidates` column) may appear anywhere in
    the sentence as a literal substring; (b) no hanja run anywhere in the
    sentence may DECODE to this reading via `Vocab.sub_lexicon` (built the
    same way extract_seeds.py builds it: hanja string of length>=2 whose
    hanja.txt reading is unique and length-matched) — this catches OTHER
    candidates for the same reading that (a) doesn't, e.g. a same-length
    hanja string that happens to be a valid alternate spelling.
  - Same reading, same page: at most ONE sentence (document-bias guard) —
    the FIRST sentence (in corpus order) that passes every other check wins;
    a page can still contribute sentences for OTHER readings.
  - Per reading: at most 8 sentences total, drawn via reservoir sampling
    (Algorithm R, `random.Random(20260731)`) over the whole corpus scan so
    the 8 kept sentences are uniform over every page that offered one, not
    just the first 8 encountered.

SPLIT: page-level (never reading-level, so a document's sentences never
straddle dev/test — 연구 문서 §5.1's per-family/per-document split
requirement). `split = "dev" if (sha256(page_id)[:8 bytes as big-endian int])
% 1000 < 400 else "test"` — a ~40/60 split, computed once per page and shared
by every sentence mined from it.

Usage — smoke run (see plan §9 D2 gate instructions; do NOT run the full
corpus until the smoke run is reviewed):
    python3 scripts/hanja-context/build_d2_mining.py --limit-pages 20000

Full corpus run (only after the smoke run is reviewed and approved):
    python3 scripts/hanja-context/build_d2_mining.py
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc
import extract_and_filter as ef
import extract_seeds as es

SEEDS_DIR = hc.WORK_DIR / "seeds"
D2_DIR = hc.WORK_DIR / "d2"
READING_SELECTION_TSV = D2_DIR / "reading-selection.tsv"
MINED_OUT = D2_DIR / "mined-sentences.tsv"
STATS_OUT = D2_DIR / "mining-stats.json"
REPORT_OUT = D2_DIR / "disjointness-report.md"

SEED_COLS = 13  # level,source,reading,hanja,page_id,family,span_start,span_len,in_target_inventory,is_ambiguous,residual_hanja,input_sentence,evidence

MIN_SENT_LEN = 20
MAX_SENT_LEN = 160
MAX_PER_READING = 8
MINING_SEED = 20260731
SPLIT_DEV_THRESHOLD_PER_MILLE = 400  # dev iff (hash % 1000) < 400 -> ~40% dev / 60% test
PROGRESS_EVERY_PAGES = 50_000

JOSA_EOMI_WORDS = (
    "은", "는", "이", "가", "을", "를", "의", "에서", "와", "과", "로", "도", "만",
    "부터", "까지", "처럼", "보다", "라고", "이나", "이라",
)
JOSA_EOMI_LEADING_CHARS = {w[0] for w in JOSA_EOMI_WORDS}
assert "".join(JOSA_EOMI_WORDS) == "은는이가을를의에서와과로도만부터까지처럼보다라고이나이라"


def is_space_or_punct(ch: str) -> bool:
    return ch.isspace() or ch in es.KOREAN_PUNCT_CHARS or es._is_punct(ch)


def boundary_ok(sentence: str, start: int, end: int) -> bool:
    before_ok = start == 0 or is_space_or_punct(sentence[start - 1])
    if not before_ok:
        return False
    if end == len(sentence):
        return True
    after_ch = sentence[end]
    return is_space_or_punct(after_ch) or after_ch in JOSA_EOMI_LEADING_CHARS


# ---------------------------------------------------------------------------
# Reading trie — finds every occurrence (not just the longest-at-position) of
# any selected reading, at every start position (no skip-ahead), since each
# occurrence needs its own boundary/leak check and distinct readings are
# independent signals here (unlike extract_and_filter.scan_anchors's
# flashtext-style single-longest-match-then-advance, which is the wrong
# semantics for "does reading R appear here").
# ---------------------------------------------------------------------------
class _ReadingTrieNode:
    __slots__ = ("children", "reading")

    def __init__(self) -> None:
        self.children: dict[str, "_ReadingTrieNode"] = {}
        self.reading: str | None = None


def build_reading_trie(readings: list[str]) -> _ReadingTrieNode:
    root = _ReadingTrieNode()
    for reading in readings:
        node = root
        for ch in reading:
            node = node.children.setdefault(ch, _ReadingTrieNode())
        node.reading = reading
    return root


def find_reading_occurrences(sentence: str, root: _ReadingTrieNode) -> list[tuple[str, int, int]]:
    """[(reading, start, end), ...] for every (start position, reading) where
    `reading` matches sentence[start:end] exactly. Checks every start
    position (a match doesn't block checking the next start position)."""
    hits: list[tuple[str, int, int]] = []
    n = len(sentence)
    for start in range(n):
        node = root
        idx = start
        while idx < n:
            child = node.children.get(sentence[idx])
            if child is None:
                break
            node = child
            idx += 1
            if node.reading is not None:
                hits.append((node.reading, start, idx))
    return hits


def sublexicon_leak(sentence: str, reading: str, vocab: "es.Vocab") -> bool:
    for m in es.HANJA_RUN_RE.finditer(sentence):
        run = m.group(0)
        if len(run) >= 2 and vocab.sub_lexicon.get(run) == reading:
            return True
    return False


def split_for_page(page_id: str) -> str:
    digest = hashlib.sha256(page_id.encode("utf-8")).digest()[:8]
    val = int.from_bytes(digest, "big")
    return "dev" if (val % 1000) < SPLIT_DEV_THRESHOLD_PER_MILLE else "test"


# ---------------------------------------------------------------------------
# reading-selection.tsv loader (Task 1's output)
# ---------------------------------------------------------------------------
def load_reading_selection(path: Path) -> dict[str, list[str]]:
    """reading -> list of candidate hanja strings (freq stripped)."""
    result: dict[str, list[str]] = {}
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 9:
                continue
            reading = cols[0]
            candidates_field = cols[8]
            candidates = [item.rpartition(":")[0] for item in candidates_field.split(",") if item]
            result[reading] = candidates
    return result


# ---------------------------------------------------------------------------
# D1 pages/families (Task 2 disjointness contract, step 1)
# ---------------------------------------------------------------------------
def compute_d1_exclusions(seeds_dir: Path) -> tuple[set[str], set[str]]:
    d1_pages: set[str] = set()
    d1_families: set[str] = set()
    for part in sorted(seeds_dir.glob("part-*.tsv")):
        with part.open(encoding="utf-8") as f:
            for line in f:
                if line.startswith("# format:") or not line.strip():
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) != SEED_COLS:
                    continue
                d1_pages.add(cols[4])
                d1_families.add(cols[5])
    return d1_pages, d1_families


class Row:
    __slots__ = ("reading", "page_id", "page_title", "split", "span_start", "span_len", "sentence")

    def __init__(self, reading, page_id, page_title, split, span_start, span_len, sentence) -> None:
        self.reading = reading
        self.page_id = page_id
        self.page_title = page_title
        self.split = split
        self.span_start = span_start
        self.span_len = span_len
        self.sentence = sentence


def reservoir_add(
    reading: str, row: Row, reservoirs: dict[str, list[Row]], seen_count: dict[str, int],
    rng: random.Random, cap: int,
) -> None:
    seen_count[reading] = seen_count.get(reading, 0) + 1
    n = seen_count[reading]
    reservoir = reservoirs.setdefault(reading, [])
    if len(reservoir) < cap:
        reservoir.append(row)
    else:
        j = rng.randint(0, n - 1)
        if j < cap:
            reservoir[j] = row


def process_page(
    title: str, page_id: str, raw_text: str, selected_readings: set[str],
    reading_candidates: dict[str, list[str]], vocab: "es.Vocab", trie: _ReadingTrieNode,
    reservoirs: dict[str, list[Row]], seen_count: dict[str, int], rng: random.Random,
    max_per_reading: int, counters: dict[str, int],
) -> None:
    cleaned = ef.strip_wiki_markup(raw_text)
    sentences = ef.split_sentences(cleaned)
    page_reading_seen: set[str] = set()
    page_split: str | None = None

    for sentence in sentences:
        counters["sentences_scanned"] += 1
        if not (MIN_SENT_LEN <= len(sentence) <= MAX_SENT_LEN):
            counters["sentences_reject_length"] += 1
            continue

        hits = find_reading_occurrences(sentence, trie)
        if not hits:
            continue

        first_by_reading: dict[str, tuple[int, int]] = {}
        for reading, start, end in hits:
            if reading not in first_by_reading:
                first_by_reading[reading] = (start, end)

        for reading, (start, end) in first_by_reading.items():
            if reading in page_reading_seen:
                counters["occurrence_reject_page_dedup"] += 1
                continue
            if sentence[start:end] != reading:
                counters["occurrence_reject_span_invariant"] += 1
                continue
            if not boundary_ok(sentence, start, end):
                counters["occurrence_reject_boundary"] += 1
                continue
            if any(cand and cand in sentence for cand in reading_candidates.get(reading, [])):
                counters["occurrence_reject_leak_candidate"] += 1
                continue
            if sublexicon_leak(sentence, reading, vocab):
                counters["occurrence_reject_leak_sublexicon"] += 1
                continue

            if page_split is None:
                page_split = split_for_page(page_id)
            page_reading_seen.add(reading)
            counters["occurrence_accepted"] += 1
            counters[f"occurrence_accepted_split_{page_split}"] += 1
            row = Row(
                reading=reading, page_id=page_id, page_title=title, split=page_split,
                span_start=start, span_len=end - start, sentence=sentence,
            )
            reservoir_add(reading, row, reservoirs, seen_count, rng, max_per_reading)


def verify_disjointness_independent(
    mined_path: Path, d1_pages: set[str], d1_families: set[str],
) -> tuple[int, int, int]:
    """Re-reads the WRITTEN output file (a separate code path from the
    generation-time page-exclusion check above) and checks every row's
    page_id / "t:"+page_title against D1_pages/D1_families. Returns
    (rows_checked, page_violations, family_violations)."""
    rows_checked = 0
    page_violations = 0
    family_violations = 0
    with mined_path.open(encoding="utf-8") as f:
        header = f.readline()
        assert header.startswith("# format:") or header.startswith("id\t")
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 8:
                continue
            _id, _reading, page_id, page_title, _split, _span_start, _span_len, _sentence = cols
            rows_checked += 1
            if page_id in d1_pages:
                page_violations += 1
            if ("t:" + page_title) in d1_families:
                family_violations += 1
    return rows_checked, page_violations, family_violations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit-bytes", type=int, default=None)
    parser.add_argument("--limit-pages", type=int, default=None)
    parser.add_argument("--corpus", type=Path, default=ef.CORPUS_PATH)
    parser.add_argument("--seeds-dir", type=Path, default=SEEDS_DIR)
    parser.add_argument("--reading-selection", type=Path, default=READING_SELECTION_TSV)
    parser.add_argument("--out-dir", type=Path, default=D2_DIR)
    parser.add_argument("--max-per-reading", type=int, default=MAX_PER_READING)
    parser.add_argument("--seed", type=int, default=MINING_SEED)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    mined_out = args.out_dir / "mined-sentences.tsv"
    stats_out = args.out_dir / "mining-stats.json"
    report_out = args.out_dir / "disjointness-report.md"

    log_path = args.out_dir / "mining.log"
    log_f = log_path.open("w", encoding="utf-8")

    def log(msg: str) -> None:
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
        print(line)
        log_f.write(line + "\n")
        log_f.flush()

    log(f"loading reading selection from {args.reading_selection} ...")
    reading_candidates = load_reading_selection(args.reading_selection)
    selected_readings = set(reading_candidates.keys())
    log(f"selected_readings={len(selected_readings)}")

    log(f"computing D1_pages/D1_families from {args.seeds_dir} ...")
    d1_pages, d1_families = compute_d1_exclusions(args.seeds_dir)
    log(f"D1_pages={len(d1_pages)} D1_families={len(d1_families)}")

    log("building vocabulary (Vocab: hanja_pairs/sub_lexicon/ambiguous_readings/target_readings) ...")
    vocab = es.Vocab()

    trie = build_reading_trie(sorted(selected_readings))

    counters: dict[str, int] = defaultdict(int)
    reservoirs: dict[str, list[Row]] = {}
    seen_count: dict[str, int] = {}
    rng = random.Random(args.seed)

    corpus_size = args.corpus.stat().st_size
    log(
        f"START corpus={args.corpus} size={corpus_size} limit_bytes={args.limit_bytes} "
        f"limit_pages={args.limit_pages}"
    )

    start_time = time.monotonic()
    completed_fully = False

    def log_progress(pos: int, note: str = "") -> None:
        elapsed = time.monotonic() - start_time
        page_rate = counters["pages_seen"] / elapsed if elapsed > 0 else 0.0
        byte_rate = pos / elapsed if elapsed > 0 else 0.0
        pct = pos / corpus_size * 100 if corpus_size else 0.0
        eta_min = (corpus_size - pos) / byte_rate / 60 if byte_rate > 0 else float("inf")
        log(
            f"{note}pages_seen={counters['pages_seen']} pages_excluded_page_id={counters['pages_excluded_page_id']} "
            f"pages_excluded_family={counters['pages_excluded_family']} "
            f"occurrence_accepted={counters['occurrence_accepted']} "
            f"pos={pos}/{corpus_size} ({pct:.1f}%) elapsed={elapsed:.1f}s "
            f"rate={page_rate:.0f} pages/s ({byte_rate / 1e6:.2f} MB/s) eta={eta_min:.1f}min"
        )

    try:
        with args.corpus.open("rb") as fh:
            context = ET.iterparse(fh, events=("start", "end"))
            _, root = next(context)
            for event, elem in context:
                if event != "end" or elem.tag != ef.PAGE_TAG:
                    continue
                counters["pages_seen"] += 1

                ns_el = elem.find(ef.NS_TAG)
                is_ns0 = ns_el is not None and (ns_el.text or "").strip() == "0"
                is_redirect = elem.find(ef.REDIRECT_TAG) is not None

                if not is_ns0 or is_redirect:
                    counters["pages_skipped_ns_or_redirect"] += 1
                    elem.clear()
                    root.clear()
                else:
                    id_el = elem.find(ef.ID_TAG)
                    page_id = (id_el.text or "").strip() if id_el is not None else ""
                    title_el = elem.find(es.TITLE_TAG)
                    title = (title_el.text or "") if title_el is not None else ""
                    page_family = "t:" + title

                    excluded = False
                    if page_id in d1_pages:
                        counters["pages_excluded_page_id"] += 1
                        excluded = True
                    if page_family in d1_families:
                        counters["pages_excluded_family"] += 1
                        excluded = True

                    if excluded:
                        counters["pages_excluded_total"] += 1
                        elem.clear()
                        root.clear()
                    else:
                        text_el = elem.find(ef.TEXT_PATH)
                        raw_text = (text_el.text or "") if text_el is not None else ""
                        elem.clear()
                        root.clear()
                        if raw_text and page_id:
                            counters["pages_mined_from"] += 1
                            process_page(
                                title, page_id, raw_text, selected_readings, reading_candidates,
                                vocab, trie, reservoirs, seen_count, rng, args.max_per_reading, counters,
                            )

                if counters["pages_seen"] % PROGRESS_EVERY_PAGES == 0:
                    log_progress(fh.tell())
                if args.limit_pages is not None and counters["pages_seen"] >= args.limit_pages:
                    log_progress(fh.tell(), note=f"[STOP --limit-pages={args.limit_pages}] ")
                    break
                if args.limit_bytes is not None and fh.tell() >= args.limit_bytes:
                    log_progress(fh.tell(), note=f"[STOP --limit-bytes={args.limit_bytes}] ")
                    break
            else:
                completed_fully = True
    finally:
        pass

    elapsed = time.monotonic() - start_time
    log(f"scan finished completed_fully={completed_fully} elapsed={elapsed:.1f}s")

    # -----------------------------------------------------------------
    # Write mined-sentences.tsv (span invariant re-checked here too, as a
    # final defensive gate — violations are dropped and counted, never
    # written).
    # -----------------------------------------------------------------
    span_violations_at_write = 0
    rows_written = 0
    seq = 0
    header = "# format: d2-mined-sentences v1 id<TAB>reading<TAB>page_id<TAB>page_title<TAB>split<TAB>span_start<TAB>span_len<TAB>sentence\n"
    with mined_out.open("w", encoding="utf-8") as f:
        f.write(header)
        for reading in sorted(reading_candidates.keys()):
            rows = reservoirs.get(reading, [])
            rows_sorted = sorted(rows, key=lambda r: (r.page_id, r.span_start))
            for row in rows_sorted:
                if row.sentence[row.span_start:row.span_start + row.span_len] != row.reading:
                    span_violations_at_write += 1
                    counters["span_invariant_violations_at_write"] += 1
                    continue
                seq += 1
                row_id = f"d2-{seq:06d}"
                cols = [
                    row_id, row.reading, row.page_id, row.page_title, row.split,
                    str(row.span_start), str(row.span_len), row.sentence,
                ]
                sanitized = [c.replace("\t", " ").replace("\n", " ").replace("\r", " ") for c in cols]
                f.write("\t".join(sanitized) + "\n")
                rows_written += 1
    log(f"wrote {mined_out}: rows_written={rows_written} span_violations_at_write={span_violations_at_write}")

    # -----------------------------------------------------------------
    # mining-stats.json
    # -----------------------------------------------------------------
    per_reading_mined_counts = {reading: len(reservoirs.get(reading, [])) for reading in sorted(reading_candidates.keys())}
    readings_under_quota = {
        reading: count for reading, count in per_reading_mined_counts.items() if count < args.max_per_reading
    }
    stats_out_dict = {
        "corpus_path": str(args.corpus),
        "corpus_size_bytes": corpus_size,
        "limit_bytes": args.limit_bytes,
        "limit_pages": args.limit_pages,
        "completed_fully": completed_fully,
        "elapsed_sec": elapsed,
        "max_per_reading": args.max_per_reading,
        "seed": args.seed,
        "selected_readings": len(selected_readings),
        "d1_pages": len(d1_pages),
        "d1_families": len(d1_families),
        "counters": dict(sorted(counters.items())),
        "rows_written": rows_written,
        "per_reading_mined_counts": per_reading_mined_counts,
        "readings_under_quota": readings_under_quota,
        "readings_zero_mined": sorted(r for r, c in per_reading_mined_counts.items() if c == 0),
    }
    with stats_out.open("w", encoding="utf-8") as f:
        json.dump(stats_out_dict, f, ensure_ascii=False, indent=2)
    log(f"wrote {stats_out}")

    # -----------------------------------------------------------------
    # disjointness-report.md — independent re-read verification (separate
    # code path from the generation-time pages_excluded_* counters above).
    # -----------------------------------------------------------------
    rows_checked, page_violations, family_violations = verify_disjointness_independent(mined_out, d1_pages, d1_families)
    report_lines = [
        "# D2 채굴 문장 불겹침 검증 보고서 (disjointness-report.md)\n",
        "## D1 배제 집합 크기\n",
        f"- D1_pages (seeds/part-*.tsv 5열 page_id, distinct): {len(d1_pages):,}",
        f"- D1_families (seeds/part-*.tsv 6열 family, distinct): {len(d1_families):,}",
        "",
        "## 생성 시 페이지 배제 카운트 (생성 경로)\n",
        f"- pages_seen: {counters['pages_seen']:,}",
        f"- pages_excluded_page_id (page_id ∈ D1_pages): {counters['pages_excluded_page_id']:,}",
        f"- pages_excluded_family (\"t:\"+title ∈ D1_families): {counters['pages_excluded_family']:,}",
        f"- pages_excluded_total (union, dedup 후 실제 스킵된 페이지 수): {counters['pages_excluded_total']:,}",
        f"- pages_mined_from (본문 추출 대상이 된 페이지 수): {counters['pages_mined_from']:,}",
        "",
        "## 독립 재검증 (산출된 mined-sentences.tsv를 다시 읽어 수행 — 생성 시 카운터와 별개 코드 경로)\n",
        f"- 검증 대상 행 수: {rows_checked:,}",
        f"- page_id ∈ D1_pages 위반: **{page_violations:,}**",
        f"- \"t:\"+page_title ∈ D1_families 위반: **{family_violations:,}**",
        "",
        (
            "재검증 결과가 위 두 위반 수 모두 0이면, 산출된 채굴 문장 집합에 D1 씨앗이 사용한 "
            "페이지·family가 전혀 섞이지 않았다는 뜻이다 — 이 확인은 mining-stats.json의 생성 시 "
            "카운터를 신뢰하지 않고, 최종 산출 파일 자체를 다시 읽어 독립적으로 수행했다."
        ),
        "",
        "## span 불변식\n",
        f"- span_invariant_violations_at_write (버려진 행 수): {span_violations_at_write:,}",
    ]
    with report_out.open("w", encoding="utf-8") as f:
        f.write("\n".join(report_lines) + "\n")
    log(f"wrote {report_out}")

    log(
        f"FINISHED rows_written={rows_written} span_invariant_violations_total={span_violations_at_write} "
        f"disjointness_page_violations={page_violations} disjointness_family_violations={family_violations}"
    )
    log_f.close()

    print(f"span_invariant_violations_total={span_violations_at_write}")
    print(f"disjointness_page_violations={page_violations} disjointness_family_violations={family_violations}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
