# When a walk ends, and what the controller writes: walkpad-ios's
# WalkController rules, as walkpad-app's controller.test.ts checks them
# (without steps and Health), against a real Store in a scratch directory and
# a source the test drives by hand. The readings and instants are those of
# the walkpad-ios tests.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import sqlite3
import tempfile
import unittest
from pathlib import Path

from controller import IDLE_LIMIT_S, WalkController
from link import Connected, KnownPad, Off, Waiting
from recorder import PadCounters, SpeedPoint, WalkTotals
from store import Settings, Store
from tests.test_frames import frame

START = 1_800_000_000.0
PAD = KnownPad("00:00:00:00:00:00", "MAXFREE-TEST")


def at(seconds: float) -> float:
    return START + seconds


def pad_frame(speed: float, elapsed: int, km: float, kcal: int = 0) -> bytes:
    """One frame as the pad sends it: counters as the pad reads them."""
    m, s = divmod(elapsed, 60)
    return frame(f"st{20 if speed > 0 else 10},ca{kcal},dis{km:.2f},p{speed:.1f},t{m}.{s:02d}").encode("latin-1")


class HandSource:
    """link.PadSource the test drives: it records what it was asked."""

    def __init__(self):
        self.events = None
        self.calls = []

    def now(self): return START
    def start(self, events, known, enabled): self.events = events; self.calls.append(("start", known, enabled))
    def set_enabled(self, on): self.calls.append(("enabled", on))
    def forget(self): self.calls.append(("forget",))
    async def close(self): pass

    def connect(self, seconds=0):
        self.events.link_changed(Connected(PAD.name), at(seconds))

    def lose(self, seconds):
        self.events.link_changed(Waiting(PAD.name), at(seconds))

    def send(self, seconds, speed, elapsed, km, kcal=0, channel="ffe2"):
        self.events.notification(channel, pad_frame(speed, elapsed, km, kcal), at(seconds))


class Fixture(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "walkpad.db"
        self.store, _ = Store.open(self.path, import_from=None)
        self.start()

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def start(self):
        self.source = HandSource()
        self.logged = []
        self.controller = WalkController(self.store, self.source, [], log=self.logged.append)

    def restart(self):
        """The helper stopping and starting again on the same database."""
        self.store.close()
        self.store, _ = Store.open(self.path, import_from=None)
        self.start()

    def walks(self):
        return [(w.totals.started_at, w.totals.counters, w.finished) for w in self.store.walks()]


class Recording(Fixture):
    def test_connects_to_the_pad_unless_told_not_to(self):
        self.assertEqual(self.source.calls, [("start", None, True)])

    def test_stores_a_walk_once_the_belt_moves_and_follows_it(self):
        self.source.connect()
        self.source.send(0, 3.0, 1, 0.0)
        self.source.send(59, 3.0, 60, 0.05, kcal=3)
        self.assertEqual(self.walks(), [(at(0), PadCounters(60, 0.05, 3), False)])
        [walk] = self.store.walks()
        self.assertEqual(walk.totals.ended_at, at(59))
        self.assertEqual(self.controller.view().open, walk)
        self.assertEqual(self.controller.view().trace, (SpeedPoint(at(0), 3.0, 0.0), SpeedPoint(at(59), 3.0, 0.05)))
        self.assertEqual(self.store.samples(walk.id), list(self.controller.view().trace))

    def test_an_idle_pad_is_not_a_walk(self):
        self.source.connect()
        self.source.send(0, 0.0, 0, 0.0)
        self.assertEqual(self.store.walks(), [])
        self.assertEqual(self.controller.view().speed_kmh, 0.0)

    def test_the_pad_restarting_its_counters_finishes_the_walk_and_opens_the_next(self):
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5, kcal=20)
        self.source.send(10, 0.0, 0, 0.0)
        self.source.send(20, 2.0, 1, 0.0)
        self.assertEqual(self.walks(), [(at(20), PadCounters(1, 0.0, 0), False),
                                        (at(0), PadCounters(600, 0.5, 20), True)])
        self.assertEqual(self.controller.view().trace, (SpeedPoint(at(20), 2.0, 0.0),))

    def test_reads_frames_on_both_characteristics_through_separate_buffers(self):
        """Half a frame on ffe2 then a whole one on ffe1 must not splice."""
        self.source.connect()
        split = pad_frame(3.0, 62, 0.06)
        self.controller.notification("ffe2", split[:20], at(0))
        self.controller.notification("ffe1", pad_frame(3.0, 61, 0.05), at(1))
        self.assertEqual(self.walks(), [(at(1), PadCounters(61, 0.05, 0), False)])
        self.controller.notification("ffe2", split[20:], at(2))
        self.assertEqual(self.controller.view().open.totals.counters, PadCounters(62, 0.06, 0))

    def test_logs_the_first_rejected_frame_on_a_channel(self):
        self.source.connect()
        self.controller.notification("ffe1", b"EE,p9,000,FF", at(0))
        self.controller.notification("ffe1", b"EE,p9,000,FF", at(1))
        self.assertEqual(self.logged, ["rejected 1 frames on ffe1"])

    def test_a_new_connection_does_not_finish_a_frame_from_the_last_one(self):
        self.source.connect()
        data = pad_frame(3.0, 60, 0.05)
        self.source.events.notification("ffe2", data[:20], at(0))
        self.source.lose(1)
        self.source.connect(2)
        self.source.events.notification("ffe2", data[20:], at(3))
        self.assertEqual(self.store.walks(), [])


