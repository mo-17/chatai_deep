#!/usr/bin/env python3
"""验证 HAP 原生库的可加载段与准备的官方库一致，并包含对应许可。"""
import json
from pathlib import Path
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'scripts/sherpa-native.json').read_text())
for name in manifest['libraries']:
    source = root / 'ohos/entry/libs/arm64-v8a' / name
    fingerprint = subprocess.check_output([sys.executable, str(root / 'scripts/verify-hap-aot.py'), 'fingerprint', str(source)], text=True).strip()
    subprocess.run([sys.executable, str(root / 'scripts/verify-hap-aot.py'), 'verify', fingerprint,
                    sys.argv[1], f'libs/arm64-v8a/{name}'], check=True)
with zipfile.ZipFile(sys.argv[1]) as hap:
    for name in ['sherpa-onnx.txt', 'onnxruntime.txt', 'onnxruntime-notices.txt', 'espeak-ng.txt', 'piper-phonemize.txt', 'sherpa-dependencies.txt']:
        if hap.read(f'resources/rawfile/flutter_assets/assets/licenses/{name}') != (root / 'assets/licenses' / name).read_bytes():
            raise SystemExit(f'License asset mismatch: {name}')
print('Verified Sherpa native libraries and bundled notices')
