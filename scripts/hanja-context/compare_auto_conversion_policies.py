#!/usr/bin/env python3
"""Diagnostic policy comparison on existing AI labels, never a generalization/acceptance gate."""
import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path


def wilson(correct, total):
    if not total:
        return None
    z = 1.959963984540054
    p = correct / total
    denominator = 1 + z*z/total
    center = (p + z*z/(2*total)) / denominator
    radius = z * math.sqrt(p*(1-p)/total + z*z/(4*total*total)) / denominator
    return [center-radius, center+radius]


def automatic_value(result, policy):
    automatic = result['auto_value'] if result['seg_ok'] else ''
    if policy == 'positive_context_and_no_tie' and automatic:
        score = next(s for s in result['scores'] if s['value'] == automatic)
        competitors = [s['boost'] for s in result['scores']
                       if s['value'] != automatic and s['word_evidence']]
        evidence = score['dictionary'] > 0 or score['association_raw'] > 0
        if not evidence or (competitors and score['boost'] <= max(competitors)):
            automatic = ''
    elif policy != 'current' and policy != 'positive_context_and_no_tie':
        raise ValueError(f'Unknown policy: {policy}')
    return automatic


def evaluate_policy(labels, rows, policy):
    correct = wrong = k_auto = k = um = mixed = mixed_correct = mixed_wrong = mixed_held = 0
    per_reading = defaultdict(lambda: [0, 0])
    for label in labels:
        category = label['category']
        if category not in ('U', 'M', 'K'):
            continue
        result = rows[label['id']]
        if result['reading'] != label['reading']:
            raise ValueError(f"Reading mismatch: {label['id']}")
        automatic = automatic_value(result, policy)
        if category == 'K':
            k += 1
            k_auto += bool(automatic)
            continue
        acceptable = set(label['acceptable'])
        right = bool(automatic and automatic in acceptable)
        if label.get('allow_hangul', False):
            mixed += 1
            mixed_correct += right
            mixed_wrong += bool(automatic and not right)
            mixed_held += not bool(automatic)
            continue
        um += 1
        correct += right
        wrong += bool(automatic and not right)
        per_reading[label['reading']][0] += right
        per_reading[label['reading']][1] += 1
    total_auto = correct + wrong + k_auto + mixed_correct + mixed_wrong
    total_correct_auto = correct + mixed_correct
    return dict(um_rows=um, correct_auto=correct, incorrect_auto=wrong,
        correct_auto_coverage=correct/um if um else None,
        reading_macro_correct_auto_coverage=(sum(a/b for a,b in per_reading.values()) /
            len(per_reading)) if per_reading else None,
        k_rows=k, k_auto=k_auto, k_auto_rate=k_auto/k if k else None,
        mixed_rows=mixed, mixed_correct_auto=mixed_correct,
        mixed_incorrect_auto=mixed_wrong, mixed_held=mixed_held,
        judged_auto_total=total_auto, provisional_precision=total_correct_auto/total_auto if total_auto else None,
        wilson_95=wilson(total_correct_auto, total_auto))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--labels', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = {r['id']: r for r in map(json.loads, args.results.read_text().splitlines())}
    labels = list(csv.DictReader((l for l in args.labels.read_text().splitlines()
                                 if l and not l.startswith('#')), delimiter='\t'))
    normalized = [dict(id=r['id'], reading=r['읽기'], category=r['판정범주'],
        acceptable=list(filter(None, (r['주정답']+','+r['허용집합']).split(',')))) for r in labels]
    reports = {policy: evaluate_policy(normalized, rows, policy)
               for policy in ('current', 'positive_context_and_no_tie')}
    output = dict(label_provenance='AI; no independent review yet',
        scope='Existing D2 development diagnostics; segmentation failures remain in coverage denominators.',
        decision='Do not adopt a new abstention threshold before independent dev review; report coverage with precision.',
        policies=reports)
    args.output.write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(output,ensure_ascii=False))


if __name__ == '__main__':
    main()
