# cython: language_level=3
# cython: cdivision=True
cimport cython
from cpython.bytearray cimport PyByteArray_AS_STRING, PyByteArray_GET_SIZE
from cpython.bytes cimport (PyBytes_AS_STRING, PyBytes_FromStringAndSize,
                            PyBytes_GET_SIZE)
from cpython.mem cimport PyMem_Calloc, PyMem_Free, PyMem_Malloc
from cpython.object cimport PyObject_HasAttrString
from libc.stdint cimport int32_t, uint8_t, uint32_t
from libc.stdio cimport fprintf, stderr
from libc.string cimport memcpy, strncmp

from bz3.backends.cython.bzip3 cimport (BZ3_OK, MEMLOG, KiB, MiB, bz3_bound,
                                        bz3_compress, bz3_decode_block,
                                        bz3_decompress, bz3_encode_block,
                                        bz3_free, bz3_last_error,
                                        bz3_min_memory_needed, bz3_new,
                                        bz3_orig_size_sufficient_for_decode,
                                        bz3_state, bz3_strerror, bz3_version,
                                        read_neutral_s32, write_neutral_s32)


cdef const char* magic = "BZ3v1"

cdef inline uint8_t PyFile_Check(object file):
    if PyObject_HasAttrString(file, "read") and PyObject_HasAttrString(file, "write"):  # should we check seek method?
        return 1
    return 0

