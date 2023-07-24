from typing import List, IO

class BZ3Compressor:
    block_size: int
    def __init__(self, block_size: int) -> None: ...
    def compress(self, data: bytes) -> bytes: ...
    def error(self) -> str: ...
    def flush(self) -> bytes: ...

class BZ3Decompressor:
    block_size: int
    ignore_error: bool
    unused_data: bytes
    def __init__(self, ignore_error: bool = False) -> None: ...
    def decompress(self, data: bytes) -> bytes: ...
    def error(self) -> str: ...

class BZ3OmpCompressor:
    block_size: int
    numthreads: int
    def __init__(self, block_size: int, numthreads: int) -> None: ...
    def compress(self, data: bytes) -> bytes: ...
    def error(self) -> List[str]: ...
    def flush(self) -> bytes: ...


class BZ3OmpDecompressor:
    block_size: int
    ignore_error: bool
    numthreads: int
    unused_data: int
    def __init__(self, numthreads: int, ignore_error: bool = False) -> None: ...
    def decompress(self, data: bytes) -> bytes: ...
    def error(self) -> List[str]: ...

def bound(input_size: int) -> int: ...
def compress_file(input: IO[bytes], output: IO[bytes], block_size: int) -> None: ...
def compress_into(data: bytes, out: bytearray, block_size: int = 1000000) -> int: ...
def decompress_file(input: IO[bytes], output: IO[bytes]) -> None: ...
def decompress_into(data: bytes, out: bytearray) -> int: ...
def libversion() -> str: ...
def recover_file(input: IO[bytes], output: IO[bytes]) -> None: ...
def test_file(input, should_raise: bool = False) -> bool: ...