# cython: language_level=3
# cython: cdivision=True
cimport cython
from cpython.bytes cimport (PyBytes_AS_STRING, PyBytes_FromStringAndSize,
                            PyBytes_GET_SIZE)
from cpython.mem cimport PyMem_Free, PyMem_Malloc
from cpython.object cimport PyObject_HasAttrString
from libc.stdint cimport int32_t, uint8_t, uint32_t
from libc.string cimport memcpy, strncmp

from bz3.backends.cython.buffer cimport (buffer_append_right, buffer_as_string,
                                         buffer_del, buffer_get_size,
                                         buffer_make_room_for, buffer_new,
                                         buffer_pop_left, buffer_t)
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

cpdef inline uint32_t crc32(uint32_t crc, const uint8_t[::1] buf) nogil:
    return crc32sum(crc, &buf[0], <size_t>buf.shape[0])

@cython.freelist(8)
@cython.no_gc
@cython.final
cdef class BZ3Compressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        int32_t block_size
        buffer_t* uncompressed
        bint have_magic_number

    def __cinit__(self, int32_t block_size):
        if block_size < KiB(65) or block_size > MiB(511):
            raise ValueError("Block size must be between 65 KiB and 511 MiB")
        self.block_size = block_size
        self.state = bz3_new(block_size)
        if self.state == NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = <uint8_t *>PyMem_Malloc(block_size + block_size / 50 + 32)  # for compress and decompress
        if self.buffer == NULL:
            bz3_free(self.state)
            self.state = NULL
            raise MemoryError("Failed to allocate memory")
        self.uncompressed = buffer_new(10)
        if self.uncompressed == NULL:
            raise MemoryError
        self.have_magic_number = 0 # 还没有写入magic number

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL
        if self.uncompressed != NULL:
            buffer_del(&self.uncompressed)


    cpdef inline bytes compress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t new_size
        cdef buffer_t* ret = buffer_new(10)
        if ret == NULL:
            raise MemoryError
        if not self.have_magic_number:
            memcpy(buffer_as_string(ret), magic, 5)
            write_neutral_s32(&(buffer_as_string(ret)[5]), self.block_size)
            ret.len += 9
            self.have_magic_number = 1

        try:
            if input_size > 0:
                # if PyByteArray_Resize(self.uncompressed, input_size+PyByteArray_GET_SIZE(self.uncompressed)) < 0:
                #     raise
                # memcpy(&(PyByteArray_AS_STRING(self.uncompressed)[PyByteArray_GET_SIZE(self.uncompressed)-input_size]), &data[0], input_size) # todo? direct copy to bytearray
                if buffer_append_right(self.uncompressed, &data[0], <size_t>input_size)==-1:
                    raise MemoryError
                while <int32_t>buffer_get_size(self.uncompressed)>=self.block_size:
                    memcpy(self.buffer, buffer_as_string(self.uncompressed), <size_t>self.block_size)
                    # make a copy
                    with nogil:
                        new_size = bz3_encode_block(self.state, self.buffer, self.block_size)
                    if new_size == -1:
                        raise ValueError("Failed to encode a block: %s", bz3_strerror(self.state))
                    # if PyByteArray_Resize(ret, PyByteArray_GET_SIZE(ret) + new_size + 8) < 0:
                    #     raise todo add make_room_for
                    if buffer_make_room_for(ret,  <size_t>new_size + 8) == -1:
                        raise MemoryError

                    write_neutral_s32(&(buffer_as_string(ret)[buffer_get_size(ret)]), new_size)
                    write_neutral_s32(&(buffer_as_string(ret)[buffer_get_size(ret)+4]), self.block_size)
                    memcpy(&(buffer_as_string(ret)[buffer_get_size(ret)+8]), self.buffer, <size_t>new_size)
                    ret.len += (new_size+8)

                    if buffer_pop_left(self.uncompressed, self.block_size)==-1:
                        raise MemoryError
            return PyBytes_FromStringAndSize(<char*>buffer_as_string(ret), <Py_ssize_t>buffer_get_size(ret))
        finally:
            buffer_del(&ret)

    cpdef inline bytes flush(self):
        cdef bytes ret = b""
        cdef int32_t new_size
        cdef int32_t old_size = <int32_t>buffer_get_size(self.uncompressed)
        if old_size>0:
            memcpy(self.buffer, buffer_as_string(self.uncompressed), <size_t>old_size)
            with nogil:
                new_size = bz3_encode_block(self.state, self.buffer, old_size)
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s", bz3_strerror(self.state))
            ret = PyBytes_FromStringAndSize(NULL, new_size + 8)
            if not ret:
                raise
            write_neutral_s32(<uint8_t*>PyBytes_AS_STRING(ret), new_size)
            write_neutral_s32(<uint8_t*>&(PyBytes_AS_STRING(ret)[4]), old_size)
            memcpy(&(PyBytes_AS_STRING(ret)[8]), self.buffer, <size_t> new_size)
            if buffer_pop_left(self.uncompressed, <size_t>old_size)==-1:
                raise MemoryError
        return ret

    cpdef inline str error(self):
        if bz3_last_error(self.state) != BZ3_OK:
            return (<bytes>bz3_strerror(self.state)).decode()
        return None

