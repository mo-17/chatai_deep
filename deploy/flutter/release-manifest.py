#!/usr/bin/env python3
"""读取真实 APK 的版本、架构与签名，生成不可变发布元数据；不读取私钥。"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
EXPECTED_SIGNER = 'DAE075AF9ECF7BD3C7C8C92FE8FFAD855A610C37B8731B1DE931270FAF102C7F'

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()

def inspect(path, aapt, java, apksigner):
    badging = subprocess.check_output([aapt, 'dump', 'badging', str(path)], text=True)
    identity = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    if not identity:
        raise ValueError('cannot read APK identity')
    signer = subprocess.check_output([java, '-jar', apksigner, 'verify', '--print-certs', str(path)], text=True)
    hashes = re.findall(r'certificate SHA-256 digest: ([0-9a-fA-F]+)', signer)
    if not hashes or any(item.upper() != EXPECTED_SIGNER for item in hashes):
        raise ValueError('signer differs from existing direct APK; cover upgrade is unsafe')
    if identity[1] != 'com.example.chatgpt_flutter':
        raise ValueError('package ID differs from installed direct APK')
    with zipfile.ZipFile(path) as archive:
        if any(item.endswith('.onnx') for item in archive.namelist()):
            raise ValueError('offline model unexpectedly bundled')
        abis = sorted({item.split('/')[1] for item in archive.namelist() if item.startswith('lib/') and item.endswith('.so')})
    return identity[3], int(identity[2]), abis

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk-dir', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--base-url', default='https://kushui.shop/downloads')
    parser.add_argument('--notes', required=True)
    parser.add_argument('--previous-build', type=int, required=True)
    sdk = pathlib.Path.home() / 'Library/Android/sdk/build-tools/35.0.1'
    parser.add_argument('--aapt', default=str(sdk/'aapt'))
    parser.add_argument('--apksigner', default=str(sdk/'lib/apksigner.jar'))
    parser.add_argument('--java', default='/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java')
    args = parser.parse_args()
    if not args.base_url.startswith('https://'):
        raise ValueError('release URLs require HTTPS')
    releases = {}; version = None; build = None
    args.output.mkdir(parents=True, exist_ok=True)
    for abi, source in [('universal','app-release.apk'),('arm64-v8a','app-arm64-v8a-release.apk'),('armeabi-v7a','app-armeabi-v7a-release.apk'),('x86_64','app-x86_64-release.apk')]:
        path = args.apk_dir / source
        name, code, abis = inspect(path,args.aapt,args.java,args.apksigner)
        if code <= args.previous_build or (version is not None and (name != version or code != build)):
            raise ValueError('version must increase and match all APKs')
        if abi != 'universal' and abis != [abi]:
            raise ValueError('ABI mismatch')
        version, build = name, code
        target = f'aipu-{version}-{build}-{abi}.apk'
        # 拒绝覆盖同名不同内容的不可变产物。
        destination = args.output / target
        checksum = digest(path)
        if destination.exists() and digest(destination) != checksum:
            raise ValueError('immutable artifact already exists with different bytes')
        if not destination.exists():
            import shutil
            shutil.copy2(path, destination)
        (args.output/(target+'.sha256')).write_text(checksum+'  '+target+'\n')
        releases[abi] = {'url':args.base_url.rstrip('/')+'/'+target,'sha256':checksum,'bytes':path.stat().st_size}
    universal = releases.pop('universal')
    data={'versionName':version,'versionCode':build,**universal,'cid':'321','description':args.notes,'enabled':True,'forceUpdate':False,'rolloutPercent':0,'rolloutSalt':f'{version}-{build}','artifacts':releases,'backendOrigin':'https://kushui.shop'}
    (args.output/'release.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'version':version,'build':build,'artifacts':4,'rolloutPercent':0},ensure_ascii=False))

if __name__ == '__main__':
    main()
