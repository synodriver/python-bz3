<h1 align="center"><i>✨ python-bz3 ✨ </i></h1>

<h3 align="center">The python binding for <a href="https://github.com/kspalaiologos/bzip3/tree/master">bzip3</a> </h3>

[![pypi](https://img.shields.io/pypi/v/bzip3.svg)](https://pypi.org/project/bzip3/)
![python](https://img.shields.io/pypi/pyversions/bzip3)
![implementation](https://img.shields.io/pypi/implementation/bzip3)
![wheel](https://img.shields.io/pypi/wheel/bzip3)
![license](https://img.shields.io/github/license/synodriver/python-bz3.svg)
![action](https://img.shields.io/github/workflow/status/synodriver/python-bz3/build%20wheel)

### install
```bash
pip install bzip3
```


### Usage
```python
from bz3 import compress_file, decompress_file, test_file, compress, decompress
import bz3

with open("test_inp.txt", "rb") as inp, open("compressed.bz3", "wb") as out:
    compress_file(inp, out, 1000 * 1000)

with open("compressed.bz3", "rb") as inp:
    test_file(inp, True)    

with open("compressed.bz3", "rb") as inp, open("output.txt", "wb") as out:
    decompress_file(inp, out)

print(decompress(compress(b"12121")))

with bz3.open("test.bz3", "wt", encoding="utf-8") as f:
    f.write("test data")

with bz3.open("test.bz3", "rt", encoding="utf-8") as f:
    print(f.read())
```
- use ```BZ3_USE_CFFI``` env var to specify a backend


### Public functions
```python
from typing import IO, Optional

def compress_file(input: IO, output: IO, block_size: int) -> None: ...
def decompress_file(input: IO, output: IO) -> None: ...
def test_file(input: IO, should_raise: bool = ...) -> bool: ...


class BZ3File:
    def __init__(self, filename, mode: str = ..., block_size: int = ...) -> None: ...
    def close(self) -> None: ...
    @property
    def closed(self): ...
    def fileno(self): ...
    def seekable(self): ...
    def readable(self): ...
    def writable(self): ...
    def peek(self, n: int = ...): ...
    def read(self, size: int = ...): ...
    def read1(self, size: int = ...): ...
    def readinto(self, b): ...
    def readline(self, size: int = ...): ...
    def readlines(self, size: int = ...): ...
    def write(self, data): ...
    def writelines(self, seq): ...
    def seek(self, offset, whence=...): ...
    def tell(self): ...

def open(filename, mode: str = ..., block_size: int = ..., encoding: str = ..., errors: str = ..., newline: str = ...) -> BZ3File: ...
def compress(data: bytes, block_size: int = ...) -> bytes: ...
def decompress(data: bytes) -> bytes: ...

def libversion() -> str: ... # Get bzip3 version
def bound(in: int) -> int: ... # Return the recommended size of the output buffer for the compression functions.

# High-level api
# Compress a block of data into out buffer, zerocopy, both parameters accept objects which implements buffer-protocol.
# out must be writabel, size of out must be at least equal to bound(len(inp))
def compress_into(inp: Union[bytes, bytearray], out: bytearray) -> int: ...
# Decompress a block of data into out buffer, zerocopy
def decompress_into(inp: Union[bytes, bytearray], out: bytearray) -> int: ...
```

- Note, high-level api won't work with low-level api, see [this](https://github.com/kspalaiologos/bzip3/issues/70)
