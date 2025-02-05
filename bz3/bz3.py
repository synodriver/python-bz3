"""
Copyright (c) 2008-2023 synodriver <diguohuangjiajinweijun@gmail.com>
"""

import io
import os
from builtins import open as _builtin_open
from threading import RLock
from typing import IO

from bz3.backends import BZ3Compressor, BZ3Decompressor
from bz3.compression import BaseStream, DecompressReader

try:
    from bz3.backends import BZ3OmpCompressor, BZ3OmpDecompressor
except ImportError:
    pass

_MODE_CLOSED = 0
_MODE_READ = 1
# Value 2 no longer used
_MODE_WRITE = 3


class BZ3File(BaseStream):
    """A file object providing transparent bzip3 (de)compression.

    A BZ3File can act as a wrapper for an existing file object, or refer
    directly to a named file on disk.

    Note that BZ3File provides a *binary* file interface - data read is
    returned as bytes, and data to be written should be given as bytes.
    """

    def __init__(
        self,
        filename,
        mode: str = "r",
        block_size: int = 1024 * 1024,
        num_threads: int = 1,
        ignore_error: bool = False,
    ):
        self._lock = RLock()
        self._fp = None  # type: IO
        self._closefp = False
        self._mode = _MODE_CLOSED
        if mode in ("", "r", "rb"):
            mode = "rb"
            mode_code = _MODE_READ
        elif mode in ("w", "wb"):
            mode = "wb"
            mode_code = _MODE_WRITE
            self._compressor = (
                BZ3Compressor(block_size)
                if num_threads == 1
                else BZ3OmpCompressor(block_size, num_threads)
            )
        elif mode in ("x", "xb"):
            mode = "xb"
            mode_code = _MODE_WRITE
            self._compressor = (
                BZ3Compressor(block_size)
                if num_threads == 1
                else BZ3OmpCompressor(block_size, num_threads)
            )
        elif mode in ("a", "ab"):
            mode = "ab"
            mode_code = _MODE_WRITE
            self._compressor = (
                BZ3Compressor(block_size)
                if num_threads == 1
                else BZ3OmpCompressor(block_size, num_threads)
            )
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
            raw = (
                DecompressReader(self._fp, BZ3Decompressor, ignore_error=ignore_error)
                if num_threads == 1
                else DecompressReader(
                    self._fp,
                    BZ3OmpDecompressor,
                    numthreads=num_threads,
                    ignore_error=ignore_error,
                )
            )
            self._buffer = io.BufferedReader(raw)
        else:
            self._pos = 0

    def close(self):
        """Flush and close the file.

        May be called more than once without error. Once the file is
        closed, any other operation on it will raise a ValueError.
        """
        with self._lock:
            if self._mode == _MODE_CLOSED:
                return
            try:
                if self._mode == _MODE_READ:
                    self._buffer.close()
                elif self._mode == _MODE_WRITE:
                    self._fp.write(self._compressor.flush())
                    self._compressor = None
            finally:
                try:
                    if self._closefp:
                        self._fp.close()
                finally:
                    self._fp = None
                    self._closefp = False
                    self._mode = _MODE_CLOSED
                    self._buffer = None

    @property
    def closed(self):
        """True if this file is closed."""
        return self._mode == _MODE_CLOSED

    def fileno(self):
        """Return the file descriptor for the underlying file."""
        self._check_not_closed()
        return self._fp.fileno()

    def seekable(self):
        """Return whether the file supports seeking."""
        return self.readable() and self._buffer.seekable()

    def readable(self):
        """Return whether the file was opened for reading."""
        self._check_not_closed()
        return self._mode == _MODE_READ

    def writable(self):
        """Return whether the file was opened for writing."""
        self._check_not_closed()
        return self._mode == _MODE_WRITE

    def peek(self, n=0):
        """Return buffered data without advancing the file position.

        Always returns at least one byte of data, unless at EOF.
        The exact number of bytes returned is unspecified.
        """
        with self._lock:
            self._check_can_read()
            # Relies on the undocumented fact that BufferedReader.peek()
            # always returns at least one byte (except at EOF), independent
            # of the value of n
            return self._buffer.peek(n)

    def read(self, size=-1):
        """Read up to size uncompressed bytes from the file.

        If size is negative or omitted, read until EOF is reached.
        Returns b'' if the file is already at EOF.
        """
        with self._lock:
            self._check_can_read()
            return self._buffer.read(size)

    def read1(self, size=-1):
        """Read up to size uncompressed bytes, while trying to avoid
        making multiple reads from the underlying stream. Reads up to a
        buffer's worth of data if size is negative.

        Returns b'' if the file is at EOF.
        """
        with self._lock:
            self._check_can_read()
            if size < 0:
                size = io.DEFAULT_BUFFER_SIZE
            return self._buffer.read1(size)

    def readinto(self, b):
        """Read bytes into b.

        Returns the number of bytes read (0 for EOF).
        """
        with self._lock:
            self._check_can_read()
            return self._buffer.readinto(b)

    def readline(self, size=-1):
        """Read a line of uncompressed bytes from the file.

        The terminating newline (if present) is retained. If size is
        non-negative, no more than size bytes will be read (in which
        case the line may be incomplete). Returns b'' if already at EOF.
        """
        if not isinstance(size, int):
            if not hasattr(size, "__index__"):
                raise TypeError("Integer argument expected")
            size = size.__index__()
        with self._lock:
            self._check_can_read()
            return self._buffer.readline(size)

    def readlines(self, size=-1):
        """Read a list of lines of uncompressed bytes from the file.

        size can be specified to control the number of lines read: no
        further lines will be read once the total size of the lines read
        so far equals or exceeds size.
        """
        if not isinstance(size, int):
            if not hasattr(size, "__index__"):
                raise TypeError("Integer argument expected")
            size = size.__index__()
        with self._lock:
            self._check_can_read()
            return self._buffer.readlines(size)

    def write(self, data):
        """Write a byte string to the file.

        Returns the number of uncompressed bytes written, which is
        always len(data). Note that due to buffering, the file on disk
        may not reflect the data written until close() is called.
        """
        with self._lock:
            self._check_can_write()
            compressed = self._compressor.compress(data)
            self._fp.write(compressed)
            self._pos += len(data)
            return len(data)

    def writelines(self, seq):
        """Write a sequence of byte strings to the file.

        Returns the number of uncompressed bytes written.
        seq can be any iterable yielding byte strings.

        Line separators are not added between the written byte strings.
        """
        with self._lock:
            return BaseStream.writelines(self, seq)

    def seek(self, offset, whence=io.SEEK_SET):
        """Change the file position.

        The new position is specified by offset, relative to the
        position indicated by whence. Values for whence are:

            0: start of stream (default); offset must not be negative
            1: current stream position
            2: end of stream; offset must not be positive

        Returns the new file position.

        Note that seeking is emulated, so depending on the parameters,
        this operation may be extremely slow.
        """
        with self._lock:
            self._check_can_seek()
            return self._buffer.seek(offset, whence)

    def tell(self):
        """Return the current file position."""
        with self._lock:
            self._check_not_closed()
            if self._mode == _MODE_READ:
                return self._buffer.tell()
            return self._pos


