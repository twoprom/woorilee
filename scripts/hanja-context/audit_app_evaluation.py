#!/usr/bin/env python3
"""Compare historical D2 output with app-mode JSONL; never turn AI labels into independent gold."""
import argparse
import csv
import json
import hashlib
from collections import Counter, defaultdict
from pathlib import Path


def read_tsv(path):
    return list(csv.DictReader((line for line in Path(path).read_text().splitlines()
                               if line and not line.startswith('#')), delimiter='\t'))


def write_tsv(path, rows, fields):
    with Path(path).open('w') as f:
        writer = csv.DictWriter(f, fieldnames=fields, delimiter='\t', extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--d2-dir', type=Path, required=True)
    parser.add_argument('--results-dir', type=Path, required=True)
    parser.add_argument('--dictionary', type=Path, help='Use the dictionary matching the baseline resource manifest')
    args = parser.parse_args()
    out = args.results_dir
    app = {r['id']: r for r in map(json.loads, (out/'app-baseline.jsonl').read_text().splitlines())}
    old = {r['id']: r for r in read_tsv(out/'legacy-baseline.tsv')}
    labels = read_tsv(args.d2_dir/'label-sheet-filled.tsv')
    label_by_number = {r['번호']: r for r in labels}
    # Dictionary completeness is independent of segmentation or the first ten displayed values.
    dictionary = defaultdict(set)
    root = Path(__file__).resolve().parents[2]
    dictionary_path = args.dictionary or root/'woorilee/data/hanja/hanja.txt'
    dictionary_sha = hashlib.sha256(dictionary_path.read_bytes()).hexdigest()
    manifest = json.loads((out/'resources.json').read_text())
    expected_sha = manifest['resources']['woorilee/data/hanja/hanja.txt']['sha256']
    if dictionary_sha != expected_sha:
        raise ValueError('Dictionary does not match baseline resources.json; pass --dictionary with the matching snapshot')
    for line in dictionary_path.read_text().splitlines():
        parts = line.split(':', 2)
        if len(parts) >= 2 and not line.startswith('#'):
            dictionary[parts[0]].add(parts[1])
    diffs = []
    for id_, new in app.items():
        previous = old[id_]
        reasons = []
        if new['seg_ok'] != (previous['seg_ok'] == '1'):
            reasons.append('top3_segmentation_vs_top1')
        panel = new['panel_candidates']
        if (panel[0] if panel else '') != previous['sys_top1']:
            reasons.append('shared_tag_aware_panel_vs_legacy_ranking')
        if bool(new['auto_value']) != (previous['auto_convert'] == '1'):
            reasons.append('shared_top3_and_word_gate_vs_legacy_reranking')
        if reasons:
            diffs.append(dict(id=id_, reasons=','.join(reasons), old_seg=previous['seg_ok'],
                app_seg=int(new['seg_ok']), old_panel=previous['sys_top1'],
                app_panel=panel[0] if panel else '', old_auto=previous['auto_convert'],
                app_auto_value=new['auto_value'], hold_reason=new['hold_reason']))
    write_tsv(out/'pipeline-differences.tsv', diffs,
              ['id','reasons','old_seg','app_seg','old_panel','app_panel','old_auto','app_auto_value','hold_reason'])
    audited = []
    counts = Counter()
    top1 = top3 = um = k = k_auto = 0
    per_reading = defaultdict(lambda: [0, 0])
    for row in labels:
        new = app[row['id']]
        acceptable = set(filter(None, row['주정답'].split(',')))
        acceptable.update(filter(None, row['허용집합'].split(',')))
        all_values = dictionary[row['읽기']]
        category = row['판정범주']
        if category == '?':
            issue = 'needs_independent_semantic_review'
        elif category == 'K':
            issue = 'hangul_keep_label'
        elif acceptable and not acceptable.intersection(all_values):
            issue = 'dictionary_missing'
        elif acceptable and not acceptable.intersection(row['후보목록'].split(',')):
            issue = 'display_truncated'
        else:
            issue = 'listed'
        counts[issue] += 1
        omitted = all_values - set(row['후보목록'].split(','))
        audited.append(dict(id=row['id'], label_provenance='AI_unreviewed', category=category,
            issue=issue, dictionary_candidates=','.join(sorted(all_values)),
            dictionary_count=len(all_values), omitted_from_display=','.join(sorted(omitted)),
            app_candidates=','.join(new['panel_candidates'])))
        if category in ('U','M'):
            um += 1
            ranked = new['panel_candidates'] if new['seg_ok'] else []
            correct = bool(ranked and ranked[0] in acceptable)
            top1 += correct
            top3 += bool(acceptable.intersection(ranked[:3]))
            per_reading[row['읽기']][0] += correct
            per_reading[row['읽기']][1] += 1
        if category == 'K':
            k += 1
            k_auto += bool(new['seg_ok'] and new['auto_value'])
    write_tsv(out/'label-audit.tsv', audited,
              ['id','label_provenance','category','issue','dictionary_count','dictionary_candidates','omitted_from_display','app_candidates'])
    # Neutral 73-row sheet: preserve the original sampling, hide initial labels and app ranks.
    review = []
    for row in read_tsv(args.d2_dir/'relabel-sheet.tsv'):
        source = label_by_number[row['번호']]
        review.append(dict(id=source['id'], reading=source['읽기'], sentence=source['표시문장'],
            candidates=','.join(sorted(dictionary[source['읽기']])), category='', answer='',
            acceptable='', uncertainty_reason='', reviewer=''))
    write_tsv(out/'independent-review.tsv', review,
              ['id','reading','sentence','candidates','category','answer','acceptable','uncertainty_reason','reviewer'])
    summary = dict(dictionary_sha256=dictionary_sha, rows=len(app), app_exact=sum(r['seg_ok'] for r in app.values()),
        legacy_exact=sum(r['seg_ok']=='1' for r in old.values()), changed_rows=len(diffs),
        label_audit=dict(counts), independent_review_rows=len(review),
        provisional_AI_labels=dict(um_rows=um, top1=top1, top3=top3,
            macro_top1=sum(a/b for a,b in per_reading.values())/len(per_reading),
            k_rows=k, k_auto=k_auto),
        evaluation_history='D2 and v1/v2 have already informed error analysis/curated overrides; not unseen generalization data.',
        pending='Independent review must assign ? reasons: insufficient_context, dictionary_missing, display_truncated, normalization, specialist_review.')
    (out/'audit-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(summary,ensure_ascii=False))


if __name__ == '__main__':
    main()
