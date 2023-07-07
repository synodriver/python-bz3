"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""
import os

from bz3.backends.cython import BZ3OmpCompressor, BZ3OmpDecompressor

for i in range(100):
    compressor = BZ3OmpCompressor(10 ** 6, os.cpu_count())
    del compressor
    print("compressor fine")

for i in range(100):
    decompressor = BZ3OmpDecompressor(os.cpu_count())
    del decompressor
    print("decompressor fine")