def open(
    filename,
    mode: str = "rb",
    block_size: int = 1024 * 1024,
    encoding: str = None,
    errors: str = None,
    newline: str = None,
    num_threads: int = 1,
    ignore_error: bool = False,
) -> BZ3File:
    """Open a bzip3-compressed file in binary or text mode.

    The filename argument can be an actual filename (a str, bytes, or
    PathLike object), or an existing file object to read from or write
    to.

    The mode argument can be "r", "rb", "w", "wb", "x", "xb", "a" or
    "ab" for binary mode, or "rt", "wt", "xt" or "at" for text mode.
    The default mode is "rb", and the default compresslevel is 9.

    For binary mode, this function is equivalent to the BZ3File
    constructor: BZ3File(filename, mode, ...). In this case,
    the encoding, errors and newline arguments must not be provided.

    For text mode, a BZ3File object is created, and wrapped in an
    io.TextIOWrapper instance with the specified encoding, error
    handling behavior, and line ending(s).

    """
    if "t" in mode:
        if "b" in mode:
            raise ValueError("Invalid mode: %r" % (mode,))
    else:
        if encoding is not None:
            raise ValueError("Argument 'encoding' not supported in binary mode")
        if errors is not None:
            raise ValueError("Argument 'errors' not supported in binary mode")
        if newline is not None:
            raise ValueError("Argument 'newline' not supported in binary mode")

    bz_mode = mode.replace("t", "")
    binary_file = BZ3File(filename, bz_mode, block_size, num_threads, ignore_error)

    if "t" in mode:
        return io.TextIOWrapper(binary_file, encoding, errors, newline)
    else:
        return binary_file


def compress(data: bytes, block_size: int = 1024 * 1024, num_threads: int = 1) -> bytes:
    """Compress a block of data.

    block_size, if given, must be a number between 65 KiB and 511 MiB as bytes.
    num_threads, which control how many threads to use. if given, must >= 1.

    For incremental compression, use a BZ3Compressor object instead.
    """
    if num_threads == 1:
        compressor = BZ3Compressor(block_size)
    elif num_threads > 1:
        compressor = BZ3OmpCompressor(block_size, num_threads)
    else:
        raise ValueError("num_threads must greater or equal to 1")
    return compressor.compress(data) + compressor.flush()


def decompress(data: bytes, num_threads: int = 1) -> bytes:
    """Decompress a block of data.
    num_threads, which control how many threads to use. if given, must >= 1.

    For incremental decompression, use a BZ3Decompressor object instead.
    """
    if num_threads == 1:
        decomp = BZ3Decompressor()
    elif num_threads > 1:
        decomp = BZ3OmpDecompressor(num_threads)
    else:
        raise ValueError("num_threads must greater or equal to 1")
    return decomp.decompress(data)
