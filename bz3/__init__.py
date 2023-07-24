"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""
__version__ = "0.1.3"

from bz3.backends import (
    bound,
    compress_file,
    compress_into,
    decompress_file,
    decompress_into,
    libversion,
    recover_file,
    test_file,
)
from bz3.bz3 import BZ3File, compress, decompress, open
