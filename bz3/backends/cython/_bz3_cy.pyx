# cython: language_level=3
# cython: cdivision=True
cimport cython
from cpython.bytearray cimport (PyByteArray_AS_STRING, PyByteArray_GET_SIZE,
                                PyByteArray_Resize)
from cpython.bytes cimport (PyBytes_AS_STRING, PyBytes_FromStringAndSize,
                            PyBytes_GET_SIZE)
from cpython.mem cimport PyMem_Free, PyMem_Malloc
from cpython.object cimport PyObject_HasAttrString
from libc.stdint cimport int32_t, uint8_t, uint32_t
from libc.string cimport memcpy, strncmp

from bz3.backends.cython.bzip3 cimport (BZ3_OK, KiB, MiB, bz3_decode_block,
                                        bz3_decode_blocks, bz3_encode_block,
                                        bz3_encode_blocks, bz3_free,
                                        bz3_last_error, bz3_new, bz3_state,
                                        bz3_strerror, crc32sum,
                                        read_neutral_s32, write_neutral_s32)


cdef const char* magic = "BZ3v1"

cdef inline uint8_t PyFile_Check(object file):
    if PyObject_HasAttrString(file, "read") and PyObject_HasAttrString(file, "write"):  # should we check seek method?
        return 1
    return 0

cpdef inline uint32_t crc32(uint32_t crc, const uint8_t[::1] buf):
    return crc32sum(crc, &buf[0], <size_t>buf.shape[0])


@cython.final
cdef class BZ3Compressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        int32_t block_size
        uint8_t byteswap_buf[4]
        bytearray uncompressed
        bint have_magic_number

    def __cinit__(self, int32_t block_size):
        if block_size < KiB(65) or block_size > MiB(511):
            raise ValueError("Block size must be between 65 KiB and 511 MiB")
        self.block_size = block_size
        self.state = bz3_new(block_size)
        if self.state == NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = <uint8_t *>PyMem_Malloc(block_size + block_size / 50 + 32)
        if self.buffer == NULL:
            bz3_free(self.state)
            self.state = NULL
            raise MemoryError("Failed to allocate memory")
        self.uncompressed = bytearray()
        self.have_magic_number = 0 # 还没有写入magic number

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL

    cpdef inline bytes compress(self, const uint8_t[::1] data) with gil:
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t new_size
        cdef bytearray ret = bytearray()
        if not self.have_magic_number:
            if PyByteArray_Resize(ret, 9) < 0:
                raise
            memcpy(PyByteArray_AS_STRING(ret), magic, 5)
            write_neutral_s32(self.byteswap_buf, self.block_size)
            memcpy(&(PyByteArray_AS_STRING(ret)[5]), self.byteswap_buf, 4)
            self.have_magic_number = 1

        if input_size > 0:
            if PyByteArray_Resize(self.uncompressed, input_size+PyByteArray_GET_SIZE(self.uncompressed)) < 0:
                raise
            memcpy(&(PyByteArray_AS_STRING(self.uncompressed)[PyByteArray_GET_SIZE(self.uncompressed)-input_size]), &data[0], input_size) # todo? direct copy to bytearray
            while PyByteArray_GET_SIZE(self.uncompressed)>=self.block_size:
                memcpy(self.buffer, PyByteArray_AS_STRING(self.uncompressed), <size_t>self.block_size)
                # make a copy
                new_size = bz3_encode_block(self.state, self.buffer, self.block_size)
                if new_size == -1:
                    raise ValueError("Failed to encode a block: %s", bz3_strerror(self.state))
                if PyByteArray_Resize(ret, PyByteArray_GET_SIZE(ret) + new_size + 8) < 0:
                    raise

                write_neutral_s32(self.byteswap_buf, new_size)
                memcpy(<void *> &(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-new_size-8]), <void*>self.byteswap_buf, 4)
                write_neutral_s32(self.byteswap_buf, self.block_size)
                memcpy(<void *> &(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-new_size-4]), <void *> self.byteswap_buf, 4)
                memcpy(<void *> &(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-new_size]), self.buffer, <size_t>new_size)

                del self.uncompressed[:self.block_size]
        return bytes(ret)

    cpdef inline bytes flush(self) with gil:
        cdef bytes ret = b""
        cdef int32_t new_size
        if self.uncompressed:
            memcpy(self.buffer, PyByteArray_AS_STRING(self.uncompressed), <size_t>PyByteArray_GET_SIZE(self.uncompressed))
            new_size = bz3_encode_block(self.state, self.buffer, <int32_t>PyByteArray_GET_SIZE(self.uncompressed))
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s", bz3_strerror(self.state))
            ret = PyBytes_FromStringAndSize(NULL, new_size + 8)
            if not ret:
                raise
            write_neutral_s32(self.byteswap_buf, new_size)
            memcpy(PyBytes_AS_STRING(ret), self.byteswap_buf, 4)
            write_neutral_s32(self.byteswap_buf, <int32_t>PyByteArray_GET_SIZE(self.uncompressed))
            memcpy(&(PyBytes_AS_STRING(ret)[4]), self.byteswap_buf, 4)
            memcpy(&(PyBytes_AS_STRING(ret)[8]), self.buffer,<size_t> new_size)
            self.uncompressed.clear()
        return ret

    cpdef inline str error(self):
        if bz3_last_error(self.state) != BZ3_OK:
            return (<bytes>bz3_strerror(self.state)).decode()
        return None


