#!/usr/bin/env python3
"""Step D1 — wiki seed expansion + yield measurement (문맥 기반 한자 변환,
docs/plans/hanja-context-scaling-plan.md §8, docs/hanja-context-quality-scaling-research.md §2.1).

Single streaming pass over the Korean Wikipedia XML dump (same corpus as
extract_and_filter.py — kowiki-latest-pages-articles.xml, MediaWiki
export-0.11, 6,309,195,011 B, CC BY-SA, file date 2026-06-29). This is a
MEASUREMENT stage: it decides whether a teacher-model track is worth
entering by measuring how many high-precision (reading, hanja) seeds the
wiki actually contains beyond the existing 병기 rule. A low yield is a
valid, useful result — guards below are NOT tuned to inflate counts.

Reuses (imports, does not reimplement) hanja_common.py and
extract_and_filter.py: read_dictionary_lines/parse_reading_hanja/
candidates_by_reading/load_merged_frequency/WORK_DIR/INVENTORY_DIR from
hanja_common; strip_wiki_markup/split_sentences/PAREN_FULL_RE/MEDIAWIKI_NS/
PAGE_TAG/NS_TAG/REDIRECT_TAG/TEXT_PATH/load_targets/load_hanja_pairs from
extract_and_filter (import is side-effect-free — its main() is guarded).

Output: seeds/part-NNNN.tsv (rotated every 200,000 data rows). Each part
starts with a header comment line:

    # format: seeds-v1 level<TAB>source<TAB>reading<TAB>hanja<TAB>page_id<TAB>family<TAB>span_start<TAB>span_len<TAB>in_target_inventory<TAB>is_ambiguous<TAB>residual_hanja<TAB>input_sentence<TAB>evidence

Columns:
    level                token | type
    source               paren_strict | paren_ext | standalone | redirect | title | disambig | dislink
    reading               한글 reading (the label)
    hanja                 한자 string (the label)
    page_id               wiki dump numeric <id> of the source page
    family                t:<page title>, or t:<redirect target title with a
                          trailing " (…)" disambiguator stripped> for
                          redirect-derived pairs (연구 문서 §2.1-6) — keeps a
                          hanja redirect and the article it targets in one
                          train/dev/test split bucket
    span_start/span_len   Python character offsets into input_sentence that
                          select exactly `reading` (token rows only; -1/-1
                          for type rows, which have no sentence)
    in_target_inventory   1 if reading is one of inventory/targets.tsv's
                          readings, else 0 (tag only — never a filter here)
    is_ambiguous          1 if reading has >=2 distinct candidate hanja in
                          hanja.txt, else 0 (tag for paren rows; a hard
                          requirement — always 1 — for standalone rows)
    residual_hanja        count of hanja characters still present in
                          input_sentence after all substitutions (0 for
                          type rows, which have no input_sentence)
    input_sentence        the Hangul INPUT FORM — what a user would actually
                          have typed — tabs/newlines normalized to single
                          spaces; empty for type rows
    evidence              short human-readable justification (original
                          surface form, or "redirect 漢字 -> 한글" style note)

Also writes seeds/seed-extract-stats.json (page/sentence/emit counts, the
full reject-reason counter table, elapsed time, corpus path+size, params)
and seeds/seed-extract.log (progress every 50,000 pages).

Usage — 500MB calibration/smoke run (see docs/plans/hanja-context-scaling-plan.md
§8 D1 validation steps; do NOT run the full corpus until that smoke run is
reviewed):
    python3 scripts/hanja-context/extract_seeds.py --limit-bytes 500000000

Full corpus run (only after the smoke run is reviewed and approved):
    python3 scripts/hanja-context/extract_seeds.py
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
import time
import unicodedata
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc
import extract_and_filter as ef

SEEDS_DIR = hc.WORK_DIR / "seeds"
TITLE_TAG = ef.MEDIAWIKI_NS + "title"

ROTATE_EVERY_LINES = 200_000
PROGRESS_EVERY_PAGES = 50_000
SAMPLE_SEED = 20260725
SAMPLE_SIZE = 30

FORMAT_HEADER = (
    "# format: seeds-v1 level<TAB>source<TAB>reading<TAB>hanja<TAB>page_id<TAB>family<TAB>"
    "span_start<TAB>span_len<TAB>in_target_inventory<TAB>is_ambiguous<TAB>residual_hanja<TAB>"
    "input_sentence<TAB>evidence"
)

# ---------------------------------------------------------------------------
# Character classes (hanja class mirrors extract_and_filter.PAREN_FULL_RE's
# group(2) class exactly — CJK Unified + Ext-A, matches hanja.txt content).
# ---------------------------------------------------------------------------
HANJA_RUN_RE = re.compile(r"[一-鿿㐀-䶿]+")
HANJA_CHAR_RE = re.compile(r"[一-鿿㐀-䶿]")
HANGUL_RUN_RE = re.compile(r"[가-힣]+")
HANGUL_CHAR_RE = re.compile(r"[가-힣]")
KANA_RE = re.compile(r"[぀-ゟ゠-ヿ]")
LATIN_CHAR_RE = re.compile(r"[A-Za-z]")

BRACKET_PAIRS = [("(", ")"), ("（", "）"), ("《", "》"), ("〈", "〉"), ("「", "」"), ("『", "』"), ("[", "]")]
KOREAN_PUNCT_CHARS = set("·.,!?~…-—_:;\"'“”‘’()（）[]{}《》〈〉「」『』" + "　")

EXT_HEAD_RE = re.compile(r"([가-힣]+) ?([(（])")
LABEL_OK_RES = [
    re.compile(r"^\s*$"),
    re.compile(r"^[A-Za-z][A-Za-z .\-]{0,10}[:,]?\s*$"),
    re.compile(r"^(한자|漢字)\s*[:：]?\s*$"),
]
MAX_EXT_GROUP_LEN = 120
MAX_EXT_LABEL_PREFIX_LEN = 12

DISAMBIG_TITLE_SUFFIX = "(동음이의)"
DISAMBIG_BODY_MARKER = "{{동음이의"

WIKILINK_RE = re.compile(r"\[\[([^\[\]]*)\]\]")

TRAILING_DISAMBIGUATOR_RE = re.compile(r"\s*\([^()]*\)\s*$")


def strip_disambiguator(title: str) -> str:
    """Strip one trailing ' (…)' disambiguator, e.g. '장 (성씨)' -> '장'."""
    return TRAILING_DISAMBIGUATOR_RE.sub("", title)


# ---------------------------------------------------------------------------
# Vocabulary (built once at startup)
# ---------------------------------------------------------------------------

class Vocab:
    def __init__(self) -> None:
        lines = hc.read_dictionary_lines()
        self.hanja_pairs: set[tuple[str, str]] = ef.load_hanja_pairs()
        raw_candidates = hc.candidates_by_reading(lines)
        self.ambiguous_readings: set[str] = {
            r for r, vals in raw_candidates.items() if len(set(vals)) >= 2
        }
        targets = ef.load_targets(hc.INVENTORY_DIR / "targets.tsv")
        self.target_readings: set[str] = set(targets.keys())

        # sub_lexicon: hanja string (len>=2) -> unique length-matching reading.
        by_hanja: dict[str, set[str]] = {}
        for reading, hanja in self.hanja_pairs:
            if len(hanja) >= 2 and len(hanja) == len(reading):
                by_hanja.setdefault(hanja, set()).add(reading)
        self.sub_lexicon: dict[str, str] = {
            h: next(iter(rs)) for h, rs in by_hanja.items() if len(rs) == 1
        }


# ---------------------------------------------------------------------------
# Bracket masking (for the standalone extractor's "not inside any bracket
# group" guard) — independent depth scan per bracket-pair type, merged.
# ---------------------------------------------------------------------------

def build_bracket_mask(s: str) -> bytearray:
    mask = bytearray(len(s))
    for open_ch, close_ch in BRACKET_PAIRS:
        depth = 0
        start = -1
        for i, ch in enumerate(s):
            if ch == open_ch:
                if depth == 0:
                    start = i
                depth += 1
            elif ch == close_ch and depth > 0:
                depth -= 1
                if depth == 0:
                    for j in range(start, i + 1):
                        mask[j] = 1
    return mask


def mask_any(mask: bytearray, start: int, end: int) -> bool:
    return any(mask[start:end])


# ---------------------------------------------------------------------------
# paren_strict — reproduces today's rule exactly (extract_and_filter's
# classify_sentence 병기 branch), but emits the INPUT FORM (parenthetical
# deleted) instead of the raw sentence, and does not filter on
# target_readings (tags in_target_inventory instead).
# ---------------------------------------------------------------------------

class ParenMatch:
    __slots__ = ("del_start", "del_end", "read_start", "read_end", "reading", "hanja", "evidence")

    def __init__(self, del_start, del_end, read_start, read_end, reading, hanja, evidence):
        self.del_start = del_start
        self.del_end = del_end
        self.read_start = read_start
        self.read_end = read_end
        self.reading = reading
        self.hanja = hanja
        self.evidence = evidence


def find_paren_strict(sentence: str, vocab: Vocab, counters: dict[str, int]) -> list[ParenMatch]:
    out = []
    for m in ef.PAREN_FULL_RE.finditer(sentence):
        hangul_run, hanja_str = m.group(1), m.group(2)
        if len(hangul_run) < len(hanja_str):
            counters["paren_strict_reject_length_mismatch"] += 1
            continue
        suffix = hangul_run[-len(hanja_str):]
        if (suffix, hanja_str) not in vocab.hanja_pairs:
            counters["paren_strict_reject_not_pair"] += 1
            continue
        read_end = m.start(1) + len(hangul_run)
        read_start = read_end - len(suffix)
        # Deletion span = optional-nothing (strict pattern has no space) +
        # the "(hanja)" group itself, i.e. from end of hangul_run through
        # the closing paren inclusive.
        out.append(
            ParenMatch(
                del_start=read_end, del_end=m.end(0),
                read_start=read_start, read_end=read_end,
                reading=suffix, hanja=hanja_str,
                evidence=m.group(0),
            )
        )
    return out


def _label_prefix_ok(prefix: str) -> bool:
    if len(prefix) > MAX_EXT_LABEL_PREFIX_LEN:
        return False
    return any(rx.match(prefix) for rx in LABEL_OK_RES)


def find_paren_ext(
    sentence: str, vocab: Vocab, strict_spans: list[tuple[int, int]], counters: dict[str, int]
) -> list[ParenMatch]:
    out = []
    ext_spans: list[tuple[int, int]] = []
    for m in EXT_HEAD_RE.finditer(sentence):
        hangul_run = m.group(1)
        open_ch = m.group(2)
        close_ch = ")" if open_ch == "(" else "）"
        open_pos = m.start(2)
        depth = 0
        close_pos = -1
        for i in range(open_pos, len(sentence)):
            ch = sentence[i]
            if ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth == 0:
                    close_pos = i
                    break
        if close_pos == -1:
            continue  # unbalanced — not a candidate at all, not a reject
        overall_span = (m.start(1), close_pos + 1)
        if any(a < overall_span[1] and overall_span[0] < b for a, b in strict_spans):
            counters["paren_ext_skip_dup_of_strict"] += 1
            continue
        if any(a < overall_span[1] and overall_span[0] < b for a, b in ext_spans):
            continue  # already produced by an earlier head match in this sentence
        content = sentence[open_pos + 1:close_pos]
        if len(content) > MAX_EXT_GROUP_LEN:
            counters["paren_ext_reject_too_long"] += 1
            continue
        hm = HANJA_RUN_RE.search(content)
        if hm is None:
            continue  # no hanja in the group at all — not a candidate
        prefix = content[: hm.start()]
        if not _label_prefix_ok(prefix):
            counters["paren_ext_reject_group_shape"] += 1
            continue
        hanja_run = hm.group(0)
        if len(hangul_run) < len(hanja_run):
            counters["paren_ext_reject_length_mismatch"] += 1
            continue
        suffix = hangul_run[-len(hanja_run):]
        if (suffix, hanja_run) not in vocab.hanja_pairs:
            counters["paren_ext_reject_not_pair"] += 1
            continue
        read_end = m.end(1)
        read_start = read_end - len(suffix)
        ext_spans.append(overall_span)
        out.append(
            ParenMatch(
                del_start=read_end, del_end=close_pos + 1,
                read_start=read_start, read_end=read_end,
                reading=suffix, hanja=hanja_run,
                evidence=sentence[m.start(1):close_pos + 1],
            )
        )
    return out


def delete_spans(sentence: str, spans: list[tuple[int, int]]) -> tuple[str, Callable[[int], int]]:
    """Delete `spans` (list of (start,end), pre-sorted or not, non-overlapping)
    from sentence; return the resulting string and a position-mapping
    function old_index -> new_index (valid for indices that are NOT inside a
    deleted span — used here only for span boundaries that sit exactly at a
    deletion edge, never inside one)."""
    spans = sorted(spans)
    pieces = []
    cursor = 0
    # cumulative deleted length BEFORE each original position, as a sorted
    # list of (original_pos_where_deletion_starts, cumulative_len_after)
    boundaries: list[tuple[int, int]] = []
    cumulative = 0
    for start, end in spans:
        pieces.append(sentence[cursor:start])
        cursor = end
        cumulative += end - start
        boundaries.append((end, cumulative))
    pieces.append(sentence[cursor:])
    new_sentence = "".join(pieces)

    def map_pos(p: int) -> int:
        offset = 0
        for boundary_end, cum in boundaries:
            if boundary_end <= p:
                offset = cum
            else:
                break
        return p - offset

    return new_sentence, map_pos


# ---------------------------------------------------------------------------
# standalone — the worst-precision source; guards are the substance of D1.
# ---------------------------------------------------------------------------

class StandaloneCandidate:
    __slots__ = ("start", "end", "hanja", "reading")

    def __init__(self, start, end, hanja, reading):
        self.start = start
        self.end = end
        self.hanja = hanja
        self.reading = reading


def _has_partial_lexicon_match(run: str, vocab: Vocab) -> bool:
    n = len(run)
    for i in range(n):
        for j in range(i + 2, n + 1):
            if i == 0 and j == n:
                continue  # the whole run itself, not a "partial" match
            if run[i:j] in vocab.sub_lexicon:
                return True
    return False


def korean_context_ratio_ok(sentence: str) -> bool:
    hangul = 0
    hanja = 0
    denom = 0
    for ch in sentence:
        if ch.isspace():
            continue
        cat = None
        if HANGUL_CHAR_RE.match(ch):
            hangul += 1
            denom += 1
            continue
        if HANJA_CHAR_RE.match(ch):
            hanja += 1
            denom += 1
            continue
        if ch in KOREAN_PUNCT_CHARS or _is_punct(ch):
            continue
        denom += 1
    if denom == 0:
        return False
    return (hangul / denom) >= 0.5 and (hanja / denom) <= 0.20


def _is_punct(ch: str) -> bool:
    return unicodedata.category(ch).startswith("P")


def find_standalone_candidates(
    sentence: str, vocab: Vocab, mask: bytearray, counters: dict[str, int]
) -> list[StandaloneCandidate]:
    candidates: list[StandaloneCandidate] = []
    kana_present = bool(KANA_RE.search(sentence))
    ratio_ok = korean_context_ratio_ok(sentence)

    for m in HANJA_RUN_RE.finditer(sentence):
        start, end = m.span()
        run = m.group(0)

        if mask_any(mask, start, end):
            counters["standalone_reject_in_bracket"] += 1
            continue

        if len(run) < 2 or run not in vocab.sub_lexicon:
            if len(run) >= 2 and _has_partial_lexicon_match(run, vocab):
                counters["standalone_reject_partial_match"] += 1
            else:
                counters["standalone_reject_not_in_lexicon"] += 1
            continue

        reading = vocab.sub_lexicon[run]
        if reading not in vocab.ambiguous_readings:
            counters["standalone_reject_not_ambiguous"] += 1
            continue

        if not ratio_ok:
            counters["standalone_reject_korean_ratio"] += 1
            continue

        before_ch = sentence[start - 1] if start > 0 else ""
        after_ch = sentence[end] if end < len(sentence) else ""
        if before_ch and (HANJA_CHAR_RE.match(before_ch) or LATIN_CHAR_RE.match(before_ch) or KANA_RE.match(before_ch)):
            counters["standalone_reject_adjacency"] += 1
            continue
        if after_ch and (HANJA_CHAR_RE.match(after_ch) or LATIN_CHAR_RE.match(after_ch) or KANA_RE.match(after_ch)):
            counters["standalone_reject_adjacency"] += 1
            continue
        if after_ch and not (
            HANGUL_CHAR_RE.match(after_ch) or after_ch.isspace() or after_ch in KOREAN_PUNCT_CHARS or _is_punct(after_ch)
        ):
            counters["standalone_reject_adjacency"] += 1
            continue

        if kana_present:
            counters["standalone_reject_kana"] += 1
            continue

        candidates.append(StandaloneCandidate(start, end, run, reading))

    return candidates


def apply_leak_guard(
    sentence: str,
    candidates: list[StandaloneCandidate],
    vocab: Vocab,
    page_title: str,
    counters: dict[str, int],
) -> list[StandaloneCandidate]:
    if not candidates:
        return []
    # Provisional sentence: substitute ALL candidates (same length as their
    # hanja run by construction of sub_lexicon, so no offset shifts).
    chars = list(sentence)
    for c in candidates:
        chars[c.start:c.end] = list(c.reading)
    provisional = "".join(chars)

    accepted = []
    for c in candidates:
        if c.hanja in provisional:
            counters["standalone_reject_leak_gold"] += 1
            continue
        leaked_same_reading = False
        for hm in HANJA_RUN_RE.finditer(provisional):
            other_run = hm.group(0)
            if other_run == c.hanja:
                continue
            if vocab.sub_lexicon.get(other_run) == c.reading:
                leaked_same_reading = True
                break
        if leaked_same_reading:
            counters["standalone_reject_leak_same_reading"] += 1
            continue
        if c.hanja in page_title:
            counters["standalone_reject_leak_title"] += 1
            continue
        # Generalized adjacency leak (D1 part-2 coordinator fix): reject if the
        # reading text itself — not just a "(...)"-shaped annotation — sits
        # within ~1 character of the run on either side (allowing one
        # intervening character: a space, an open paren/bracket, etc.). This
        # catches bare juxtaposition glosses with no parentheses at all
        # (e.g. "천녀天女" -> "천녀천녀", "군상 群像" -> "군상 군상"), which the
        # original paren-shaped-only check missed.
        before = provisional[max(0, c.start - len(c.reading) - 1):c.start]
        after = provisional[c.end:c.end + len(c.reading) + 1]
        if c.reading in before or c.reading in after:
            counters["standalone_reject_leak_adjacent"] += 1
            continue
        accepted.append(c)
    return accepted


# ---------------------------------------------------------------------------
# Type-level extractors
# ---------------------------------------------------------------------------

def resolve_title_paren_pair(title: str, vocab: Vocab) -> tuple[str, str, bool] | None:
    """Returns (hangul, hanja, confirmed) or None. Judgment call: when the
    hangul base is longer than the bracketed hanja run (e.g. '진나라 (陳)'),
    try the length-matching SUFFIX first, then PREFIX, preferring whichever
    is a validated hanja.txt pair; if neither is validated, fall back to the
    suffix as a 'novel' guess (documented in the D1 report)."""
    m = re.match(r"^([가-힣]+) ?\(([^()]*)\)$", title)
    if not m:
        return None
    base, content = m.group(1), m.group(2)
    if len(content) > MAX_EXT_GROUP_LEN:
        return None
    hm = HANJA_RUN_RE.search(content)
    if hm is None:
        return None
    hanja_run = hm.group(0)
    if len(hanja_run) == 0 or len(hanja_run) > len(base):
        return None
    if len(base) == len(hanja_run):
        confirmed = (base, hanja_run) in vocab.hanja_pairs
        return base, hanja_run, confirmed
    suffix = base[-len(hanja_run):]
    prefix = base[: len(hanja_run)]
    suffix_confirmed = (suffix, hanja_run) in vocab.hanja_pairs
    prefix_confirmed = (prefix, hanja_run) in vocab.hanja_pairs
    if suffix_confirmed:
        return suffix, hanja_run, True
    if prefix_confirmed:
        return prefix, hanja_run, True
    return suffix, hanja_run, False


def resolve_redirect_pure_hanja(title: str, redirect_target: str, vocab: Vocab) -> tuple[str, str, bool] | None:
    """Redirect parse (a): title is pure hanja (len>=2), redirect target's
    base title (disambiguator stripped) is pure hangul of equal length."""
    if len(title) < 2 or not HANJA_RUN_RE.fullmatch(title):
        return None
    base = strip_disambiguator(redirect_target)
    if not HANGUL_RUN_RE.fullmatch(base) or len(base) != len(title):
        return None
    confirmed = (base, title) in vocab.hanja_pairs
    return base, title, confirmed


def resolve_title_pure_hanja(title: str, vocab: Vocab) -> tuple[str, str] | None:
    """title parse (a) (non-redirect): title is pure hanja and in
    sub_lexicon (unique length-matching reading) — see report for why this
    differs from the redirect parse (no second title string is available)."""
    if len(title) < 2 or not HANJA_RUN_RE.fullmatch(title):
        return None
    reading = vocab.sub_lexicon.get(title)
    if reading is None:
        return None
    return reading, title


# ---------------------------------------------------------------------------
# Row emission / writer state
# ---------------------------------------------------------------------------

class Writer:
    def __init__(self, out_dir: Path) -> None:
        self.out_dir = out_dir
        self.part_index = 0
        self.lines_in_part = 0
        self.f = None
        self._open_next()

    def _open_next(self) -> None:
        if self.f is not None:
            self.f.close()
        path = self.out_dir / f"part-{self.part_index:04d}.tsv"
        self.f = path.open("w", encoding="utf-8")
        self.f.write(FORMAT_HEADER + "\n")
        self.lines_in_part = 0

    def write_row(self, cols: list[str]) -> None:
        # Defense against a stray tab/newline in any field (e.g. input_sentence,
        # evidence) corrupting the TSV column count — also satisfies the
        # input_sentence "tabs/newlines normalized to single spaces" requirement.
        sanitized = [c.replace("\t", " ").replace("\n", " ").replace("\r", " ") for c in cols]
        self.f.write("\t".join(sanitized) + "\n")
        self.lines_in_part += 1
        if self.lines_in_part >= ROTATE_EVERY_LINES:
            self.part_index += 1
            self._open_next()

    def close(self) -> None:
        if self.f is not None:
            self.f.close()


class Emitter:
    def __init__(self, writer: Writer, vocab: Vocab, counters: dict[str, int]) -> None:
        self.writer = writer
        self.vocab = vocab
        self.counters = counters
        self.type_seen: set[tuple[str, str, str, str]] = set()
        self.samples: dict[str, list[list[str]]] = defaultdict(list)
        self.sample_seen: dict[str, int] = defaultdict(int)
        self.rng = random.Random(SAMPLE_SEED)
        self.span_violations = 0
        self.paren_strict_target_sentences: set[tuple[str, str]] = set()

    def emit_token(
        self, source: str, reading: str, hanja: str, page_id: str, family: str,
        span_start: int, span_len: int, input_sentence: str, evidence: str,
    ) -> None:
        actual = input_sentence[span_start:span_start + span_len]
        if actual != reading:
            self.span_violations += 1
            self.counters["span_invariant_violations"] += 1
            return
        in_target = 1 if reading in self.vocab.target_readings else 0
        is_amb = 1 if reading in self.vocab.ambiguous_readings else 0
        residual = len(HANJA_CHAR_RE.findall(input_sentence))
        cols = [
            "token", source, reading, hanja, page_id, family,
            str(span_start), str(span_len), str(in_target), str(is_amb),
            str(residual), input_sentence, evidence,
        ]
        self.writer.write_row(cols)
        self.counters[f"emit_{source}"] += 1
        if source == "paren_strict" and in_target:
            self.paren_strict_target_sentences.add((page_id, input_sentence))
        self._reservoir(source, cols, span_start, span_len)

    def emit_type(
        self, source: str, reading: str, hanja: str, page_id: str, family: str, evidence: str,
    ) -> None:
        key = (source, reading, hanja, family)
        if key in self.type_seen:
            self.counters[f"type_dedup_skipped_{source}"] += 1
            return
        self.type_seen.add(key)
        in_target = 1 if reading in self.vocab.target_readings else 0
        is_amb = 1 if reading in self.vocab.ambiguous_readings else 0
        cols = [
            "type", source, reading, hanja, page_id, family,
            "-1", "-1", str(in_target), str(is_amb), "0", "", evidence,
        ]
        self.writer.write_row(cols)
        self.counters[f"emit_{source}"] += 1
        self._reservoir(source, cols, None, None)

    def _reservoir(self, source: str, cols: list[str], span_start: int | None, span_len: int | None) -> None:
        self.sample_seen[source] += 1
        n = self.sample_seen[source]
        marked = cols[:]
        if span_start is not None and span_len is not None:
            sent = cols[11]
            marked_sentence = sent[:span_start] + "⟦" + sent[span_start:span_start + span_len] + "⟧" + sent[span_start + span_len:]
            marked = cols[:]
            marked[11] = marked_sentence
        bucket = self.samples[source]
        if len(bucket) < SAMPLE_SIZE:
            bucket.append(marked)
        else:
            j = self.rng.randint(0, n - 1)
            if j < SAMPLE_SIZE:
                bucket[j] = marked


# ---------------------------------------------------------------------------
# Per-sentence token-level processing
# ---------------------------------------------------------------------------

def process_sentence(sentence: str, page_id: str, page_title: str, family: str, vocab: Vocab, emitter: Emitter, counters: dict[str, int]) -> None:
    strict_matches = find_paren_strict(sentence, vocab, counters)
    # Overlap checks need the FULL match span (hangul run start through
    # close paren), not just the deletion span (which starts after the
    # hangul run) — paren_ext's own candidate spans include the hangul run.
    strict_full_spans = [(pm.read_start, pm.del_end) for pm in strict_matches]
    ext_matches = find_paren_ext(sentence, vocab, strict_full_spans, counters)

    tagged_paren_matches = [("paren_strict", pm) for pm in strict_matches] + [("paren_ext", pm) for pm in ext_matches]

    delete_list = [(pm.del_start, pm.del_end) for _source, pm in tagged_paren_matches]
    if delete_list:
        s1, map_pos = delete_spans(sentence, delete_list)
    else:
        s1, map_pos = sentence, (lambda p: p)

    mask = build_bracket_mask(s1)
    candidates = find_standalone_candidates(s1, vocab, mask, counters)
    accepted = apply_leak_guard(s1, candidates, vocab, page_title, counters)

    chars = list(s1)
    for c in accepted:
        chars[c.start:c.end] = list(c.reading)
    s_final = "".join(chars)

    for source_name, pm in tagged_paren_matches:
        emitter.emit_token(
            source_name, pm.reading, pm.hanja, page_id, family,
            map_pos(pm.read_start), len(pm.reading), s_final, pm.evidence,
        )

    for c in accepted:
        emitter.emit_token(
            "standalone", c.reading, c.hanja, page_id, family,
            c.start, len(c.reading), s_final,
            f"standalone {c.hanja}→{c.reading}",
        )

    counters["sentences_with_any_emit"] += 1 if (tagged_paren_matches or accepted) else 0


# ---------------------------------------------------------------------------
# Type-level page processing
# ---------------------------------------------------------------------------

def process_redirect_page(title: str, redirect_target: str | None, page_id: str, vocab: Vocab, emitter: Emitter, counters: dict[str, int]) -> None:
    if not redirect_target:
        return
    family = "t:" + strip_disambiguator(redirect_target)

    pair_a = resolve_redirect_pure_hanja(title, redirect_target, vocab)
    if pair_a is not None:
        hangul, hanja, confirmed = pair_a
        tag = "confirmed" if confirmed else "novel"
        emitter.emit_type(
            "redirect", hangul, hanja, page_id, family,
            f"redirect {hanja} -> {hangul} ({tag})",
        )
        counters[f"redirect_pure_hanja_{tag}"] += 1

    pair_b = resolve_title_paren_pair(title, vocab)
    if pair_b is not None:
        hangul, hanja, confirmed = pair_b
        tag = "confirmed" if confirmed else "novel"
        emitter.emit_type(
            "redirect", hangul, hanja, page_id, family,
            f"redirect title-paren {title} -> ({hangul},{hanja}) ({tag})",
        )
        counters[f"redirect_title_paren_{tag}"] += 1


def process_title_page(title: str, page_id: str, vocab: Vocab, emitter: Emitter, counters: dict[str, int]) -> None:
    family = "t:" + title

    pair_a = resolve_title_pure_hanja(title, vocab)
    if pair_a is not None:
        reading, hanja = pair_a
        emitter.emit_type(
            "title", reading, hanja, page_id, family,
            f"title {hanja} -> {reading} (confirmed, sub_lexicon)",
        )
        counters["title_pure_hanja_confirmed"] += 1

    pair_b = resolve_title_paren_pair(title, vocab)
    if pair_b is not None:
        hangul, hanja, confirmed = pair_b
        tag = "confirmed" if confirmed else "novel"
        emitter.emit_type(
            "title", hangul, hanja, page_id, family,
            f"title title-paren {title} -> ({hangul},{hanja}) ({tag})",
        )
        counters[f"title_title_paren_{tag}"] += 1


def process_disambig_page(title: str, raw_text: str, page_id: str, vocab: Vocab, emitter: Emitter, counters: dict[str, int]) -> None:
    family = "t:" + title
    cleaned = ef.strip_wiki_markup(raw_text)
    for line in cleaned.split("\n"):
        line = line.strip()
        if not line:
            continue
        counters["disambig_lines_scanned"] += 1
        strict_matches = find_paren_strict(line, vocab, counters)
        strict_full_spans = [(pm.read_start, pm.del_end) for pm in strict_matches]
        ext_matches = find_paren_ext(line, vocab, strict_full_spans, counters)
        for pm in strict_matches + ext_matches:
            emitter.emit_type(
                "disambig", pm.reading, pm.hanja, page_id, family,
                f"disambig line: {pm.evidence}",
            )


def process_dislink_page(title: str, raw_text: str, page_id: str, vocab: Vocab, emitter: Emitter, counters: dict[str, int]) -> None:
    family = "t:" + title
    for m in WIKILINK_RE.finditer(raw_text):
        inner = m.group(1)
        if "|" not in inner:
            continue
        parts = inner.split("|")
        if len(parts) != 2:
            continue
        side1, side2 = parts[0].strip(), parts[1].strip()
        if not side1 or not side2:
            continue
        counters["dislink_candidates_seen"] += 1
        is_hanja1 = bool(HANJA_RUN_RE.fullmatch(side1))
        is_hanja2 = bool(HANJA_RUN_RE.fullmatch(side2))
        is_hangul1 = bool(HANGUL_RUN_RE.fullmatch(side1))
        is_hangul2 = bool(HANGUL_RUN_RE.fullmatch(side2))
        if is_hanja1 and is_hangul2 and len(side1) == len(side2):
            hanja, hangul = side1, side2
        elif is_hanja2 and is_hangul1 and len(side1) == len(side2):
            hanja, hangul = side2, side1
        else:
            counters["dislink_reject_shape"] += 1
            continue
        confirmed = (hangul, hanja) in vocab.hanja_pairs
        tag = "confirmed" if confirmed else "novel"
        emitter.emit_type(
            "dislink", hangul, hanja, page_id, family,
            f"[[{inner}]] ({tag})",
        )
        counters[f"dislink_{tag}"] += 1


# ---------------------------------------------------------------------------
# XML streaming main loop
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--limit-bytes", type=int, default=None)
    parser.add_argument("--limit-pages", type=int, default=None)
    parser.add_argument("--corpus", type=Path, default=ef.CORPUS_PATH)
    parser.add_argument("--out-dir", type=Path, default=SEEDS_DIR)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for old in args.out_dir.glob("part-*.tsv"):
        old.unlink()

    log_path = args.out_dir / "seed-extract.log"
    log_f = log_path.open("w", encoding="utf-8")

    def log(msg: str) -> None:
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
        print(line)
        log_f.write(line + "\n")
        log_f.flush()

    log("Building vocabulary (sub_lexicon, hanja_pairs, ambiguous_readings, target_readings)...")
    vocab = Vocab()
    log(
        f"vocab: hanja_pairs={len(vocab.hanja_pairs)} sub_lexicon={len(vocab.sub_lexicon)} "
        f"ambiguous_readings={len(vocab.ambiguous_readings)} target_readings={len(vocab.target_readings)}"
    )

    counters: dict[str, int] = defaultdict(int)
    writer = Writer(args.out_dir)
    emitter = Emitter(writer, vocab, counters)

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
            f"{note}pages_seen={counters['pages_seen']} ns0_kept={counters['pages_ns0_kept']} "
            f"redirect={counters['pages_redirect_seen']} sentences_scanned={counters['sentences_scanned']} "
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
                if not is_ns0:
                    counters["pages_non_ns0_skipped"] += 1
                    elem.clear()
                    root.clear()
                else:
                    id_el = elem.find(ef.ID_TAG)
                    page_id = (id_el.text or "").strip() if id_el is not None else ""
                    title_el = elem.find(TITLE_TAG)
                    title = (title_el.text or "") if title_el is not None else ""
                    redirect_el = elem.find(ef.REDIRECT_TAG)
                    is_redirect = redirect_el is not None
                    redirect_target = redirect_el.get("title") if is_redirect else None

                    if is_redirect:
                        counters["pages_redirect_seen"] += 1
                        process_redirect_page(title, redirect_target, page_id, vocab, emitter, counters)
                        elem.clear()
                        root.clear()
                    else:
                        counters["pages_ns0_kept"] += 1
                        text_el = elem.find(ef.TEXT_PATH)
                        raw_text = (text_el.text or "") if text_el is not None else ""
                        elem.clear()
                        root.clear()

                        family = "t:" + title
                        process_title_page(title, page_id, vocab, emitter, counters)
                        process_dislink_page(title, raw_text, page_id, vocab, emitter, counters)
                        if title.endswith(DISAMBIG_TITLE_SUFFIX) or (raw_text and DISAMBIG_BODY_MARKER in raw_text):
                            process_disambig_page(title, raw_text, page_id, vocab, emitter, counters)

                        cleaned = ef.strip_wiki_markup(raw_text)
                        for sentence in ef.split_sentences(cleaned):
                            counters["sentences_scanned"] += 1
                            process_sentence(sentence, page_id, title, family, vocab, emitter, counters)

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
        writer.close()

    elapsed = time.monotonic() - start_time
    output_files = sorted(args.out_dir.glob("part-*.tsv"))
    output_bytes = sum(f.stat().st_size for f in output_files)

    stats_out = {
        "corpus_path": str(args.corpus),
        "corpus_size_bytes": corpus_size,
        "limit_bytes": args.limit_bytes,
        "limit_pages": args.limit_pages,
        "completed_fully": completed_fully,
        "elapsed_sec": elapsed,
        "counters": dict(sorted(counters.items())),
        "span_invariant_violations": emitter.span_violations,
        "paren_strict_target_sentences_distinct": len(emitter.paren_strict_target_sentences),
        "output_files": len(output_files),
        "output_bytes": output_bytes,
        "vocab": {
            "hanja_pairs": len(vocab.hanja_pairs),
            "sub_lexicon": len(vocab.sub_lexicon),
            "ambiguous_readings": len(vocab.ambiguous_readings),
            "target_readings": len(vocab.target_readings),
        },
    }
    stats_path = args.out_dir / "seed-extract-stats.json"
    with stats_path.open("w", encoding="utf-8") as f:
        json.dump(stats_out, f, ensure_ascii=False, indent=2)

    samples_path = args.out_dir / "seed-samples.json"
    with samples_path.open("w", encoding="utf-8") as f:
        json.dump({k: v for k, v in emitter.samples.items()}, f, ensure_ascii=False, indent=2)

    log(
        f"FINISHED completed_fully={completed_fully} elapsed={elapsed:.1f}s "
        f"pages_seen={counters['pages_seen']} sentences_scanned={counters['sentences_scanned']} "
        f"output_files={len(output_files)} output_bytes={output_bytes} "
        f"paren_strict_target_sentences_distinct={len(emitter.paren_strict_target_sentences)} "
        f"span_invariant_violations={emitter.span_violations}"
    )
    log_f.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
