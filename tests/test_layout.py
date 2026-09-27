import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, ROOT)

from agentmux import sidebar as sb  # noqa: E402

NOW = 1_800_000_000
FIXTURE = os.path.join(HERE, "fixtures", "panes_five_agents.tsv")


def load_rows():
    with open(FIXTURE, encoding="utf-8") as fh:
        return sb.parse_rows(fh.read(), sep="\t")


class CellsTest(unittest.TestCase):
    def test_cell_width(self):
        self.assertEqual(sb.cell_width("a"), 1)
        self.assertEqual(sb.cell_width(sb.GLYPH["blocked"]), 1)  # plane-15 PUA
        self.assertEqual(sb.cell_width(""), 1)  # BMP PUA
        self.assertEqual(sb.cell_width("́"), 0)  # combining
        self.assertEqual(sb.cell_width("中"), 2)  # wide CJK
        self.assertEqual(sb.cell_width("\x1b"), 0)

    def test_fit_pads_and_truncates(self):
        self.assertEqual(sb.fit("abc", 5), "abc  ")
        self.assertEqual(sb.fit("abc", 5, "right"), "  abc")
        self.assertEqual(sb.fit("abcdefgh", 5), "abcd…")
        self.assertEqual(sb.fit("中中中", 5), "中中…")
        self.assertEqual(sb.str_width(sb.fit("中中中", 4)), 4)
        self.assertEqual(sb.fit("x", 0), "")

    def test_sgr(self):
        self.assertEqual(sb.sgr("#fd6883"), "38;2;253;104;131")
        self.assertEqual(sb.sgr("colour240"), "38;5;240")
        self.assertEqual(sb.sgr("color9"), "38;5;9")
        self.assertEqual(sb.sgr("red"), "31")
        self.assertEqual(sb.sgr("brightred"), "91")
        self.assertEqual(sb.sgr("default"), "39")
        self.assertEqual(sb.sgr("nonsense"), "39")

    def test_elapsed(self):
        self.assertEqual(sb.fmt_elapsed(5), "0m05s")
        self.assertEqual(sb.fmt_elapsed(185), "3m05s")
        self.assertEqual(sb.fmt_elapsed(3725), "1h02m")
        self.assertEqual(sb.fmt_elapsed(-3), "0m00s")
        self.assertEqual(sb.fmt_ago(30), "30s")
        self.assertEqual(sb.fmt_ago(200), "3m")
        self.assertEqual(sb.fmt_ago(7200), "2h")


class ModelTest(unittest.TestCase):
    def test_model_from_fixture(self):
        model = sb.build_model(load_rows(), NOW, "%9")
        # worst first: done, delegating, working, then the idle one (shell grace)
        self.assertEqual([a.state for a in model.agents], ["done", "delegating", "working", "idle"])
        # the stale agent (shell + updated 900 s ago) is gone, the sidebar row is skipped
        self.assertNotIn("stale", [a.project for a in model.agents])
        self.assertEqual(model.counts, {"done": 1, "delegating": 1, "working": 1, "idle": 1})

    def test_ttl(self):
        model = sb.build_model(load_rows(), NOW, "%9", ttl=100)
        states = {a.project: a.state for a in model.agents}
        self.assertEqual(states["herdr"], "idle")  # done, 200 s old > ttl 100
        self.assertEqual(states[".dotfiles"], "working")

    def test_grouped_sessions_list_a_pane_once(self):
        rows = load_rows()
        twin = dict(next(r for r in rows if r["pane_id"] == "%1"), session_name="3-twin")
        model = sb.build_model([*rows, twin], NOW, "%9")
        self.assertEqual([a.target for a in model.agents].count("3:1.1"), 1)
        self.assertEqual(len(model.agents), 4)


class GoldenTest(unittest.TestCase):
    def run_once(self, *extra):
        cmd = [
            sys.executable,
            os.path.join(ROOT, "bin", "agentmux-sidebar"),
            "--once",
            "--input",
            FIXTURE,
            "--now",
            str(NOW),
            "--width",
            "46",
            "--no-color",
            *extra,
        ]
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout

    def golden(self, name):
        with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as fh:
            return fh.read()

    def test_46x24(self):
        out = self.run_once("--height", "24")
        self.assertEqual(out, self.golden("sidebar_46x24.txt"))
        lines = out.split("\n")[:-1]
        self.assertEqual(len(lines), 24)
        self.assertTrue(all(sb.str_width(line) == 46 for line in lines))

    def test_46x8_truncates_with_footer(self):
        out = self.run_once("--height", "8")
        self.assertEqual(out, self.golden("sidebar_46x8.txt"))
        self.assertIn("+2 more", out)

    def test_compact(self):
        out = self.run_once("--height", "12", "--density", "compact")
        self.assertEqual(out, self.golden("sidebar_46x12_compact.txt"))

    def test_print_format(self):
        out = subprocess.run(
            [sys.executable, os.path.join(ROOT, "bin", "agentmux-sidebar"), "--print-format"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.rstrip("\n")
        self.assertEqual(out.count("\x1f"), len(sb.FIELDS) - 1)
        self.assertIn("#{@agentmux_state}", out)

    def test_empty(self):
        model = sb.build_model([], NOW, "%1")
        frame = sb.render(model, 30, 5, sb.Theme({}, enabled=False))
        self.assertEqual(frame.lines[2], sb.fit(" no agents", 30))
        self.assertEqual(len(frame.lines), 5)

    def test_colour_lines_keep_width(self):
        model = sb.build_model(load_rows(), NOW, "%9")
        frame = sb.render(model, 46, 24, sb.Theme(dict(sb.DEFAULT_COLORS)))
        import re

        strip = re.compile(r"\x1b\[[0-9;]*m")
        for line in frame.lines:
            self.assertEqual(sb.str_width(strip.sub("", line)), 46)
        self.assertEqual(frame.rows[0][0], 2)  # first agent row y, right under the rule


class TermTest(unittest.TestCase):
    def test_diff_repaint(self):
        r, w = os.pipe()
        term = sb.Term(w)
        term.draw(["a", "b"], full=True)
        n = term.draw(["a", "c"])
        os.close(w)
        data = os.read(r, 4096).decode()
        os.close(r)
        self.assertIn("\x1b[2J", data)
        self.assertTrue(data.endswith("\x1b[2;1Hc\x1b[0m"))
        self.assertEqual(n, len("\x1b[2;1Hc\x1b[0m"))


if __name__ == "__main__":
    unittest.main()
