// 执行真实 ArkTS 方法体，系统 API 使用可控文件提供方替身；真机交互仍需单独验收。
const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');

function fixture({ selected = ['content://picked'], saveUris = ['content://saved'], data = Buffer.from('hello'), size = data.length, name = '../note.txt', failRead = false } = {}) {
  const files = new Map([['content://picked', Buffer.from(data)], ['content://saved', Buffer.from('old longer content')]]);
  const directories = new Set();
  const handles = new Map();
  const closed = [];
  let next = 0, flushed = 0;
  const io = {
    OpenMode: { READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8 },
    accessSync: p => directories.has(p) || files.has(p),
    lstatSync(p) { return { size: files.get(p)?.length || 0, mtime: 1, isFile:()=>files.has(p), isDirectory:()=>directories.has(p), isSymbolicLink:()=>false }; },
    listFileSync(p) { return [...new Set([...directories,...files.keys()].filter(k=>k.startsWith(p+'/')).map(k=>k.substring(p.length+1).split('/')[0]))]; },
    mkdirSync: p => directories.add(p),
    async rmdir(p) {
      for (const key of files.keys()) if (key.startsWith(p + '/')) files.delete(key);
      for (const key of directories) if (key === p || key.startsWith(p + '/')) directories.delete(key);
    },
    async open(p, mode) {
      if (mode & 8 || !files.has(p)) files.set(p, Buffer.alloc(0));
      const h = { fd: ++next, path: p, name, position: 0 }; handles.set(h.fd, h); return h;
    },
    async stat() { return { size, isFile: () => true }; },
    async read(fd, buffer) {
      if (failRead) throw new Error('provider failed');
      const h = handles.get(fd), input = files.get(h.path);
      const count = Math.min(2, input.length - h.position);
      new Uint8Array(buffer).set(input.subarray(h.position, h.position + count)); h.position += count; return count;
    },
    async write(fd, bytes) {
      const h = handles.get(fd), count = Math.min(2, bytes.byteLength);
      files.set(h.path, Buffer.concat([files.get(h.path), Buffer.from(bytes).subarray(0, count)])); return count;
    },
    async close(h) { closed.push(h.fd); handles.delete(h.fd); },
    async fsync() { flushed++; },
  };
  class DocumentViewPicker {
    async select(options) { fixture.lastOptions = options; return await selected; }
    async save(options) { fixture.lastSaveOptions = options; return saveUris; }
  }
  const native = load('../files/FilePickerPlugin', { '@kit.CoreFileKit': { fileIo: io, picker: { DocumentViewPicker, DocumentSelectOptions: class {}, DocumentSaveOptions: class {} } } }, { cacheDir: '/cache', filesDir: '/files' });
  return { ...native, files, directories, handles, closed, get flushed() { return flushed; } };
}

test('导入短读/短写仍得到完整缓存，文件名不能逃逸缓存目录', async () => {
  const f = fixture(); const picked = await f.call('pickFiles', { allowedExtensions: ['txt'], allowMultiple: true });
  assert.equal(picked.length, 1); assert.equal(picked[0].size, 5);
  assert.match(picked[0].path, /^\/cache\/chatai_file_picker\/\d+_0\/0_.*note\.txt$/);
  assert.equal(picked[0].name.includes('/'), false);
  assert.equal(f.files.get(picked[0].path).toString(), 'hello'); assert.equal(f.handles.size, 0);
  assert.equal(fixture.lastOptions.maxSelectNumber, 10);
});
test('导出处理短写并截断旧内容，完成后关闭和刷盘', async () => {
  const f = fixture(); const bytes = new Uint8Array([1, 2, 3]);
  assert.equal(await f.call('saveFile', { fileName: 'backup.zip', bytes }), 'content://saved');
  assert.deepEqual(f.files.get('content://saved'), Buffer.from(bytes)); assert.equal(f.handles.size, 0); assert.equal(f.flushed, 1);
});
test('取消不打开文件，系统失败不会报告成功', async () => {
  const f = fixture({ selected: [], saveUris: [] });
  assert.equal(await f.call('pickFiles'), null);
  assert.equal(await f.call('saveFile', { fileName: 'a', bytes: new Uint8Array() }), null);
  assert.equal(f.closed.length, 0);
  const broken = fixture({ failRead: true });
  await assert.rejects(broken.call('pickFiles'), { code: 'file_picker_error' });
  assert.equal(broken.handles.size, 0);
  assert.equal([...broken.files.keys()].some(k => k.startsWith('/cache/')), false);
});
test('超限与扩展名不符时关闭句柄并移除整批缓存', async () => {
  for (const options of [{ size: 256 * 1024 * 1024 + 1 }, { name: 'wrong.exe' }]) {
    const f = fixture(options);
    await assert.rejects(f.call('pickFiles', { allowedExtensions: ['txt'] }), { code: 'file_picker_error' });
    assert.equal(f.handles.size, 0); assert.equal([...f.files.keys()].some(k => k.startsWith('/cache/')), false);
  }
});
test('并发请求被拒绝，engine 销毁后不复制返回的 URI', async () => {
  let resume; const selected = new Promise(resolve => { resume = resolve; });
  const f = fixture({ selected }); const pending = f.call('pickFiles');
  await assert.rejects(f.call('pickFiles'), { code: 'picker_busy' });
  f.plugin.onDetachedFromEngine({}); f.plugin.onAttachedToEngine({ getBinaryMessenger() {} }); resume(['content://picked']);
  await assert.rejects(pending, { code: 'file_picker_error' }); assert.equal(f.closed.length, 0);
});
