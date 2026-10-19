#!/usr/bin/env python3
"""Compare ELF program headers and loadable bytes; packaging may rewrite section names."""
import hashlib
import struct
import sys
import zipfile
from pathlib import Path


def fingerprint(data):
    if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01':
        raise ValueError('Expected a 64-bit little-endian ELF')
    if struct.unpack_from('<H', data, 18)[0] != 183:
        raise ValueError('Expected arm64 AOT')
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    if size != 56 or not 0 < count <= 1024 or offset + size * count > len(data):
        raise ValueError('Invalid ELF program headers')
    digest = hashlib.sha256()
    # All program headers affect the loader, including non-PT_LOAD entries.
    digest.update(data[offset:offset + size * count])
    loads = 0
    executable = False
    for index in range(count):
        kind, flags, start, _, _, length, memory, _ = struct.unpack_from('<IIQQQQQQ', data, offset + size * index)
        if kind != 1:  # PT_LOAD
            continue
        if length > memory or start + length > len(data):
            raise ValueError('Invalid ELF load segment')
        digest.update(data[start:start + length])
        loads += 1
        executable |= bool(flags & 1)
    if not loads or not executable:
        raise ValueError('ELF has no executable load segments')
    return digest.hexdigest()


def main():
    mode, value, *rest = sys.argv[1:]
    if mode == 'fingerprint' and not rest:
        print(fingerprint(Path(value).read_bytes()))
    elif mode == 'verify' and len(rest) == 1:
        with zipfile.ZipFile(rest[0]) as archive:
            actual = fingerprint(archive.read('libs/arm64-v8a/libapp.so'))
        if actual != value:
            raise ValueError('HAP contains a different Dart AOT build; refusing stale artifact')
        print('Verified HAP Dart AOT load segments SHA-256: ' + actual)
    else:
        raise ValueError('Usage: fingerprint app.so | verify HASH app.hap')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, struct.error) as error:
        sys.exit(str(error))
