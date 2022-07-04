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
from bz3 import compress, decompress, test


with open("test_inp.txt", "rb") as inp, open("compressed.bz3", "wb") as out:
    compress(inp, out, 1000 * 1000)

with open("compressed.bz3", "rb") as inp:
    test(inp, True)    

with open("compressed.bz3", "rb") as inp, open("output.txt", "wb") as out:
    decompress(inp, out)
```



### Public functions
```python
from typing import IO

def crc32(crc: int, buf: bytes) -> int: ...
def compress(input: IO, output: IO, block_size: int) -> None: ...
def decompress(input: IO, output: IO) -> None: ...
def test(input: IO, should_raise: bool = ...) -> bool: ...
```