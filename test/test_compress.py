"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import os
from unittest import TestCase

from bz3 import compress_file, decompress_file
from bz3 import open as bz3_open
from bz3 import test_file


# os.environ["BZ3_USE_CFFI"] = "1"


class TestCompress(TestCase):
    def test_compress(self):
        with open("test_input.tar", "rb") as inp, open("compressed.bz3", "wb") as out:
            compress_file(inp, out, 1000 * 1000)

    def test_decompress(self):
        with open("compressed.bz3", "rb") as inp, open("output.tar", "wb") as out:
            decompress_file(inp, out)

    def test_filelike_write(self):
        with bz3_open("test.bz3", "wt", encoding="utf-8") as f:
            f.write("test data")
        with bz3_open("test.bz3", "rt", encoding="utf-8") as f:
            self.assertEqual(f.read(), "test data")


if __name__ == "__main__":
    import unittest

    unittest.main()
