#!/usr/bin/env python3
"""Validate a human D2 review and score it without modifying the submitted TSV or AI labels."""
import argparse
import csv
import hashlib
import json
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

from compare_auto_conversion_policies import automatic_value, evaluate_policy


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_tsv(path):
    with Path(path).open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader((line for line in stream if not line.startswith('#')), delimiter='\t'))


def index_rows(rows):
    indexed = {}
    for row in rows:
        if not row.get('id') or row['id'] in indexed:
            raise ValueError(f"Missing or duplicate ID: {row.get('id')}")
        indexed[row['id']] = row
    return indexed


def normalize_review(submitted, neutral, clarification):
    source = index_rows(submitted)
    expected = index_rows(neutral)
    if source.keys() != expected.keys():
        raise ValueError('Submitted IDs must exactly match the neutral review sheet')
    overrides = clarification.get('rows', {})
    if not overrides.keys() <= source.keys():
        raise ValueError('Clarification contains unknown IDs')
    labels, warnings = [], []
    for id_, row in source.items():
        for field in ('reading', 'sentence'):
            if row[field] != expected[id_][field]:
                raise ValueError(f'{id_}: {field} differs from neutral sheet')
        override = overrides.get(id_, {})
        if set(override) - {'category', 'allow_hangul', 'confirmation'}:
            raise ValueError(f'{id_}: unsupported clarification field')
        category = override.get('category', row['category'].strip())
        if category not in ('U', 'M', 'K', '?'):
            raise ValueError(f'{id_}: missing or invalid category')
        answer = row['answer'].strip()
        supplied = [v.strip() for v in row['acceptable'].split(',') if v.strip()]
        acceptable = list(dict.fromkeys(([answer] if answer else []) + supplied))
        allow_hangul = override.get('allow_hangul', False)
        if type(allow_hangul) is not bool:
            raise ValueError(f'{id_}: allow_hangul must be Boolean')
        if category in ('U', 'M'):
            if not answer:
                raise ValueError(f'{id_}: U/M requires a primary answer')
            if row['reading'] in acceptable and not allow_hangul:
                raise ValueError(f'{id_}: mixed Hangul/Hanja needs explicit confirmation')
            if allow_hangul and (category != 'M' or row['reading'] not in acceptable or
                                 not set(acceptable) - {row['reading']}):
                raise ValueError(f'{id_}: mixed M requires both Hangul and Hanja outputs')
            if category == 'U' and len(acceptable) != 1:
                raise ValueError(f'{id_}: U must have exactly one acceptable output')
            if category == 'M' and len(acceptable) < 2:
                raise ValueError(f'{id_}: M must have at least two acceptable outputs')
            if category == 'M' and answer not in supplied:
                warnings.append(dict(id=id_, issue='primary_answer_included_in_acceptable_set'))
        elif answer or acceptable or allow_hangul:
            raise ValueError(f'{id_}: K/? must not contain answer outputs')
        if category == '?' and not row['uncertainty_reason'].strip():
            warnings.append(dict(id=id_, issue='uncertainty_reason_not_supplied'))
        labels.append(dict(id=id_, reading=row['reading'], sentence=row['sentence'],
            category=category, source_category=row['category'], answer=answer,
            acceptable=acceptable, allow_hangul=allow_hangul,
            uncertainty_reason=row['uncertainty_reason'].strip(), reviewer=row['reviewer'].strip(),
            clarification=override.get('confirmation', '')))
    return labels, warnings


