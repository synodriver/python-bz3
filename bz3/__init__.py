"""
Copyright (c) 2008-2025 synodriver <diguohuangjiajinweijun@gmail.com>
"""

__version__ = "0.1.9"

from bz3.backends import (
    bound,
    compress_file,
    compress_into,
    decompress_file,
    decompress_into,
    libversion,
    min_memory_needed,
    orig_size_sufficient_for_decode,
    recover_file,
    test_file,
)
from bz3.bz3 import BZ3File, compress, decompress, open
