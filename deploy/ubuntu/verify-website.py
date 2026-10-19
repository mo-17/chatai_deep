#!/usr/bin/env python3
"""公网只读验收：系统 curl 校验 TLS、路由、静态资源及安装包分段内容，无凭据。"""
import argparse
import datetime
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urljoin


class Resources(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        for key in ('href', 'src'):
            value = attrs.get(key, '')
            if value.startswith(('/site-assets/', '/_next/static/')):
                self.urls.add(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://kushui.shop')
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    checks = []

    def check(name, passed):
        checks.append({'name': name, 'passed': bool(passed)})
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)

    def request(path, method='GET', headers=(), origin=None):
        with tempfile.TemporaryDirectory(prefix='chatai-public-check-') as temp:
            head, body = Path(temp)/'headers', Path(temp)/'body'
            command = ['curl', '--silent', '--show-error', '--connect-timeout', '10',
                       '--max-time', '35', '--dump-header', str(head), '--output', str(body),
                       '--write-out', '%{http_code}']
            if method == 'HEAD':
                command.append('--head')
            else:
                command += ['--max-filesize', '8388608']
            for header in headers:
                command += ['--header', header]
            result = subprocess.run(command + [urljoin((origin or args.origin) + '/', path)], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('公网请求失败：' + path + ' (curl ' + str(result.returncode) + ')')
            # 只保留最后一个 HTTP 头块，兼容本机网络代理的 CONNECT 响应。
            raw = head.read_text().replace('\r\n', '\n').strip().split('\n\n')[-1]
            fields = dict(line.split(':', 1) for line in raw.splitlines()[1:] if ':' in line)
            fields = {key.lower(): value.strip() for key, value in fields.items()}
            return int(result.stdout), fields, body.read_bytes()

    status, headers, home = request('/')
    check('官网 HTTPS 与产品正文', status == 200 and b'id="hero-title"' in home)
    check('标准 HTTPS 经 Cloudflare 边缘', headers.get('server') == 'cloudflare' and bool(headers.get('cf-ray')))
    check('官网 CSP、nosniff 与重验证缓存', "script-src 'self'" in headers.get('content-security-policy', '') and headers.get('x-content-type-options') == 'nosniff' and headers.get('cache-control') == 'no-cache')
    resources = Resources()
    resources.feed(home.decode())
    for url in sorted(resources.urls):
        code, _, content = request(url)
        check('官网资源 ' + url, code == 200 and len(content) > 0)
    code, _, _ = request('/site-assets/not-a-real-file.css')
    check('缺失官网资源返回 404', code == 404)
    code, _, robots = request('/robots.txt')
    check('爬虫仅开放官网与展示资源', code == 200 and b'Disallow: /' in robots and b'Allow: /$' in robots)
    for path, expected_code, target in [('/index.html', 308, '/'), ('/admin', 302, '/login'), ('/admin/', 302, '/login')]:
        code, fields, _ = request(path)
        check('路由 ' + path, code == expected_code and fields.get('location') == target)

    code, _, login = request('/login')
    check('后台登录页保持 Next.js', code == 200 and b'/_next/' in login)
    admin_resources = Resources()
    admin_resources.feed(login.decode())
    check('后台存在静态资源', bool(admin_resources.urls))
    for url in sorted(admin_resources.urls):
        code, _, content = request(url)
        check('后台资源 ' + url, code == 200 and len(content) > 0)

    for path, expected in [('/healthz', 200), ('/uapi/auth/public-config', 200), ('/uapi/ai/catalog', 401), ('/uapi/admin/me', 401), ('/api/admin/me', 401)]:
        code, _, content = request(path)
        check('API ' + path, code == expected and isinstance(json.loads(content), dict))
    for path in ['/', '/login']:
        code, fields, _ = request(path, origin='http://kushui.shop')
        check('HTTP 跳转 ' + path, code in (301, 308) and fields.get('location') == args.origin + path)

    for path in ['/', '/login?from=www']:
        code, fields, _ = request(path, origin='https://www.kushui.shop')
        check('WWW 跳转保留路径和查询 ' + path, code == 308 and fields.get('location') == args.origin + path)
    code, fields, _ = request('/uapi/auth/public-config', headers=['Origin: ' + args.origin])
    check('标准 HTTPS 精确 CORS 来源', code == 200 and fields.get('access-control-allow-origin') == args.origin)
    code, fields, _ = request('/api/admin/me')
    check('受保护 API 不在边缘缓存', code == 401 and fields.get('cf-cache-status') in ('DYNAMIC', 'BYPASS') and fields.get('age') is None)

    code, _, raw = request('/site-assets/release.json')
    release = json.loads(raw)
    check('下载版本元数据', code == 200 and release['channel'] == 'preview' and release['signing'] == 'debug')
    digest = hashlib.sha256()
    with args.apk.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            digest.update(chunk)
    size = args.apk.stat().st_size
    check('本地 APK 与公开摘要和大小一致', digest.hexdigest() == release['sha256'] and size == release['bytes'])
    code, fields, _ = request(release['url'], method='HEAD')
    check('APK 附件头与大小', code == 200 and fields.get('content-disposition') == 'attachment' and fields.get('content-length') == str(size))
    for start, end in [(0, 4095), (size-4096, size-1)]:
        code, fields, content = request(release['url'], headers=['Range: bytes=' + str(start) + '-' + str(end)])
        with args.apk.open('rb') as stream:
            stream.seek(start)
            expected = stream.read(end-start+1)
        check('APK 公网分段内容 ' + str(start), code == 206 and fields.get('content-range') == 'bytes ' + str(start) + '-' + str(end) + '/' + str(size) and content == expected)
    code, _, content = request(release['url'] + '.sha256')
    check('公开 SHA-256 文件', code == 200 and content.decode().split()[0] == release['sha256'])
    code, _, _ = request('/downloads/')
    check('禁止安装包目录列表', code == 403)
    code, _, _ = request('/downloads/not-a-real-file.apk')
    check('缺失安装包返回 404', code == 404)

    report = {'origin': args.origin, 'checkedAt': datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
              'passed': sum(item['passed'] for item in checks), 'total': len(checks), 'checks': checks}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(str(report['passed']) + '/' + str(report['total']) + ' 项通过；报告：' + str(args.output))
    return 0 if all(item['passed'] for item in checks) else 1


if __name__ == '__main__':
    raise SystemExit(main())
