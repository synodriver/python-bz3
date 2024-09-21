"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""
import secrets
import sys
from unittest import TestCase

sys.path.append(".")
from bz3 import bound, compress, compress_into, decompress, decompress_into


def generate_random_bytes(n):
    length = secrets.randbelow(n + 1)
    random_bytes = secrets.token_bytes(length)
    return random_bytes


class FuzzTest(TestCase):
    def setUp(self) -> None:
        pass

    def tearDown(self) -> None:
        pass

    def test_randombytes(self):
        for i in range(1000):
            b = generate_random_bytes(1000)
            self.assertEqual(decompress(compress(b)), b)

    def test_randombytes_zerocopy(self):
        for i in range(1000):
            b = generate_random_bytes(1000)
            outsize = (
                bound(len(b)) * 2
            )  # This is a bug(?) related to upstream. bz3_compress sometimes consumes more buffer than bz3_bound expected
            outbuff = bytearray(outsize)
            outbuff2 = bytearray(outsize)
            compressed_size = compress_into(b, outbuff)
            decompressed_size = decompress_into(outbuff[:compressed_size], outbuff2)
            self.assertEqual(bytes(outbuff2[:decompressed_size]), b)


if __name__ == "__main__":
    import unittest

    unittest.main()
