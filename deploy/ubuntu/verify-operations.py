#!/usr/bin/env python3
"""已部署监控与试用资格验收。仅合成临时账号；不执行模型推理或发送邮件。"""
import argparse
import datetime
import json
from pathlib import Path
import urllib.error
import urllib.request

ORIGIN = 'https://kushui.shop'


def credentials(path):
    if path.stat().st_mode & 0o077:
        raise ValueError('credential_permissions')
    value = json.loads(path.read_text())
    if value.get('baseUrl') != ORIGIN:
        raise ValueError('credential_origin')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--admin', type=Path, required=True)
    parser.add_argument('--user', type=Path, required=True)
    parser.add_argument('--phase', choices=['unverified', 'verified'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    admin, user = credentials(args.admin), credentials(args.user)
    checks = []

    def check(name, passed):
        checks.append({'name': name, 'passed': bool(passed)})
        if not passed:
            raise RuntimeError('operation_verification_failed: ' + name)

    def call(path, body=None, token=None):
        headers = {'User-Agent': 'AipuDeploymentCheck/1.0', 'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(ORIGIN + path, headers=headers,
                                         data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.load(response), response.headers
        except urllib.error.HTTPError as error:
            return error.code, {}, error.headers

    try:
        _, login, _ = call('/uapi/admin/login', {'userName': admin['userName'], 'password': admin['password']})
        admin_token = login['data']['token']
        _, login, _ = call('/uapi/auth/login/password', {'channel': 'email', 'identifier': user['email'], 'password': user['password']})
        user_token = login['data']
        status, _, _ = call('/uapi/admin/operations')
        check('监控拒绝匿名访问', status == 401)
        status, _, _ = call('/uapi/admin/operations', token=user_token)
        check('监控拒绝普通用户', status == 403)
        status, response, headers = call('/uapi/admin/operations', token=admin_token)
        data = response.get('data', {})
        check('管理员监控经可信公网 HTTPS 返回', status == 200 and bool(headers.get('CF-Ray')))
        check('监控禁用缓存', 'no-store' in headers.get('Cache-Control', ''))
        check('监控包含数据库与固定六类统计', data.get('database', {}).get('ok') is True and len(data.get('http', [])) == 6)
        check('试用保持开启且预算保留', data.get('budget', {}).get('trialEnabled') is True and data['budget']['tokenLimit'] == 100000)
        _, response, _ = call('/uapi/admin/access-policy', token=admin_token)
        policy = response['data']
        check('邮箱资格与服务端风控已启用', policy['requireVerifiedEmail'] is True and policy['requestsPerMinute'] == 6 and policy['globalMaxConcurrent'] == 4 and policy['dailyTokens'] == 10000)
        _, response, _ = call('/uapi/account/usage', token=user_token)
        usage = response['data']
        check('邮箱资格与测试阶段一致', usage['trialEligible'] == (args.phase == 'verified'))
        if args.phase == 'unverified':
            check('提供可恢复的资格原因', usage['trialUnavailableReason'] == 'verified_email_required')
            # 非纯文本负载是额外保险：若邮箱校验失效，也会在预算估算处被拒绝，不能触发付费推理。
            messages = [{'role': 'user', 'content': [{'type': 'text', 'text': 'qualification-only'}]}]
            for model in ['__aipu_trial__', policy['trialModel']]:
                for suffix in ['', '/stream']:
                    status, _, _ = call('/uapi/chat/completions' + suffix,
                        {'model': model, 'messages': messages, 'max_tokens': 1}, user_token)
                    check('未验证邮箱拦截 ' + ('试用别名' if model == '__aipu_trial__' else '真实模型') + (suffix or '/json'), status == 403)
        else:
            check('已验证邮箱显示剩余额度', usage['remainingTokens'] == 10000 and usage['remainingRequests'] == 100)
    finally:
        report = {'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'phase': args.phase, 'passed': sum(c['passed'] for c in checks), 'total': len(checks), 'checks': checks}
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f"{report['passed']}/{report['total']} checks passed")


if __name__ == '__main__':
    main()
