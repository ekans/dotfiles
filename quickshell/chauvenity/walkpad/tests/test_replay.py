# The fake pad: its script and the frames it makes.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import asyncio
import tempfile
import time
import unittest
from pathlib import Path

from frames import FrameBuffer, PadStatus, parse_frame
from link import Connected, KnownPad, Off, Searching, Unavailable, Waiting
from replay import FAKE_ADDRESS, Directive, ReplaySource, frame_for, parse_script

FAKE = KnownPad(FAKE_ADDRESS, "MAXFREE-FAKE")


class Recorder:
    """link.PadEvents that keeps what it was told, readings decoded."""

    def __init__(self, source):
        self.source = source
        self.events = []
        self.buffers = {}

    def link_changed(self, state, now):
        self.events.append(("link", state, now - self.source.started_at))

    def notification(self, channel, data, now):
        for reading in self.buffers.setdefault(channel, FrameBuffer()).append(data):
            self.events.append(("reading", channel, reading, now - self.source.started_at))

    def pad_found(self, pad):
        self.events.append(("found", pad))

    def links(self):
        return [e[1] for e in self.events if e[0] == "link"]

    def readings(self):
        return [e[2] for e in self.events if e[0] == "reading"]


class Played(unittest.TestCase):
    def play(self, script, known=None, enabled=True, then=None):
        """Runs `script` to its end; `then(source)` runs after it, on the loop."""
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.replay"
            path.write_text(script)
            source = ReplaySource(path)

            async def run():
                recorder = Recorder(source)
                source.start(recorder, known, enabled)
                await source._task
                if then:
                    then(source)
                await source.close()
                return recorder

            return asyncio.run(run())


