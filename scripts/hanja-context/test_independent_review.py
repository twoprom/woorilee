import unittest

from compare_auto_conversion_policies import automatic_value, evaluate_policy
from import_independent_review import audit_rows, index_rows, normalize_review


def source(category='U', answer='機器', acceptable=''):
    return dict(id='sample', reading='기기', sentence='실험실 ⟦기기⟧', category=category,
                answer=answer, acceptable=acceptable, uncertainty_reason='', reviewer='', complete='1')


def result(value='機器', seg_ok=True):
    return dict(id='sample', reading='기기', seg_ok=seg_ok, auto_value=value, split='test',
                panel_candidates=['器機', '機器'], hold_reason='', scores=[
                    dict(value='機器', dictionary=0, association_raw=0, boost=10, word_evidence=True),
                    dict(value='器機', dictionary=0, association_raw=1, boost=10, word_evidence=True)])


class IndependentReviewTests(unittest.TestCase):
    def normalize(self, row, clarification=None):
        return normalize_review([row], [source()], clarification or {})

    def test_identity_and_duplicate_errors_do_not_trust_complete_flag(self):
        with self.assertRaises(ValueError):
            index_rows([source(), source()])
        with self.assertRaises(ValueError):
            self.normalize(dict(source(), sentence='changed'))
        with self.assertRaises(ValueError):
            self.normalize(source(category=''))

    def test_missing_primary_in_exported_acceptable_is_unioned(self):
        labels, _ = self.normalize(source('M', '機器', '器機'))
        self.assertEqual(labels[0]['acceptable'], ['機器', '器機'])

    def test_mixed_output_requires_explicit_user_confirmation(self):
        row = source('M', '기기', '機器')
        with self.assertRaises(ValueError):
            self.normalize(row)
        labels, _ = self.normalize(row, {'rows': {'sample': {'allow_hangul': True}}})
        held = evaluate_policy(labels, {'sample': result('')}, 'current')
        self.assertEqual(held['mixed_held'], 1)
        self.assertEqual(held['um_rows'], 0)
        self.assertIsNone(held['k_auto_rate'])
        converted = evaluate_policy(labels, {'sample': result()}, 'current')
        self.assertEqual(converted['provisional_precision'], 1)

    def test_unknown_rows_and_answer_overrides_are_rejected(self):
        with self.assertRaises(ValueError):
            self.normalize(source(), {'rows': {'other': {'category': 'U'}}})
        with self.assertRaises(ValueError):
            self.normalize(source(), {'rows': {'sample': {'answer': '器機'}}})

    def test_uncertain_without_reason_is_excluded_without_inventing_reason(self):
        labels, warnings = self.normalize(source('?', ''))
        self.assertEqual(labels[0]['uncertainty_reason'], '')
        self.assertEqual(warnings, [dict(id='sample', issue='uncertainty_reason_not_supplied')])
        self.assertEqual(evaluate_policy(labels, {'sample': result()}, 'current')['judged_auto_total'], 0)

    def test_segmentation_failure_cannot_score_panel_or_auto_as_correct(self):
        labels, _ = self.normalize(source())
        report = evaluate_policy(labels, {'sample': result(seg_ok=False)}, 'current')
        self.assertEqual(report['correct_auto_coverage'], 0)
        self.assertEqual(report['judged_auto_total'], 0)

    def test_current_uses_preview_instead_of_panel_top1(self):
        labels, _ = self.normalize(source())
        report = evaluate_policy(labels, {'sample': result()}, 'current')
        self.assertEqual(report['correct_auto'], 1)
        self.assertEqual(automatic_value(result(), 'positive_context_and_no_tie'), '')
        self.assertEqual(automatic_value(result('器機'), 'positive_context_and_no_tie'), '')

    def test_human_answer_outside_dictionary_is_retained_and_flagged(self):
        labels, _ = self.normalize(source())
        old = {'sample': {'판정범주': 'U', '주정답': '器機', '허용집합': ''}}
        rows = audit_rows(labels, {'sample': result()}, old, {'기기': {'器機'}})
        self.assertEqual(labels[0]['answer'], '機器')
        self.assertEqual(rows[0]['dictionary_gap_unmatched'], '機器')
        self.assertEqual(rows[0]['outcome'], 'correct_auto')


if __name__ == '__main__':
    unittest.main()
