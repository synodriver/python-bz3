from typing import IO

from bz3.backends.cffi._bz3_cffi import ffi, lib


def KiB(x: int) -> int:
    return x * 1024


def MiB(x: int) -> int:
    return x * 1024 * 1024


def check_file(file) -> bool:
    if hasattr(file, "read") and hasattr(file, "write"):
        return True
    return False


def crc32(crc: int, buf: bytes) -> int:
    return lib.crc32sum(crc, ffi.cast("uint8_t*", ffi.from_buffer(buf)), len(buf))


def compress(input: IO, output: IO, block_size: int) -> None:
    if not check_file(input):
        raise TypeError(
            "input except a file-like object, got %s" % type(input).__name__
        )
    if not check_file(output):
        raise TypeError(
            "output except a file-like object, got %s" % type(output).__name__
        )
    state = lib.bz3_new(block_size)
    if state == ffi.NULL:
        raise MemoryError("Failed to create a block encoder state")
    buffer = ffi.cast("uint8_t*", lib.PyMem_Malloc(block_size + block_size // 50 + 32))
    if buffer == ffi.NULL:
        lib.bz3_free(state)
        raise MemoryError
    byteswap_buf = ffi.new("uint8_t[4]")
    output.write(b"BZ3v1")
    lib.write_neutral_s32(byteswap_buf, block_size)
    output.write(ffi.unpack(ffi.cast("char*", byteswap_buf), 4))  # magic header

    try:
        while True:
            data = input.read(block_size)
            if not data:
                break
            lib.memcpy(buffer, ffi.from_buffer(data), len(data))
            new_size = lib.bz3_encode_block(state, buffer, len(data))
            if new_size == -1:
                raise ValueError(
                    "Failed to encode a block: %s", lib.bz3_strerror(state)
                )
            lib.write_neutral_s32(byteswap_buf, new_size)
            output.write(ffi.unpack(ffi.cast("char*", byteswap_buf), 4))
            lib.write_neutral_s32(byteswap_buf, len(data))
            output.write(ffi.unpack(ffi.cast("char*", byteswap_buf), 4))
            output.write(ffi.unpack(ffi.cast("char*", buffer), new_size))
            output.flush()
    finally:
        output.flush()
        lib.bz3_free(state)
        lib.PyMem_Free(buffer)


def decompress(input: IO, output: IO) -> None:
    if not check_file(input):
        raise TypeError(
            "input except a file-like object, got %s" % type(input).__name__
        )
    if not check_file(output):
        raise TypeError(
            "output except a file-like object, got %s" % type(output).__name__
        )
    # cdef bytes data
    # cdef int32_t block_size
    data: bytes = input.read(9)  # magic and block_size type: bytes len = 9
    if len(data) < 9:
        raise ValueError("Invalid file. Reason: Smaller than magic header")
    if data[:5] != b"BZ3v1":
        raise ValueError("Invalid signature")
    block_size: int = lib.read_neutral_s32(
        ffi.cast("uint8_t*", ffi.from_buffer(data[5:]))
    )
    if block_size < KiB(65) or block_size > MiB(511):
        raise ValueError(
            "The input file is corrupted. Reason: Invalid block size in the header"
        )
    state = lib.bz3_new(block_size)
    if state == ffi.NULL:
        raise MemoryError("Failed to create a block encoder state")
    buffer = ffi.cast("uint8_t*", lib.PyMem_Malloc(block_size + block_size // 50 + 32))
    if buffer == ffi.NULL:
        lib.bz3_free(state)
        raise MemoryError("Failed to allocate memory")
    # cdef uint8_t byteswap_buf[4]
    # cdef int32_t new_size, old_size, code
    try:
        while True:
            data = input.read(4)
            if len(data) < 4:
                break
            new_size = lib.read_neutral_s32(ffi.cast("uint8_t*", ffi.from_buffer(data)))
            data = input.read(4)
            if len(data) < 4:
                break
            old_size = lib.read_neutral_s32(ffi.cast("uint8_t*", ffi.from_buffer(data)))
            data = input.read(new_size)  # type: bytes
            if len(data) < new_size:
                break
            lib.memcpy(buffer, ffi.cast("uint8_t*", ffi.from_buffer(data)), new_size)
            code = lib.bz3_decode_block(state, buffer, new_size, old_size)
            if code == -1:
                raise ValueError(
                    "Failed to decode a block: %s", lib.bz3_strerror(state)
                )
            output.write(ffi.unpack(ffi.cast("char*", buffer), old_size))
            output.flush()
    finally:
        output.flush()
        lib.bz3_free(state)
        lib.PyMem_Free(buffer)


def test(input: IO, should_raise: bool = False) -> bool:
    if not check_file(input):
        raise TypeError(
            "input except a file-like object, got %s" % type(input).__name__
        )
    # cdef bytes data
    # cdef int32_t block_size
    data: bytes = input.read(9)  # magic and block_size type: bytes len = 9
    if len(data) < 9:
        if should_raise:
            raise ValueError("Invalid file. Reason: Smaller than magic header")
        return False
    if data[:5] != b"BZ3v1":
        if should_raise:
            raise ValueError("Invalid signature")
        return False
    block_size: int = lib.read_neutral_s32(
        ffi.cast("uint8_t*", ffi.from_buffer(data[5:]))
    )
    if block_size < KiB(65) or block_size > MiB(511):
        if should_raise:
            raise ValueError(
                "The input file is corrupted. Reason: Invalid block size in the header"
            )
        return False
    state = lib.bz3_new(block_size)
    if state == ffi.NULL:
        raise MemoryError("Failed to create a block encoder state")
    buffer = ffi.cast("uint8_t*", lib.PyMem_Malloc(block_size + block_size // 50 + 32))
    if buffer == ffi.NULL:
        lib.bz3_free(state)
        raise MemoryError("Failed to allocate memory")
    # cdef uint8_t byteswap_buf[4]
    # cdef int32_t new_size, old_size, code
    try:
        while True:
            data = input.read(4)
            if len(data) < 4:
                break
            new_size = lib.read_neutral_s32(ffi.cast("uint8_t*", ffi.from_buffer(data)))
            data = input.read(4)
            if len(data) < 4:
                break
            old_size = lib.read_neutral_s32(ffi.cast("uint8_t*", ffi.from_buffer(data)))
            data = input.read(new_size)  # type: bytes
            if len(data) < new_size:
                break
            lib.memcpy(buffer, ffi.cast("uint8_t*", ffi.from_buffer(data)), new_size)
            code = lib.bz3_decode_block(state, buffer, new_size, old_size)
            if code == -1:
                if should_raise:
                    raise ValueError(
                        "Failed to decode a block: %s", lib.bz3_strerror(state)
                    )
                return False
        return True
    finally:
        lib.bz3_free(state)
        lib.PyMem_Free(buffer)