@cython.final
cdef class BZ3Decompressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        int32_t block_size
        uint8_t byteswap_buf[4]
        bytearray unused  # 还没解压的数据
        bint have_magic_number
    
    cdef readonly bint eof
    cdef readonly bint needs_input

    cdef inline int init_state(self, int32_t block_size):
        """should exec only once"""
        self.block_size = block_size
        self.state = bz3_new(block_size)
        if self.state == NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = <uint8_t *> PyMem_Malloc(block_size + block_size / 50 + 32)
        if self.buffer == NULL:
            bz3_free(self.state)
            self.state = NULL
            raise MemoryError("Failed to allocate memory")

    def __cinit__(self):
        self.unused = bytearray()
        self.have_magic_number = 0 # 还没有读到magic number
        self.needs_input = 1
        self.eof = 0

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL

    cpdef inline bytes decompress(self, const uint8_t[::1] data) with gil:
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t code
        cdef bytearray ret = bytearray()
        cdef int32_t new_size, old_size, block_size
        if input_size > 0:
            if PyByteArray_Resize(self.unused, input_size+PyByteArray_GET_SIZE(self.unused)) < 0:
                raise
            memcpy(&(PyByteArray_AS_STRING(self.unused)[PyByteArray_GET_SIZE(self.unused)-input_size]), &data[0], input_size) # self.unused.extend
            if PyByteArray_GET_SIZE(self.unused) > 9 and not self.have_magic_number: # 9 bytes magic number
                if strncmp(PyByteArray_AS_STRING(self.unused), magic, 5) != 0:
                    raise ValueError("Invalid signature")
                block_size = read_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(self.unused)[5]))
                if block_size  < KiB(65) or block_size >MiB(511):
                    raise ValueError("The input file is corrupted. Reason: Invalid block size in the header")
                self.init_state(block_size)
                del self.unused[:9]
                self.have_magic_number = 1

            while True:
                if PyByteArray_GET_SIZE(self.unused)<8: # 8 byte的 header都不够 直接返回
                    self.needs_input = 1
                    break
                new_size = read_neutral_s32(<uint8_t*>PyByteArray_AS_STRING(self.unused)) # todo gcc warning but bytes is contst
                old_size = read_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(self.unused)[4]))
                if PyByteArray_GET_SIZE(self.unused) < new_size+8: # 数据段不够
                    self.needs_input = 1
                    break
                self.needs_input = 0 # 现在够了
                memcpy(self.buffer, &(PyByteArray_AS_STRING(self.unused)[8]), <size_t>new_size)

                code = bz3_decode_block(self.state, self.buffer, new_size, old_size)
                if code == -1:
                    raise ValueError("Failed to decode a block: %s", bz3_strerror(self.state))
                if PyByteArray_Resize(ret, PyByteArray_GET_SIZE(ret) + old_size) < 0:
                    raise
                memcpy(&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-old_size]), self.buffer, <size_t>old_size)
                del self.unused[:new_size+8]
        return bytes(ret)

    @property
    def unused_data(self):
        """Data found after the end of the compressed stream."""
        return bytes(self.unused)

    cpdef inline str error(self):
        if bz3_last_error(self.state) != BZ3_OK:
            return (<bytes> bz3_strerror(self.state)).decode()
        return None


cpdef inline void compress(object input, object output, int32_t block_size) with gil:
    if not PyFile_Check(input):
        raise TypeError("input except a file-like object, got %s" % type(input).__name__)
    if not PyFile_Check(output):
        raise TypeError("output except a file-like object, got %s" % type(output).__name__)
    cdef bz3_state *state = bz3_new(block_size)
    if state == NULL:
        raise MemoryError("Failed to create a block encoder state")
    cdef uint8_t * buffer = <uint8_t *>PyMem_Malloc(block_size + block_size / 50 + 32)
    if buffer == NULL:
        bz3_free(state)
        state = NULL
        raise MemoryError
    cdef bytes data
    cdef int32_t new_size
    cdef uint8_t byteswap_buf[4]

    output.write(b"BZ3v1")
    write_neutral_s32(byteswap_buf, block_size)
    output.write(PyBytes_FromStringAndSize(<char*>&byteswap_buf[0], 4))  # magic header

    try:
        while True:
            data = input.read(block_size)
            if not data:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), PyBytes_GET_SIZE(data))
            new_size = bz3_encode_block(state, buffer, <int32_t>PyBytes_GET_SIZE(data))
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s", bz3_strerror(state))
            # print(f"oldsize: {PyBytes_GET_SIZE(data)} newsize{new_size}") # todo del
            write_neutral_s32(byteswap_buf, new_size)
            output.write(PyBytes_FromStringAndSize(<char*>&byteswap_buf[0], 4))
            write_neutral_s32(byteswap_buf, <int32_t>PyBytes_GET_SIZE(data))
            output.write(PyBytes_FromStringAndSize(<char*>&byteswap_buf[0], 4))
            output.write(PyBytes_FromStringAndSize(<char*>buffer, new_size))
            output.flush()
    finally:
        output.flush()
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)