class WhenAWalkEnds(Fixture):
    def test_finishes_the_walk_when_the_pad_goes_away_with_the_belt_stopped(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.source.send(1, 0.0, 61, 0.05)
        self.source.lose(2)
        self.assertIsNone(self.controller.view().open)
        self.assertIsNone(self.controller.view().speed_kmh)
        self.assertEqual(self.walks(), [(at(0), PadCounters(61, 0.05, 0), True)])

    def test_waits_for_the_link_to_come_back_when_it_drops_with_the_belt_running(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.source.lose(1)
        self.assertEqual(self.walks(), [(at(0), PadCounters(60, 0.05, 0), False)])
        self.source.connect(5)
        self.source.send(6, 3.0, 66, 0.06)
        self.assertEqual(self.walks(), [(at(0), PadCounters(66, 0.06, 0), False)])

    def test_shows_no_speed_once_the_link_is_lost(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.assertEqual(self.controller.view().speed_kmh, 3.0)
        self.source.lose(1)
        self.assertIsNone(self.controller.view().speed_kmh)
        self.assertEqual(self.controller.view().link, Waiting(PAD.name))

    def test_finishes_a_walk_whose_counters_have_not_moved_for_ten_minutes_on_a_frame(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.source.send(1, 0.0, 60, 0.05)
        self.source.send(11 * 60, 0.0, 60, 0.05)
        self.assertIsNone(self.controller.view().open)
        self.assertEqual(self.walks(), [(at(0), PadCounters(60, 0.05, 0), True)])

    def test_finishes_a_walk_whose_counters_have_not_moved_for_ten_minutes_on_the_clock(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.source.lose(1)
        self.controller.check_idle(at(IDLE_LIMIT_S))
        self.assertEqual(self.walks(), [(at(0), PadCounters(60, 0.05, 0), False)])
        self.controller.check_idle(at(IDLE_LIMIT_S + 1))
        self.assertEqual(self.walks(), [(at(0), PadCounters(60, 0.05, 0), True)])

    def test_finishes_a_walk_on_request_and_the_pad_carrying_on_starts_the_next_from_zero(self):
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5, kcal=20)
        self.controller.finish()
        self.assertIsNone(self.controller.view().open)
        self.assertEqual(self.controller.view().trace, ())
        self.source.send(60, 3.0, 660, 0.55, kcal=23)
        self.assertEqual(self.walks(), [(at(60), PadCounters(60, 0.05, 3), False),
                                        (at(0), PadCounters(600, 0.5, 20), True)])

    def test_finishing_twice_is_finishing_once(self):
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5, kcal=20)
        self.controller.finish()
        revision = self.store.revision
        self.controller.finish()
        self.assertEqual(self.store.revision, revision)
        self.source.send(60, 3.0, 660, 0.55, kcal=23)
        self.assertEqual(self.controller.view().open.totals.counters, PadCounters(60, 0.05, 3))

    def test_forgets_a_deleted_open_walk_without_merging_the_pad_into_the_previous_one(self):
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5)
        walk = self.controller.view().open
        self.assertTrue(self.controller.delete(walk.id))
        self.assertEqual(self.store.walks(), [])
        self.assertEqual(self.store.samples(walk.id), [])
        self.assertIsNone(self.controller.view().open)
        self.source.send(60, 3.0, 660, 0.55)
        self.assertEqual(self.walks(), [(at(60), PadCounters(60, 0.05, 0), False)])

    def test_deleting_a_finished_walk_leaves_the_open_one_alone(self):
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5)
        self.source.send(10, 0.0, 0, 0.0)
        self.source.send(20, 2.0, 1, 0.0)
        finished = self.store.walks()[1]
        self.assertTrue(self.controller.delete(finished.id))
        self.assertFalse(self.controller.delete(finished.id))
        self.assertEqual(self.walks(), [(at(20), PadCounters(1, 0.0, 0), False)])


class TheSettings(Fixture):
    def test_remembers_the_pad_the_link_found(self):
        self.controller.pad_found(PAD)
        self.assertEqual(self.store.settings(), Settings(connect=True, pad=PAD))
        other = KnownPad("00:00:00:00:00:01", "MAXFREE-OTHER")
        self.controller.pad_found(other)
        self.assertEqual(self.store.settings().pad, other)
        self.assertEqual(self.controller.view().settings.pad, other)

    def test_forgets_the_pad_and_lets_the_link_look_for_one_again(self):
        self.controller.pad_found(PAD)
        self.controller.forget()
        self.assertEqual(self.store.settings(), Settings(connect=True, pad=None))
        self.assertEqual(self.source.calls[-1], ("forget",))

    def test_connect_off_is_persisted_and_hands_the_pad_back(self):
        self.controller.set_connect(False)
        self.assertFalse(self.store.settings().connect)
        self.assertEqual(self.source.calls[-1], ("enabled", False))

    def test_connect_on_again_is_persisted_and_reaches_for_the_pad(self):
        self.controller.set_connect(False)
        self.controller.set_connect(True)
        self.assertTrue(self.store.settings().connect)
        self.assertEqual(self.source.calls[-1], ("enabled", True))

    def test_connect_on_while_on_tries_again_now(self):
        self.controller.set_connect(True)
        self.assertEqual(self.source.calls, [("start", None, True), ("enabled", True)])

    def test_toggling_the_connection_answers_the_new_setting(self):
        self.assertFalse(self.controller.toggle_connect())
        self.assertTrue(self.controller.toggle_connect())
        self.assertEqual(self.source.calls[1:], [("enabled", False), ("enabled", True)])

    def test_turning_the_connection_off_mid_walk_with_the_belt_stopped_finishes_it(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.source.send(1, 0.0, 60, 0.05)
        self.controller.set_connect(False)
        self.source.events.link_changed(Off(), at(2))
        self.assertEqual(self.walks(), [(at(0), PadCounters(60, 0.05, 0), True)])


class AfterARestart(Fixture):
    """The helper restarting: a crash, an update of its code, a new version.
    The bar reloading does not restart it at all."""

    def test_tells_the_link_what_the_settings_say(self):
        self.controller.pad_found(PAD)
        self.controller.set_connect(False)
        self.restart()
        self.assertEqual(self.source.calls, [("start", PAD, False)])

    def test_resumes_the_open_walk_and_its_trace_without_splitting_it(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.source.send(30, 3.0, 90, 0.08)
        self.restart()
        self.assertEqual(len(self.controller.view().trace), 2)
        self.source.connect(33)
        self.source.send(34, 3.0, 94, 0.08)
        self.assertEqual(self.walks(), [(at(0), PadCounters(94, 0.08, 0), False)])
        self.assertEqual(len(self.controller.view().trace), 3)

    def test_stopping_with_the_belt_stopped_is_not_the_pad_going_away(self):
        self.source.connect()
        self.source.send(0, 0.0, 60, 0.05)
        self.source.send(1, 3.0, 61, 0.06)
        self.source.send(2, 0.0, 61, 0.06)
        self.restart()
        self.assertEqual(self.walks(), [(at(1), PadCounters(61, 0.06, 0), False)])
        self.assertEqual(self.controller.view().open.id, self.store.walks()[0].id)

    def test_resumes_with_the_newest_finished_walk_as_where_the_pad_stood(self):
        finished = WalkTotals(at(0), at(600), PadCounters(600, 0.5, 20), 3.0)
        open = WalkTotals(at(1000), at(1600), PadCounters(600, 0.5, 20), 3.0)
        first = self.store.open_walk(finished, closing=None)
        second = self.store.open_walk(open, closing=first.id)
        self.store.add_sample(second.id, SpeedPoint(at(1000), 3.0, 0.0))
        self.restart()
        self.assertEqual(self.controller.view().open.id, second.id)
        self.assertEqual(self.controller.view().trace, (SpeedPoint(at(1000), 3.0, 0.0),))
        self.source.connect(1605)
        self.source.send(1610, 3.0, 601, 0.51, kcal=20)
        self.assertEqual(self.controller.view().open.totals.counters, PadCounters(601, 0.51, 20))

    def test_closes_walks_cut_short_and_resumes_the_latest_one(self):
        self.store.close()
        with sqlite3.connect(self.path) as db:
            db.execute("DROP INDEX one_open_walk")
            for started in (at(0), at(1000)):
                db.execute("INSERT INTO walks (started_at, ended_at, elapsed_s, distance_km, calories, max_speed,"
                           " offset_elapsed_s, offset_distance_km, offset_calories, finished)"
                           " VALUES (?, ?, 60, 0.05, 3, 3.0, 0, 0, 0, 0)", (started, started + 60))
        db.close()
        self.store, _ = Store.open(self.path, import_from=None)
        self.start()
        self.assertEqual(self.walks(), [(at(1000), PadCounters(60, 0.05, 3), False),
                                        (at(0), PadCounters(60, 0.05, 3), True)])
        self.assertEqual(self.controller.view().open.totals.started_at, at(1000))

    def test_finishes_at_start_a_walk_left_open_past_the_idle_limit(self):
        self.source.connect()
        self.source.send(-IDLE_LIMIT_S - 1, 3.0, 60, 0.05)
        self.restart()
        self.assertIsNone(self.controller.view().open)
        self.assertEqual(self.walks(), [(at(-IDLE_LIMIT_S - 1), PadCounters(60, 0.05, 0), True)])

    def test_a_pad_that_kept_counting_after_a_finished_walk_starts_the_next_from_zero(self):
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5, kcal=20)
        self.controller.finish()
        self.restart()
        self.source.connect(65)
        self.source.send(65, 3.0, 660, 0.55, kcal=23)
        self.assertEqual(self.walks(), [(at(65), PadCounters(60, 0.05, 3), False),
                                        (at(0), PadCounters(600, 0.5, 20), True)])


if __name__ == "__main__":
    unittest.main()