@cython.freelist(8)
@cython.no_gc
@cython.final
cdef class BZ3Compressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        readonly int32_t block_size
        bytearray uncompressed
        bint have_magic_number

    def __cinit__(self, int32_t block_size):
        if block_size < KiB(65) or block_size > MiB(511):
            raise ValueError("Block size must be between 65 KiB and 511 MiB")
        self.block_size = block_size
        self.state = bz3_new(block_size)
        if self.state == NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = <uint8_t *>PyMem_Malloc(bz3_bound(block_size))
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

    cpdef inline bytes compress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t new_size
        cdef bytearray ret = bytearray()
        if not self.have_magic_number:
            # if PyByteArray_Resize(ret, 9) < 0:
            #     raise
            # memcpy(PyByteArray_AS_STRING(ret), magic, 5)
            ret.extend(<bytes>magic[:5]+b"\x00\x00\x00\x00")  # 9 bytes
            write_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(ret)[5]), self.block_size)
            self.have_magic_number = 1

        if input_size > 0:
            # if PyByteArray_Resize(self.uncompressed, input_size+PyByteArray_GET_SIZE(self.uncompressed)) < 0:
            #     raise
            # memcpy(&(PyByteArray_AS_STRING(self.uncompressed)[PyByteArray_GET_SIZE(self.uncompressed)-input_size]), &data[0], input_size) # todo? direct copy to bytearray
            self.uncompressed.extend(data)
            while PyByteArray_GET_SIZE(self.uncompressed)>=self.block_size:
                memcpy(self.buffer, PyByteArray_AS_STRING(self.uncompressed), <size_t>self.block_size)
                # make a copy
                with nogil:
                    new_size = bz3_encode_block(self.state, self.buffer, self.block_size)
                if new_size == -1:
                    raise ValueError("Failed to encode a block: %s" % bz3_strerror(self.state))
                # if PyByteArray_Resize(ret, PyByteArray_GET_SIZE(ret) + new_size + 8) < 0:
                #     raise
                ret.extend((new_size + 8)*b"\x00")
                write_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-new_size-8]), new_size)
                write_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-new_size-4]), self.block_size)
                memcpy(&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-new_size]), self.buffer, <size_t>new_size)

                del self.uncompressed[:self.block_size]
        return bytes(ret)

    cpdef inline bytes flush(self):
        cdef bytes ret = b""
        cdef int32_t new_size
        cdef int32_t old_size = <int32_t>PyByteArray_GET_SIZE(self.uncompressed)
        if self.uncompressed:
            memcpy(self.buffer, PyByteArray_AS_STRING(self.uncompressed), <size_t>old_size)
            with nogil:
                new_size = bz3_encode_block(self.state, self.buffer, old_size)
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s" % bz3_strerror(self.state))
            ret = PyBytes_FromStringAndSize(NULL, new_size + 8)
            if not ret:
                raise
            write_neutral_s32(<uint8_t*>PyBytes_AS_STRING(ret), new_size)
            write_neutral_s32(<uint8_t*>&(PyBytes_AS_STRING(ret)[4]), old_size)
            memcpy(&(PyBytes_AS_STRING(ret)[8]), self.buffer, <size_t> new_size)
            self.uncompressed.clear()
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
        size_t buffer_size
        readonly int32_t block_size
        bytearray unused  # 还没解压的数据
        bint have_magic_number
        readonly bint ignore_error # 是否忽略decode错误

    cdef inline int init_state(self, int32_t block_size) except -1:
        """should exec only once"""
        self.block_size = block_size
        self.state = bz3_new(block_size)
        if self.state == NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer_size = bz3_bound(block_size)
        self.buffer = <uint8_t *> PyMem_Malloc(self.buffer_size)
        if self.buffer == NULL:
            bz3_free(self.state)
            self.state = NULL
            raise MemoryError("Failed to allocate memory")

    def __cinit__(self, bint ignore_error = False):
        self.unused = bytearray()
        self.have_magic_number = 0 # 还没有读到magic number
        self.ignore_error = ignore_error

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL

    cpdef inline bytes decompress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t code
        cdef bytearray ret = bytearray()
        cdef int32_t new_size, old_size, block_size
        if input_size > 0:
            # if PyByteArray_Resize(self.unused, input_size+PyByteArray_GET_SIZE(self.unused)) < 0:
            #     raise
            # memcpy(&(PyByteArray_AS_STRING(self.unused)[PyByteArray_GET_SIZE(self.unused)-input_size]), &data[0], input_size) # self.unused.extend
            self.unused.extend(data)
            if PyByteArray_GET_SIZE(self.unused) >= 9 and not self.have_magic_number: # 9 bytes magic number
                if strncmp(PyByteArray_AS_STRING(self.unused), magic, 5) != 0:
                    raise ValueError("Invalid signature")
                block_size = read_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(self.unused)[5]))
                if block_size < KiB(65) or block_size > MiB(511):
                    raise ValueError("The input file is corrupted. Reason: Invalid block size in the header")
                self.init_state(block_size)
                del self.unused[:9]
                self.have_magic_number = 1

            while True:
                if PyByteArray_GET_SIZE(self.unused)<8: # 8 byte的 header都不够 直接返回
                    break
                new_size = read_neutral_s32(<uint8_t*>PyByteArray_AS_STRING(self.unused)) # todo gcc warning but bytes is contst
                old_size = read_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(self.unused)[4]))
                if old_size > <int32_t>bz3_bound(self.block_size) or new_size > <int32_t>bz3_bound(self.block_size):
                    raise ValueError("Failed to decode a block: Inconsistent headers.")
                if PyByteArray_GET_SIZE(self.unused) < new_size+8: # 数据段不够
                    break
                memcpy(self.buffer, &(PyByteArray_AS_STRING(self.unused)[8]), <size_t>new_size)
                with nogil:
                    code = bz3_decode_block(self.state, self.buffer, self.buffer_size, new_size, old_size)
                if code == -1:
                    if self.ignore_error:
                        fprintf(stderr, "Writing invalid block: %s\n", bz3_strerror(self.state))
                    else:
                        raise ValueError("Failed to decode a block: %s" % bz3_strerror(self.state))
                # if PyByteArray_Resize(ret, PyByteArray_GET_SIZE(ret) + old_size) < 0:
                #     raise
                ret.extend(<bytes>self.buffer[:old_size])
                # memcpy(&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-old_size]), self.buffer, <size_t>old_size)
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


