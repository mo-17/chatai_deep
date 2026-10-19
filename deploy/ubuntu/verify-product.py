#!/usr/bin/env python3
"""显式凭据启用的线上验收；只用临时普通用户，不调用真实模型或发送邮件。"""
import argparse
import json
import pathlib
import urllib.request
import urllib.error
import uuid

ORIGIN='https://kushui.shop'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--admin-credentials',type=pathlib.Path,required=True)
    parser.add_argument('--user-credentials',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--prepare-trial',action='store_true')
    args=parser.parse_args()
    checks=[]
    def check(name,condition):
        checks.append({'name':name,'passed':bool(condition)})
        print(('PASS ' if condition else 'FAIL ')+name,flush=True)
        if not condition: raise RuntimeError('verification_failed')
    def credentials(path):
        if path.stat().st_mode & 0o077:raise RuntimeError('credentials_must_be_0600')
        value=json.loads(path.read_text())
        if value.get('baseUrl') != ORIGIN:raise RuntimeError('credential_destination_mismatch')
        return value
    def call(path,body=None,token=None,method=None):
        headers={'User-Agent':'AipuDeploymentCheck/1.0','Content-Type':'application/json'}
        if token:headers['Authorization']='Bearer '+token
        request=urllib.request.Request(ORIGIN+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
        try:
            with urllib.request.urlopen(request,timeout=30) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:
            try:return error.code,json.load(error)
            except ValueError:return error.code,{}
    try:
        admin=credentials(args.admin_credentials);user=credentials(args.user_credentials)
        status,login=call('/api/admin/login',{'userName':admin['userName'],'password':admin['password']})
        check('管理员正常登录',status==200 and bool(login.get('data',{}).get('token')))
        admin_token=login['data']['token']
        status,login=call('/uapi/auth/login/password',{'channel':'email','identifier':user['email'],'password':user['password']})
        check('普通用户正常登录',status in (200,201) and isinstance(login.get('data'),str) and bool(login['data']))
        user_token=login['data']
        status,usage=call('/uapi/account/usage',token=user_token)
        check('每日一万 Token 政策与当前用量可读',status==200 and usage['data']['dailyTokens']==10000 and usage['data']['usedTokens']==0)
        check('普通用户不能修改额度',call('/uapi/admin/access-policy',{'dailyTokens':999999},token=user_token,method='PATCH')[0]==403)
        check('普通用户不能读后台反馈列表',call('/uapi/admin/feedback',token=user_token)[0]==403)
        if args.prepare_trial:
            status,policy=call('/uapi/admin/access-policy',token=admin_token)
            check('管理员读取额度政策',status==200)
            check('未意外启用试用或额度',not policy['data']['trialEnabled'] and not policy['data']['limitsEnabled'])
            status,_=call('/uapi/admin/access-policy',{'trialProviderCode':'deepseek','trialModel':'deepseek-flash','dailyTokens':10000},token=admin_token,method='PATCH')
            check('保存已确认试用参数且保持关闭',status==200)
            status,providers=call('/uapi/admin/ai/providers',token=admin_token)
            rows=providers.get('data',[])
            rows=rows.get('list',[]) if isinstance(rows,dict) else rows
            provider=next(p for p in rows if p['code']=='deepseek')
            status,models=call('/uapi/admin/ai/models',token=admin_token)
            rows=models.get('data',[])
            rows=rows.get('list',[]) if isinstance(rows,dict) else rows
            if not any(m['providerId']==provider['id'] and m['modelId']=='deepseek-flash' for m in rows):
                status,_=call('/uapi/admin/ai/models',{'providerId':provider['id'],'modelId':'deepseek-flash','displayName':'DeepSeek V4.1 Flash','enabled':True,'supportsReasoning':True},token=admin_token)
                check('准备 DeepSeek Flash 模型元数据',status in (200,201))
        payload={'requestId':str(uuid.uuid4()),'category':'bug','content':'P0P1 temporary acceptance feedback - delete after QA','diagnostics':{'appVersion':'1.0.6+16','platform':'android','locale':'zh-CN','token':'synthetic-must-be-dropped'}}
        status,feedback=call('/uapi/feedback',payload,token=user_token)
        check('提交反馈且过滤诊断白名单外字段',status in (200,201) and 'token' not in feedback['data']['diagnostics'])
        feedback_id=feedback['data']['id']
        status,retry=call('/uapi/feedback',payload,token=user_token)
        check('反馈未知结果重试不会重复创建',status in (200,201) and retry['data']['id']==feedback_id)
        status,replied=call('/uapi/admin/feedback/'+str(feedback_id),{'status':'resolved','reply':'P0P1 synthetic acceptance reply - remove after QA'},token=admin_token,method='PATCH')
        check('后台处理并回复反馈',status==200 and replied['data']['status']=='resolved')
        status,mine=call('/uapi/feedback',token=user_token)
        check('用户能查看自己的处理结果与回复',status==200 and any(item['id']==feedback_id and item['reply']==replied['data']['reply'] for item in mine['data']['list']))
        status,_=call('/uapi/chat/completions',{'model':'__aipu_trial__','messages':[{'role':'user','content':'This request must not reach an upstream provider.'}]},token=user_token)
        check('试用未配置时拒绝调用上游',status==403)
        check('匿名不能读取用量',call('/uapi/account/usage')[0]==401)
    finally:
        args.output.write_text(json.dumps({'checks':checks,'passed':sum(bool(c['passed']) for c in checks),'total':len(checks)},ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':
    try:main()
    except Exception as error:raise SystemExit('Product verification failed: '+type(error).__name__)
