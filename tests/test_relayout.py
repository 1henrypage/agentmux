import io
import os
import sys
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, ROOT)

from agentmux import relayout as rl  # noqa: E402

# Real #{window_layout} strings from a live tmux 3.7 server (tests/e2e.sh section 5
# reproduces the same drift against a live server; these are the frozen numbers from that
# repro: a 220x50 window, two panes split 131|88, sidebar width 46).
CLEAN = "05a3,220x50,0,0{131x50,0,0,0,88x50,132,0,1}"
SQ0 = "3350,220x50,0,0{46x50,0,0,2,103x50,47,0,0,69x50,151,0,1}"
BUGGY_AFTER_5_TOGGLES = "2073,220x50,0,0{191x50,0,0,0,28x50,192,0,1}"  # the reported bug
CLEAN_TB = "7273,220x50,0,0[220x29,0,0,0,220x20,0,30,1]"
SQ0_TB = "b917,220x50,0,0{46x50,0,0,2,173x50,47,0[173x29,47,0,0,173x20,47,30,1]}"
SINGLE_LEAF = "ad1f,220x50,0,0,2"

IDS = {0, 1}


def with_checksum(body: str) -> str:
    return f"{rl.checksum(body):04x},{body}"


class ParseSerializeTest(unittest.TestCase):
    def test_checksum_matches_tmux(self):
        self.assertEqual(rl.checksum("220x50,0,0{131x50,0,0,0,88x50,132,0,1}"), 0x05A3)

    def test_round_trip_real_layouts(self):
        for s in (CLEAN, SQ0, BUGGY_AFTER_5_TOGGLES, CLEAN_TB, SQ0_TB, SINGLE_LEAF):
            self.assertEqual(rl.serialize(rl.parse(s)), s)

    def test_rejects_malformed(self):
        with self.assertRaises(ValueError):
            rl.parse("05a3,220x50,0,0{131x50,0,0,0")  # unterminated container


class StripTest(unittest.TestCase):
    def test_flattened_left_right_drops_the_sidebar_leaf(self):
        stripped = rl.strip(rl.parse(SQ0), IDS)
        self.assertEqual(rl.serialize(stripped), "b223,173x50,0,0{103x50,0,0,0,69x50,104,0,1}")

    def test_nested_top_bottom_collapses_the_wrapper(self):
        stripped = rl.strip(rl.parse(SQ0_TB), IDS)
        # the wrapping {} node had only the [] subtree left once the sidebar leaf was
        # dropped, so strip collapses it away rather than keeping a single-child node.
        self.assertIsNone(stripped.pane_id)
        self.assertEqual(stripped.kind, "v")
        self.assertEqual([c.pane_id for c in stripped.children], [0, 1])
        self.assertEqual(rl.serialize(stripped), "205c,173x50,0,0[173x29,0,0,0,173x20,0,30,1]")

    def test_collapsing_to_a_lone_pane_repositions_but_keeps_its_own_size(self):
        stripped = rl.strip(rl.parse(SQ0), {0})
        self.assertEqual(stripped.pane_id, 0)
        self.assertEqual((stripped.w, stripped.h, stripped.x, stripped.y), (103, 50, 0, 0))

    def test_no_matching_pane_refuses(self):
        self.assertIsNone(rl.strip(rl.parse(SQ0), {99}))

    def test_leaves_the_input_tree_alone(self):
        tree = rl.parse(SQ0_TB)
        rl.strip(tree, IDS)
        self.assertEqual(rl.serialize(tree), SQ0_TB)


class BorrowedTest(unittest.TestCase):
    def test_none_for_different_orientation(self):
        self.assertIsNone(rl.borrowed(rl.parse(CLEAN), rl.parse(CLEAN_TB)))

    def test_none_for_different_child_count(self):
        added = with_checksum("220x50,0,0{46x50,0,0,2,60x50,47,0,0,50x50,108,0,1,60x50,159,0,3}")
        stripped = rl.strip(rl.parse(added), {0, 1, 3})  # a pane was added: 3 real panes now
        self.assertIsNone(rl.borrowed(rl.parse(CLEAN), stripped))


