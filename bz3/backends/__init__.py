"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
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
        BZ3OmpCompressor,
        BZ3OmpDecompressor,
        bound,
        compress_file,
        compress_into,
        decompress_file,
        decompress_into,
        libversion,
        recover_file,
        test_file,
    )
else:
    from bz3.backends.cffi import (
        BZ3Compressor,
        BZ3Decompressor,
        bound,
        compress_file,
        compress_into,
        decompress_file,
        decompress_into,
        libversion,
        recover_file,
        test_file,
    )
