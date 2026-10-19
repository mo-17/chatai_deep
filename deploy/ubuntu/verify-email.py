#!/usr/bin/env python3
"""显式收件邮箱的线上邮件验收；仅操作本脚本新建的临时账号，不输出凭据。"""
import argparse
import json
import os
import pathlib
import secrets
import urllib.error
import urllib.request

ORIGIN = 'https://kushui.shop'


def call(path, body=None, token=None):
    headers = {'User-Agent': 'AipuDeploymentCheck/1.0', 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(ORIGIN + path, headers=headers,
                                 data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=40) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def private_read(path):
    if path.stat().st_mode & 0o077:
        raise RuntimeError('private_file_permissions')
    return json.loads(path.read_text())


def private_write(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump(value, handle)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('stage', choices=['prepare', 'send-register', 'register', 'send-login', 'login', 'send-reset', 'reset'])
    p.add_argument('--email', required=True)
    p.add_argument('--admin-credentials', type=pathlib.Path, required=True)
    p.add_argument('--state', type=pathlib.Path, required=True)
    p.add_argument('--code-file', type=pathlib.Path)
    p.add_argument('--report', type=pathlib.Path, required=True)
    args = p.parse_args()
    checks = json.loads(args.report.read_text()) if args.report.exists() else []

    def check(name, ok):
        checks.append({'name': name, 'passed': bool(ok)})
        args.report.write_text(json.dumps(checks, ensure_ascii=False, indent=2) + '\n')
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
        if not ok:
            raise RuntimeError('email_verification_failed')

    admin = private_read(args.admin_credentials)
    if admin['baseUrl'] != ORIGIN:
        raise RuntimeError('destination_mismatch')
    status, response = call('/uapi/admin/login', {'userName': admin['userName'], 'password': admin['password']})
    if status != 200 or not response.get('data', {}).get('token'):
        raise RuntimeError('admin_login_failed')
    admin_token = response['data']['token']
    if args.stage == 'prepare':
        if args.state.exists():
            raise RuntimeError('state_already_exists')
        # 管理列表 keyword 只搜索用户名；逐页核对 email，不能用空搜索结果当作邮箱未注册。
        rows = []
        page = 1
        while True:
            status, users = call('/uapi/admin/users?page=' + str(page) + '&pageSize=100', token=admin_token)
            if status != 200:
                raise RuntimeError('existing_account_check_failed')
            batch = users['data']['list']
            rows.extend(batch)
            if len(rows) >= users['data']['total']:
                break
            if not batch or page >= 1000:
                raise RuntimeError('existing_account_check_incomplete')
            page += 1
        check('收件邮箱不存在现有账号', not any((u.get('email') or '').lower() == args.email.lower() for u in rows))
        status, providers = call('/uapi/admin/auth/providers', token=admin_token)
        provider = next(x for x in providers['data'] if x['key'] == 'generic')
        check('SMTP 已配置且当前配置测试成功', status == 200 and provider['configured'] and provider['lastTestStatus'] == 'ok' and provider['lastTestRevision'] == provider['configRevision'])
        if not provider['enabled']:
            status, _ = call('/uapi/admin/auth/providers/generic/activate', {}, admin_token)
            check('启用已验证的 SMTP', status == 200)
        private_write(args.state, {'baseUrl': ORIGIN, 'email': args.email, 'password': secrets.token_urlsafe(24), 'newPassword': secrets.token_urlsafe(24), 'id': None})
        return
    state = private_read(args.state)
    if state['baseUrl'] != ORIGIN or state['email'] != args.email:
        raise RuntimeError('state_identity_mismatch')
    identity = {'channel': 'email', 'identifier': args.email}
    if args.stage.startswith('send-'):
        purpose = {'send-register': 'register', 'send-login': 'login', 'send-reset': 'reset_password'}[args.stage]
        status, _ = call('/uapi/auth/code/send', {**identity, 'purpose': purpose})
        check(purpose + ' 邮件提交成功', status == 200)
        return
    if not args.code_file or args.code_file.stat().st_mode & 0o077:
        raise RuntimeError('private_code_required')
    code = args.code_file.read_text().strip()
    if len(code) != 6 or not code.isdigit():
        raise RuntimeError('invalid_code')
    if args.stage == 'register':
        if state['id'] is not None:
            raise RuntimeError('already_registered')
        status, response = call('/uapi/auth/register', {**identity, 'code': code, 'password': state['password']})
        check('实际收信验证码注册并验证邮箱', status == 200 and isinstance(response.get('data'), str) and response.get('extra', {}).get('emailVerified') and response['extra']['email'] == args.email)
        state['id'] = response['extra']['id']
        state['userName'] = response['extra']['userName']
        private_write(args.state, state)
        status, response = call('/uapi/auth/login/password', {**identity, 'password': state['password']})
        check('注册后密码登录', status == 200 and response.get('extra', {}).get('id') == state['id'])
    elif args.stage == 'login':
        status, response = call('/uapi/auth/login/code', {**identity, 'code': code})
        check('实际收信验证码登录同一临时账号', status == 200 and response.get('extra', {}).get('id') == state['id'])
        status, _ = call('/uapi/auth/login/code', {**identity, 'code': code})
        check('已消费验证码不能重复登录', status == 400)
    elif args.stage == 'reset':
        if not state['id']:
            raise RuntimeError('temporary_account_required')
        status, response = call('/uapi/auth/login/password', {**identity, 'password': state['password']})
        check('重置前身份仍为临时账号', status == 200 and response.get('extra', {}).get('id') == state['id'])
        old_token = response['data']
        status, _ = call('/uapi/auth/reset-password', {**identity, 'code': code, 'newPassword': state['newPassword']})
        check('实际收信验证码找回临时账号密码', status == 200)
        status, _ = call('/uapi/auth/login/password', {**identity, 'password': state['password']})
        check('重置后旧密码失效', status == 400)
        status, response = call('/uapi/auth/login/password', {**identity, 'password': state['newPassword']})
        check('重置后新密码登录同一临时账号', status == 200 and response.get('extra', {}).get('id') == state['id'])
        status, _ = call('/uapi/account/usage', token=old_token)
        check('重置密码撤销旧登录态', status == 401)
    args.code_file.unlink()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit('Email verification failed: ' + type(error).__name__)
