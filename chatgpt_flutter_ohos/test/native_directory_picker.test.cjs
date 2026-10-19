const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture({ supported = true, selected = ['file://docs/documents/picked'], entries, names, failRead = false, beforeRead } = {}) {
  const nodes = new Map(Object.entries(entries || {
    '/documents/picked': { kind: 'dir' }, '/documents/picked/子目录': { kind: 'dir' },
    '/documents/picked/子目录/文档.txt': { kind: 'file', data: Buffer.from('中文😀') },
    '/documents/picked/a.txt': { kind: 'file', data: Buffer.from('ABC') },
  }));
  const handles = new Map(); let next = 0, selectCalls = 0, selectOptions;
  const stat = node => ({ size: node.size === undefined ? node.data?.length || 0 : node.size,
    isDirectory: () => node.kind === 'dir', isFile: () => node.kind === 'file', isSymbolicLink: () => node.kind === 'link' });
  const native = load('../files/FilePickerPlugin', { '@kit.CoreFileKit': {
    fileUri: { FileUri: class { constructor(uri) { this.path = decodeURIComponent(new URL(uri).pathname); } } },
    picker: { DocumentSelectOptions: class {}, DocumentSelectMode: { FOLDER: 1 }, DocumentViewPicker: class {
      async select(options) { selectCalls++; selectOptions = options; return selected; }
    } },
    fileIo: { OpenMode: { READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8, NOFOLLOW: 16 },
      accessSync: path => nodes.has(path), mkdirSync: path => { nodes.set(path, { kind: 'dir' }); },
      async lstat(path) { if (!nodes.has(path)) throw new Error('missing'); return stat(nodes.get(path)); },
      async stat(fd) { return stat(nodes.get(handles.get(fd).path)); },
      async listFile(path, options) {
        if (names) return names;
        return [...nodes.keys()].filter(p => p.startsWith(path + '/') && !p.substring(path.length + 1).includes('/')).map(p => p.substring(path.length + 1)).slice(0, options.listNum);
      },
      async open(path, mode) {
        if ((mode & 16) && nodes.get(path)?.kind === 'link') throw new Error('symlink');
        if (mode & 4) nodes.set(path, { kind: 'file', data: Buffer.alloc(0) });
        if (!nodes.has(path)) throw new Error('missing');
        const handle = { fd: ++next, path, position: 0 }; handles.set(handle.fd, handle); return handle;
      },
      async read(fd, buffer) {
        if (beforeRead) await beforeRead;
        if (failRead) throw new Error('provider read failed');
        const handle = handles.get(fd), data = nodes.get(handle.path).data || Buffer.alloc(0);
        const count = Math.min(2, data.length - handle.position);
        new Uint8Array(buffer).set(data.subarray(handle.position, handle.position + count)); handle.position += count; return count;
      },
      async write(fd, data) { const node = nodes.get(handles.get(fd).path), part = Buffer.from(data).subarray(0, 1); node.data = Buffer.concat([node.data, part]); return part.length; },
      async close(h) { handles.delete(h.fd); },
      async rmdir(path) { for (const key of [...nodes.keys()]) if (key === path || key.startsWith(path + '/')) nodes.delete(key); },
    },
  } }, { cacheDir: '/cache' }, { canIUse: () => supported });
  return { ...native, nodes, handles, get selectCalls() { return selectCalls; }, get selectOptions() { return selectOptions; } };
}
test('目录选择检查系统能力，手机无能力时明确失败；取消不复制', async () => {
  const phone = fixture({ supported: false }); assert.equal(await phone.call('supportsDirectories'), false);
  await assert.rejects(phone.call('getDirectoryPath'), { code: 'directory_unsupported' }); assert.equal(phone.selectCalls, 0);
  const trailing = fixture({ selected: ['file://docs/documents/picked/'] });
  assert.ok(await trailing.call('getDirectoryPath'));
  await assert.rejects(fixture({ selected: ['file://docs/'] }).call('getDirectoryPath'), { code: 'file_picker_error' });
  const cancelled = fixture({ selected: [] }); assert.equal(await cancelled.call('getDirectoryPath'), null); assert.equal(cancelled.handles.size, 0);
});
test('保留中文与子目录，短读短写后字节一致；只释放本次副本', async () => {
  const f = fixture(), path = await f.call('getDirectoryPath');
  assert.equal(f.selectOptions.selectMode, 1); assert.equal(f.selectOptions.maxSelectNumber, 1);
  assert.equal(f.nodes.get(path + '/子目录/文档.txt').data.toString(), '中文😀');
  assert.equal(f.nodes.get(path + '/a.txt').data.toString(), 'ABC'); assert.equal(f.handles.size, 0);
  assert.equal(await f.call('releaseDirectory', { path }), true);
  assert.equal(f.nodes.has(path), false); assert.equal(f.nodes.has('/documents/picked/a.txt'), true);
  await assert.rejects(f.call('releaseDirectory', { path: '/documents/picked' }), { code: 'file_picker_error' });
});
test('路径穿越、大小写碰撞和符号链接整批拒绝，不返回部分目录', async () => {
  for (const options of [{ names: ['../secret'] }, { names: ['A.txt', 'a.txt'], entries: { '/documents/picked': { kind: 'dir' }, '/documents/picked/A.txt': { kind: 'file', data: Buffer.from('x') } } },
    { entries: { '/documents/picked': { kind: 'dir' }, '/documents/picked/link': { kind: 'link' } } }]) {
    const f = fixture(options); await assert.rejects(f.call('getDirectoryPath'), { code: 'file_picker_error' });
    assert.equal(f.handles.size, 0); assert.equal([...f.nodes.keys()].some(p => p.includes('/tree_')), false);
  }
});
test('文件数量、尺寸与层级预算检查，读取失败关闭句柄并清理', async () => {
  const many = { '/documents/picked': { kind: 'dir' } };
  for (let i = 0; i < 257; i++) many['/documents/picked/' + i] = { kind: 'file', data: Buffer.from('x') };
  const deep = { '/documents/picked': { kind: 'dir' } }; let path = '/documents/picked';
  for (let i = 0; i < 13; i++) { path += '/dir'; deep[path] = { kind: 'dir' }; }
  for (const options of [{ entries: many }, { entries: deep }, { failRead: true }, { entries: { '/documents/picked': { kind: 'dir' }, '/documents/picked/large': { kind: 'file', size: 64*1024*1024+1 } } }]) {
    const f = fixture(options); await assert.rejects(f.call('getDirectoryPath'), { code: 'file_picker_error' });
    assert.equal(f.handles.size, 0); assert.equal([...f.nodes.keys()].some(p => p.includes('/tree_')), false);
  }
});
test('复制中并发拒绝，engine 销毁后不回传迟到副本', async () => {
  let resume; const f = fixture({ beforeRead: new Promise(r => { resume = r; }) });
  const pending = f.call('getDirectoryPath'); await tick();
  await assert.rejects(f.call('getDirectoryPath'), { code: 'picker_busy' });
  f.plugin.onDetachedFromEngine({}); resume(); await assert.rejects(pending, { code: 'file_picker_error' });
  assert.equal(f.handles.size, 0); assert.equal([...f.nodes.keys()].some(p => p.includes('/tree_')), false);
});