@cython.freelist(8)
@cython.no_gc
@cython.final
cdef class BZ3Decompressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        int32_t block_size
        buffer_t* unused  # 还没解压的数据
        bint have_magic_number

    cdef inline int init_state(self, int32_t block_size) except -1:
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
        self.have_magic_number = 0 # 还没有读到magic number
        self.unused = buffer_new(10)
        if self.unused == NULL:
            raise MemoryError

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL
        if self.unused != NULL:
            buffer_del(&self.unused)

    cpdef inline bytes decompress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t code
        cdef buffer_t* ret = buffer_new(10)
        if ret == NULL:
            raise MemoryError
        cdef int32_t new_size, old_size, block_size
        try:
            if input_size > 0:
                # if PyByteArray_Resize(self.unused, input_size+PyByteArray_GET_SIZE(self.unused)) < 0:
                #     raise
                # memcpy(&(PyByteArray_AS_STRING(self.unused)[PyByteArray_GET_SIZE(self.unused)-input_size]), &data[0], input_size) # self.unused.extend
                if buffer_append_right(self.unused,  &data[0], <size_t>input_size)== -1:
                    raise MemoryError
                if buffer_get_size(self.unused) > 9 and not self.have_magic_number: # 9 bytes magic number
                    if strncmp(<const char*>buffer_as_string(self.unused), magic, 5) != 0:
                        raise ValueError("Invalid signature")
                    block_size = read_neutral_s32(&(buffer_as_string(self.unused)[5]))
                    if block_size  < KiB(65) or block_size >MiB(511):
                        raise ValueError("The input file is corrupted. Reason: Invalid block size in the header")
                    self.init_state(block_size)
                    if buffer_pop_left(self.unused, 9)==-1:
                        raise MemoryError
                    self.have_magic_number = 1

                while True:
                    if buffer_get_size(self.unused)<8: # 8 byte的 header都不够 直接返回
                        break
                    new_size = read_neutral_s32(buffer_as_string(self.unused)) # todo gcc warning but bytes is contst
                    old_size = read_neutral_s32(&(buffer_as_string(self.unused)[4]))
                    if buffer_get_size(self.unused) < new_size+8: # 数据段不够
                        break
                    memcpy(self.buffer, &(buffer_as_string(self.unused)[8]), <size_t>new_size)
                    with nogil:
                        code = bz3_decode_block(self.state, self.buffer, new_size, old_size)
                    if code == -1:
                        raise ValueError("Failed to decode a block: %s", bz3_strerror(self.state))
                    if buffer_append_right(ret, self.buffer, <size_t>old_size)==-1:
                        raise MemoryError
                    if buffer_pop_left(self.unused, new_size+8)==-1:
                        raise MemoryError

            return PyBytes_FromStringAndSize(<char*>buffer_as_string(ret), <Py_ssize_t>buffer_get_size(ret))
        finally:
            buffer_del(&ret)

    @property
    def unused_data(self):
        """Data found after the end of the compressed stream."""
        return PyBytes_FromStringAndSize(<char*>buffer_as_string(self.unused), <Py_ssize_t>buffer_get_size(self.unused))

    cpdef inline str error(self):
        if bz3_last_error(self.state) != BZ3_OK:
            return (<bytes> bz3_strerror(self.state)).decode()
        return None


cpdef inline void compress_file(object input, object output, int32_t block_size):
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
    cdef int32_t old_size
    try:
        while True:
            data = input.read(block_size)
            if not data:
                break
            old_size = <int32_t>PyBytes_GET_SIZE(data)
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t>old_size)
            with nogil:
                new_size = bz3_encode_block(state, buffer, old_size)
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s", bz3_strerror(state))
            write_neutral_s32(byteswap_buf, new_size)
            output.write(PyBytes_FromStringAndSize(<char*>&byteswap_buf[0], 4))
            write_neutral_s32(byteswap_buf, old_size)
            output.write(PyBytes_FromStringAndSize(<char*>&byteswap_buf[0], 4))
            output.write(PyBytes_FromStringAndSize(<char*>buffer, new_size))
            output.flush()
    finally:
        output.flush()
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)

cpdef inline void decompress_file(object input, object output):
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
            with nogil:
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

cpdef inline bint test_file(object input, bint should_raise = False) except? 0:
    if not PyFile_Check(input):
        raise TypeError("input except a file-like object, got %s" % type(input).__name__)
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
            new_size = read_neutral_s32(<uint8_t *> PyBytes_AS_STRING(data))
            data = input.read(4)
            if PyBytes_GET_SIZE(data) < 4:
                break
            old_size = read_neutral_s32(<uint8_t *> PyBytes_AS_STRING(data))
            data = input.read(new_size)  # type: bytes
            if PyBytes_GET_SIZE(data) < new_size:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t> new_size)
            with nogil:
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
