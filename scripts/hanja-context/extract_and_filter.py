#!/usr/bin/env python3
"""Step 5a JOB 2 — corpus extraction + filtering (문맥 기반 한자 변환).

Single streaming pass over the Korean Wikipedia XML dump
(kowiki-latest-pages-articles.xml — dbname kowiki, generator MediaWiki
1.47.0-wmf.4, file date 2026-06-29, license CC BY-SA). Writes ONLY the
sentences that carry usable context-association signal — never the
raw/unfiltered corpus. See README.md for the full pipeline contract (corpus
identity, license, run commands, output format).

A sentence is kept iff EITHER holds:
  (a) 병기 — contains a validated "한글(漢字)" pair: the trailing suffix of
      the hangul run (same length as the parenthesized hanja run) is a
      dictionary reading for that hanja (hanja.txt) AND that suffix reading
      is one of our ambiguous target readings (inventory/targets.tsv).
  (b) anchor — contains >=1 anchor reading (inventory/anchors.tsv, distinct
      readings) as a substring, found via a small trie (flashtext-style:
      longest match at each start position, then advance past it).

Usage — throughput measurement first (see plan §7 5a gate instructions),
on the first ~200MB:
    python3 scripts/hanja-context/extract_and_filter.py --limit-bytes 200000000

Full corpus run (tens of minutes expected — launch with Bash
run_in_background, poll extract.log / the filtered/ dir periodically):
    python3 scripts/hanja-context/extract_and_filter.py

Writes:
    .../work/hanja-context/filtered/part-NNNN.txt  (kind<TAB>sentence, rotated every 200k lines)
    .../work/hanja-context/extract-stats.json      (counts + gate-preview table + thin-signal flags)
    .../work/hanja-context/extract.log             (progress log, every 50k pages)
    .../work/hanja-context/DONE                    (marker, only written on a full uninterrupted pass)
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hanja_common as hc

CORPUS_PATH = Path("/Volumes/Workbench/wooriHanjaModel/data/kowiki-latest-pages-articles.xml")

MEDIAWIKI_NS = "{http://www.mediawiki.org/xml/export-0.11/}"
PAGE_TAG = MEDIAWIKI_NS + "page"
NS_TAG = MEDIAWIKI_NS + "ns"
REDIRECT_TAG = MEDIAWIKI_NS + "redirect"
TEXT_PATH = MEDIAWIKI_NS + "revision/" + MEDIAWIKI_NS + "text"

ROTATE_EVERY_LINES = 200_000
PROGRESS_EVERY_PAGES = 50_000

HANGUL_RE = re.compile(r"[가-힣]")
PAREN_QUICK_RE = re.compile(r"[가-힣]\([一-鿿㐀-䶿]")
PAREN_FULL_RE = re.compile(r"([가-힣]+)\(([一-鿿㐀-䶿]+)\)")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")
HEADING_LINE_RE = re.compile(r"^[ \t]*=+.*=+[ \t]*$", re.MULTILINE)
LIST_MARKER_RE = re.compile(r"^[ \t]*(?:[*#:;]+[ \t]*)+")
URL_RE = re.compile(r"(?:https?://|www\.)\S+", re.IGNORECASE)
REF_SELF_CLOSING_RE = re.compile(r"<ref\b[^>]*/>", re.IGNORECASE)
REF_PAIRED_RE = re.compile(r"<ref\b[^>]*>.*?</ref>", re.IGNORECASE | re.DOTALL)
# Paired tags whose CONTENT is non-prose and must go with the tags (math
# formulas, source code, galleries, timelines) — REMAINING_TAG_RE alone would
# strip the tags but leak the content into "sentences".
NON_PROSE_TAG_RE = re.compile(
    r"<(math|code|syntaxhighlight|source|pre|score|timeline|gallery|nowiki|chem)\b[^>]*>.*?</\1\s*>",
    re.IGNORECASE | re.DOTALL,
)
REMAINING_TAG_RE = re.compile(r"<[^>]+>")
LINK_RE = re.compile(r"\[\[([^\[\]]*)\]\]")
FILE_CATEGORY_PREFIXES = ("파일:", "file:", "분류:")


# ---------------------------------------------------------------------------
# Wiki markup stripping
# ---------------------------------------------------------------------------

def remove_balanced(text: str, open_tok: str, close_tok: str) -> str:
    """Remove every balanced open_tok...close_tok span, handling nesting
    (used for {{ templates }} and {| tables |}). An unbalanced trailing open
    conservatively drops the rest of the string rather than risk leaking
    markup into a "sentence"."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        next_open = text.find(open_tok, i)
        if next_open == -1:
            out.append(text[i:])
            break
        out.append(text[i:next_open])
        depth = 1
        j = next_open + len(open_tok)
        while depth > 0:
            next_o = text.find(open_tok, j)
            next_c = text.find(close_tok, j)
            if next_c == -1:
                j = n
                break
            if next_o != -1 and next_o < next_c:
                depth += 1
                j = next_o + len(open_tok)
            else:
                depth -= 1
                j = next_c + len(close_tok)
        i = j
    return "".join(out)


