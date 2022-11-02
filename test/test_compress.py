"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import sys

sys.path.append(".")
import os
from random import randint
from unittest import TestCase

from bz3 import bound, compress_file, compress_into, decompress_file, decompress_into
from bz3 import open as bz3_open
from bz3 import test_file, libversion

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

    def test_zerocopy(self):
        outsize = bound(100)
        out = bytearray(200)
        out2 = bytearray(200)
        for i in range(1000):
            inp = bytes([randint(0, 255) for _ in range(100)])
            buffer_updated = compress_into(inp, out)
            buffer_updated = decompress_into(out[:buffer_updated], out2)
            self.assertEqual(bytes(out2[:buffer_updated]), inp)

    def test_version(self):
        self.assertTrue(isinstance(libversion(), str))

if __name__ == "__main__":
    import unittest

    unittest.main()
