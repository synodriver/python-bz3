"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import sys
import time
from concurrent.futures import ThreadPoolExecutor, wait

from unittest import TestCase

sys.path.append(".")

import bz3


class TestThread(TestCase):
    def test_class(self):
        start = time.time()
        futures = []
        with ThreadPoolExecutor(8) as pool:
            for i in range(1000):
                future = pool.submit(bz3.compress, b"1111" * 100000)
                futures.append(future)
            wait(futures)
            print("multithread done")
        print(f"{time.time() - start}")

    def test_single(self):
        start = time.time()
        for i in range(1000):
            bz3.compress(b"1111" * 100000)
        print("singlethread done")
        print(f"{time.time() - start}")


if __name__ == "__main__":
    import unittest

    unittest.main()
