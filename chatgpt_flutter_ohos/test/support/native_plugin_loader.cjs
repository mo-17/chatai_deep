const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const ts = createRequire(path.resolve(__dirname, '../../../chatgpt_backend/package.json'))('typescript');
module.exports = function load(name, dependencies, context) {
  const source = fs.readFileSync(path.resolve(__dirname, '../../ohos/entry/src/main/ets/media', name + '.ets'), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(code, { module, exports: module.exports, Map, Uint8Array, ArrayBuffer, require(id) {
    if (id === '@ohos/flutter_ohos') return { MethodChannel: class { setMethodCallHandler() {} } };
    if (!(id in dependencies)) throw new Error('Unexpected import: ' + id);
    return dependencies[id];
  } });
  const plugin = new module.exports.default(context);
  plugin.onAttachedToEngine({ getBinaryMessenger() {} });
  const call = (method, args = {}) => new Promise((resolve, reject) => plugin.onMethodCall({ method, argument: k => args[k] ?? null }, {
    success: resolve, error: (code, message) => reject(Object.assign(new Error(message), { code })), notImplemented: () => reject(new Error('not implemented')),
  }));
  return { plugin, call };
};