def write_tsv(path, rows, fields):
    with Path(path).open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter='\t', extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def audit_rows(labels, results, ai_labels, dictionary):
    audit = []
    for label in labels:
        id_ = label['id']
        result = results[id_]
        if result['reading'] != label['reading']:
            raise ValueError(f'{id_}: result reading differs from review')
        accepted = set(label['acceptable'])
        hanja = accepted - {label['reading']}
        available = dictionary[label['reading']]
        equivalent = {unicodedata.normalize('NFKC', value) for value in available}
        missing = hanja - available
        variant = {value for value in missing if unicodedata.normalize('NFKC', value) in equivalent}
        panel = result['panel_candidates'] if result['seg_ok'] else []
        automatic = automatic_value(result, 'current')
        judged = label['category'] != '?'
        if not judged:
            outcome = 'excluded_uncertain'
        elif automatic:
            outcome = 'correct_auto' if automatic in accepted else 'incorrect_auto'
        else:
            outcome = 'acceptable_hold' if label['category'] == 'K' or label['allow_hangul'] else 'held_hanja_required'
        old = ai_labels[id_]
        old_set = set(filter(None, (old['주정답']+','+old['허용집합']).split(',')))
        audit.append(dict(id=id_, reading=label['reading'], category=label['category'],
            allow_hangul=int(label['allow_hangul']), acceptable=','.join(label['acceptable']),
            split=result['split'], seg_ok=int(result['seg_ok']), panel_top1=panel[0] if panel else '',
            panel_top3=','.join(panel[:3]), panel_top1_correct=int(bool(panel and panel[0] in hanja)),
            panel_top3_correct=int(bool(hanja.intersection(panel[:3]))),
            auto_value=automatic, hold_reason=result['hold_reason'], outcome=outcome,
            strict_auto_value=automatic_value(result, 'positive_context_and_no_tie'),
            dictionary_missing=','.join(sorted(missing)), compatibility_variant=','.join(sorted(variant)),
            dictionary_gap_unmatched=','.join(sorted(missing-variant)),
            ai_category=old['판정범주'], category_matches_ai=int(label['category'] == old['판정범주']),
            acceptable_set_matches_ai=int(accepted == old_set), sentence=label['sentence']))
    return audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'neutral', 'clarifications', 'results', 'ai-labels', 'dictionary', 'output-dir'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    clarification = json.loads(args.clarifications.read_text())
    if clarification['source_sha256'] != sha256(args.source):
        raise ValueError('Clarifications do not match the submitted source hash')
    labels, warnings = normalize_review(read_tsv(args.source), read_tsv(args.neutral), clarification)
    results = index_rows([json.loads(line) for line in args.results.read_text().splitlines() if line])
    ai_labels = index_rows(read_tsv(args.ai_labels))
    dictionary = defaultdict(set)
    for line in args.dictionary.read_text().splitlines():
        parts = line.split(':', 2)
        if not line.startswith('#') and len(parts) >= 2:
            dictionary[parts[0]].add(parts[1])
    audit = audit_rows(labels, results, ai_labels, dictionary)
    hanja_only = [r for r in audit if r['category'] in ('U', 'M') and not r['allow_hangul']]
    policies = {policy: evaluate_policy(labels, results, policy)
                for policy in ('current', 'positive_context_and_no_tie')}
    summary = dict(label_provenance='User-submitted human review plus explicit chat clarifications',
        scope='73 previously sampled D2 development rows; not an unseen generalization test. '
              'No user personalization or session history. Exact output matching; Unicode variants are audit flags only.',
        rows=len(labels), category_counts=dict(Counter(r['category'] for r in labels)),
        judged_rows=sum(r['category'] != '?' for r in labels), excluded_uncertain=sum(r['category'] == '?' for r in labels),
        mixed_hangul_hanja_rows=sum(r['allow_hangul'] for r in labels),
        missing_reviewer_rows=sum(not r['reviewer'] for r in labels),
        hanja_only_panel=dict(rows=len(hanja_only), top1=sum(r['panel_top1_correct'] for r in hanja_only),
            top3=sum(r['panel_top3_correct'] for r in hanja_only), exact_segmentation=sum(r['seg_ok'] for r in hanja_only)),
        outcomes=dict(Counter(r['outcome'] for r in audit)),
        category_agreement_with_AI=sum(r['category_matches_ai'] for r in audit),
        exact_acceptable_set_agreement_with_AI=sum(r['acceptable_set_matches_ai'] for r in audit),
        dictionary_gap_rows=[r['id'] for r in audit if r['dictionary_gap_unmatched']],
        compatibility_variant_rows=[r['id'] for r in audit if r['compatibility_variant']],
        policies=policies, warnings=warnings,
        decision='Retain current app policy. Reviewed development sample has only three K rows; '
                 'do not tune thresholds on existing test rows or claim 99% precision.')
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)
    # All validation precedes output; never overwrite the human source or existing AI labels.
    for target in ('submitted.tsv', 'labels.tsv', 'row-audit.tsv', 'summary.json', 'provenance.json'):
        if (out/target).resolve() in {getattr(args, key).resolve() for key in
                ('source', 'neutral', 'clarifications', 'results', 'ai_labels', 'dictionary')}:
            raise ValueError('Output must not overwrite an input')
    (out/'submitted.tsv').write_bytes(args.source.read_bytes())
    serialized = [dict(r, acceptable=','.join(r['acceptable']), allow_hangul=int(r['allow_hangul'])) for r in labels]
    write_tsv(out/'labels.tsv', serialized, list(serialized[0]))
    write_tsv(out/'row-audit.tsv', audit, list(audit[0]))
    (out/'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2)+'\n')
    provenance = dict(inputs={key: dict(path=str(getattr(args, key)), sha256=sha256(getattr(args, key)))
        for key in ('source', 'neutral', 'clarifications', 'results', 'ai_labels', 'dictionary')},
        scripts={str(path): sha256(path) for path in (Path(__file__), Path(__file__).with_name('compare_auto_conversion_policies.py'))},
        reviewer='Authenticated chat user submitted file; no reviewer alias was provided. Raw reviewer fields remain blank.',
        clarification=clarification, original_complete_flag='Ignored; validated schema and explicit clarifications determine eligibility.')
    (out/'provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == '__main__':
    main()