class GiveBackTest(unittest.TestCase):
    def test_exact_when_sq_equals_sq0(self):
        sq0_stripped = rl.strip(rl.parse(SQ0), IDS)
        delta = rl.borrowed(rl.parse(CLEAN), sq0_stripped)
        result = rl.give_back(sq0_stripped, delta)
        self.assertEqual(rl.serialize(result), CLEAN)

    def test_on_top_of_a_resize(self):
        sq0_stripped = rl.strip(rl.parse(SQ0), IDS)
        delta = rl.borrowed(rl.parse(CLEAN), sq0_stripped)
        resized = with_checksum("220x50,0,0{46x50,0,0,2,120x50,47,0,0,52x50,168,0,1}")
        sq_stripped = rl.strip(rl.parse(resized), IDS)
        result = rl.give_back(sq_stripped, delta)
        # the resize (120|52) plus what was originally borrowed (28|19): 148|71.
        self.assertEqual(rl.serialize(result), "44ab,220x50,0,0{148x50,0,0,0,71x50,149,0,1}")

    def test_nested_top_bottom_exact(self):
        sq0_stripped = rl.strip(rl.parse(SQ0_TB), IDS)
        delta = rl.borrowed(rl.parse(CLEAN_TB), sq0_stripped)
        result = rl.give_back(sq0_stripped, delta)
        self.assertEqual(rl.serialize(result), CLEAN_TB)

    def test_refuses_when_a_pane_was_added(self):
        sq0_stripped = rl.strip(rl.parse(SQ0), IDS)
        delta = rl.borrowed(rl.parse(CLEAN), sq0_stripped)
        added = with_checksum("220x50,0,0{46x50,0,0,2,60x50,47,0,0,50x50,108,0,1,60x50,159,0,3}")
        sq_stripped = rl.strip(rl.parse(added), {0, 1, 3})
        self.assertIsNone(rl.give_back(sq_stripped, delta))


class ScaleTest(unittest.TestCase):
    def test_keeps_the_sum_and_the_ratio(self):
        self.assertEqual(rl._scale([103, 69], 219), [131, 88])

    def test_leftover_goes_to_the_largest_remainders(self):
        # exact shares 3.33.. each: one leftover unit, to the first of the tied remainders
        self.assertEqual(rl._scale([1, 1, 1], 10), [4, 3, 3])

    def test_never_below_one_when_shrinking(self):
        out = rl._scale([1, 1, 50], 30)
        self.assertEqual(sum(out), 30)
        self.assertTrue(all(size >= 1 for size in out), out)


class ExpandTest(unittest.TestCase):
    def test_fills_the_width(self):
        sq0_stripped = rl.strip(rl.parse(SQ0), IDS)
        expanded = rl.expand(sq0_stripped, 220, 50)
        self.assertEqual(expanded.w, 220)
        self.assertEqual(sum(c.w for c in expanded.children) + 1, 220)

    def test_three_panes_fill_the_width(self):
        added = with_checksum("220x50,0,0{46x50,0,0,2,60x50,47,0,0,50x50,108,0,1,60x50,159,0,3}")
        sq_stripped = rl.strip(rl.parse(added), {0, 1, 3})
        expanded = rl.expand(sq_stripped, 220, 50)
        self.assertEqual(sum(c.w for c in expanded.children) + 2, 220)


class RelayoutTest(unittest.TestCase):
    def test_exact_give_back(self):
        self.assertEqual(rl.serialize(rl.relayout(CLEAN, SQ0, SQ0, [0, 1])), CLEAN)

    def test_fits_the_window_when_the_sidebar_was_resized(self):
        # the sidebar went from 46 to 30 columns while it was here, pane 0 took the 16
        narrowed = with_checksum("220x50,0,0{30x50,0,0,2,119x50,31,0,0,69x50,151,0,1}")
        result = rl.relayout(CLEAN, SQ0, narrowed, [0, 1])
        # 119|69 plus what each lent (28|19) is 147|88, 236 wide: scaled into 220
        self.assertEqual([(c.w, c.x) for c in result.children], [(137, 0), (82, 138)])
        self.assertEqual((result.w, result.h), (220, 50))

    def test_refuses_panes_listed_out_of_layout_order(self):
        # select-layout would put pane 1 in pane 0's cell and the other way round
        self.assertIsNone(rl.relayout(CLEAN, SQ0, SQ0, [1, 0]))

    def test_refuses_a_pane_the_layout_does_not_know(self):
        self.assertIsNone(rl.relayout(CLEAN, SQ0, SQ0, [0, 1, 7]))


class MainTest(unittest.TestCase):
    def run_main(self, *args: str) -> tuple[int, str]:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = rl.main(["relayout.py", *args])
        return rc, buf.getvalue().strip()

    def test_happy_path_idempotent(self):
        rc, out = self.run_main(CLEAN, SQ0, SQ0, "%0,%1")
        self.assertEqual(rc, 0)
        self.assertEqual(out, CLEAN)

    def test_falls_back_to_expand_when_history_missing(self):
        rc, out = self.run_main("", "", SQ0, "%0,%1")
        self.assertEqual(rc, 0)
        self.assertEqual(rl.parse(out).w, 220)

    def test_prints_nothing_when_sq_has_no_current_pane(self):
        rc, out = self.run_main(CLEAN, SQ0, SQ0, "%5,%6")
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")

    def test_prints_nothing_for_malformed_pane_ids(self):
        rc, out = self.run_main(CLEAN, SQ0, SQ0, "%0,%x")
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
