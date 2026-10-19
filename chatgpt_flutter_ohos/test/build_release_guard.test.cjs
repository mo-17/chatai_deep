const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
function run(mode) {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'chatai-hap-guard-'));
  const root = path.join(parent, 'app'); fs.mkdirSync(root);
  try {
    fs.mkdirSync(path.join(root, 'scripts')); fs.mkdirSync(path.join(root, 'bin'));
    fs.mkdirSync(path.join(root, 'assets/licenses'), { recursive: true });
    fs.mkdirSync(path.resolve(root, '../ohos_plugins/flutter_js/native/quickjs'), { recursive: true });
    fs.writeFileSync(path.join(root, 'assets/licenses/quickjs.txt'), 'MIT test license');
    fs.writeFileSync(path.resolve(root, '../ohos_plugins/flutter_js/native/quickjs/LICENSE'), 'MIT test license');
    for (const name of ['build-release.sh', 'verify-hap-aot.py', 'prepare-sherpa.py', 'verify-sherpa-hap.py']) fs.copyFileSync(path.resolve(__dirname, '../scripts', name), path.join(root, 'scripts', name));
    const binary=Buffer.alloc(320);binary.set([127,69,76,70,2,1,1]);binary.writeUInt16LE(183,18);
    binary.writeBigUInt64LE(64n,32);binary.writeUInt16LE(56,54);binary.writeUInt16LE(1,56);
    binary.writeUInt32LE(1,64);binary.writeUInt32LE(5,68);binary.writeBigUInt64LE(256n,96);binary.writeBigUInt64LE(256n,104);binary.writeBigUInt64LE(4096n,112);binary.write('current-aot',128);
    const nativeDir=path.join(root,'ohos/entry/libs/arm64-v8a');fs.mkdirSync(nativeDir,{recursive:true});
    const libraries={};for(const name of ['libsherpa-onnx-c-api.so','libonnxruntime.so']) {
      fs.writeFileSync(path.join(nativeDir,name),binary);libraries[name]=require('node:crypto').createHash('sha256').update(binary).digest('hex');
    }
    fs.writeFileSync(path.join(root,'scripts/sherpa-native.json'),JSON.stringify({version:'1.13.8',libraries}));
    for(const name of ['sherpa-onnx','onnxruntime','onnxruntime-notices','espeak-ng','piper-phonemize','sherpa-dependencies'])fs.writeFileSync(path.join(root,'assets/licenses',name+'.txt'),'test license');
    fs.writeFileSync(path.join(root, 'config.json'), '{"BACKEND_HOST":"example.test","BACKEND_HTTPS":true}');
    fs.writeFileSync(path.join(root, 'bin/fvm'), `#!/usr/bin/env python3
import json, os, struct, sys, zipfile
from pathlib import Path
args=sys.argv[1:]
def elf(stale=False):
 data=bytearray(320)
 data[:7]=bytes([127,69,76,70,2,1,1])
 struct.pack_into('<H',data,18,183); struct.pack_into('<Q',data,32,64); struct.pack_into('<HH',data,54,56,1)
 struct.pack_into('<IIQQQQQQ',data,64,1,5,0,0,0,256,256,4096)
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
  data=elf(os.environ['GUARD_MODE']=='stale'); struct.pack_into('<Q',data,40,256); struct.pack_into('<HHH',data,58,64,1,0); data[300]=1  # packager may rewrite non-loadable metadata
  z.writestr('libs/arm64-v8a/libapp.so', data)
  native=elf(os.environ['GUARD_MODE']=='stale_native'); struct.pack_into('<Q',native,40,256); struct.pack_into('<HHH',native,58,64,1,0); native[300]=1
  z.writestr('libs/arm64-v8a/libchatai_js.so', native)
  z.writestr('resources/rawfile/flutter_assets/assets/licenses/quickjs.txt', 'missing' if os.environ['GUARD_MODE']=='bad_license' else 'MIT test license')
  for name in ['libsherpa-onnx-c-api.so','libonnxruntime.so']:
   z.writestr('libs/arm64-v8a/'+name,elf(os.environ['GUARD_MODE']=='stale_sherpa'))
  for name in ['sherpa-onnx','onnxruntime','onnxruntime-notices','espeak-ng','piper-phonemize','sherpa-dependencies']:
   z.writestr('resources/rawfile/flutter_assets/assets/licenses/'+name+'.txt','missing' if os.environ['GUARD_MODE']=='bad_sherpa_license' else 'test license')
 artifact=Path('ohos/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libchatai_js.so')
 artifact.parent.mkdir(parents=True); artifact.write_bytes(elf())
else: sys.exit(9)
`);
    fs.chmodSync(path.join(root, 'bin/fvm'), 0o755);
    const result = spawnSync('bash', ['scripts/build-release.sh', 'config.json'], {
      cwd: root, encoding: 'utf8', env: { ...process.env, PATH: `${path.join(root, 'bin')}:${process.env.PATH}`, GUARD_MODE: mode },
    });
    return { ...result, packaged: fs.existsSync(path.join(root, 'packaged')) };
  } finally { fs.rmSync(parent, { recursive: true, force: true }); }
}
test('Dart 编译失败立即停止，不打包陈旧缓存', () => {
  const result = run('compile_error'); assert.equal(result.status, 7); assert.equal(result.packaged, false);
});
test('HAP 中的 AOT 与当前独立编译结果不同则失败', () => {
  const result = run('stale'); assert.notEqual(result.status, 0); assert.match(result.stderr, /different Dart AOT/);
});
test('只有 HAP 内的 AOT 哈希一致才返回成功', () => {
  const result = run('current'); assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /Verified HAP load segments/);
});

test('原生 QuickJS 库与打包内容不符或许可缺失时失败', () => {
  for (const mode of ['stale_native', 'bad_license']) assert.notEqual(run(mode).status, 0);
});
test('Sherpa/ONNX Runtime 可加载段或随包许可证不一致时禁止构建成功',()=>{
  for(const mode of ['stale_sherpa','bad_sherpa_license'])assert.notEqual(run(mode).status,0);
});
