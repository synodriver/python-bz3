from libc.stdint cimport (int8_t, int16_t, int32_t, uint8_t, uint16_t,
                          uint32_t, uint64_t)


cdef extern from "common.h" nogil:
    ctypedef uint8_t u8
    ctypedef uint16_t u16
    ctypedef uint32_t u32
    ctypedef uint64_t u64

    ctypedef int8_t s8
    ctypedef int16_t s16
    ctypedef int32_t s32

    s32 read_neutral_s32(const u8 * data)
    void write_neutral_s32(u8 * data, s32 value)

cdef extern from "libbz3.h" nogil:
    int BZ3_OK
    int BZ3_ERR_OUT_OF_BOUNDS
    int BZ3_ERR_BWT
    int BZ3_ERR_CRC
    int BZ3_ERR_MALFORMED_HEADER
    int BZ3_ERR_TRUNCATED_DATA
    int BZ3_ERR_DATA_TOO_BIG

    struct bz3_state:
        pass

    int8_t bz3_last_error(bz3_state * state)
    const char * bz3_strerror(bz3_state * state)
    bz3_state * bz3_new(int32_t block_size)
    void bz3_free(bz3_state * state)
    int32_t bz3_encode_block(bz3_state * state, uint8_t * buffer, int32_t size)
    int32_t bz3_decode_block(bz3_state * state, uint8_t * buffer, int32_t size, int32_t orig_size)
    void bz3_encode_blocks(bz3_state * states[], uint8_t * buffers[], int32_t sizes[], int32_t n);
    void bz3_decode_blocks(bz3_state * states[], uint8_t * buffers[], int32_t sizes[], int32_t orig_sizes[],
                           int32_t n)



cdef extern from "lzp.h" nogil:
    lzp_compress(const u8 * input, u8 * output, s32 n, s32 hash, s32 min, s32 * lut)
    lzp_decompress(const u8 * input, u8 * output, s32 n, s32 hash, s32 min, s32 * lut)

cdef extern from "crc32.h" nogil:
    u32 crc32sum(u32 crc, u8 * buf, size_t size)
