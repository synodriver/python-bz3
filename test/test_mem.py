"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""
import sys
import os
from unittest import TestCase

sys.path.append(".")

import memtrace
current_dir = os.path.dirname(__file__)


class TestSeek(TestCase):
    def test_not_leak(self):
        state = memtrace.State([(r"BZ3OmpDecompressor __cinit__ (?P<addr>\w+)",
                                 r"BZ3OmpDecompressor __dealloc__ (?P<addr>\w+)"),
                                (r"PyMem_Malloc (?P<addr>\w+)",
                                 r"PyMem_Free (?P<addr>\w+)"),
                                (r"bz3_new (?P<addr>\w+)",
                                 r"bz3_free (?P<addr>\w+)")
                                ])
        memtrace.parse_log(os.path.join(current_dir, "mem.log"), state)

    def test_not_leak2(self):
        state = memtrace.State([(r"BZ3OmpDecompressor __cinit__ (?P<addr>\w+)",
                                 r"BZ3OmpDecompressor __dealloc__ (?P<addr>\w+)"),
                                (r"PyMem_Malloc (?P<addr>\w+)",
                                 r"PyMem_Free (?P<addr>\w+)"),
                                (r"bz3_new (?P<addr>\w+)",
                                 r"bz3_free (?P<addr>\w+)")
                                ])
        memtrace.parse_log(os.path.join(current_dir, "mem2.log"), state)

    def test_not_leak3(self):
        state = memtrace.State([(r"BZ3OmpDecompressor __cinit__ (?P<addr>\w+)",
                                 r"BZ3OmpDecompressor __dealloc__ (?P<addr>\w+)"),
                                (r"PyMem_Malloc (?P<addr>\w+)",
                                 r"PyMem_Free (?P<addr>\w+)"),
                                (r"bz3_new (?P<addr>\w+)",
                                 r"bz3_free (?P<addr>\w+)")
                                ])
        memtrace.parse_log(os.path.join(current_dir, "mem3.log"), state)

    def tearDown(self) -> None:
        print("done")

if __name__ == "__main__":
    import unittest

    unittest.main()