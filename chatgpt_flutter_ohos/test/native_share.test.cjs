const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');

function fixture({ manual = false, failShow = false, failRead = false, symbolic = false, declaredSize = 5, sizes = {} } = {}) {
  const files = new Map([['/files/export.txt', Buffer.from('hello')]]), dirs = new Set(), handles = new Map();
  const panels = []; let sequence = 0;
  const stats = p => ({ size: sizes[p] ?? (files.has(p) ? declaredSize : 0), isFile: () => files.has(p), isDirectory: () => dirs.has(p), isSymbolicLink: () => symbolic });
  const io = {
    OpenMode: { READ_ONLY: 1, CREATE: 2, READ_WRITE: 4, TRUNC: 8 },
    accessSync: p => dirs.has(p) || files.has(p), mkdirSync: p => dirs.add(p),
    listFileSync(p) { return [...new Set([...files.keys(), ...dirs].filter(k => k.startsWith(p + '/')).map(k => k.substring(p.length + 1).split('/')[0]))]; },
    async lstat(p) { return stats(p); },
    async stat(fd) { return stats(handles.get(fd).path); },
    async open(p, mode) { if (mode & 2) files.set(p, Buffer.alloc(0)); const h = { fd: ++sequence, path: p, pos: 0 }; handles.set(h.fd, h); return h; },
    async close(h) { handles.delete(h.fd); },
    async read(fd, buffer) { if (failRead) throw new Error('read failed'); const h = handles.get(fd), b = files.get(h.path); const count = Math.min(2, b.length - h.pos); new Uint8Array(buffer).set(b.subarray(h.pos, h.pos + count)); h.pos += count; return count; },
    async write(fd, bytes) { const h = handles.get(fd), b = Buffer.from(bytes).subarray(0, 1); files.set(h.path, Buffer.concat([files.get(h.path), b])); return b.length; },
    async rmdir(p) { for (const k of files.keys()) if (k.startsWith(p + '/')) files.delete(k); for (const k of dirs) if (k === p || k.startsWith(p + '/')) dirs.delete(k); },
  };
  class SharedData { constructor(record) { this.records = [record]; } addRecord(record) { this.records.push(record); } }
  class ShareController {
    constructor(data) { this.data = data; this.handlers = new Map(); panels.push(this); }
    on(name, fn) { this.handlers.set(name, fn); }
    off(name, fn) { assert.equal(typeof fn, 'function'); this.handlers.delete(name); }
    async show() {
      if (failShow) throw Object.assign(new Error('show failed'), { code: 401 });
      if (!manual) setImmediate(() => { this.handlers.get('shareCompleted')?.({}); this.handlers.get('dismiss')?.(); });
    }
  }
  const native = load('SharePlugin', {
    '@kit.CoreFileKit': { fileIo: io, fileUri: { getUriFromPath: p => 'file://' + p } },
    '@kit.ShareKit': { systemShare: { SharedData, ShareController, SelectionMode: { SINGLE: 1 }, SharePreviewMode: { DETAIL: 1 } } },
    '@kit.ArkData': { uniformTypeDescriptor: { UniformDataType: { PLAIN_TEXT: 'plain', FILE: 'file' }, getUniformDataTypeByFilenameExtension: () => 'text' } },
  }, { cacheDir: '/cache', filesDir: '/files', tempDir: '/temp' });
  const share = (args = {}) => native.call('share', { files: [], ...args });
  return { ...native, share, files, dirs, handles, panels };
}
const fileArgs = { files: [new Map([['path', '/files/export.txt'], ['name', '报告.txt']])] };

test('分享独立副本，原文件删除后仍可读，短读短写保留字节', async () => {
  const f = fixture(); assert.equal(await f.share(fileArgs), 'success');
  const uri = f.panels[0].data.records[0].uri, copy = uri.substring('file://'.length);
  f.files.delete('/files/export.txt'); assert.equal(f.files.get(copy).toString(), 'hello');
  assert.equal(f.handles.size, 0); assert.equal(f.panels[0].handlers.size, 0);
});
test('面板展示不代表完成；取消、完成和 engine 销毁分别结算', async () => {
  const f = fixture({ manual: true }); let settled = false;
  const pending = f.share({ text: 'hello' }).then(value => { settled = true; return value; });
  await new Promise(setImmediate); assert.equal(settled, false);
  await assert.rejects(f.share({ text: 'again' }), { code: 'share_busy' });
  f.panels[0].handlers.get('dismiss')(); assert.equal(await pending, 'dismissed');
  const next = f.share({ text: 'again' }); await new Promise(setImmediate);
  f.plugin.onDetachedFromEngine({}); assert.equal(await next, 'unavailable'); assert.equal(f.panels[1].handlers.size, 0);
});
test('错误、超限、沙箱外路径、符号链接和错误 codec 类型均拒绝且清理副本', async () => {
  for (const options of [{ failShow: true }, { failRead: true }, { symbolic: true }, { declaredSize: 65 * 1024 * 1024 }]) {
    const f = fixture(options); await assert.rejects(f.share(fileArgs), { code: 'share_error' });
    assert.equal(f.handles.size, 0); assert.equal([...f.files.keys()].some(p => p.startsWith('/cache/')), false);
  }
  for (const path of ['/outside/file', '/files/../secret', '/files/a//b']) {
    await assert.rejects(fixture().share({ files: [new Map([['path', path], ['name', 'file']])] }), { code: 'share_error' });
  }
  await assert.rejects(fixture().share({ files: [{ path: '/files/export.txt', name: 'file' }] }), { code: 'share_error' });
});
test('只清理命名规则匹配的过期分享批次，保留未知目录和新副本', async () => {
  const f = fixture(); f.dirs.add('/cache/chatai_share'); f.dirs.add('/cache/chatai_share/1_0'); f.dirs.add('/cache/chatai_share/keep');
  f.files.set('/cache/chatai_share/1_0/old.txt', Buffer.from('old'));
  f.files.set('/cache/chatai_share/keep/notes.txt', Buffer.from('keep'));
  await f.share(fileArgs); assert.equal(f.files.has('/cache/chatai_share/1_0/old.txt'), false);
  assert.equal(f.files.has('/cache/chatai_share/keep/notes.txt'), true);
});
test('分享缓存达到上限时拒绝新副本，不删除尚未过期的分享', async () => {
  const retained = '/cache/chatai_share/keep/large.bin';
  const f = fixture({ sizes: { [retained]: 512 * 1024 * 1024 } });
  f.dirs.add('/cache/chatai_share'); f.dirs.add('/cache/chatai_share/keep');
  f.files.set(retained, Buffer.from('retained'));
  await assert.rejects(f.share(fileArgs), { code: 'share_error' });
  assert.equal(f.files.has(retained), true); assert.equal(f.handles.size, 0);
});
