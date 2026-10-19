const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
function run(mode) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'chatai-hap-guard-'));
  try {
    fs.mkdirSync(path.join(root, 'scripts')); fs.mkdirSync(path.join(root, 'bin'));
    for (const name of ['build-release.sh', 'verify-hap-aot.py']) fs.copyFileSync(path.resolve(__dirname, '../scripts', name), path.join(root, 'scripts', name));
    fs.writeFileSync(path.join(root, 'config.json'), '{"BACKEND_HOST":"example.test","BACKEND_HTTPS":true}');
    fs.writeFileSync(path.join(root, 'bin/fvm'), `#!/usr/bin/env python3
import json, os, struct, sys, zipfile
from pathlib import Path
args=sys.argv[1:]
def elf(stale=False):
 data=bytearray(320)
 data[:7]=bytes([127,69,76,70,2,1,1])
 struct.pack_into('<H',data,18,183); struct.pack_into('<Q',data,32,64); struct.pack_into('<HH',data,54,56,1)
 struct.pack_into('<IIQQQQQQ',data,64,1,5,128,128,128,128,128,4096)
 data[128:139]=b'current-aot' if not stale else b'stale-aot!!'
 return data
if '--version' in args:
 print(json.dumps(dict(frameworkVersion='3.35.7-ohos-local', channel='main', repositoryUrl='local', frameworkRevision='a'*40, engineRevision='b'*40, dartSdkVersion='3.9.2')))
elif 'assemble' in args:
 if os.environ['GUARD_MODE']=='compile_error': sys.exit(7)
 artifact=Path('build/ohos/intermediates/flutter/defaultRelease/arm64-v8a/app.so')
 artifact.parent.mkdir(parents=True); artifact.write_bytes(elf())
elif 'build' in args:
 Path('packaged').touch()
 hap=Path('build/ohos/hap/entry-default-signed.hap'); hap.parent.mkdir(parents=True)
 with zipfile.ZipFile(hap, 'w') as z:
  data=elf(os.environ['GUARD_MODE']=='stale'); data[300]=1  # packager may rewrite non-loadable metadata
  z.writestr('libs/arm64-v8a/libapp.so', data)
else: sys.exit(9)
`);
    fs.chmodSync(path.join(root, 'bin/fvm'), 0o755);
    const result = spawnSync('bash', ['scripts/build-release.sh', 'config.json'], {
      cwd: root, encoding: 'utf8', env: { ...process.env, PATH: `${path.join(root, 'bin')}:${process.env.PATH}`, GUARD_MODE: mode },
    });
    return { ...result, packaged: fs.existsSync(path.join(root, 'packaged')) };
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
test('Dart 编译失败立即停止，不打包陈旧缓存', () => {
  const result = run('compile_error'); assert.equal(result.status, 7); assert.equal(result.packaged, false);
});
test('HAP 中的 AOT 与当前独立编译结果不同则失败', () => {
  const result = run('stale'); assert.notEqual(result.status, 0); assert.match(result.stderr, /different Dart AOT/);
});
test('只有 HAP 内的 AOT 哈希一致才返回成功', () => {
  const result = run('current'); assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /Verified HAP Dart AOT load segments/);
});
