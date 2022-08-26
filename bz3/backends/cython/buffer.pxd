# cython: language_level=3
# cython: cdivision=True
from libc.stdint cimport uint8_t


cdef extern from "buffer.h" nogil:
    ctypedef struct buffer_t:
        uint8_t * data
        size_t len
        size_t cap

    buffer_t *buffer_new(size_t cap)
    buffer_t * buffer_new_from_string(char* str)
    buffer_t *buffer_new_from_string_and_size(uint8_t *str, size_t len)
    size_t buffer_get_size(buffer_t *self)
    size_t buffer_get_cap(buffer_t *self)
    uint8_t *buffer_as_string(buffer_t *self)
    int buffer_append_right(buffer_t *self, uint8_t *str, size_t len)
    int buffer_pop_left(buffer_t *self, size_t len)
    int buffer_make_room_for(buffer_t *self, size_t size)
    void buffer_del(buffer_t ** self)
