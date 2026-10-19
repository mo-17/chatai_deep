#!/usr/bin/env python3
"""Compare ELF loader data, allowing strip to rewrite section-table-only metadata."""
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
        segment = bytearray(data[start:start + length])
        # ELF 节表供链接/调试工具使用；strip 会修改这些字段，即使头部位于 PT_LOAD。
        # 保留机器类型、入口、程序头等加载器使用的字段及全部代码/数据。
        for begin, end in ((40, 48), (58, 64)):
            lower, upper = max(start, begin), min(start + length, end)
            if lower < upper:
                segment[lower - start:upper - start] = bytes(upper - lower)
        digest.update(segment)
        loads += 1
        executable |= bool(flags & 1)
    if not loads or not executable:
        raise ValueError('ELF has no executable load segments')
    return digest.hexdigest()


def main():
    mode, value, *rest = sys.argv[1:]
    if mode == 'fingerprint' and not rest:
        print(fingerprint(Path(value).read_bytes()))
    elif mode == 'verify' and len(rest) in (1, 2):
        with zipfile.ZipFile(rest[0]) as archive:
            entry = rest[1] if len(rest) == 2 else 'libs/arm64-v8a/libapp.so'
            actual = fingerprint(archive.read(entry))
        if actual != value:
            kind = 'Dart AOT' if entry.endswith('/libapp.so') else 'QuickJS native'
            raise ValueError(f'HAP contains a different {kind} build; refusing stale artifact')
        print('Verified HAP load segments (' + entry + ') SHA-256: ' + actual)
    else:
        raise ValueError('Usage: fingerprint app.so | verify HASH app.hap [ENTRY]')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, struct.error) as error:
        sys.exit(str(error))