def compress_file(object input, object output, int32_t block_size):
    if not PyFile_Check(input):
        raise TypeError("input except a file-like object, got %s" % type(input).__name__)
    if not PyFile_Check(output):
        raise TypeError("output except a file-like object, got %s" % type(output).__name__)
    cdef bz3_state *state = bz3_new(block_size)
    if state == NULL:
        raise MemoryError("Failed to create a block encoder state")
    cdef uint8_t * buffer = <uint8_t *>PyMem_Malloc(bz3_bound(block_size))
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
                raise ValueError("Failed to encode a block: %s" % bz3_strerror(state))
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
        buffer = NULL

def decompress_file(object input, object output):
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
    cdef size_t buffer_size = bz3_bound(block_size)
    cdef uint8_t *buffer = <uint8_t *> PyMem_Malloc(buffer_size)
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
            if old_size > <int32_t>bz3_bound(block_size) or new_size > <int32_t>bz3_bound(block_size):
                raise ValueError("Failed to decode a block: Inconsistent headers.")
            data = input.read(new_size) # type: bytes
            if PyBytes_GET_SIZE(data) < new_size:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t> new_size)
            with nogil:
                code = bz3_decode_block(state, buffer, buffer_size, new_size, old_size)
            if code == -1:
                raise ValueError("Failed to decode a block: %s" % bz3_strerror(state))
            output.write(PyBytes_FromStringAndSize(<char*>buffer, old_size))
            output.flush()
    finally:
        output.flush()
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)
        buffer = NULL

def recover_file(object input, object output):
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
    cdef size_t buffer_size = bz3_bound(block_size)
    cdef uint8_t *buffer = <uint8_t *> PyMem_Malloc(buffer_size)
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
            if old_size > <int32_t>bz3_bound(block_size) or new_size > <int32_t>bz3_bound(block_size):
                raise ValueError("Failed to decode a block: Inconsistent headers.")
            data = input.read(new_size) # type: bytes
            if PyBytes_GET_SIZE(data) < new_size:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t> new_size)
            with nogil:
                code = bz3_decode_block(state, buffer, buffer_size, new_size, old_size)
            if code == -1:
                fprintf(stderr, "Writing invalid block: %s\n", bz3_strerror(state))
            output.write(PyBytes_FromStringAndSize(<char*>buffer, old_size))
            output.flush()
    finally:
        output.flush()
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)
        buffer = NULL

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
    cdef size_t buffer_size = bz3_bound(block_size)
    cdef uint8_t *buffer = <uint8_t *> PyMem_Malloc(buffer_size)
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
            if old_size > <int32_t>bz3_bound(block_size) or new_size > <int32_t>bz3_bound(block_size):
                if should_raise:
                    raise ValueError("Failed to decode a block: Inconsistent headers.")
                return 0
            data = input.read(new_size)  # type: bytes
            if PyBytes_GET_SIZE(data) < new_size:
                break
            memcpy(buffer, PyBytes_AS_STRING(data), <size_t> new_size)
            with nogil:
                code = bz3_decode_block(state, buffer, buffer_size, new_size, old_size)
            # print(f"newsize {new_size} oldsize {old_size}") # todo
            if code == -1:
                if should_raise:
                    raise ValueError("Failed to decode a block: %s" % bz3_strerror(state))
                return 0
        return 1
    finally:
        bz3_free(state)
        state = NULL
        PyMem_Free(buffer)
        buffer = NULL

cpdef inline size_t bound(size_t input_size) nogil:
    return bz3_bound(input_size)


cpdef inline size_t compress_into(const uint8_t[::1] data, uint8_t[::1] out, uint32_t block_size = 1000000) except? 0:
    cdef:
        size_t out_size = <size_t>out.shape[0]
        int bzerr
    with nogil:
        bzerr = bz3_compress(block_size, &data[0], &out[0], <size_t>data.shape[0], &out_size)
    if bzerr != BZ3_OK:
        raise ValueError(f"bz3_compress() failed with error code {bzerr}")
    return out_size

