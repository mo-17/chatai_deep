#!/usr/bin/env bash
# 在现有 Linux 依赖上只构建 OCR 后台页面。不会切换服务或迁移数据库。
set -Eeuo pipefail
[[ $EUID == 0 && $# == 2 ]] || { echo 'Usage: sudo bash prepare-workbench.sh PAYLOAD EXPECTED_RELEASE' >&2; exit 1; }
payload=$(realpath "$1")
previous=$(readlink -f /opt/chatai-deep/current)
[[ $previous == "$2" ]] || { echo 'Current release changed' >&2; exit 1; }
exec 9>/run/lock/chatai-deep-deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
python3 - "$previous/chatgpt_admin" "$payload/admin-baseline.json" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
for name,expected in json.loads(pathlib.Path(sys.argv[2]).read_text()).items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=expected:
        raise SystemExit('Admin baseline changed: '+name)
PY
candidate=$(mktemp -d /opt/chatai-deep/releases/$(date -u +%Y%m%dT%H%M%SZ).ocr-workbench.XXXXXXXX)
chmod 0755 "$candidate"
cp -al "$previous/." "$candidate/"
python3 - "$candidate/chatgpt_admin" "$payload/admin-source.tgz" <<'PY'
import os,pathlib,shutil,sys,tarfile
root=pathlib.Path(sys.argv[1]); output=root/'.next'
assert '.ocr-workbench.' in root.parent.name
if output.is_symlink(): output.unlink()
elif output.exists(): shutil.rmtree(output)
# Next 会更新 tsbuildinfo、next-env 等文件；打断后台源码的硬链接。
for base,dirs,files in os.walk(root):
    dirs[:]=[name for name in dirs if name!='node_modules']
    for name in files:
        path=pathlib.Path(base)/name
        if path.is_symlink(): continue
        tmp=path.with_name(path.name+'.ocr-next')
        shutil.copy2(path,tmp); os.replace(tmp,path)
allowed={'src/app/(dashboard)/ocr/page.tsx','src/components/layout/Sidebar.tsx','src/components/layout/Topbar.tsx'}
with tarfile.open(sys.argv[2]) as archive:
    assert set(archive.getnames())==allowed
    for member in archive:
        assert member.isfile() and member.size<100000
        path=root/member.name; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(archive.extractfile(member).read())
PY
systemd-run --unit="chatai-ocr-admin-build-$(date +%s)" --wait --pipe --collect \
  --property="WorkingDirectory=$candidate/chatgpt_admin" --property=MemoryMax=768M \
  --property=MemorySwapMax=512M --property=CPUQuota=100% --property=Nice=10 \
  --setenv=NEXT_TELEMETRY_DISABLED=1 --setenv=CHATAI_LOW_MEMORY_BUILD=true \
  --setenv=NEXT_PUBLIC_BACKEND=http://127.0.0.1:3000 --setenv=NODE_OPTIONS=--max-old-space-size=512 \
  /opt/chatai-deep/node/bin/node node_modules/next/dist/bin/next build --webpack
python3 - "$candidate" <<'PY'
import importlib.util,pathlib,sys
root=pathlib.Path(sys.argv[1]); path=root/'deploy/ubuntu/package.py'
spec=importlib.util.spec_from_file_location('deployment_package',path)
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
module.verify_admin_styles(root)
assert (root/'chatgpt_admin/.next/server/app/ocr.html').exists()
PY
printf '%s\n' "$candidate" > "$payload/candidate.txt"
printf '%s\n' "$previous" > "$payload/previous.txt"
echo 'OCR admin candidate built; production services unchanged.'
