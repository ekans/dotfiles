# Readings to walks: walkpad-ios's WalkRecorderTests, values unchanged.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import unittest

from frames import PadReading, PadStatus
from recorder import MAX_GAP_S, Change, PadCounters, WalkRecorder, WalkTotals

START = 1_800_000_000.0


def at(seconds: float) -> float:
    return START + seconds


def reading(speed: float, elapsed: int, km: float, kcal: int = 0) -> PadReading:
    return PadReading(speed_kmh=speed, distance_km=km, calories=kcal, elapsed_s=elapsed, heart_rate=0,
                      status=PadStatus.RUNNING if speed > 0 else PadStatus.IDLE,
                      max_speed_kmh=6, min_speed_kmh=1)


class Recorder(unittest.TestCase):
    def test_an_idle_pad_is_not_a_walk(self):
        recorder = WalkRecorder.resume(None)
        self.assertEqual(recorder.record(reading(0, 0, 0), at(0))[0], Change.IGNORED)
        self.assertIsNone(recorder.current)

    def test_the_belt_moving_opens_a_walk_that_follows_the_counters(self):
        recorder = WalkRecorder.resume(None)
        self.assertEqual(recorder.record(reading(3, 1, 0.0), at(0))[0], Change.OPENED)
        self.assertEqual(recorder.record(reading(3, 60, 0.05, kcal=3), at(59))[0], Change.UPDATED)
        walk = recorder.current
        self.assertEqual(walk.started_at, at(0))
        self.assertEqual(walk.ended_at, at(59))
        self.assertEqual(walk.counters, PadCounters(60, 0.05, 3))

    def test_a_pause_stays_one_walk_and_repeated_frames_are_ignored(self):
        recorder = WalkRecorder.resume(None)
        recorder.record(reading(3, 60, 0.05), at(0))
        self.assertEqual(recorder.record(reading(0, 60, 0.05), at(1))[0], Change.UPDATED)
        self.assertEqual(recorder.record(reading(0, 60, 0.05), at(2))[0], Change.IGNORED)
        self.assertEqual(recorder.record(reading(3, 61, 0.06), at(300))[0], Change.UPDATED)
        self.assertEqual(recorder.current.started_at, at(0))

    def test_counters_restarting_opens_a_new_walk(self):
        recorder = WalkRecorder.resume(None)
        recorder.record(reading(3, 600, 0.5), at(0))
        self.assertEqual(recorder.record(reading(0, 0, 0), at(10))[0], Change.IGNORED)
        self.assertEqual(recorder.record(reading(2, 1, 0), at(20))[0], Change.OPENED)
        self.assertEqual(recorder.current.started_at, at(20))

    def test_a_long_gap_opens_a_new_walk_even_with_continuous_counters(self):
        recorder = WalkRecorder.resume(None)
        recorder.record(reading(3, 60, 0.05), at(0))
        self.assertEqual(recorder.record(reading(3, 61, 0.06), at(MAX_GAP_S + 1))[0], Change.OPENED)

    def test_a_walk_picked_up_after_the_helper_finished_one_starts_from_zero(self):
        recorder = WalkRecorder.resume(None)
        recorder.record(reading(3, 600, 0.5, kcal=20), at(0))
        recorder.finish()
        self.assertIsNone(recorder.current)
        self.assertEqual(recorder.record(reading(0, 600, 0.5, kcal=20), at(5))[0], Change.IGNORED)
        self.assertEqual(recorder.record(reading(3, 660, 0.55, kcal=23), at(65))[0], Change.OPENED)
        self.assertEqual(recorder.current.counters, PadCounters(60, 0.05, 3))
        self.assertEqual(recorder.record(reading(3, 720, 0.6, kcal=26), at(125))[0], Change.UPDATED)
        self.assertEqual(recorder.current.counters.elapsed_s, 120)

    def test_the_offset_survives_a_restart(self):
        finished = WalkTotals(started_at=at(0), ended_at=at(600), counters=PadCounters(600, 0.5, 20),
                              max_speed_kmh=3)
        recorder = WalkRecorder.resume(None, last_finished=finished)
        recorder.record(reading(3, 660, 0.55, kcal=23), at(700))
        self.assertEqual(recorder.current.counters.elapsed_s, 60)

    def test_an_open_walk_resumes_after_a_restart(self):
        open_walk = WalkTotals(started_at=at(0), ended_at=at(600), counters=PadCounters(600, 0.5, 20),
                               max_speed_kmh=3)
        recorder = WalkRecorder.resume(open_walk)
        self.assertEqual(recorder.record(reading(3, 610, 0.51), at(610))[0], Change.UPDATED)
        self.assertEqual(recorder.current.started_at, at(0))

    def test_speed_points_are_throttled_except_when_the_speed_changes(self):
        recorder = WalkRecorder.resume(None)
        self.assertIsNotNone(recorder.record(reading(3, 1, 0), at(0))[1])
        self.assertIsNone(recorder.record(reading(3, 2, 0.001), at(0.3))[1])
        self.assertEqual(recorder.record(reading(4, 2, 0.002), at(0.6))[1].speed_kmh, 4)
        self.assertIsNotNone(recorder.record(reading(4, 3, 0.003), at(1.7))[1])


if __name__ == "__main__":
    unittest.main()