cpdef inline size_t decompress_into(const uint8_t[::1] data, uint8_t[::1] out) except? 0:
    cdef:
        size_t out_size = <size_t>out.shape[0]
        int bzerr
    with nogil:
        bzerr = bz3_decompress(&data[0], &out[0], <size_t>data.shape[0], &out_size)
    if bzerr != BZ3_OK:
        raise ValueError(f"bz3_decompress() failed with error code {bzerr}")
    return out_size

cpdef inline size_t min_memory_needed(int32_t block_size) noexcept:
    cdef size_t ret
    with nogil:
        ret = bz3_min_memory_needed(block_size)
    return ret

cpdef inline int orig_size_sufficient_for_decode(const uint8_t[::1] block, int32_t orig_size) noexcept:
    cdef int ret
    with nogil:
        ret = bz3_orig_size_sufficient_for_decode(&block[0], <size_t>block.shape[0], orig_size)
    return ret

cpdef inline str libversion():
    return (<bytes>bz3_version()).decode()

# openmp
from cython.parallel cimport prange


cdef void bz3_encode_blocks(bz3_state ** states, uint8_t ** buffers, int32_t *sizes, int32_t numthreads) noexcept:
    # sizes: read and write
    cdef int32_t i
    for i in prange(numthreads, nogil=True, schedule="static", num_threads=numthreads):
        sizes[i] = bz3_encode_block(states[i], buffers[i], sizes[i])


