const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const ts = createRequire(path.resolve(__dirname, '../../../chatgpt_backend/package.json'))('typescript');
module.exports = function load(name, dependencies, context, options = {}) {
  const nativeRoot = path.resolve(__dirname, '../../ohos/entry/src/main/ets');
  const filename = path.resolve(nativeRoot, 'media', name + '.ets');
  const modules = options.modules || new Map();
  const events = [], timers = new Map();
  let timerId = 0;
  function local(filename) {
    if (!filename.startsWith(nativeRoot + path.sep)) throw Error('Outside native fixture root');
    if (modules.has(filename)) return modules.get(filename).exports;
    const module = { exports: {} }; modules.set(filename, module);
    const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
    vm.runInNewContext(code, { module, exports: module.exports, Map, Set, Uint8Array, ArrayBuffer,
    canIUse: options.canIUse || (() => true),
    setTimeout(fn, ms) { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
    clearTimeout(id) { timers.delete(id); }, require(id) {
    if (id === '@ohos/flutter_ohos') return { MethodChannel: class {
      setMethodCallHandler() {} invokeMethod(method, value) { events.push({ method, value }); }
    } };
    if (id.startsWith('.')) return local(path.resolve(path.dirname(filename), id + '.ets'));
    if (!(id in dependencies)) throw new Error('Unexpected import: ' + id);
    return dependencies[id];
  } });
    return module.exports;
  }
  const plugin = new (local(filename).default)(context);
  plugin.onAttachedToEngine({ getBinaryMessenger() {}, getApplicationContext() { return options.applicationContext || context; } });
  const call = (method, args = {}) => new Promise((resolve, reject) => plugin.onMethodCall({ method, argument: k => args[k] ?? null }, {
    success: resolve, error: (code, message) => reject(Object.assign(new Error(message), { code })), notImplemented: () => reject(new Error('not implemented')),
  }));
  return { plugin, call, events, timers, modules };
};
