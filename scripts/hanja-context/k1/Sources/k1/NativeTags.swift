// Native-tag detection — the POS-category fix (coordinator review, Part 3 task A).
//
// Bug being fixed: kiwi_builder_add_alias_word_with_def takes ONE pos for both the alias
// (the reading itself) and the donor lookup. The original build-donors pipeline let ANY donor's
// own analyzed tag decide the registration pos — so a NIKL donor tagged VA/VV/MAG/XR caused the
// READING ITSELF to be registered as a verb/adjective/adverb/root, a category error (target
// readings are 한자어 nouns). The fix: register a candidate ONLY under a POS the reading itself
// natively carries in the bundled model — never fall back across POS to accommodate a donor.
//
// Methodology note: an earlier version of this file inferred "native tag" from sentence-level
// analyze() of the bare reading string (topN up to 10), but that picks up OOV rule-based tag
// GUESSES (e.g. 정부/NNP surfaced at rank 6 purely from the character-level unknown-word model,
// with a score ~13 nats below the real NNG entry) as if they were real dictionary entries —
// wildly overcounting "native NNP" (44% of readings, clearly wrong for a 한자어 noun domain) and
// re-introducing exactly the hijack risk the fix is meant to remove. kiwi_find_morphemes is a
// direct DICTIONARY lookup (bypasses sentence analysis and its OOV fallback entirely), so it
// answers "does this exact (form, tag) exist as a real morpheme" cleanly — verified against
// register-probe's known cases (서울: NNG=2, NNP=1, i.e. genuinely both; 수도/사과/정도/학교/정부:
// NNG only; 전기/공사/경기/이상/대전: genuinely both).
import CKiwi
import Foundation

/// The reading's own native POS tag(s), from a direct dictionary lookup (kiwi_find_morphemes,
/// sense_id=-1 i.e. any sense) rather than sentence analysis. Falls back to {NNG} — a documented
/// ASSUMPTION, not a discovered fact, since 한자어 target readings are overwhelmingly common nouns
/// — only when the reading exists as neither NNG nor NNP in the model at all (reported separately
/// as `fallbackCount` so it's auditable).
func computeNativeTags(_ readings: [String], kiwi: KiwiRaw) -> (tags: [String: Set<String>], fallbackCount: Int) {
    var result: [String: Set<String>] = [:]
    var fallbackCount = 0
    for reading in readings {
        var tags = Set<String>()
        for tag in ["NNG", "NNP"] {
            var morphIds = [UInt32](repeating: 0, count: 1)
            let count = kiwi_find_morphemes(kiwi.handle, reading, tag, -1, &morphIds, 1)
            if count > 0 { tags.insert(tag) }
        }
        if tags.isEmpty {
            tags = ["NNG"]
            fallbackCount += 1
        }
        result[reading] = tags
    }
    return (result, fallbackCount)
}