cpdef inline void decompress(object input, object output) with gil:
    if not PyFile_Check(input):
        raise TypeError("input except a file-like object, got %s" % type(input).__name__)
    if not PyFile_Check(output):
        raise TypeError("output except a file-like object, got %s" % type(output).__name__)
    cdef bytes data
    cdef int32_t block_size
    data = input.read(9) # magic and block_size type: bytes len = 9
    if PyBytes_GET_SIZE(data) < 9:
        raise ValueError("Invalid file. Reason: Smaller than magic header")
    if strncmp(PyBytes_AS_STRING(data), magic, 5) != 0:
        raise ValueError("Invalid signature")
    block_size = read_neutral_s32(<uint8_t*>&(PyBytes_AS_STRING(data)[5]))
    if block_size < KiB(65) or block_size > MiB(511):
        raise ValueError("The input file is corrupted. Reason: Invalid block size in the header")
    cdef bz3_state *state = bz3_new(block_size)
    if state == NULL:
        raise MemoryError("Failed to create a block encoder state")
    cdef uint8_t *buffer = <uint8_t *> PyMem_Malloc(block_size + block_size / 50 + 32)
    if buffer == NULL:
        bz3_free(state)
        state = NULL
        raise MemoryError("Failed to allocate memory")
    cdef int32_t new_size, old_size, code

    try:
        while True:
            data = input.read(4)
            if PyBytes_GET_SIZE(data) < 4:
                break
            new_size = read_neutral_s32(<uint8_t*>PyBytes_AS_STRING(data))
            data = input.read(4)
            if PyBytes_GET_SIZE(data) < 4:
                break
            old_size = read_neutral_s32(<uint8_t *> PyBytes_AS_STRING(data))
            data = input.read(new_size) # type: bytes
            if PyBytes_GET_SIZE(data) < new_size:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t> new_size)
            code = bz3_decode_block(state, buffer, new_size, old_size)
            if code == -1:
                raise ValueError("Failed to decode a block: %s", bz3_strerror(state))
            output.write(PyBytes_FromStringAndSize(<char*>buffer, old_size))
            output.flush()
    finally:
        output.flush()
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)

cpdef inline bint test(object input, bint should_raise = False) except? 0 with gil:
    if not PyFile_Check(input):
        raise TypeError("input except a file-like object, got %s" % type(input).__name__)
        return 0
    cdef bytes data
    cdef int32_t block_size
    data = input.read(9)  # magic and block_size type: bytes len = 9
    if PyBytes_GET_SIZE(data) < 9:
        if should_raise:
            raise ValueError("Invalid file. Reason: Smaller than magic header")
        return 0
    if strncmp(PyBytes_AS_STRING(data), magic, 5) != 0:
        if should_raise:
            raise ValueError("Invalid signature")
        return 0
    block_size = read_neutral_s32(<uint8_t *> &(PyBytes_AS_STRING(data)[5]))
    if block_size < KiB(65) or block_size > MiB(511):
        if should_raise:
            raise ValueError("The input file is corrupted. Reason: Invalid block size in the header")
        return 0
    cdef bz3_state *state = bz3_new(block_size)
    if state == NULL:
        raise MemoryError("Failed to create a block encoder state")
        return 0
    cdef uint8_t *buffer = <uint8_t *> PyMem_Malloc(block_size + block_size / 50 + 32)
    if buffer == NULL:
        bz3_free(state)
        state = NULL
        raise MemoryError("Failed to allocate memory")
        return 0
    cdef int32_t new_size, old_size, code

    try:
        while True:
            data = input.read(4)
            if PyBytes_GET_SIZE(data) < 4:
                break
            new_size = read_neutral_s32(<uint8_t *> PyBytes_AS_STRING(data))
            data = input.read(4)
            if PyBytes_GET_SIZE(data) < 4:
                break
            old_size = read_neutral_s32(<uint8_t *> PyBytes_AS_STRING(data))
            data = input.read(new_size)  # type: bytes
            if PyBytes_GET_SIZE(data) < new_size:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t> new_size)
            code = bz3_decode_block(state, buffer, new_size, old_size)
            # print(f"newsize {new_size} oldsize {old_size}") # todo
            if code == -1:
                if should_raise:
                    raise ValueError("Failed to decode a block: %s", bz3_strerror(state))
                return 0
        return 1
    finally:
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)
