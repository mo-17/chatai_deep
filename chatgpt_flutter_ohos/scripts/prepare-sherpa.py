#!/usr/bin/env python3
"""安装固定官方 OHOS 库；不接受 Android/Linux 替代，不覆盖未校验的库。"""
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / 'scripts/sherpa-native.json').read_text())


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(archive=None):
    target = ROOT / 'ohos/entry/libs/arm64-v8a'
    libraries = MANIFEST['libraries']
    if all((target / name).is_file() and digest((target / name).read_bytes()) == sha
           for name, sha in libraries.items()):
        print('Verified Sherpa/ONNX Runtime OHOS 1.13.8 libraries')
        return
    if archive:
        data = Path(archive).read_bytes()
    else:
        with urlopen(MANIFEST['url'], timeout=60) as response:
            data = response.read(16 * 1024 * 1024 + 1)
    if digest(data) != MANIFEST['archiveSha256']:
        raise ValueError('Sherpa archive SHA-256 mismatch')
    with tempfile.TemporaryDirectory(prefix='chatai-sherpa-') as work:
        compressed = Path(work) / 'release.tar.bz2'
        compressed.write_bytes(data)
        with tarfile.open(compressed, 'r:bz2') as source:
            verified = {}
            for name, sha in libraries.items():
                member = source.getmember(f"sherpa-onnx-v{MANIFEST['version']}-ohos-arm64-v8a/lib/{name}")
                if not member.isfile() or member.size > 32 * 1024 * 1024:
                    raise ValueError('Invalid library member')
                binary = source.extractfile(member).read()
                if digest(binary) != sha or binary[:6] != b'\x7fELF\x02\x01' or binary[18:20] != b'\xb7\x00':
                    raise ValueError(f'Invalid OHOS arm64 library: {name}')
                verified[name] = binary
            target.mkdir(parents=True, exist_ok=True)
            for name, binary in verified.items():
                temporary = target / (name + '.tmp')
                try:
                    temporary.write_bytes(binary)
                    os.replace(temporary, target / name)
                finally:
                    temporary.unlink(missing_ok=True)
    print('Installed verified Sherpa/ONNX Runtime OHOS 1.13.8 libraries')


if __name__ == '__main__':
    prepare(sys.argv[1] if len(sys.argv) > 1 else None)
