"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""
import sys
import os
from unittest import TestCase

sys.path.append(".")

import bz3

current_dir = os.path.dirname(__file__)


class TestSeek(TestCase):
    def setUp(self) -> None:
        if not os.path.exists(os.path.join(current_dir, "test.bz3")):
            with bz3.open(os.path.join(current_dir, "test.bz3"), "wb", num_threads=os.cpu_count()) as f:
                f.write(b"1111" * 1000)

    def test_seek(self):
        with bz3.open(os.path.join(current_dir, "test.bz3"), "rb", num_threads=os.cpu_count()) as f:
            for i in range(100):
                self.assertEqual(f.read(1000), b"1" * 1000, "read error")
                f.seek(0, 2)
                f.seek(0, 0)
            pass

    def tearDown(self) -> None:
        print("done")

if __name__ == "__main__":
    import unittest

    unittest.main()
