"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import os
from unittest import TestCase

os.environ["BZ3_USE_CFFI"] = "1"

from bz3 import compress, decompress, test


class TestCompress(TestCase):
    def test_compress(self):
        with open("test_input.tar", "rb") as inp, open("compressed.bz3", "wb") as out:
            compress(inp, out, 1000 * 1000)

    def test_decompress(self):
        with open("compressed.bz3", "rb") as inp, open("output.tar", "wb") as out:
            decompress(inp, out)


if __name__ == "__main__":
    import unittest

    unittest.main()