def strip_file_and_category_links(text: str) -> str:
    """Remove [[파일:...]] / [[File:...]] / [[분류:...]] links entirely,
    including any nested [[...]] inside (e.g. a caption with its own link).
    Other [[...]] links are left untouched for simplify_links()."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        next_open = text.find("[[", i)
        if next_open == -1:
            out.append(text[i:])
            break
        out.append(text[i:next_open])
        inner_start = next_open + 2
        matched = any(
            text[inner_start : inner_start + len(p)].lower() == p
            for p in FILE_CATEGORY_PREFIXES
        )
        if not matched:
            out.append("[[")
            i = inner_start
            continue
        depth = 1
        j = inner_start
        while depth > 0:
            next_o = text.find("[[", j)
            next_c = text.find("]]", j)
            if next_c == -1:
                j = n
                break
            if next_o != -1 and next_o < next_c:
                depth += 1
                j = next_o + 2
            else:
                depth -= 1
                j = next_c + 2
        i = j
    return "".join(out)


def _link_replacer(match: "re.Match[str]") -> str:
    inner = match.group(1)
    target, sep, display = inner.partition("|")
    return display if sep else inner


def simplify_links(text: str) -> str:
    """[[a|b]] -> b, [[a]] -> a. Bounded iterations to resolve any residual
    (rare) nesting left after file/category stripping; stops as soon as a
    pass makes no change."""
    for _ in range(5):
        new_text = LINK_RE.sub(_link_replacer, text)
        if new_text == text:
            return new_text
        text = new_text
    return text


def strip_wiki_markup(text: str) -> str:
    text = remove_balanced(text, "{{", "}}")
    text = remove_balanced(text, "{|", "|}")
    # Self-closing refs MUST be stripped before paired refs: otherwise the
    # paired regex's opening-tag pattern `<ref\b[^>]*>` greedily treats a
    # self-closing ref's "/>" as its ">", then its non-greedy `.*?</ref>`
    # runs forward to the NEXT ref's closing tag, swallowing real sentence
    # text in between.
    text = REF_SELF_CLOSING_RE.sub("", text)
    text = REF_PAIRED_RE.sub("", text)
    text = NON_PROSE_TAG_RE.sub("", text)
    text = REMAINING_TAG_RE.sub("", text)
    text = strip_file_and_category_links(text)
    text = simplify_links(text)
    # Unbalanced link brackets that survived (source typos / truncated spans)
    # are markup debris — drop the tokens, keep the text.
    text = text.replace("[[", "").replace("]]", "")
    text = text.replace("'''", "").replace("''", "")
    text = HEADING_LINE_RE.sub("", text)
    text = URL_RE.sub("", text)
    text = html.unescape(text)
    return text


def split_sentences(text: str) -> list[str]:
    """Newline split, then (?<=[.!?])\\s+ split; keep fragments >=10 chars
    (after whitespace collapse) that contain hangul."""
    out = []
    for line in text.split("\n"):
        line = LIST_MARKER_RE.sub("", line)
        # Table-syntax / heading / formula remnants (malformed source markup
        # that survived the balanced-span removals) — never prose, drop whole line.
        if line.lstrip()[:1] in ("|", "!", "="):
            continue
        for frag in SENTENCE_SPLIT_RE.split(line):
            collapsed = " ".join(frag.split())
            if len(collapsed) >= 10 and HANGUL_RE.search(collapsed):
                out.append(collapsed)
    return out


# ---------------------------------------------------------------------------
# Target / anchor inventory loading. Local parsers (not added to
# hanja_common.py) — mirrors build_anchors.py's own local targets.tsv
# parser: hanja_common.py is the already-verified shared lib for the
# *dictionary* source files, not for these derived inventory outputs.
# ---------------------------------------------------------------------------

def load_targets(path: Path) -> dict[str, list[tuple[str, int]]]:
    """reading -> [(candidate_hanja, freq), ...] from targets.tsv."""
    targets: dict[str, list[tuple[str, int]]] = {}
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            reading, _total_freq, candidates_field = cols
            candidates = []
            for item in candidates_field.split(","):
                candidate, _, freq_str = item.rpartition(":")
                candidates.append((candidate, int(freq_str)))
            targets[reading] = candidates
    return targets


def load_anchor_attributions(path: Path) -> dict[str, list[tuple[str, str]]]:
    """anchor_reading -> [(target_reading, candidate_hanja), ...] from anchors.tsv."""
    result: dict[str, list[tuple[str, str]]] = {}
    with path.open(encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 5:
                continue
            target_reading, candidate_hanja, anchor_reading, _anchor_hanja, _anchor_freq = cols
            result.setdefault(anchor_reading, []).append((target_reading, candidate_hanja))
    return result


def load_hanja_pairs() -> set[tuple[str, str]]:
    """Set of all (reading, hanja) pairs in hanja.txt — reuses hanja_common's
    dictionary-line reader/parser rather than re-implementing it."""
    pairs: set[tuple[str, str]] = set()
    for line in hc.read_dictionary_lines():
        parsed = hc.parse_reading_hanja(line)
        if parsed is not None:
            pairs.add(parsed)
    return pairs


# ---------------------------------------------------------------------------
# Anchor trie (flashtext-style longest match, stdlib only)
# ---------------------------------------------------------------------------

class _TrieNode:
    __slots__ = ("children", "reading")

    def __init__(self) -> None:
        self.children: dict[str, "_TrieNode"] = {}
        self.reading: str | None = None


def build_trie(readings) -> _TrieNode:
    root = _TrieNode()
    for reading in readings:
        node = root
        for ch in reading:
            node = node.children.setdefault(ch, _TrieNode())
        node.reading = reading
    return root


def scan_anchors(sentence: str, root: _TrieNode) -> list[str]:
    """All anchor readings found as substrings of `sentence`. At each start
    position, walk the trie as far as possible and remember the longest
    complete reading seen; if one was found, advance past it (flashtext
    style), else advance by one character."""
    hits = []
    n = len(sentence)
    pos = 0
    while pos < n:
        node = root
        best_end = -1
        best_reading = None
        idx = pos
        while idx < n:
            child = node.children.get(sentence[idx])
            if child is None:
                break
            node = child
            idx += 1
            if node.reading is not None:
                best_end = idx
                best_reading = node.reading
        if best_reading is not None:
            hits.append(best_reading)
            pos = best_end
        else:
            pos += 1
    return hits


# ---------------------------------------------------------------------------
# Sentence classification
# ---------------------------------------------------------------------------

def classify_sentence(
    sentence: str,
    hanja_pairs: set[tuple[str, str]],
    target_readings: set[str],
    anchor_trie: _TrieNode,
    anchor_attrib: dict[str, list[tuple[str, str]]],
    paren_counts: dict[str, dict[str, int]],
    anchor_counts_by_reading: dict[str, int],
    anchor_counts_by_pair: dict[str, dict[str, int]],
) -> str | None:
    """Returns 'paren' / 'anchor' / 'both' / None (drop). Side effect:
    increments the count dicts passed in (module-level stats accumulation)."""
    is_paren = False
    if PAREN_QUICK_RE.search(sentence):
        for m in PAREN_FULL_RE.finditer(sentence):
            hangul_run, hanja_str = m.group(1), m.group(2)
            if len(hangul_run) < len(hanja_str):
                continue
            s = hangul_run[-len(hanja_str):]
            if s in target_readings and (s, hanja_str) in hanja_pairs:
                is_paren = True
                bucket = paren_counts.setdefault(s, {})
                bucket[hanja_str] = bucket.get(hanja_str, 0) + 1

    is_anchor = False
    anchor_hits = scan_anchors(sentence, anchor_trie)
    if anchor_hits:
        hit_pairs: set[tuple[str, str]] = set()
        for reading in set(anchor_hits):
            for target_reading, candidate_hanja in anchor_attrib.get(reading, ()):
                hit_pairs.add((target_reading, candidate_hanja))
        if hit_pairs:
            is_anchor = True
            hit_readings: set[str] = set()
            for target_reading, candidate_hanja in hit_pairs:
                bucket = anchor_counts_by_pair.setdefault(target_reading, {})
                bucket[candidate_hanja] = bucket.get(candidate_hanja, 0) + 1
                hit_readings.add(target_reading)
            for target_reading in hit_readings:
                anchor_counts_by_reading[target_reading] = anchor_counts_by_reading.get(target_reading, 0) + 1

    if is_paren and is_anchor:
        return "both"
    if is_paren:
        return "paren"
    if is_anchor:
        return "anchor"
    return None


# ---------------------------------------------------------------------------
# XML streaming
# ---------------------------------------------------------------------------

def extract_page_text(elem) -> tuple[bool, bool, str | None]:
    """(is_ns0, is_redirect, text_or_None) for a fully-parsed <page> element."""
    ns_el = elem.find(NS_TAG)
    is_ns0 = ns_el is not None and (ns_el.text or "").strip() == "0"
    is_redirect = elem.find(REDIRECT_TAG) is not None
    text = None
    if is_ns0 and not is_redirect:
        text_el = elem.find(TEXT_PATH)
        if text_el is not None:
            text = text_el.text or ""
    return is_ns0, is_redirect, text


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--limit-bytes", type=int, default=None,
        help="Stop after ~N bytes of the source file have been read (throughput measurement run).",
    )
    parser.add_argument(
        "--limit-pages", type=int, default=None,
        help="Stop after N <page> elements have been seen.",
    )
    parser.add_argument("--corpus", type=Path, default=CORPUS_PATH)
    args = parser.parse_args()

    hc.WORK_DIR.mkdir(parents=True, exist_ok=True)
    hc.FILTERED_DIR.mkdir(parents=True, exist_ok=True)
    for old in hc.FILTERED_DIR.glob("part-*.txt"):
        old.unlink()
    done_marker = hc.WORK_DIR / "DONE"
    if done_marker.exists():
        done_marker.unlink()

    targets = load_targets(hc.INVENTORY_DIR / "targets.tsv")
    target_readings = set(targets.keys())
    anchor_attrib = load_anchor_attributions(hc.INVENTORY_DIR / "anchors.tsv")
    anchor_trie = build_trie(anchor_attrib.keys())
    hanja_pairs = load_hanja_pairs()
    eval_readings = hc.load_eval_readings()

    anchors_tsv_count_by_pair: dict[tuple[str, str], int] = {}
    for _anchor_reading, pairs in anchor_attrib.items():
        for pair in pairs:
            anchors_tsv_count_by_pair[pair] = anchors_tsv_count_by_pair.get(pair, 0) + 1

    corpus_size = args.corpus.stat().st_size
    log_path = hc.WORK_DIR / "extract.log"
    log_f = log_path.open("w", encoding="utf-8")

    def log(msg: str) -> None:
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
        print(line)
        log_f.write(line + "\n")
        log_f.flush()

    log(
        f"START corpus={args.corpus} size={corpus_size} limit_bytes={args.limit_bytes} "
        f"limit_pages={args.limit_pages} targets={len(targets)} distinct_anchor_readings={len(anchor_attrib)}"
    )

    stats = {
        "pages_seen": 0,
        "pages_ns0_kept": 0,
        "pages_redirect_skipped": 0,
        "pages_non_ns0_skipped": 0,
        "sentences_scanned": 0,
        "sentences_kept_paren": 0,
        "sentences_kept_anchor": 0,
        "sentences_kept_both": 0,
    }
    paren_counts: dict[str, dict[str, int]] = {}
    anchor_counts_by_reading: dict[str, int] = {}
    anchor_counts_by_pair: dict[str, dict[str, int]] = {}

    part_index = 0
    lines_in_part = 0
    out_f = None

    def open_next_part() -> None:
        nonlocal out_f, lines_in_part
        if out_f is not None:
            out_f.close()
        part_path = hc.FILTERED_DIR / f"part-{part_index:04d}.txt"
        out_f = part_path.open("w", encoding="utf-8")
        lines_in_part = 0

    open_next_part()

    start_time = time.monotonic()
    completed_fully = False

    def log_progress(pos: int, note: str = "") -> None:
        elapsed = time.monotonic() - start_time
        page_rate = stats["pages_seen"] / elapsed if elapsed > 0 else 0.0
        byte_rate = pos / elapsed if elapsed > 0 else 0.0
        pct = pos / corpus_size * 100 if corpus_size else 0.0
        eta_min = (corpus_size - pos) / byte_rate / 60 if byte_rate > 0 else float("inf")
        projected_total_min = corpus_size / byte_rate / 60 if byte_rate > 0 else float("inf")
        log(
            f"{note}pages_seen={stats['pages_seen']} ns0_kept={stats['pages_ns0_kept']} "
            f"redirect_skipped={stats['pages_redirect_skipped']} "
            f"sentences_scanned={stats['sentences_scanned']} "
            f"kept(paren/anchor/both)={stats['sentences_kept_paren']}/{stats['sentences_kept_anchor']}/{stats['sentences_kept_both']} "
            f"pos={pos}/{corpus_size} ({pct:.1f}%) elapsed={elapsed:.1f}s "
            f"rate={page_rate:.0f} pages/s ({byte_rate / 1e6:.2f} MB/s) "
            f"eta={eta_min:.1f}min projected_total={projected_total_min:.1f}min"
        )

    try:
        with args.corpus.open("rb") as fh:
            context = ET.iterparse(fh, events=("start", "end"))
            _, root = next(context)
            for event, elem in context:
                if event != "end" or elem.tag != PAGE_TAG:
                    continue
                stats["pages_seen"] += 1

                is_ns0, is_redirect, text = extract_page_text(elem)
                elem.clear()
                root.clear()

                if not is_ns0:
                    stats["pages_non_ns0_skipped"] += 1
                elif is_redirect:
                    stats["pages_redirect_skipped"] += 1
                else:
                    stats["pages_ns0_kept"] += 1
                    if text:
                        cleaned = strip_wiki_markup(text)
                        for sentence in split_sentences(cleaned):
                            stats["sentences_scanned"] += 1
                            kind = classify_sentence(
                                sentence, hanja_pairs, target_readings,
                                anchor_trie, anchor_attrib,
                                paren_counts, anchor_counts_by_reading, anchor_counts_by_pair,
                            )
                            if kind is None:
                                continue
                            stats[f"sentences_kept_{kind}"] += 1
                            out_f.write(f"{kind}\t{sentence}\n")
                            lines_in_part += 1
                            if lines_in_part >= ROTATE_EVERY_LINES:
                                part_index += 1
                                open_next_part()

                if stats["pages_seen"] % PROGRESS_EVERY_PAGES == 0:
                    log_progress(fh.tell())

                if args.limit_pages is not None and stats["pages_seen"] >= args.limit_pages:
                    log_progress(fh.tell(), note=f"[STOP --limit-pages={args.limit_pages}] ")
                    break
                if args.limit_bytes is not None and fh.tell() >= args.limit_bytes:
                    log_progress(fh.tell(), note=f"[STOP --limit-bytes={args.limit_bytes}] ")
                    break
            else:
                completed_fully = True
    finally:
        if out_f is not None:
            out_f.close()

    elapsed = time.monotonic() - start_time

    output_files = sorted(hc.FILTERED_DIR.glob("part-*.txt"))
    output_bytes = sum(f.stat().st_size for f in output_files)

    gate_preview: dict[str, list[dict]] = {}
    thin_signal_flags: list[dict] = []
    for reading in eval_readings:
        rows = []
        for candidate, _freq in targets.get(reading, []):
            anchors_tsv_n = anchors_tsv_count_by_pair.get((reading, candidate), 0)
            paren_n = paren_counts.get(reading, {}).get(candidate, 0)
            anchor_n = anchor_counts_by_pair.get(reading, {}).get(candidate, 0)
            total_obs = paren_n + anchor_n
            flagged = anchors_tsv_n <= 2 or total_obs < 20
            row = {
                "candidate": candidate,
                "anchors_tsv_count": anchors_tsv_n,
                "paren_validated_count": paren_n,
                "anchor_hit_sentences": anchor_n,
                "total_observations": total_obs,
                "thin_signal": flagged,
            }
            rows.append(row)
            if flagged:
                thin_signal_flags.append({"reading": reading, **row})
        gate_preview[reading] = rows

    stats_out = {
        "corpus_path": str(args.corpus),
        "corpus_size_bytes": corpus_size,
        "limit_bytes": args.limit_bytes,
        "limit_pages": args.limit_pages,
        "completed_fully": completed_fully,
        "elapsed_sec": elapsed,
        **stats,
        "output_files": len(output_files),
        "output_bytes": output_bytes,
        "eval27_series": {
            "anchor_hit_sentence_counts_by_reading": {
                r: anchor_counts_by_reading.get(r, 0) for r in eval_readings
            },
            "paren_validated_counts_by_candidate": {
                r: paren_counts.get(r, {}) for r in eval_readings
            },
        },
        "gate_preview": gate_preview,
        "thin_signal_flags": thin_signal_flags,
    }
    stats_path = hc.WORK_DIR / "extract-stats.json"
    with stats_path.open("w", encoding="utf-8") as f:
        json.dump(stats_out, f, ensure_ascii=False, indent=2)

    log(
        f"FINISHED completed_fully={completed_fully} elapsed={elapsed:.1f}s "
        f"pages_seen={stats['pages_seen']} sentences_scanned={stats['sentences_scanned']} "
        f"kept(paren/anchor/both)={stats['sentences_kept_paren']}/{stats['sentences_kept_anchor']}/{stats['sentences_kept_both']} "
        f"output_files={len(output_files)} output_bytes={output_bytes} "
        f"thin_signal_flags={len(thin_signal_flags)}"
    )

    if completed_fully:
        with done_marker.open("w", encoding="utf-8") as f:
            f.write(f"completed {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(json.dumps(stats, ensure_ascii=False) + "\n")

    log_f.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
