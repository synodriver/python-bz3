import glob
import sys

from cffi import FFI

ffibuilder = FFI()
ffibuilder.cdef(
    """
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;



#define BZ3_OK 0
#define BZ3_ERR_OUT_OF_BOUNDS -1
#define BZ3_ERR_BWT -2
#define BZ3_ERR_CRC -3
#define BZ3_ERR_MALFORMED_HEADER -4
#define BZ3_ERR_TRUNCATED_DATA -5
#define BZ3_ERR_DATA_TOO_BIG -6

struct bz3_state;

/**
 * @brief Get the last error number associated with a given state.
 */
int8_t bz3_last_error(struct bz3_state * state);

/**
 * @brief Return a user-readable message explaining the cause of the last error.
 */
const char * bz3_strerror(struct bz3_state * state);

/**
 * @brief Construct a new block encoder state, which will encode blocks as big as the given block size.
 * The decoder will be able to decode blocks at most as big as the given block size.
 * Returns NULL in case allocation fails or the block size is not between 65K and 511M
 */
struct bz3_state * bz3_new(int32_t block_size);

/**
 * @brief Free the memory occupied by a block encoder state.
 */
void bz3_free(struct bz3_state * state);

/**
 * @brief Return the recommended size of the output buffer for the compression functions.
 */
size_t bz3_bound(size_t input_size);

/* ** HIGH LEVEL APIs ** */

/**
 * @brief Compress a block of data. This function does not support parallelism
 * by itself, consider using the low level `bz3_encode_blocks()` function instead.
 * Using the low level API might provide better performance.
 * Returns a bzip3 error code; BZ3_OK when the operation is successful.
 * Make sure to set out_size to the size of the output buffer before the operation;
 * out_size must be at least equal to `bz3_bound(in_size)'.
 */
int bz3_compress(uint32_t block_size, const uint8_t * in, uint8_t * out, size_t in_size, size_t * out_size);

/**
 * @brief Decompress a block of data. This function does not support parallelism
 * by itself, consider using the low level `bz3_decode_blocks()` function instad.
 * Using the low level API might provide better performance.
 * Returns a bzip3 error code; BZ3_OK when the operation is successful.
 * Make sure to set out_size to the size of the output buffer before the operation.
 */
int bz3_decompress(const uint8_t * in, uint8_t * out, size_t in_size, size_t * out_size);

/**
 * @brief Encode a single block. Returns the amount of bytes written to `buffer'.
 * `buffer' must be able to hold at least `size + size / 50 + 32' bytes. The size must not
 * exceed the block size associated with the state.
 */
int32_t bz3_encode_block(struct bz3_state * state, uint8_t * buffer, int32_t size);

/**
 * @brief Decode a single block.
 * `buffer' must be able to hold at least `size + size / 50 + 32' bytes. The size must not exceed
 * the block size associated with the state.
 * @param size The size of the compressed data in `buffer'
 * @param orig_size The original size of the data before compression.
 */
int32_t bz3_decode_block(struct bz3_state * state, uint8_t * buffer, int32_t size, int32_t orig_size);

/**
 * @brief Encode `n' blocks, all in parallel.
 * All specifics of the `bz3_encode_block' still hold. The function will launch a thread for each block.
 * The compressed sizes are written to the `sizes' array. Every buffer is overwritten and none of them can overlap.
 * Precisely `n' states, buffers and sizes must be supplied.
 *
 * Expects `n' between 2 and 16.
 *
 * Present in the shared library only if -lpthread was present during building.
 */
//void bz3_encode_blocks(struct bz3_state * states[], uint8_t * buffers[], int32_t sizes[], int32_t n);

/**
 * @brief Decode `n' blocks, all in parallel.
 * Same specifics as `bz3_encode_blocks', but doesn't overwrite `sizes'.
 */
//void bz3_decode_blocks(struct bz3_state * states[], uint8_t * buffers[], int32_t sizes[], int32_t orig_sizes[], int32_t n);

const char * bz3_version();

s32 read_neutral_s32(u8 * data);
void write_neutral_s32(u8 * data, s32 value);
void* PyMem_Malloc(size_t n);
void PyMem_Free(void* p);
int strncmp (const char *s1, const char *s2, size_t size);
void *memcpy  (void *pto, const void *pfrom, size_t size);
    """
)

source = """
#include <stdint.h>
#include <string.h>
#include "common.h"
#include "libbz3.h"
#include "libsais.h"
"""
c_sources = glob.glob("./dep/src/*.c")
c_sources = list(filter(lambda x: "main" not in x, c_sources))
print(c_sources)

ffibuilder.set_source(
    "bz3.backends.cffi._bz3",
    source,
    sources=c_sources,
    include_dirs=["./dep/include"],
    define_macros=[("VERSION", '"1.1.8.r20-g4c62bca"')],
)

if __name__ == "__main__":
    ffibuilder.compile()