@cython.freelist(8)
@cython.no_gc
@cython.final
cdef class BZ3OmpCompressor:
    cdef:
        bz3_state ** states
        uint8_t ** buffers
        int32_t * sizes   # compressed
        int32_t * old_sizes # origin size
        readonly int32_t block_size
        bytearray uncompressed
        bint have_magic_number
        readonly uint32_t numthreads  # how many threads to use

    def __cinit__(self, int32_t block_size, uint32_t numthreads):
        if block_size < KiB(65) or block_size > MiB(511):
            raise ValueError("Block size must be between 65 KiB and 511 MiB")
        self.block_size = block_size
        self.states = <bz3_state **>PyMem_Calloc(<size_t>numthreads, sizeof(bz3_state *)) # prepare the array
        if not self.states:
            raise MemoryError
        MEMLOG("PyMem_Malloc %p\n", self.states)
        self.buffers = <uint8_t **>PyMem_Calloc(<size_t>numthreads, sizeof(uint8_t *))
        if not self.buffers:
            PyMem_Free(self.states)
            self.states = NULL
            raise MemoryError
        MEMLOG("PyMem_Malloc %p\n", self.buffers)
        self.sizes = <int32_t *>PyMem_Malloc(sizeof(int32_t) * numthreads)
        if not self.sizes:
            PyMem_Free(self.states)
            MEMLOG("PyMem_Free %p\n", self.states)
            self.states = NULL
            PyMem_Free(self.buffers)
            MEMLOG("PyMem_Free %p\n", self.buffers)
            self.buffers = NULL
            raise MemoryError
        MEMLOG("PyMem_Malloc %p\n", self.sizes)
        self.old_sizes = <int32_t *> PyMem_Malloc(sizeof(int32_t) * numthreads)
        if not self.old_sizes:
            PyMem_Free(self.states)
            MEMLOG("PyMem_Free %p\n", self.states)
            self.states = NULL
            PyMem_Free(self.buffers)
            MEMLOG("PyMem_Free %p\n", self.buffers)
            self.buffers = NULL
            PyMem_Free(self.sizes)
            MEMLOG("PyMem_Free %p\n", self.sizes)
            self.sizes = NULL
            raise MemoryError
        MEMLOG("PyMem_Malloc %p\n", self.old_sizes)

        cdef uint32_t i
        try:
            for i in range(numthreads):
                self.states[i] = bz3_new(block_size)
                if self.states[i] == NULL:
                    raise MemoryError("Failed to create a block encoder state")  # todo 如何善后
                MEMLOG("bz3_new %p\n", self.states[i])
                self.buffers[i] = <uint8_t *>PyMem_Malloc(bz3_bound(block_size))
                if self.buffers[i] == NULL:
                    raise MemoryError("Failed to allocate memory")
                MEMLOG("PyMem_Malloc %p\n", self.buffers[i])
        except:
            self.free_states()
            self.free_buffers()
            PyMem_Free(self.states)
            MEMLOG("PyMem_Free %p\n", self.states)
            self.states = NULL
            PyMem_Free(self.buffers)
            MEMLOG("PyMem_Free %p\n", self.buffers)
            self.buffers = NULL
            PyMem_Free(self.sizes)
            MEMLOG("PyMem_Free %p\n", self.sizes)
            self.sizes = NULL
            PyMem_Free(self.old_sizes)
            MEMLOG("PyMem_Free %p\n", self.old_sizes)
            self.old_sizes = NULL
            raise
        self.uncompressed = bytearray()
        self.have_magic_number = 0 # 还没有写入magic number
        self.numthreads = numthreads

    cdef inline void free_states(self):
        cdef uint32_t i
        if self.states:
            for i in range(self.numthreads):
                if self.states[i]:
                    bz3_free(self.states[i])
                    MEMLOG("bz3_free %p\n", self.states[i])
                    self.states[i] = NULL

    cdef inline void free_buffers(self):
        cdef uint32_t i
        if self.buffers:
            for i in range(self.numthreads):
                if self.buffers[i]:
                    PyMem_Free(self.buffers[i])
                    MEMLOG("PyMem_Free %p\n", self.buffers[i])
                    self.buffers[i] = NULL

    def __dealloc__(self):
        self.free_states()
        self.free_buffers()
        if self.states:
            PyMem_Free(self.states)
            MEMLOG("PyMem_Free %p\n", self.states)
            self.states = NULL
        if self.buffers:
            PyMem_Free(self.buffers)
            MEMLOG("PyMem_Free %p\n", self.buffers)
            self.buffers = NULL
        if self.sizes:
            PyMem_Free(self.sizes)
            MEMLOG("PyMem_Free %p\n", self.sizes)
            self.sizes = NULL
        if self.old_sizes:
            PyMem_Free(self.old_sizes)
            MEMLOG("PyMem_Free %p\n", self.old_sizes)
            self.old_sizes = NULL

    cpdef inline bytes compress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t new_size
        cdef bytearray ret = bytearray()
        cdef int32_t all_blocks_size = self.block_size * self.numthreads
        if not self.have_magic_number:
            # if PyByteArray_Resize(ret, 9) < 0:
            #     raise
            # memcpy(PyByteArray_AS_STRING(ret), magic, 5)
            ret.extend(<bytes>magic[:5]+b"\x00\x00\x00\x00")  # 9 bytes
            write_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(ret)[5]), self.block_size)
            self.have_magic_number = 1
        cdef uint32_t i
        if input_size > 0:
            # if PyByteArray_Resize(self.uncompressed, input_size+PyByteArray_GET_SIZE(self.uncompressed)) < 0:
            #     raise
            # memcpy(&(PyByteArray_AS_STRING(self.uncompressed)[PyByteArray_GET_SIZE(self.uncompressed)-input_size]), &data[0], input_size) # todo? direct copy to bytearray
            self.uncompressed.extend(data)
            if PyByteArray_GET_SIZE(self.uncompressed) >= all_blocks_size:  # able to perform a compress
                while PyByteArray_GET_SIZE(self.uncompressed) >= all_blocks_size:  # ensure fill all blocks
                    for i in range(self.numthreads):
                        self.sizes[i] = self.block_size  # fill the sizes array
                        memcpy(self.buffers[i], &PyByteArray_AS_STRING(self.uncompressed)[i*self.block_size], <size_t>self.block_size)
                        # make a copy
                    bz3_encode_blocks(self.states, self.buffers, self.sizes, <int32_t>self.numthreads)
                    for i in range(self.numthreads):
                        if bz3_last_error(self.states[i]) != BZ3_OK:
                            raise ValueError("Failed to encode a block: %s" % bz3_strerror(self.states[i]))
                        # if PyByteArray_Resize(ret, PyByteArray_GET_SIZE(ret) + new_size + 8) < 0:
                        #     raise
                        ret.extend((self.sizes[i] + 8)*b"\x00")
                        write_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-self.sizes[i]-8]), self.sizes[i])
                        write_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-self.sizes[i]-4]), self.block_size)
                        memcpy(&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret)-self.sizes[i]]), self.buffers[i], <size_t>self.sizes[i])

                    del self.uncompressed[:all_blocks_size]
        return bytes(ret)

    cpdef inline bytes flush(self):
        cdef bytearray ret = bytearray()
        cdef int32_t new_size
        cdef int32_t remain_size = <int32_t>PyByteArray_GET_SIZE(self.uncompressed)
        cdef:
            int i = 0  # thread count
            int j
        if self.uncompressed:  # will perform a compress
            while self.block_size * (i+1) < remain_size:
                memcpy(self.buffers[i],
                       &PyByteArray_AS_STRING(self.uncompressed)[i*self.block_size],
                       <size_t>self.block_size)
                self.sizes[i] = self.old_sizes[i] = self.block_size
                # old_sizes[i] = self.block_size
                i += 1
            memcpy(self.buffers[i],
                   &PyByteArray_AS_STRING(self.uncompressed)[i * self.block_size],
                   <size_t> (remain_size-i*self.block_size))  # fill as many blocks as possible
            self.sizes[i] = self.old_sizes[i] = remain_size-i*self.block_size
            # old_sizes[i] = remain_size-i*self.block_size
            i += 1
            bz3_encode_blocks(self.states, self.buffers, self.sizes, i)
            for j in range(i):  # state index
                if bz3_last_error(self.states[j]) != BZ3_OK:
                    raise ValueError("Failed to encode a block: %s" % bz3_strerror(self.states[j]))

                ret.extend((self.sizes[j] + 8) * b"\x00")
                write_neutral_s32(<uint8_t *> &(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret) - self.sizes[j] - 8]),
                                  self.sizes[j])
                write_neutral_s32(<uint8_t *> &(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret) - self.sizes[j] - 4]),
                                  self.old_sizes[j])
                memcpy(&(PyByteArray_AS_STRING(ret)[PyByteArray_GET_SIZE(ret) - self.sizes[j]]), self.buffers[j],
                       <size_t> self.sizes[j])

            self.uncompressed.clear()
        return bytes(ret)

    cpdef inline list error(self):
        cdef uint32_t i
        cdef list ret = []
        for i in range(self.numthreads):
            if bz3_last_error(self.states[i]) != BZ3_OK:
                ret.append((<bytes>bz3_strerror(self.states[i])).decode())
        return ret


