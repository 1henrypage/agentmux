import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from agentmux import titlecodec as tc


class SanitizeTest(unittest.TestCase):
    def test_maps_unsafe_chars(self):
        self.assertEqual(tc.sanitize("a|b~c;d#e%f,g", 99), "a_b_c_d_e_f_g")

    def test_keeps_safe_chars(self):
        self.assertEqual(tc.sanitize("proj-1.2_x@y+(z) ok", 99), "proj-1.2_x@y+(z) ok")

    def test_truncates(self):
        self.assertEqual(tc.sanitize("abcdef", 3), "abc")

    def test_none(self):
        self.assertEqual(tc.sanitize(None, 3), "")


class RoundTripTest(unittest.TestCase):
    def test_round_trip(self):
        header = tc.Header(host="devbox", minute=29000000, heartbeat=60)
        entries = [
            tc.Entry(
                host="devbox",
                state="blocked",
                kind="claude",
                project="api",
                start=1700000000,
                subagents=2,
                updated=1700000100,
                visible=True,
                target="main:2.1",
                detail="permission Bash",
            ),
            tc.Entry(host="devbox", state="idle", kind="codex", project="web", target="main:3.1"),
        ]
        text = tc.encode(header, entries)
        self.assertTrue(text.startswith("AGX1|h=devbox|t=29000000|hb=60~"))
        self.assertTrue(text.endswith("~"))
        self.assertNotIn(";", text)
        self.assertNotIn("#", text)
        self.assertNotIn(",", text)
        decoded = tc.decode(text)
        self.assertIsNotNone(decoded)
        self.assertEqual(decoded.header, header)
        self.assertEqual(decoded.entries, entries)

    def test_empty_aggregate(self):
        text = tc.Header(host="h", minute=1, heartbeat=0).encode() + "~"
        decoded = tc.decode(text)
        self.assertEqual(decoded.entries, [])
        self.assertEqual(decoded.header.heartbeat, 0)
        self.assertTrue(decoded.header.fresh(10**9))
        self.assertEqual(decoded.header.expiry(10**9), 0)

    def test_truncated_trailing_entry_is_dropped(self):
        full = tc.encode(
            tc.Header("h", 1, 60),
            [
                tc.Entry(host="h", state="working", target="a:1.1"),
                tc.Entry(host="h", target="a:2.1"),
            ],
        )
        cut = full[: full.rfind("~") - 3]
        decoded = tc.decode(cut)
        self.assertEqual(len(decoded.entries), 1)
        self.assertEqual(decoded.entries[0].target, "a:1.1")

    def test_nested_hosts_and_visibility(self):
        text = (
            "AGX1|h=bastion|t=5|hb=60~"
            "h=bastion|s=working|k=claude|p=x|b=1|n=0|u=2|x=1|w=s:1.1|d=~"
            "h=inner|s=done|k=codex|p=y|b=|n=0|u=3|x=0|w=t:2.1|d=finished~"
        )
        decoded = tc.decode(text)
        self.assertEqual([e.host for e in decoded.entries], ["bastion", "inner"])
        self.assertTrue(decoded.entries[0].visible)
        self.assertFalse(decoded.entries[1].visible)
        self.assertEqual(decoded.entries[1].start, 0)
        self.assertEqual(decoded.worst(), "done")
        self.assertEqual(decoded.worst(include_done=False), "working")
        self.assertEqual(tc.strip_header(text), text.split("~", 1)[1])

    def test_unknown_state_and_keys_are_tolerated(self):
        text = "AGX1|h=h|t=1|hb=60|zz=9~h=h|s=weird|q=1|w=a:1.1~"
        decoded = tc.decode(text)
        self.assertEqual(decoded.entries[0].state, "idle")

    def test_bad_input(self):
        self.assertIsNone(tc.decode(""))
        self.assertIsNone(tc.decode("hello"))
        self.assertIsNone(tc.decode("AGX1"))
        self.assertIsNone(tc.decode("AGX1|h=x"))  # no terminator at all
        self.assertEqual(tc.decode("AGX1|h=x|t=abc|hb=~").header.minute, 0)

    def test_header_freshness(self):
        header = tc.Header("h", minute=1000, heartbeat=60)
        self.assertTrue(header.fresh(1003 * 60))
        self.assertFalse(header.fresh(1004 * 60))
        self.assertEqual(header.expiry(1000 * 60), 1000 * 60 + 180)

    def test_entry_encode_sanitizes(self):
        entry = tc.Entry(host="h", state="nope", project="a|b", detail="x~y" * 20, target="s p")
        text = entry.encode()
        self.assertIn("s=idle", text)
        self.assertIn("p=a_b", text)
        self.assertIn("w=s_p", text)
        d = dict(p.split("=", 1) for p in text.split("|"))
        self.assertEqual(len(d["d"]), tc.MAX_DETAIL)


if __name__ == "__main__":
    unittest.main()
