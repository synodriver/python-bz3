from unittest import TestCase

from bz3.backends.cython import BZ3OmpCompressor, BZ3OmpDecompressor
from bz3 import compress, decompress, open as _open

import os

origin_data = b"124" * (600 * 10 ** 6 + 7)


class TestOmp(TestCase):

    def test_compress(self):
        compressor = BZ3OmpCompressor(10 ** 6, os.cpu_count() / 2)
        # origin_data = b"124" * (600*10 ** 6 + 7)
        compressed_data = compressor.compress(origin_data) + compressor.flush()
        self.assertEqual(decompress(compressed_data), origin_data)

    def test_decompress(self):
        # origin_data = b"124" * (10 ** 6 + 7)
        compressed_data = compress(origin_data)
        decompressor = BZ3OmpDecompressor(os.cpu_count() / 2)
        self.assertEqual(decompressor.decompress(compressed_data), origin_data)

    def test_stream(self):
        with _open("test.bz3", "wb", num_threads=16) as f:
            f.write(origin_data)
        with _open("test.bz3", "rb", num_threads=16) as f:
            self.assertEqual(f.read(),origin_data)


if __name__ == "__main__":
    import unittest

    unittest.main()
