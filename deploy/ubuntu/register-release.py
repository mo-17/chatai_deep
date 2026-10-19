#!/usr/bin/env python3
"""注册暂停的直发版本，并在独立 QA 渠道验证灰度；不向正式用户开启推送。"""
import argparse
import hashlib
import json
import pathlib
import urllib.request
import urllib.error
import uuid

ORIGIN='https://kushui.shop'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials',required=True,type=pathlib.Path)
    parser.add_argument('--manifest',required=True,type=pathlib.Path)
    parser.add_argument('--output',required=True,type=pathlib.Path)
    args=parser.parse_args()
    if args.credentials.stat().st_mode&0o077:raise RuntimeError('credential_permissions')
    credentials=json.loads(args.credentials.read_text())
    if credentials.get('baseUrl')!=ORIGIN:raise RuntimeError('credential_origin')
    manifest=json.loads(args.manifest.read_text())
    token=None
    checks=[]
    def call(path,body=None,method=None):
        headers={'User-Agent':'AipuDeploymentCheck/1.0','Content-Type':'application/json'}
        if token:headers['Authorization']='Bearer '+token
        request=urllib.request.Request(ORIGIN+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
        with urllib.request.urlopen(request,timeout=30) as response:return json.load(response)
    def check(name,condition):
        checks.append({'name':name,'passed':bool(condition)})
        print(('PASS ' if condition else 'FAIL ')+name,flush=True)
        if not condition:raise RuntimeError('release_verification_failed')
    login=call('/api/admin/login',{'userName':credentials['userName'],'password':credentials['password']})
    token=login['data']['token']
    payload={key:manifest[key] for key in ['versionName','versionCode','url','sha256','cid','description','forceUpdate','enabled','rolloutPercent','rolloutSalt','artifacts']}
    payload['rolloutPercent']=0
    existing=call('/uapi/admin/versions?page=1&pageSize=100')['data']['list']
    record=next((v for v in existing if v['cid']==payload['cid'] and v['versionCode']==payload['versionCode']),None)
    if record:
        check('已注册版本内容匹配',record['sha256']==payload['sha256'] and record['artifacts']==payload['artifacts'] and record['rolloutPercent']==0)
    else:record=call('/uapi/admin/versions',payload)['data']
    check('正式体验版本保持暂停推送',record['rolloutPercent']==0)
    qa=None
    try:
        qa_payload={**payload,'cid':'qa-rollout-'+uuid.uuid4().hex,'rolloutPercent':50}
        qa=call('/uapi/admin/versions',qa_payload)['data']
        def bucket(value):
            key=f"{qa['id']}:{qa['versionCode']}:{qa['rolloutSalt']}:{value}"
            return int.from_bytes(hashlib.sha256(key.encode()).digest()[:4],'big')%10000
        selected=next('qa-install-'+str(i).zfill(10) for i in range(1000) if bucket('qa-install-'+str(i).zfill(10))<5000)
        excluded=next('qa-install-'+str(i).zfill(10) for i in range(1000) if bucket('qa-install-'+str(i).zfill(10))>=5000)
        path=f"/uapi/checkUpdate?cid={qa['cid']}&version=1.0.5&versionCode=15&channel=direct&platform=android&abi=arm64-v8a"
        found=call(path+'&installationId='+selected)['data']
        check('独立 QA 渠道灰度命中返回对应架构',found['updateAvailable'] and found['sha256']==payload['artifacts']['arm64-v8a']['sha256'])
        check('同一安装标识稳定命中',call(path+'&installationId='+selected)['data']['id']==found['id'])
        check('灰度排除用户不收到新版',not call(path+'&installationId='+excluded)['data']['updateAvailable'])
        check('旧客户端不参与灰度',not call(path)['data']['updateAvailable'])
        call('/uapi/admin/versions/'+str(qa['id']),{'rolloutPercent':0},method='PATCH')
        check('暂停后命中用户也不收到新版',not call(path+'&installationId='+selected)['data']['updateAvailable'])
    finally:
        if qa:call('/uapi/admin/versions/'+str(qa['id']),method='DELETE')
    old=call('/uapi/checkUpdate?cid=321&versionCode=14&channel=direct&platform=android')['data']
    check('暂停新版仍保留上一全量版本供旧客户端更新',old['updateAvailable'] and old['versionCode']=='15')
    current=call('/uapi/checkUpdate?cid=321&versionCode=16&channel=direct&platform=android')['data']
    check('当前体验包不会降级',not current['updateAvailable'])
    args.output.write_text(json.dumps({'releaseId':record['id'],'checks':checks},ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':
    try:main()
    except Exception as error:raise SystemExit('Release registration failed: '+type(error).__name__)
