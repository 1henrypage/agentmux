import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agentmux import titlecodec as tc
from agentmux.title_changed import plan

NOW = 1_800_000_000
MIN = NOW // 60


def title(*entries, host="devbox", hb=60, minute=MIN):
    return tc.encode(tc.Header(host, minute, hb), list(entries))


def entry(state, target="main:1.1", host="devbox", **kw):
    kw.setdefault("project", "api")
    kw.setdefault("kind", "claude")
    kw.setdefault("updated", NOW)
    return tc.Entry(host=host, state=state, target=target, **kw)


class PlanTest(unittest.TestCase):
    def test_same_title_is_noop(self):
        t = title(entry("working"))
        self.assertIsNone(plan(t, t, "", False, "laptop", False, "", NOW))

    def test_non_title_is_noop(self):
        self.assertIsNone(plan("zsh", "", "", False, "laptop", False, "", NOW))

    def test_summary_options(self):
        t = title(
            entry("working", start=NOW - 30),
            entry("done", "main:2.1"),
            entry("delegating", "main:3.1", subagents=2),
        )
        p = plan(t, "", "", False, "laptop", False, "", NOW)
        o = p.options
        self.assertEqual(o["r_host"], "devbox")
        self.assertEqual(o["r_n"], "3")
        self.assertEqual(o["r_worst"], "done")
        self.assertEqual(o["r_worst2"], "delegating")
        self.assertEqual(o["r_deleg"], "2")
        self.assertEqual(o["r_exp"], str(NOW + 180))
        self.assertEqual(o["r_seen"], "")
        self.assertEqual(o["r_done"], "devbox:main:2.1")
        self.assertEqual(o["r_prev"], t)
        # label follows the worst entry
        self.assertEqual(o["r_proj"], "api")
        self.assertEqual(o["r_start"], "")  # worst is done -> no timer

    def test_one_shot_never_expires(self):
        t = title(entry("working", target=""), hb=0)
        p = plan(t, "", "", False, "laptop", False, "", NOW)
        self.assertEqual(p.options["r_exp"], "0")

    def test_self_echo_dropped(self):
        t = title(entry("blocked", host="laptop"), entry("working", host="devbox"))
        p = plan(t, "", "", False, "laptop", False, "", NOW)
        self.assertEqual(p.options["r_n"], "1")
        self.assertEqual(p.options["r_worst"], "working")

    def test_seen_kept_when_done_set_shrinks_or_stays(self):
        t1 = title(entry("done", "main:2.1"), entry("working"))
        t2 = title(entry("done", "main:2.1"), entry("done"))
        p = plan(t1, "", "", False, "laptop", True, "devbox:main:2.1", NOW)
        self.assertEqual(p.options["r_seen"], "1")
        # label switches to the worst non-done entry when seen
        self.assertEqual(p.options["r_worst2"], "working")
        p = plan(t2, t1, "", False, "laptop", True, "devbox:main:2.1", NOW)
        self.assertEqual(p.options["r_seen"], "")  # new done entry -> unseen

    def test_notify_blocked_and_done_only_when_not_viewed(self):
        before = title(entry("working", detail="x"))
        after = title(entry("blocked", detail="permission Bash"))
        p = plan(after, before, "", False, "laptop", False, "", NOW)
        self.assertEqual(len(p.notifications), 1)
        self.assertIn("needs you: permission Bash", p.notifications[0][1])
        self.assertTrue(p.options["r_notified"])
        # same stamp again (flap) -> no second notification
        p2 = plan(after, before, p.options["r_notified"], False, "laptop", False, "", NOW)
        self.assertEqual(p2.notifications, [])
        # viewed -> silent
        p3 = plan(after, before, "", True, "laptop", False, "", NOW)
        self.assertEqual(p3.notifications, [])
        done = title(entry("done"))
        p4 = plan(done, after, "", False, "laptop", False, "", NOW)
        self.assertEqual(p4.notifications[0][1], "api on devbox is done")
        # idle -> done is not a completion
        p5 = plan(done, title(entry("idle")), "", False, "laptop", False, "", NOW)
        self.assertEqual(p5.notifications, [])

    def test_stale_header_is_silent(self):
        before = title(entry("working"))
        after = title(entry("blocked"), minute=MIN - 10)
        p = plan(after, before, "", False, "laptop", False, "", NOW)
        self.assertEqual(p.notifications, [])
        self.assertEqual(p.options["r_worst"], "blocked")

    def test_notify_switches(self):
        before = title(entry("working"))
        after = title(entry("blocked"))
        p = plan(after, before, "", False, "laptop", False, "", NOW, notify_blocked=False)
        self.assertEqual(p.notifications, [])

    def test_empty_aggregate_clears(self):
        p = plan(title(), title(entry("working")), "", False, "laptop", False, "", NOW)
        self.assertEqual(p.options["r_n"], "0")
        self.assertEqual(p.options["r_worst"], "idle")
        self.assertEqual(p.options["r_proj"], "")


if __name__ == "__main__":
    unittest.main()
