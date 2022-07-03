"""
Copyright (c) 2008-2021 synodriver <synodriver@gmail.com>
"""
import bz2
import io
import os
from builtins import open as _builtin_open
from threading import RLock

from bz3.backends import BZ3Compressor, BZ3Decompressor
from bz3.compression import BaseStream, DecompressReader

_MODE_CLOSED = 0
_MODE_READ = 1
# Value 2 no longer used
_MODE_WRITE = 3


class BZ3File(BaseStream):
    """A file object providing transparent bzip2 (de)compression.

    A BZ3File can act as a wrapper for an existing file object, or refer
    directly to a named file on disk.

    Note that BZ3File provides a *binary* file interface - data read is
    returned as bytes, and data to be written should be given as bytes.
    """

    def __init__(self, filename, mode: str = "r", block_size: int = 1024 * 1024):
        self._lock = RLock()
        self._fp = None
        self._closefp = False
        self._mode = _MODE_CLOSED
        if mode in ("", "r", "rb"):
            mode = "rb"
            mode_code = _MODE_READ
        elif mode in ("w", "wb"):
            mode = "wb"
            mode_code = _MODE_WRITE
            self._compressor = BZ3Compressor(block_size)
        elif mode in ("x", "xb"):
            mode = "xb"
            mode_code = _MODE_WRITE
            self._compressor = BZ3Compressor(block_size)
        elif mode in ("a", "ab"):
            mode = "ab"
            mode_code = _MODE_WRITE
            self._compressor = BZ3Compressor(block_size)
        else:
            raise ValueError("Invalid mode: %r" % (mode,))

        if isinstance(filename, (str, bytes, os.PathLike)):
            self._fp = _builtin_open(filename, mode)
            self._closefp = True
            self._mode = mode_code
        elif hasattr(filename, "read") or hasattr(filename, "write"):
            self._fp = filename
            self._mode = mode_code
        else:
            raise TypeError("filename must be a str, bytes, file or PathLike object")

        if self._mode == _MODE_READ:
            raw = DecompressReader(self._fp, BZ3Decompressor, trailing_error=OSError)
            self._buffer = io.BufferedReader(raw)
        else:
            self._pos = 0
