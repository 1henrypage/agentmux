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
        model = sb.build_model(load_rows(), NOW, "%9", "laptop")
        hosts = [h for h, _ in model.groups]
        self.assertEqual(hosts, ["", "devbox"])
        local = model.groups[0][1]
        # worst first: done, delegating, working, then the idle one (shell grace)
        self.assertEqual([a.state for a in local], ["done", "delegating", "working", "idle"])
        # the stale agent (shell + updated 900 s ago) is gone, the sidebar row is skipped
        self.assertNotIn("stale", [a.project for a in local])
        remote = model.groups[1][1]
        self.assertEqual([a.state for a in remote], ["blocked", "working"])
        self.assertEqual(remote[0].target, "main:2.1")
        self.assertEqual(
            model.counts, {"done": 1, "delegating": 1, "working": 2, "idle": 1, "blocked": 1}
        )

    def test_ttl_and_expiry(self):
        rows = load_rows()
        model = sb.build_model(rows, NOW, "%9", "laptop", ttl=100)
        local = {a.project: a.state for a in model.groups[0][1]}
        self.assertEqual(local["herdr"], "idle")  # done, 200 s old > ttl 100
        self.assertEqual(local[".dotfiles"], "working")
        # remote expiry in the past drops the whole group
        for r in rows:
            if r["pane_id"] == "%5":
                r["r_exp"] = str(NOW - 1)
        model = sb.build_model(rows, NOW, "%9", "laptop")
        self.assertEqual([h for h, _ in model.groups], [""])

    def test_remote_seen_renders_done_as_idle(self):
        rows = load_rows()
        for r in rows:
            if r["pane_id"] == "%5":
                r["pane_title"] = r["pane_title"].replace("s=blocked", "s=done")
                r["r_seen"] = "1"
        model = sb.build_model(rows, NOW, "%9", "laptop")
        remote = model.groups[1][1]
        self.assertEqual({a.state for a in remote}, {"idle", "working"})

    def test_self_echo_dropped(self):
        rows = load_rows()
        model = sb.build_model(rows, NOW, "%9", "devbox")
        self.assertEqual([h for h, _ in model.groups], [""])

    def test_host_order_forgets(self):
        order = sb.HostOrder()
        self.assertEqual(order.touch(["b", "a"], 0), ["b", "a"])
        self.assertEqual(order.touch(["a"], 10), ["a"])
        self.assertEqual(order.touch(["a", "b"], 20), ["b", "a"])  # b remembered
        self.assertEqual(order.touch(["a", "b"], 100), ["a", "b"])  # b forgotten, re-added


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
            "--host",
            "laptop",
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
        self.assertIn("+4 more", out)

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
        model = sb.build_model([], NOW, "%1", "h")
        frame = sb.render(model, 30, 5, sb.Theme({}, enabled=False))
        self.assertEqual(frame.lines[2], sb.fit(" no agents", 30))
        self.assertEqual(len(frame.lines), 5)

    def test_colour_lines_keep_width(self):
        model = sb.build_model(load_rows(), NOW, "%9", "laptop")
        frame = sb.render(model, 46, 24, sb.Theme(dict(sb.DEFAULT_COLORS)))
        import re

        strip = re.compile(r"\x1b\[[0-9;]*m")
        for line in frame.lines:
            self.assertEqual(sb.str_width(strip.sub("", line)), 46)
        self.assertEqual(frame.rows[0][0], 3)  # first agent row y


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
