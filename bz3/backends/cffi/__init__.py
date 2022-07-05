from typing import IO, Optional

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


class BZ3Compressor:
    def __init__(self, block_size: int):
        if block_size < KiB(65) or block_size > MiB(511):
            raise ValueError("Block size must be between 65 KiB and 511 MiB")
        self.block_size = block_size
        self.state = lib.bz3_new(block_size)
        if self.state == ffi.NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = ffi.cast(
            "uint8_t*", lib.PyMem_Malloc(block_size + block_size // 50 + 32)
        )
        if self.buffer == ffi.NULL:
            lib.bz3_free(self.state)
            raise MemoryError("Failed to allocate memory")
        self.uncompressed = bytearray()
        self.have_magic_number = False  # 还没有写入magic number
        self.byteswap_buf = ffi.new("uint8_t[4]")

    def __del__(self):
        if self.state != ffi.NULL:
            lib.bz3_free(self.state)
        if self.buffer != ffi.NULL:
            lib.PyMem_Freffi.e(self.buffer)

    def compress(self, data: bytes) -> bytes:
        input_size: int = len(data)
        ret = bytearray()
        if not self.have_magic_number:
            ret.extend(b"BZ3v1")
            lib.write_neutral_s32(
                ffi.cast("uint8_t*", self.byteswap_buf), self.block_size
            )
            ret.extend(ffi.unpack(ffi.cast("char*", self.byteswap_buf), 4))
            self.have_magic_number = True

        if input_size > 0:
            self.uncompressed.extend(data)
            while len(self.uncompressed) >= self.block_size:
                lib.memcpy(
                    self.buffer, ffi.from_buffer(self.uncompressed), self.block_size
                )
                # make a copy
                new_size = lib.bz3_encode_block(
                    self.state, self.buffer, self.block_size
                )
                if new_size == -1:
                    raise ValueError(
                        "Failed to encode a block: %s", lib.bz3_strerror(self.state)
                    )

                lib.write_neutral_s32(ffi.cast("uint8_t*", self.byteswap_buf), new_size)
                ret.extend(ffi.unpack(ffi.cast("char*", self.byteswap_buf), 4))
                lib.write_neutral_s32(
                    ffi.cast("uint8_t*", self.byteswap_buf), self.block_size
                )
                ret.extend(ffi.unpack(ffi.cast("char*", self.byteswap_buf), 4))
                ret.extend(ffi.unpack(ffi.cast("char*", self.buffer), new_size))

                del self.uncompressed[: self.block_size]
        return bytes(ret)

    def flush(self) -> bytes:
        ret = bytearray()
        if self.uncompressed:
            lib.memcpy(
                self.buffer, ffi.from_buffer(self.uncompressed), len(self.uncompressed)
            )
            new_size = lib.bz3_encode_block(
                self.state, self.buffer, len(self.uncompressed)
            )
            if new_size == -1:
                raise ValueError(
                    "Failed to encode a block: %s", lib.bz3_strerror(self.state)
                )
            # ret = PyBytes_FromStringAndSize(NULL, new_size + 8)
            # if not ret:
            #     raise
            lib.write_neutral_s32(ffi.cast("uint8_t*", self.byteswap_buf), new_size)
            ret.extend(ffi.unpack(ffi.cast("char*", self.byteswap_buf), 4))
            lib.write_neutral_s32(
                ffi.cast("uint8_t*", self.byteswap_buf), len(self.uncompressed)
            )
            ret.extend(ffi.unpack(ffi.cast("char*", self.byteswap_buf), 4))
            ret.extend(ffi.unpack(ffi.cast("char*", self.buffer), new_size))
            self.uncompressed.clear()
        return bytes(ret)

    def error(self) -> str:
        if lib.bz3_last_error(self.state) != lib.BZ3_OK:
            return ffi.string(lib.bz3_strerror(self.state)).decode()
        return None


class BZ3Decompressor:
    # cdef:
    #     bz3_state * state
    #     uint8_t * buffer
    #     int32_t block_size
    #     uint8_t byteswap_buf[4]
    #     bytearray unused  # 还没解压的数据
    #     bint have_magic_number

    # cdef readonly bint eof
    # cdef readonly bint needs_input
    # cdef readonly bint needs_input

    def init_state(self, block_size: int) -> int:
        """should exec only once"""
        self.block_size = block_size
        self.state = lib.bz3_new(block_size)
        if self.state == ffi.NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = ffi.cast(
            "uint8_t*", lib.PyMem_Malloc(block_size + block_size // 50 + 32)
        )
        if self.buffer == ffi.NULL:
            lib.bz3_free(self.state)
            self.state = ffi.NULL
            raise MemoryError("Failed to allocate memory")

    def __init__(self):
        self.unused = bytearray()
        self.have_magic_number = False  # 还没有读到magic number

    def __del__(self):
        if self.state != ffi.NULL:
            lib.bz3_free(self.state)
        if self.buffer != ffi.NULL:
            lib.PyMem_Free(self.buffer)

    def decompress(self, data: bytes) -> bytes:
        input_size: int = len(data)
        ret = bytearray()
        # cdef int32_t new_size, old_size, block_size
        if input_size > 0:
            # if PyByteArray_Resize(self.unused, input_size+PyByteArray_GET_SIZE(self.unused)) < 0:
            #     raise
            # memcpy(&(PyByteArray_AS_STRING(self.unused)[PyByteArray_GET_SIZE(self.unused)-input_size]), &data[0], input_size) # self.unused.extend
            self.unused.extend(data)
            if (
                len(self.unused) > 9 and not self.have_magic_number
            ):  # 9 bytes magic number
                if bytes(self.unused[:5]) != b"BZ3v1":
                    raise ValueError("Invalid signature")
                temp = self.unused[5:9]
                block_size = lib.read_neutral_s32(
                    ffi.cast("uint8_t*", ffi.from_buffer(temp))
                )
                if block_size < KiB(65) or block_size > MiB(511):
                    raise ValueError(
                        "The input file is corrupted. Reason: Invalid block size in the header"
                    )
                self.init_state(block_size)
                del self.unused[:9]
                self.have_magic_number = True

            while True:
                if len(self.unused) < 8:  # 8 byte的 header都不够 直接返回
                    break
                new_size = lib.read_neutral_s32(
                    ffi.cast("uint8_t*", ffi.from_buffer(self.unused))
                )  # todo gcc warning but bytes is contst
                temp = self.unused[4:8]
                old_size = lib.read_neutral_s32(
                    ffi.cast("uint8_t*", ffi.from_buffer(temp))
                )
                if len(self.unused) < new_size + 8:  # 数据段不够
                    break
                temp = self.unused[8:]
                lib.memcpy(self.buffer, ffi.from_buffer(temp), new_size)

                code = lib.bz3_decode_block(self.state, self.buffer, new_size, old_size)
                if code == -1:
                    raise ValueError(
                        "Failed to decode a block: %s", lib.bz3_strerror(self.state)
                    )
                ret.extend(ffi.unpack(ffi.cast("char*", self.buffer), old_size))
                del self.unused[: new_size + 8]
        return bytes(ret)

    @property
    def unused_data(self):
        """Data found after the end of the compressed stream."""
        return bytes(self.unused)

    def error(self) -> Optional[str]:
        if lib.bz3_last_error(self.state) != lib.BZ3_OK:
            return ffi.string(lib.bz3_strerror(self.state)).decode()
        return None


def compress_file(input: IO, output: IO, block_size: int) -> None:
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


def decompress_file(input: IO, output: IO) -> None:
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


def test_file(input: IO, should_raise: bool = False) -> bool:
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
