from cpython.bytearray cimport PyByteArray_AS_STRING, PyByteArray_Resize
from cpython.bytes cimport PyBytes_AS_STRING, PyBytes_FromStringAndSize
from cpython.mem cimport PyMem_Free, PyMem_Malloc
from libc.stdint cimport int32_t, uint8_t, uint32_t
from libc.string cimport memcpy

cimport cython

from bz3.backends.cython.bzip3 cimport (bz3_decode_block, bz3_decode_blocks,
                                        bz3_encode_block, bz3_encode_blocks,
                                        bz3_free, bz3_last_error, bz3_new,
                                        bz3_state, bz3_strerror, crc32sum,
                                        read_neutral_s32, write_neutral_s32)


cpdef inline uint32_t crc32(uint32_t crc, uint8_t[::1] buf):
    return crc32sum(crc, &buf[0], <size_t>buf.shape[0])

@cython.final
cdef class BZ3Compressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        int32_t block_size
        uint8_t byteswap_buf[4]
        bytearray uncompressed

    def __cinit__(self, int32_t block_size = 1000000):
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

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL

    cpdef inline bytes compress(self, const uint8_t[::1] data):  # todo use self.buffer
        cdef Py_ssize_t input_size = data.shape[0]
        if PyByteArray_Resize(self.uncompressed, input_size+len(self.uncompressed)) < 0:
            raise
        memcpy(&(PyByteArray_AS_STRING(self.uncompressed)[len(self.uncompressed)-input_size]), &data[0], input_size) # todo? direct copy to bytearray  
        cdef int32_t new_size
        cdef bytearray ret = bytearray()
        while len(self.uncompressed)>=self.block_size:
            memcpy(self.buffer, PyByteArray_AS_STRING(self.uncompressed), <size_t>self.block_size)
            # make a copy
            new_size = bz3_encode_block(self.state, self.buffer, self.block_size)
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s", bz3_strerror(self.state))
            if PyByteArray_Resize(ret, len(ret) + new_size + 8) < 0:
                raise

            write_neutral_s32(self.byteswap_buf, new_size)
            memcpy(<void *> &(PyByteArray_AS_STRING(ret)[len(ret)-new_size-8]), <void*>self.byteswap_buf, 4)
            write_neutral_s32(self.byteswap_buf, self.block_size)
            memcpy(<void *> &(PyByteArray_AS_STRING(ret)[len(ret)-new_size-4]), <void *> self.byteswap_buf, 4)
            memcpy(<void *> &(PyByteArray_AS_STRING(ret)[len(ret)-new_size]), self.buffer, <size_t>new_size)

            del self.uncompressed[:self.block_size]  # todo profille here using c api
        return bytes(ret)

    cpdef inline bytes flush(self):
        cdef bytes ret = b""
        cdef int32_t new_size
        if self.uncompressed:
            memcpy(self.buffer, PyByteArray_AS_STRING(self.uncompressed), <size_t>len(self.uncompressed))
            new_size = bz3_encode_block(self.state, self.buffer, len(self.uncompressed))
            if new_size == -1:
                raise ValueError("Failed to encode a block: %s", bz3_strerror(self.state))
            ret = PyBytes_FromStringAndSize(NULL, new_size + 8)
            if not ret:
                raise
            write_neutral_s32(self.byteswap_buf, new_size)
            memcpy(PyBytes_AS_STRING(ret), self.byteswap_buf, 4)
            write_neutral_s32(self.byteswap_buf, len(self.uncompressed))
            memcpy(&(PyBytes_AS_STRING(ret)[4]), self.byteswap_buf, 4)
            memcpy(&(PyBytes_AS_STRING(ret)[8]), self.buffer,<size_t> new_size)
            self.uncompressed.clear()
        return ret


cdef class BZ3Decompressor:
    cdef:
        bz3_state * state
        uint8_t * buffer
        int32_t block_size
        uint8_t byteswap_buf[4]
    
    cdef readonly bint eof

    def __cinit__(self, int32_t block_size = 1000000):
        self.block_size = block_size
        self.state = bz3_new(block_size)
        if self.state == NULL:
            raise MemoryError("Failed to create a block encoder state")
        self.buffer = <uint8_t *> PyMem_Malloc(block_size + block_size / 50 + 32)
        if self.buffer == NULL:
            bz3_free(self.state)
            self.state = NULL
            raise MemoryError("Failed to allocate memory")

    def __dealloc__(self):
        if self.state != NULL:
            bz3_free(self.state)
            self.state = NULL
        if self.buffer !=NULL:
            PyMem_Free(self.buffer)
            self.buffer = NULL

    cpdef bytes decompress(self, const uint8_t[::1] data):
        cdef Py_ssize_t input_size = data.shape[0]
        if <int32_t>input_size > self.block_size:
            raise ValueError("input chunk is too big")
        if input_size<8:
            raise ValueError("no more data")
        cdef int32_t new_size = read_neutral_s32(&data[0]) # todo gcc warning but bytes is contst
        cdef int32_t old_size = read_neutral_s32(&data[4])
        if  input_size< new_size+8:
            raise ValueError("no more data")
        memcpy(self.buffer, &data[8], <size_t>new_size)

        cdef int32_t ret = bz3_decode_block(self.state, self.buffer, new_size, old_size)
        if ret == -1:
            raise ValueError("Failed to decode a block: %s", bz3_strerror(self.state))
        return PyBytes_FromStringAndSize(<char*>self.buffer, <Py_ssize_t>old_size)

    @property
    def needs_input(self):
        """True if more input is needed before more decompressed data can be produced."""
        pass

    @property
    def unused_data(self):
        """Data found after the end of the compressed stream."""
        pass

