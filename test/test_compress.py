"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import os
from unittest import TestCase

os.environ["BZ3_USE_CFFI"] = "1"

from bz3 import compress_file, decompress_file, test_file, open as bz3_open


class TestCompress(TestCase):
    def test_compress(self):
        with open("test_input.tar", "rb") as inp, open("compressed.bz3", "wb") as out:
            compress_file(inp, out, 1000 * 1000)

    def test_decompress(self):
        with open("compressed.bz3", "rb") as inp, open("output.tar", "wb") as out:
            decompress_file(inp, out)

    def test_filelike(self):
        with bz3_open("test.bz3", "wt", encoding="utf-8") as f:
            f.write("test data")

    def test_filelike_read(self):
        with bz3_open("test.bz3", "rt", encoding="utf-8") as f:
            print(f.read())


if __name__ == "__main__":
    import unittest

    unittest.main()
