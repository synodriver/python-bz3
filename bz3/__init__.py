"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
__version__ = "0.0.1.rc2"

from bz3.backends import compress_file, decompress_file, test_file, crc32
from bz3.bz3 import BZ3File, open, compress, decompress
