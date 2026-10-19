#!/usr/bin/env python3
"""生成和校验部署专用 EnvironmentFile；不执行其中的内容。"""
import argparse
from pathlib import Path
import re
import secrets
import shlex


def read_config(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, raw = line.partition('=')
        if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key) or key in result:
            raise ValueError('环境文件包含非法或重复的键；请使用简单 KEY=value 格式。')
        values = shlex.split(raw, comments=False)
        if len(values) > 1:
            raise ValueError(f'{key} 含空格时必须使用引号。')
        result[key] = values[0] if values else ''
    return result


def validate(path):
    config = read_config(path)
    fixed = {
        'NODE_ENV': 'production', 'HOST': '127.0.0.1', 'PORT': '3000',
        'DB_HOST': '127.0.0.1', 'DB_PORT': '5432', 'DB_USER': 'chatai_app',
        'DB_NAME': 'chatai_app', 'DB_SSL': 'false', 'DB_SYNCHRONIZE': 'false',
        'UPLOADS_DIR': '/var/lib/chatai-deep/uploads',
    }
    for key, value in fixed.items():
        if config.get(key) != value:
            raise ValueError(f'本部署方案要求 {key}={value}')
    if not re.fullmatch(r'[a-f0-9]{64}', config.get('DB_PASSWORD', '')):
        raise ValueError('DB_PASSWORD 应保留首次生成的 64 位十六进制值。')
    for key in ['JWT_SECRET', 'APP_SECRET_KEY']:
        if len(config.get(key, '')) < 32 or config[key] in {'GENERATED_ON_SERVER', 'CHANGE_ME'}:
            raise ValueError(f'{key} 必须为至少 32 字符的随机值。')
    if config['JWT_SECRET'] == config['APP_SECRET_KEY']:
        raise ValueError('JWT_SECRET 和 APP_SECRET_KEY 必须不同。')
    if len(config.get('ADMIN_DEFAULT_PASSWORD', '')) < 16 or config['ADMIN_DEFAULT_PASSWORD'] == 'admin123':
        raise ValueError('ADMIN_DEFAULT_PASSWORD 至少需要 16 字符。')
    if config.get('DB_POOL_MAX') not in {'1', '2', '3', '4', '5'}:
        raise ValueError('2 GB 配置的 DB_POOL_MAX 应为 1～5。')
    return config


def generate(template, destination):
    content = Path(template).read_text()
    for key, size in [('DB_PASSWORD', 32), ('JWT_SECRET', 48),
                      ('APP_SECRET_KEY', 48), ('ADMIN_DEFAULT_PASSWORD', 24)]:
        content = content.replace(f'{key}=GENERATED_ON_SERVER', f'{key}={secrets.token_hex(size)}')
    # 独占创建，绝不覆盖已有密钥。
    with open(destination, 'x', opener=lambda path, flags: __import__('os').open(path, flags, 0o600)) as output:
        output.write(content)
    validate(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['generate', 'validate', 'db-password'])
    parser.add_argument('path')
    parser.add_argument('destination', nargs='?')
    args = parser.parse_args()
    try:
        if args.command == 'generate':
            if not args.destination:
                raise ValueError('generate 需要目标文件路径。')
            generate(args.path, args.destination)
        else:
            config = validate(args.path)
            if args.command == 'db-password':
                print(config['DB_PASSWORD'])
    except (ValueError, OSError) as error:
        parser.exit(1, f'{error}\n')