class Script(Played):
    def test_reads_every_directive(self):
        text = """# a comment
pace 0
at -2d18h
pad MAXFREE-FAKE
on
belt 3.0 600   # walking
belt 0 120
wait 30
drop
back
off
resume 180 0.15
held
raw ffe1 EE,p1.0,\\xb2,FF
bluetooth off
end
"""
        self.assertEqual([(d.verb, d.args) for d in parse_script(text)], [
            ("pace", ("0",)), ("at", ("-2d18h",)), ("pad", ("MAXFREE-FAKE",)), ("on", ()),
            ("belt", ("3.0", "600")), ("belt", ("0", "120")), ("wait", ("30",)), ("drop", ()), ("back", ()),
            ("off", ()), ("resume", ("180", "0.15")), ("held", ()), ("raw", ("ffe1", "EE,p1.0,\\xb2,FF")), ("bluetooth", ("off",)), ("end", ()),
        ])
        self.assertEqual(parse_script("on\n")[0], Directive("on", (), 1))

    def test_names_the_line_of_a_bad_directive(self):
        for text, error in (("pace 0\nbelt fast 10\n", "line 2: belt takes a speed in km/h and seconds, not 'fast 10'"),
                            ("at yesterday", "line 1: at takes an offset like -2d18h, not 'yesterday'"),
                            ("on\n\nwalk 3", "line 3: unknown directive 'walk'"),
                            ("wait", "line 1: wait takes 1 argument"),
                            ("raw ffe3 EE,FF", "line 1: raw takes ffe1 or ffe2, not 'ffe3'"),
                            ("bluetooth maybe", "line 1: bluetooth takes on or off, not 'maybe'")):
            with self.subTest(text):
                self.assertEqual(parse_script(text), error)

    def test_a_bad_script_fails_at_start(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "bad.replay"
            path.write_text("on\nbelt 3\n")
            with self.assertRaisesRegex(ValueError, "line 2: belt takes 2 arguments"):
                ReplaySource(path)


class Frames(Played):
    def test_a_made_up_frame_decodes_to_what_it_was_made_from(self):
        reading = parse_frame(frame_for(3.0, 754, 0.62, 31))
        self.assertEqual((reading.speed_kmh, reading.elapsed_s, reading.distance_km, reading.calories, reading.status),
                         (3.0, 754, 0.62, 31, PadStatus.RUNNING))
        self.assertEqual(parse_frame(frame_for(0, 754, 0.62, 31)).status, PadStatus.IDLE)

    def test_the_belt_advances_the_counters_like_the_pad(self):
        recorder = self.play("on\nbelt 3.6 10\nbelt 0 2\n")
        readings = recorder.readings()
        self.assertEqual(len(readings), 1 + 20 + 4)
        self.assertEqual([(r.speed_kmh, r.elapsed_s, r.distance_km) for r in (readings[0], readings[2], readings[20])],
                         [(0.0, 0, 0.0), (3.6, 1, 0.0), (3.6, 10, 0.01)])
        self.assertEqual({(r.speed_kmh, r.elapsed_s, r.distance_km) for r in readings[21:]}, {(0.0, 10, 0.01)})
        times = [e[3] for e in recorder.events if e[0] == "reading"]
        self.assertEqual(times[:3], [0.0, 0.5, 1.0])

    def test_calories_grow_with_the_distance(self):
        readings = self.play("on\nbelt 6 600\n").readings()
        self.assertEqual((readings[-1].distance_km, readings[-1].calories), (1.0, 45))

    def test_switching_the_pad_off_starts_its_counters_from_zero(self):
        readings = self.play("on\nbelt 3.6 10\noff\non\nbelt 3.6 2\n").readings()
        self.assertEqual(readings[-1].elapsed_s, 2)

    def test_a_drop_keeps_the_counters(self):
        recorder = self.play("on\nbelt 3.6 10\ndrop\nwait 4\nback\nbelt 3.6 2\n")
        self.assertEqual(recorder.readings()[-1].elapsed_s, 12)
        self.assertEqual(recorder.links(), [Searching(), Connected("MAXFREE-FAKE"), Waiting("MAXFREE-FAKE"),
                                            Connected("MAXFREE-FAKE")])

    def test_a_resumed_pad_carries_on_from_its_counters(self):
        recorder = self.play("resume 180 0.15\nbelt 3.6 10\n", known=FAKE)
        self.assertEqual(recorder.links(), [Waiting("MAXFREE-FAKE"), Connected("MAXFREE-FAKE")])
        self.assertEqual([(r.elapsed_s, r.distance_km) for r in recorder.readings()[::20]], [(180, 0.15), (190, 0.16)])

    def test_sends_raw_notifications_verbatim(self):
        recorder = self.play(f"on\nraw ffe1 {frame_for(2.0, 5, 0.0, 0)}\nraw ffe1 EE,p\\xb2,000,FF\n")
        self.assertEqual([(e[1], e[2].speed_kmh) for e in recorder.events if e[0] == "reading"],
                         [("ffe2", 0.0), ("ffe1", 2.0)])
        self.assertEqual(recorder.buffers["ffe1"].rejected, 1)


class Link(Played):
    def test_finds_the_pad_and_connects_to_it(self):
        recorder = self.play("pad MAXFREE-FAKE\non\n")
        self.assertEqual([e[:2] for e in recorder.events[:3]],
                         [("link", Searching()), ("found", FAKE), ("link", Connected("MAXFREE-FAKE"))])

    def test_a_remembered_pad_is_waited_for_and_not_found_again(self):
        recorder = self.play("wait 5\non\n", known=FAKE)
        self.assertEqual(recorder.links(), [Waiting("MAXFREE-FAKE"), Connected("MAXFREE-FAKE")])
        self.assertNotIn("found", [e[0] for e in recorder.events])

    def test_the_iphone_holding_the_pad_is_waiting_with_bluez_s_error(self):
        recorder = self.play("held\nwait 20\non\n", known=FAKE)
        held = Waiting("MAXFREE-FAKE", recorder.source.started_at + 3.0, "Input/output error")
        self.assertEqual(recorder.links(), [Waiting("MAXFREE-FAKE"), held, Connected("MAXFREE-FAKE")])
        self.assertEqual([e[2] for e in recorder.events if e[0] == "link"], [0.0, 0.0, 20.0])

    def test_bluetooth_off_is_unavailable(self):
        recorder = self.play("bluetooth off\nbluetooth on\non\n", known=FAKE)
        self.assertEqual(recorder.links(), [Waiting("MAXFREE-FAKE"), Unavailable("Bluetooth is off"),
                                            Waiting("MAXFREE-FAKE"), Connected("MAXFREE-FAKE")])

    def test_forget_looks_for_the_pad_again(self):
        recorder = self.play("on\n", known=FAKE, then=lambda source: source.forget())
        self.assertEqual(recorder.links(), [Waiting("MAXFREE-FAKE"), Connected("MAXFREE-FAKE"), Searching(),
                                            Connected("MAXFREE-FAKE")])
        self.assertEqual([e for e in recorder.events if e[0] == "found"], [("found", FAKE)])


class Clock(Played):
    def test_a_pace_0_script_runs_at_once_on_its_virtual_clock(self):
        began = time.monotonic()
        recorder = self.play("pace 0\nat -2d\non\nbelt 3.0 3600\nat -1h\nbelt 3.0 1\n")
        self.assertLess(time.monotonic() - began, 5)
        times = [e[3] for e in recorder.events if e[0] == "reading"]
        self.assertEqual((times[0], times[7200], times[-1]), (-2 * 86400, -2 * 86400 + 3600, -3600 + 1))

    def test_a_pace_1_script_runs_in_real_time(self):
        began = time.monotonic()
        self.play("pace 1\non\nwait 0.3\n")
        self.assertGreaterEqual(time.monotonic() - began, 0.3)

    def test_connect_off_reports_off_and_drops_frames(self):
        recorder = self.play("on\nbelt 3.0 10\n", known=FAKE, enabled=False,
                             then=lambda source: source.set_enabled(True))
        self.assertEqual(recorder.links(), [Off(), Connected("MAXFREE-FAKE")])
        self.assertEqual(recorder.readings(), [])

    def test_connect_off_mid_script_releases_the_pad(self):
        recorder = self.play("on\n", known=FAKE, then=lambda source: source.set_enabled(False))
        self.assertEqual(recorder.links(), [Waiting("MAXFREE-FAKE"), Connected("MAXFREE-FAKE"), Off()])

    def test_stops_at_end(self):
        recorder = self.play("on\nend\nbelt 3.0 10\n")
        self.assertEqual(len(recorder.readings()), 1)


if __name__ == "__main__":
    unittest.main()
