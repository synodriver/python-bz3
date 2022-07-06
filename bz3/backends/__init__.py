"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import os
import platform

impl = platform.python_implementation()


def _should_use_cffi() -> bool:
    ev = os.getenv("BZ3_USE_CFFI")
    if ev is not None:
        return True
    if impl == "CPython":
        return False
    else:
        return True


if not _should_use_cffi():
    from bz3.backends.cython import (
        BZ3Compressor,
        BZ3Decompressor,
        compress_file,
        crc32,
        decompress_file,
        test_file,
    )
else:
    from bz3.backends.cffi import (
        BZ3Compressor,
        BZ3Decompressor,
        compress_file,
        crc32,
        decompress_file,
        test_file,
    )
