"""The before/after report: when a difference counts, and how launches are pooled."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('compare_report', REPO / 'Scripts/perf/compare_report.py')
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class RankSumTests(unittest.TestCase):
    def test_equal_values_share_the_mean_of_their_ranks(self):
        self.assertEqual(compare.midranks([5.0, 1.0, 5.0, 9.0]), [2.5, 1.0, 2.5, 4.0])

    def test_two_sides_that_do_not_overlap_are_as_unlikely_as_the_sizes_allow(self):
        # 2 of the 924 ways to deal twelve figures into two sixes separate them fully.
        p_value = compare.rank_sum_p([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
        self.assertAlmostEqual(p_value, 2 / 924)

    def test_the_test_is_two_sided(self):
        self.assertEqual(compare.rank_sum_p([7, 8, 9, 10], [1, 2, 3, 4]), compare.rank_sum_p([1, 2, 3, 4], [7, 8, 9, 10]))

    def test_interleaved_sides_are_not_told_apart(self):
        self.assertGreater(compare.rank_sum_p([1, 3, 5, 7, 9, 11], [2, 4, 6, 8, 10, 12]), 0.5)

    def test_large_samples_fall_back_to_a_repeatable_estimate(self):
        low, high = list(range(12)), list(range(12, 24))
        self.assertEqual(compare.rank_sum_p(low, high), compare.rank_sum_p(low, high))
        self.assertLess(compare.rank_sum_p(low, high), 0.001)


class VerdictTests(unittest.TestCase):
    def test_a_clear_drop_is_lower(self):
        change, p_value, word = compare.verdict([128, 131, 127, 134, 129, 130], [101, 99, 103, 100, 102, 101])
        self.assertEqual(word, 'lower')
        self.assertAlmostEqual(change, -28.5)
        self.assertLess(p_value, 0.01)

    def test_a_separation_that_chance_reaches_now_and_then_is_only_possible(self):
        # Four a side, fully apart: 2 of the 70 ways to deal them out, p = 0.029.
        _, p_value, word = compare.verdict([7, 8, 9, 10], [1, 2, 3, 4])
        self.assertEqual(word, 'possibly lower')
        self.assertGreater(p_value, 0.01)
        _, _, word = compare.verdict([1, 2, 3, 4], [7, 8, 9, 10])
        self.assertEqual(word, 'possibly higher')

    def test_a_difference_inside_the_spread_is_no_measurable_change(self):
        _, _, word = compare.verdict([101, 134, 102, 128, 133, 104], [103, 130, 101, 127, 135, 102])
        self.assertEqual(word, 'no measurable change')

    def test_three_launches_a_side_can_never_show_a_difference(self):
        _, p_value, word = compare.verdict([1, 2, 3], [7, 8, 9])
        self.assertIsNone(p_value)
        self.assertEqual(word, 'too few launches to tell')


class ReportTests(unittest.TestCase):
    def write(self, folder, name, lines):
        path = Path(folder) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('\n'.join(lines) + '\n')

    def test_rounds_are_pooled_and_conditions_are_flagged(self):
        with tempfile.TemporaryDirectory() as folder:
            self.write(folder, 'before-1/summary.txt', ['settings: runs=2 settle=75s window=60s', 'system: test Mac'])
            for side, base in (('before', 130.0), ('after', 100.0)):
                for round_number in (1, 2):
                    for launch in (1, 2):
                        asleep = 1 if (side, round_number, launch) == ('after', 2, 2) else 0
                        self.write(folder, f'{side}-{round_number}/launch-{launch}-metrics.txt', [
                            'pid=123',
                            f'app_footprint_mb_median={base + round_number + launch / 5}',
                            f'display_asleep={asleep}',
                        ])
            text = compare.report(folder, 'aaaaaaa', 'bbbbbbb')

        self.assertIn('4 launches a side', text)
        self.assertIn('runs=2 settle=75s window=60s', text)
        row = next(line for line in text.splitlines() if line.startswith('| Idle memory (physical footprint)'))
        self.assertIn('131.8 (131.2 to 132.4) MB', row)
        self.assertIn('101.8 (101.2 to 102.4) MB', row)
        self.assertIn('-30.0 MB, -22.8%', row)
        self.assertIn('| possibly lower (p = 0.029) |', row)
        self.assertIn('A "possibly" row lies between p = 0.01 and p = 0.05', text)
        self.assertIn('| Launch to history loaded | not measured | not measured |', text)
        self.assertIn('0 launch(es) before and 1 after ran with the display asleep', text)


if __name__ == '__main__':
    unittest.main()
