from typing import IO

from bz3.backends.cffi._bz3_cffi import ffi, lib


def check_file(file) -> bool:
    if hasattr(file, "read") and hasattr(file, "write"):
        return True
    return False


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
    buffer = ffi.cast("uint8_t*", lib.PyMem_Malloc(block_size + block_size / 50 + 32))
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
    finally:
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
    pass
