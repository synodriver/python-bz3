"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
__version__ = "0.0.9"

from bz3.backends import (
    bound,
    compress_file,
    compress_into,
    decompress_file,
    decompress_into,
    libversion,
    test_file,
)
from bz3.bz3 import BZ3File, compress, decompress, open
