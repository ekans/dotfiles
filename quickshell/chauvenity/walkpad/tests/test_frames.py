# The frame decoder and FrameBuffer: walkpad-ios's PadFrameTests and
# FrameBufferTests, values unchanged, plus the buffer cap from walkpad-app.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import unittest

from frames import FrameBuffer, PadReading, PadStatus, parse_frame


def frame(fields: str) -> str:
    """Builds a frame with a valid checksum around `fields`."""
    body = f"EE,{fields}"
    return f"{body},{(sum(body.encode('latin-1')) + 162) % 256:03d},FF"


class ParseFrame(unittest.TestCase):
    def test_decodes_a_real_frame(self):
        self.assertEqual(
            parse_frame("EE,c0,sf0,st20,mp6.0,ms15,mi1.0,ca36,dis1.23,h00,s0,p3.0,t24.38,077,FF"),
            PadReading(speed_kmh=3.0, distance_km=1.23, calories=36, elapsed_s=24 * 60 + 38,
                       heart_rate=0, status=PadStatus.RUNNING, max_speed_kmh=6.0, min_speed_kmh=1.0))

    def test_rejects_corrupted_frames(self):
        # Both captured from the pad by the BB plugin, garbled in the air.
        for corrupted in ("EE,c0,sf0,st10,mp6.0,ms15,mi1.0,ca24,dis0.80,h00,s0,p0.,,t16.51,068,FF",
                          "EE,c0,sf0,st10,mp6.0,ms15,mi1.0,ca1,dis0.5,h00ss0,p0.0,t3.31,214,FF"):
            with self.subTest(corrupted):
                self.assertIsNone(parse_frame(corrupted))

    def test_rejects_what_is_not_a_frame(self):
        for text in ("", "EE,FF", "XX,p3.0,t1.00,000,FF"):
            with self.subTest(text):
                self.assertIsNone(parse_frame(text))

    def test_decodes_status(self):
        for code, status in (("10", PadStatus.IDLE), ("20", PadStatus.RUNNING),
                             ("30", PadStatus.SPEEDING_UP), ("40", PadStatus.SLOWING_DOWN),
                             ("99", PadStatus.UNKNOWN)):
            with self.subTest(code):
                self.assertEqual(parse_frame(frame(f"st{code},p1.0")).status, status)

    def test_treats_missing_fields_as_zero(self):
        reading = parse_frame(frame("c0"))
        self.assertEqual(reading.speed_kmh, 0)
        self.assertEqual(reading.elapsed_s, 0)
        self.assertEqual(reading.status, PadStatus.UNKNOWN)

    # Where Python's parsing differs from Swift's (frames.py header).
    def test_rounds_calories_half_away_from_zero_as_swift(self):
        self.assertEqual(parse_frame(frame("ca36.5,p1.0")).calories, 37)

    def test_reads_a_checksum_strictly(self):
        body = "EE,p1.0"
        checksum = (sum(body.encode("latin-1")) + 162) % 256
        self.assertIsNone(parse_frame(f"{body}, {checksum},FF"))

    def test_skips_a_field_with_a_non_ascii_digit(self):
        self.assertEqual(parse_frame(frame("p\xb2,dis1.00")).speed_kmh, 0)


class Buffer(unittest.TestCase):
    def test_joins_a_frame_split_across_notifications(self):
        buffer = FrameBuffer()
        data = frame("st20,p3.0,dis1.00,t10.00").encode("latin-1")
        self.assertEqual(buffer.append(data[:20]), [])
        self.assertEqual([r.elapsed_s for r in buffer.append(data[20:])], [600])

    def test_splits_several_frames_in_one_notification(self):
        buffer = FrameBuffer()
        readings = buffer.append((frame("p1.0") + frame("p2.0")).encode("latin-1"))
        self.assertEqual([r.speed_kmh for r in readings], [1.0, 2.0])

    def test_skips_noise_before_a_frame_and_counts_bad_ones(self):
        buffer = FrameBuffer()
        readings = buffer.append(("xyz" + frame("p1.0") + "EE,p9,000,FF").encode("latin-1"))
        self.assertEqual([r.speed_kmh for r in readings], [1.0])
        self.assertEqual(buffer.rejected, 1)

    def test_drops_a_runaway_buffer_that_never_closes_a_frame(self):
        buffer = FrameBuffer()
        buffer.append(b"E" * 513)
        self.assertEqual([r.speed_kmh for r in buffer.append(frame("p1.0").encode("latin-1"))], [1.0])

    def test_logs_the_first_rejection_and_every_hundredth_after(self):
        buffer = FrameBuffer()
        logged = []
        for i in range(1, 202):
            buffer.append(b"EE,p9,000,FF")
            if buffer.should_log_rejection():
                logged.append(buffer.rejected)
        self.assertEqual(logged, [1, 101, 201])


if __name__ == "__main__":
    unittest.main()
