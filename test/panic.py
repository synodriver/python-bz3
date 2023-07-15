"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""
import os
import sys

sys.path.append(".")
from bz3.backends.cython import BZ3OmpCompressor, BZ3OmpDecompressor, BZ3Compressor, BZ3Decompressor

for i in range(100):
    compressor = BZ3OmpCompressor(10 ** 6, os.cpu_count())
    del compressor
    print("compressor fine")

for i in range(100):
    decompressor = BZ3OmpDecompressor(os.cpu_count())
    del decompressor
    print("decompressor fine")

for i in range(100):
    decompressor = BZ3Compressor(10 ** 6)
    del decompressor
    print("compressor fine")

for i in range(100):
    decompressor = BZ3Decompressor()
    del decompressor
    print("decompressor fine")