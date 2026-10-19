#!/usr/bin/env python3
"""从现有模型生成可重现 ZIP 与校验目录，保持源模型不变。"""
import argparse
import hashlib
import json
import pathlib
import zipfile


def package(source, output, base_url):
    output.mkdir(parents=True, exist_ok=True)
    model_id = source.name
    archive = output / (model_id + '-v1.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zip_file:
        for path in sorted(source.rglob('*')):
            if path.is_symlink():
                raise ValueError('model contains symlink')
            if path.is_file():
                info = zipfile.ZipInfo(str(path.relative_to(source)), (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                zip_file.writestr(info, path.read_bytes())
    digest = hashlib.sha256()
    with archive.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    descriptor = {'id': model_id, 'title': '中文女声 Baker', 'url': base_url.rstrip('/') + '/' + archive.name,
                  'sha256': digest.hexdigest(), 'bytes': archive.stat().st_size}
    (output / 'catalog.json').write_text(json.dumps({'models': [descriptor]}, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(descriptor, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2] / 'chatgpt_flutter/assets/sherpa_onnx/matcha-icefall-zh-baker')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--base-url', default='https://kushui.shop/downloads/models')
    args = parser.parse_args()
    package(args.source, args.output, args.base_url)
