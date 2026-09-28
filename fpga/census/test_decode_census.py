"""Regression tests for untrusted census capture framing."""

import unittest

from decode_census import PRE, crc16, frames


NPINS = 102
NBYTES = 13
NDETAIL = 31
CAPN = 63


def frame(*, npins=NPINS, ndetail=NDETAIL, capn=CAPN):
    body = bytes([3, npins, ndetail, capn])
    body += bytes(3 * NBYTES + 2 * NDETAIL + 4 + 2 * CAPN)
    checksum = crc16(body)
    return PRE + body + checksum.to_bytes(2, "big")


class FrameTests(unittest.TestCase):
    def decode(self, data):
        return list(frames(iter([data]), NBYTES, NDETAIL, NPINS))

    def test_valid_frame(self):
        decoded = self.decode(frame())
        self.assertEqual(len(decoded), 1)
        snapshot, low, high, edges, stats = decoded[0]
        self.assertEqual(len(snapshot), NPINS)
        self.assertEqual(len(low), NPINS)
        self.assertEqual(len(high), NPINS)
        self.assertEqual(len(edges), NDETAIL)
        self.assertEqual(len(stats["words"]), CAPN)

    def test_bad_counts_resynchronize_to_next_frame(self):
        good = frame()
        for bad in (frame(npins=255), frame(ndetail=255), frame(capn=255)):
            with self.subTest(header=bad[4:8]):
                self.assertEqual(len(self.decode(bad + good)), 1)

    def test_bad_pinmap_rejected(self):
        with self.assertRaises(ValueError):
            list(frames(iter([frame()]), NBYTES - 1, NDETAIL, NPINS))


if __name__ == "__main__":
    unittest.main()
