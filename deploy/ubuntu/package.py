#!/usr/bin/env python3
"""从显式路径清单打包 Node 源码，不携带本地环境、依赖或 Flutter 工程。"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import tarfile

REQUIRED = [
    'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', '.npmrc',
    'chatgpt_backend/package.json', 'chatgpt_backend/tsconfig.json',
    'chatgpt_backend/tsconfig.build.json', 'chatgpt_backend/nest-cli.json',
    'chatgpt_backend/src', 'chatgpt_backend/libs',
    'chatgpt_admin/package.json', 'chatgpt_admin/tsconfig.json',
    'chatgpt_admin/next.config.ts', 'chatgpt_admin/postcss.config.mjs',
    'chatgpt_admin/hero.ts',
    'chatgpt_admin/src', 'deploy/ubuntu',
]
SKIP = {'node_modules', 'dist', 'build', '.next', '.git', '.wrangler',
        'uploads', 'coverage', 'logs', 'tests', '__tests__', '__pycache__'}


def include(info):
    parts = Path(info.name).parts
    # src/test 是仍被 AppModule 静态导入的业务模块，必须保留；只排除包根测试目录。
    if len(parts) >= 2 and parts[0] in {'chatgpt_backend', 'chatgpt_admin'} and parts[1] == 'test':
        return None
    if any(p in SKIP or p.startswith('.env') for p in parts):
        return None
    name = parts[-1]
    if name.endswith('.env') or ('.env.' in name and not name.endswith('.example')):
        return None
    if name.endswith(('.pem', '.key', '.p8', '.p12', '.pfx', '.jks', '.keystore',
                      '.tgz', '.tar.gz', '.tsbuildinfo', '.DS_Store',
                      '.spec.ts', '.test.ts', '.test.tsx')):
        return None
    if 'secrets' in parts:
        return None
    if info.issym() or info.islnk():
        raise ValueError(f'源码中出现链接，请先检查并改用普通文件：{info.name}')
    if not (info.isfile() or info.isdir()):
        raise ValueError(f'不支持的源码文件类型：{info.name}')
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
    return info


def package(source, output):
    source, output = Path(source).resolve(), Path(output).resolve()
    for name in REQUIRED:
        if not (source / name).exists():
            raise ValueError(f'缺少源码：{name}')
    # 输出放在打包目录外，防止归档递归读取自身。
    if output.is_relative_to(source):
        raise ValueError('请将输出文件放在源码目录外，例如 /tmp/chatai-ubuntu-source.tgz')
    if output.exists():
        raise ValueError(f'拒绝覆盖已有文件：{output}')
    try:
        with tarfile.open(output, 'w:gz', dereference=False) as archive:
            names = REQUIRED + (['chatgpt_admin/public'] if (source / 'chatgpt_admin/public').exists() else [])
            for name in names:
                archive.add(source / name, arcname=name, filter=include)
    except BaseException:
        output.unlink(missing_ok=True)
        raise


ADMIN_STYLE_MARKERS = {
    '按钮高度': r'\.h-10(?=[\s,{])',
    '按钮最小宽度': r'\.min-w-20(?=[\s,{])',
    '按钮前景色': r'\.text-primary-foreground(?=[\s,{])',
    '输入框标签状态': re.escape(r'group-data-\[filled-within\=true\]'),
}


def verify_admin_style_source(directory):
    source = Path(directory) / 'node_modules/@heroui/theme/dist'
    if not source.is_dir() or not any(source.glob('*.js')):
        raise ValueError('HeroUI 样式源不存在；检查 .npmrc 的依赖提升配置并重新 pnpm install')


def verify_admin_styles(directory):
    files = list((Path(directory) / 'chatgpt_admin/.next/static').rglob('*.css'))
    if not files:
        raise ValueError('后台 CSS 产物缺失')
    css = '\n'.join(path.read_text() for path in files)
    missing = [name for name, pattern in ADMIN_STYLE_MARKERS.items()
               if not re.search(pattern, css)]
    if missing:
        raise ValueError('后台组件样式缺失：' + '、'.join(missing))


def verify_release(directory):
    root = Path(directory)
    manifest = json.loads((root / 'ubuntu-release.json').read_text())
    expected = {'platform': 'linux', 'arch': platform.machine(), 'nodeMajor': 22,
                'backend': 'http://127.0.0.1:3000', 'format': 1}
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f'构建产物不匹配：{key} 应为 {value}')
    for name in ['chatgpt_backend/dist/src/main.js',
                 'chatgpt_backend/dist/src/database/migration-main.js',
                 'chatgpt_backend/node_modules/pg/package.json',
                 'chatgpt_admin/.next/BUILD_ID',
                 'chatgpt_admin/node_modules/next/dist/bin/next']:
        if not (root / name).is_file():
            raise ValueError(f'构建产物缺失：{name}')
    verify_admin_styles(root)
    for app in ['chatgpt_backend', 'chatgpt_admin']:
        if any((root / app).glob('.env*')):
            raise ValueError(f'构建产物含环境文件：{app}/.env*')
    for base, directories, files in os.walk(root):
        for name in directories + files:
            path = Path(base) / name
            if path.is_symlink() and not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f'构建产物含外部链接：{path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    pack = sub.add_parser('source')
    pack.add_argument('source')
    pack.add_argument('output')
    verify = sub.add_parser('verify')
    verify.add_argument('directory')
    style_source = sub.add_parser('style-source')
    style_source.add_argument('directory')
    args = parser.parse_args()
    try:
        if args.command == 'source':
            package(args.source, args.output)
            print(f'源码包已生成：{args.output}')
        elif args.command == 'style-source':
            verify_admin_style_source(args.directory)
        else:
            verify_release(args.directory)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f'{error}\n')
