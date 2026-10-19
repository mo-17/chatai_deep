#!/usr/bin/env python3
"""Certbot DNS-01 hook：只管理 kushui.shop 的证书验证 TXT，不输出令牌。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

DOMAIN = 'kushui.shop'
RECORD_NAME = '_acme-challenge'
# GoDaddy 实测需同时授予 domains.domain:read 和 domains.dns:update。
API = f'https://api.godaddy.com/v3/domains/zones/{DOMAIN}/dns-records'
TOKEN_FILE = Path('/etc/letsencrypt/secrets/godaddy-pat')
STATE_DIR = Path('/var/lib/chatai-certbot')


class HookError(Exception):
    pass


def load_token(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
            raise HookError('令牌文件必须由运行账号拥有，权限为 0600。')
        token = source.read(8193).strip()
    if not 20 <= len(token) <= 8192 or any(character.isspace() for character in token):
        raise HookError('令牌文件格式无效。')
    return token


class GoDaddy:
    def __init__(self, token):
        self.token = token
        # 不向系统代理发送凭据，也不跟随可能泄漏 Authorization 的重定向。
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method, suffix='', payload=None, query=None):
        url = API + suffix
        if query:
            url += '?' + urllib.parse.urlencode(query)
        body = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(url, data=body, method=method, headers={
            'Authorization': 'Bearer ' + self.token,
            'Content-Type': 'application/json',
            'X-Request-Id': str(uuid.uuid4()),
        })
        try:
            with self.opener.open(request, timeout=30) as response:
                result = response.read(1024 * 1024)
        except urllib.error.HTTPError as error:
            # 服务端错误体或异常文本可能包含请求信息，绝不直接输出。
            raise HookError(f'GoDaddy DNS API 返回 HTTP {error.code}，请检查令牌权限/有效期。') from None
        except (urllib.error.URLError, OSError):
            raise HookError('GoDaddy DNS API 连接失败。') from None
        try:
            return json.loads(result) if result else None
        except (ValueError, UnicodeError):
            raise HookError('GoDaddy DNS API 返回了无效 JSON。') from None

    def records(self):
        records = []
        for page in range(1, 21):
            result = self.request('GET', query={
                'type': 'TXT', 'name': RECORD_NAME, 'page': page, 'pageSize': 100,
            })
            if not isinstance(result, dict) or not isinstance(result.get('items'), list):
                raise HookError('GoDaddy DNS 列表格式与 v3 API 不匹配。')
            for record in result['items']:
                if record.get('type') == 'TXT' and record.get('name') == RECORD_NAME:
                    records.append(record)
            if not any(link.get('rel') == 'next' for link in result.get('links', [])):
                return records
        raise HookError('证书验证记录分页超出限制。')

    def create(self, value):
        try:
            result = self.request('POST', payload={
                'type': 'TXT', 'name': RECORD_NAME, 'data': value, 'ttl': 600,
            })
            if isinstance(result, dict) and result.get('recordId'):
                return str(result['recordId'])
        except HookError as original:
            # POST 超时不等于未创建；只按本次随机验证值恢复，不盲目重试 POST。
            matches = [r for r in self.records() if r.get('data') == value]
            if matches:
                return str(matches[0]['recordId'])
            raise original
        matches = [r for r in self.records() if r.get('data') == value]
        if matches:
            return str(matches[0]['recordId'])
        raise HookError('无法确认本次验证记录已创建。')

    def delete_owned(self, record_id, value):
        # 删除前重新校验 recordId、类型、名称和值，保留旧验证值及其它业务记录。
        matches = [r for r in self.records() if str(r.get('recordId')) == record_id]
        if not matches:
            return
        if len(matches) != 1 or matches[0].get('data') != value:
            raise HookError('验证记录已被其它操作修改，拒绝删除。')
        self.request('DELETE', '/' + urllib.parse.quote(record_id, safe=''))


def authoritative_visible(value):
    import dns.exception
    import dns.resolver
    try:
        resolver = dns.resolver.Resolver()
        resolver.lifetime = 5
        nameservers = sorted(str(r.target).rstrip('.') for r in resolver.resolve(DOMAIN, 'NS'))
        if not nameservers:
            return False
        for nameserver in nameservers:
            addresses = [str(r) for r in resolver.resolve(nameserver, 'A')]
            if not addresses:
                return False
            for address in addresses:
                direct = dns.resolver.Resolver(configure=False)
                direct.nameservers = [address]
                direct.lifetime = 5
                answer = direct.resolve(RECORD_NAME + '.' + DOMAIN, 'TXT', search=False)
                if value not in {b''.join(record.strings).decode('ascii') for record in answer}:
                    return False
        return True
    except (dns.exception.DNSException, OSError, UnicodeError):
        return False


class Challenge:
    def __init__(self, api, state_dir=STATE_DIR, visible=authoritative_visible):
        self.api, self.state_dir, self.visible = api, Path(state_dir), visible

    def path(self, value):
        return self.state_dir / (hashlib.sha256(value.encode()).hexdigest() + '.json')

    def save(self, value, state):
        self.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = self.state_dir.stat()
        if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
            raise HookError('验证状态目录权限必须为 0700。')
        target = self.path(value)
        temporary = target.with_suffix('.' + uuid.uuid4().hex + '.tmp')
        with open(temporary, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
            json.dump(state, output)
        os.replace(temporary, target)

    def cleanup(self, value):
        path = self.path(value)
        if not path.exists():
            return
        state = json.loads(path.read_text())
        if state.get('domain') != DOMAIN or state.get('value') != value:
            raise HookError('验证状态不匹配，拒绝清理。')
        if state.get('owned'):
            record_id = state.get('recordId')
            if record_id:
                self.api.delete_owned(str(record_id), value)
            else:
                # 创建请求结果未知时，保留状态直至能按本次值查明结果。
                for record in self.api.records():
                    if record.get('data') == value:
                        self.api.delete_owned(str(record['recordId']), value)
        path.unlink()

    def auth(self, value, timeout=900, settle=30):
        previous = next((r for r in self.api.records() if r.get('data') == value), None)
        if not self.path(value).exists():
            self.save(value, {'domain': DOMAIN, 'value': value,
                              'owned': previous is None,
                              'recordId': str(previous['recordId']) if previous else None})
        try:
            if previous is None:
                record_id = self.api.create(value)
                self.save(value, {'domain': DOMAIN, 'value': value,
                                  'owned': True, 'recordId': record_id})
            deadline = time.monotonic() + timeout
            while not self.visible(value):
                if time.monotonic() >= deadline:
                    raise HookError('等待所有权威 DNS 发布验证记录超时。')
                print('等待权威 DNS 验证记录同步……', file=sys.stderr, flush=True)
                time.sleep(10)
            # 额外等待边缘同步；不依赖本机递归 DNS 的旧缓存。
            time.sleep(settle)
            print('所有权威 DNS 已发布验证记录。', file=sys.stderr, flush=True)
        except BaseException:
            try:
                self.cleanup(value)
            except Exception:
                print('验证失败后的清理未完成，状态已保留。', file=sys.stderr)
            raise


def challenge_value(environment):
    if environment.get('CERTBOT_DOMAIN') != DOMAIN:
        raise HookError('仅允许为 kushui.shop 验证证书。')
    value = environment.get('CERTBOT_VALIDATION', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}', value):
        raise HookError('Certbot DNS 验证值格式无效。')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['probe', 'auth', 'cleanup'])
    args = parser.parse_args()
    try:
        value = None if args.action == 'probe' else challenge_value(os.environ)
        api = GoDaddy(load_token(TOKEN_FILE))
        if args.action == 'probe':
            print(json.dumps({'dnsApiReadable': True, 'challengeRecordCount': len(api.records())}))
        else:
            challenge = Challenge(api)
            getattr(challenge, args.action)(value)
    except HookError as error:
        # HookError 仅包含本文件构造的诊断，不包含上游响应或凭据。
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError):
        # 不输出其它异常对象，避免意外携带请求信息。
        print('GoDaddy DNS hook 失败；请检查令牌、权限、网络和权威 DNS 传播。', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