cdef void bz3_decode_blocks(bz3_state ** states, uint8_t ** buffers, size_t *buffer_sizes, int32_t* sizes, int32_t* orig_size, int32_t numthreads) noexcept:
    cdef int32_t i
    for i in prange(numthreads, nogil=True, schedule='static', num_threads=numthreads):
        bz3_decode_block(states[i], buffers[i], buffer_sizes[i], sizes[i], orig_size[i])


@cython.freelist(8)
@cython.no_gc
@cython.final
cdef class BZ3OmpDecompressor:
    cdef:
        bz3_state ** states
        uint8_t ** buffers
        size_t* buffer_sizes
        int32_t * sizes   # compressed
        int32_t * old_sizes  # origin
        readonly int32_t block_size
        bytearray unused  # 还没解压的数据
        bint have_magic_number
        readonly uint32_t numthreads  # how many threads to use
        readonly bint ignore_error  # 是否忽略decode错误

    cdef inline int init_state(self, int32_t block_size) except -1:
        """should exec only once"""
        if not self.states:
            self.states = <bz3_state **> PyMem_Calloc(self.numthreads, sizeof(bz3_state *))  # prepare the array
            if not self.states:
                raise MemoryError
            MEMLOG("PyMem_Malloc %p\n", self.states)
        if not self.buffers:
            self.buffers = <uint8_t **> PyMem_Calloc(self.numthreads, sizeof(uint8_t *))
            if not self.buffers:
                raise MemoryError
            MEMLOG("PyMem_Malloc %p\n", self.buffers)
        if not self.buffer_sizes:
            self.buffer_sizes = <size_t *> PyMem_Calloc(self.numthreads, sizeof(size_t))
            if not self.buffer_sizes:
                raise MemoryError
            MEMLOG("PyMem_Malloc %p\n", self.buffer_sizes)
        cdef size_t buffer_size = bz3_bound(block_size)
        cdef uint32_t i
        try:
            for i in range(self.numthreads):
                self.buffer_sizes[i] = buffer_size
                self.states[i] = bz3_new(block_size)
                if self.states[i] == NULL:
                    raise MemoryError("Failed to create a block encoder state")  # todo 如何善后
                MEMLOG("bz3_new %p\n", self.states[i])
                self.buffers[i] = <uint8_t *> PyMem_Malloc(buffer_size)
                if self.buffers[i] == NULL:
                    raise MemoryError("Failed to allocate memory")
                MEMLOG("PyMem_Malloc %p\n", self.buffers[i])
        except:
            self.free_states()
            self.free_buffers()
            raise
        self.block_size = block_size

    def __cinit__(self,  uint32_t numthreads, bint ignore_error = False):
        self.states = NULL
        self.buffers = NULL
        self.buffer_sizes = NULL
        self.unused = bytearray()
        self.have_magic_number = 0 # 还没有读到magic number
        self.numthreads = numthreads
        self.ignore_error = ignore_error

        self.sizes = <int32_t *> PyMem_Malloc(sizeof(int32_t) * numthreads)
        if not self.sizes:
            raise MemoryError
        MEMLOG("PyMem_Malloc %p\n", self.sizes)
        self.old_sizes = <int32_t *> PyMem_Malloc(sizeof(int32_t) * numthreads)
        if not self.old_sizes:
            PyMem_Free(self.sizes)
            self.sizes = NULL
            raise MemoryError
        MEMLOG("PyMem_Malloc %p\n", self.old_sizes)
        MEMLOG("BZ3OmpDecompressor __cinit__ %p\n", <void*>self)

    cdef inline void free_states(self):
        cdef uint32_t i
        if self.states: # states数组是否初始化，即是否调用过init_states
            for i in range(self.numthreads):
                if self.states[i]:
                    bz3_free(self.states[i])
                    MEMLOG("bz3_free %p\n", self.states[i])
                    self.states[i] = NULL

    cdef inline void free_buffers(self):
        cdef uint32_t i # states数组是否初始化，即是否调用过init_states
        if self.buffers: # states数组是否初始化，即是否调用过init_states
            for i in range(self.numthreads):
                if self.buffers[i]:
                    PyMem_Free(self.buffers[i])
                    MEMLOG("PyMem_Free %p\n", self.buffers[i])
                    self.buffers[i] = NULL

    def __dealloc__(self):
        self.free_states()
        self.free_buffers()
        if self.states:
            PyMem_Free(self.states)
            MEMLOG("PyMem_Free %p\n", self.states)
            self.states = NULL
        if self.buffers:
            PyMem_Free(self.buffers)
            MEMLOG("PyMem_Free %p\n", self.buffers)
            self.buffers = NULL
        if self.sizes:
            PyMem_Free(self.sizes)
            MEMLOG("PyMem_Free %p\n", self.sizes)
            self.sizes = NULL
        if self.old_sizes:
            PyMem_Free(self.old_sizes)
            MEMLOG("PyMem_Free %p\n", self.old_sizes)
            self.old_sizes = NULL
        if self.buffer_sizes:
            PyMem_Free(self.buffer_sizes)
            MEMLOG("PyMem_Free %p\n", self.buffer_sizes)
            self.buffer_sizes = NULL
        MEMLOG("BZ3OmpDecompressor __dealloc__ %p\n", <void *> self)

    cpdef inline bytes decompress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        cdef int32_t code
        cdef bytearray ret = bytearray()
        cdef int32_t  block_size
        cdef uint32_t i, thread_count, j, should_delete=0
        cdef int should_break = 0
        if input_size > 0:
            # if PyByteArray_Resize(self.unused, input_size+PyByteArray_GET_SIZE(self.unused)) < 0:
            #     raise
            # memcpy(&(PyByteArray_AS_STRING(self.unused)[PyByteArray_GET_SIZE(self.unused)-input_size]), &data[0], input_size) # self.unused.extend
            self.unused.extend(data) # read header
            if PyByteArray_GET_SIZE(self.unused) >= 9 and not self.have_magic_number: # 9 bytes magic number
                if strncmp(PyByteArray_AS_STRING(self.unused), magic, 5) != 0:
                    raise ValueError("Invalid signature")
                block_size = read_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(self.unused)[5]))
                if block_size < KiB(65) or block_size > MiB(511):
                    raise ValueError("The input file is corrupted. Reason: Invalid block size in the header")
                self.init_state(block_size)
                del self.unused[:9]
                self.have_magic_number = 1
            # 有几个block就用几个
            while not should_break:
                thread_count = 0  # 这一波能用上几个thread
                # should_delete = 0 # 讀取完成后從self.unused刪多少
                for i in range(self.numthreads):
                    if (PyByteArray_GET_SIZE(self.unused)-should_delete) < 8: # 8 byte的 header都不够 直接返回
                        should_break = 1
                        break
                    self.sizes[i] = read_neutral_s32(<uint8_t*>&PyByteArray_AS_STRING(self.unused)[should_delete]) # todo gcc warning but bytes is const
                    self.old_sizes[i] = read_neutral_s32(<uint8_t*>&(PyByteArray_AS_STRING(self.unused)[should_delete+4]))
                    if self.old_sizes[i] > <int32_t>bz3_bound(self.block_size) or self.sizes[i] > <int32_t>bz3_bound(self.block_size):
                        raise ValueError("Failed to decode a block: Inconsistent headers.")
                    if (PyByteArray_GET_SIZE(self.unused)-should_delete) < self.sizes[i]+8: # 数据段不够
                        should_break = 1
                        break
                    memcpy(self.buffers[i], &(PyByteArray_AS_STRING(self.unused)[should_delete+8]), <size_t>self.sizes[i])
                    should_delete += (self.sizes[i] + 8)
                    thread_count += 1
                if thread_count:  # 一个block都凑不齐decode个jb
                    bz3_decode_blocks(self.states, self.buffers, self.buffer_sizes, self.sizes, self.old_sizes, <int32_t>thread_count)
                for j in range(thread_count):
                    if bz3_last_error(self.states[j]) != BZ3_OK:
                        if self.ignore_error:
                            fprintf(stderr, "Writing invalid block: %s\n", bz3_strerror(self.states[j]))
                        else:
                            raise ValueError("Failed to decode data: %s" % bz3_strerror(self.states[j]))
                    ret.extend(<bytes>self.buffers[j][:self.old_sizes[j]])
            if should_delete:
                del self.unused[:should_delete]
        return bytes(ret)

    @property
    def unused_data(self):
        """Data found after the end of the compressed stream."""
        return bytes(self.unused)

    cpdef inline list error(self):
        cdef uint32_t i
        cdef list ret = []
        for i in range(self.numthreads):
            if bz3_last_error(self.states[i]) != BZ3_OK:
                ret.append((<bytes> bz3_strerror(self.states[i])).decode())
        return ret
