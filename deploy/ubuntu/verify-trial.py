#!/usr/bin/env python3
"""显式授权后启用生产试用；仅发起一次最多输出 64 Token 的真实付费请求。"""
import argparse
import json
import pathlib
import urllib.error
import urllib.request

ORIGIN = 'https://kushui.shop'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--admin-credentials', type=pathlib.Path, required=True)
    p.add_argument('--user-credentials', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--enable-and-keep-on-success', action='store_true', required=True)
    args = p.parse_args()
    checks = []

    def check(name, ok):
        checks.append({'name': name, 'passed': bool(ok)})
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
        if not ok:
            raise RuntimeError('trial_verification_failed')

    def credentials(path):
        if path.stat().st_mode & 0o077:
            raise RuntimeError('credentials_must_be_0600')
        value = json.loads(path.read_text())
        if value['baseUrl'] != ORIGIN:
            raise RuntimeError('destination_mismatch')
        return value

    def call(path, body=None, token=None, method=None):
        headers = {'User-Agent': 'AipuDeploymentCheck/1.0', 'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(ORIGIN + path, headers=headers, method=method,
                                     data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    enabled_here = False
    successful = False
    admin_token = None
    used = None
    try:
        admin, user = credentials(args.admin_credentials), credentials(args.user_credentials)
        status, result = call('/uapi/admin/login', {'userName': admin['userName'], 'password': admin['password']})
        check('管理员正常登录', status == 200 and bool(result.get('data', {}).get('token')))
        admin_token = result['data']['token']
        status, result = call('/uapi/auth/login/password', {'channel': 'email', 'identifier': user['email'], 'password': user['password']})
        check('临时普通用户正常登录', status == 200 and result.get('extra', {}).get('id') == user['id'])
        user_token = result['data']
        status, result = call('/uapi/admin/access-policy', token=admin_token)
        policy = result['data']
        check('已配置额度保护和指定试用模型', status == 200 and policy['limitsEnabled'] and policy['dailyTokens'] == 10000 and policy['trialProviderCode'] == 'deepseek' and policy['trialModel'] == 'deepseek-flash')
        status, before = call('/uapi/account/usage', token=user_token)
        check('调用前用量可读取', status == 200)
        if not policy['trialEnabled']:
            # PATCH 响应超时也可能已经生效；失败路径仍须尝试恢复关闭。
            enabled_here = True
            status, result = call('/uapi/admin/access-policy', {'trialEnabled': True}, admin_token, 'PATCH')
            check('已授权启用官方试用', status == 200 and result['data']['trialEnabled'])
        # 本脚本只在这里调用一次真实模型；网络未知结果不自动重试。
        status, response = call('/uapi/chat/completions', {
            'model': '__aipu_trial__',
            'messages': [{'role': 'user', 'content': 'Reply only OK.'}],
            'max_tokens': 64,
            'reasoning_policy': 'off_if_supported',
        }, user_token)
        data = response.get('data', {})
        check('真实 DeepSeek 试用返回文字', status == 200 and bool(data.get('content', '').strip()))
        used = data.get('usage', {}).get('total_tokens')
        check('真实模型返回有效用量', isinstance(used, int) and used > 0)
        status, after = call('/uapi/account/usage', token=user_token)
        check('按真实 Token 结算而非保留预估', status == 200 and after['data']['usedTokens'] - before['data']['usedTokens'] == used)
        check('计入请求次数和剩余额度', after['data']['usedRequests'] == before['data']['usedRequests'] + 1 and after['data']['remainingTokens'] == 10000 - after['data']['usedTokens'])
        check('用户可见已开启的试用入口', after['data']['trialEnabled'] and after['data']['trialModel'] == 'deepseek-flash')
        successful = True
    finally:
        if enabled_here and not successful and admin_token:
            try:
                status, _ = call('/uapi/admin/access-policy', {'trialEnabled': False}, admin_token, 'PATCH')
                closed = status == 200
            except Exception:
                closed = False
            checks.append({'name': '失败后自动关闭本次启用的试用', 'passed': closed})
        args.output.write_text(json.dumps({'checks': checks, 'passed': sum(c['passed'] for c in checks), 'total': len(checks), 'actualTokens': used, 'trialKeptEnabled': successful}, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit('Trial verification failed: ' + type(error).__name__)
