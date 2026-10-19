const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(options = {}) {
  const released = [], handles = new Set(), renders = [];
  let decodeOptions, calls = 0;
  const pixels = (label = 'pixels') => ({ async release() { released.push(label); } });
  const decoder = { async getImageInfo() { return { size: options.dimensions || { width: 6000, height: 3000 } }; },
    async createPixelMap(value) { decodeOptions = value; return pixels(value.desiredPixelFormat ? 'normalized' : 'pixels'); }, async release() { released.push('decoder'); } };
  const native = load('../ocr/OcrPlugin', {
    '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 1 },
      async lstat(path) { return { isSymbolicLink: () => options.symlink && path.endsWith('link') }; },
      async open() { const h = { fd: 1 }; handles.add(h); return h; },
      async stat() { return { size: options.size || 100, isFile: () => true }; }, async close(h) { handles.delete(h); },
    } },
    '@kit.ImageKit': { image: { PixelMapFormat: { RGBA_8888: 3 }, createImageSource() { return decoder; },
      createImagePacker() { return { async packing() { if (options.failPacking) throw new Error('packing'); return new ArrayBuffer(options.packedBytes ?? 8); }, async release() { released.push('packer'); } }; },
    } },
    '@kit.CoreVisionKit': { textRecognition: {
      async init() { return options.init === undefined ? true : options.init; },
      async release() { if (options.release) await options.release; released.push('service'); },
      async recognizeText() { calls++; if (options.failAt === calls) throw new Error('recognition failed'); return { value: options.text === undefined ? '  中文内容  ' : await options.text }; },
    } },
    '@kit.PDFKit': { pdfService: { ParseResult: { PARSE_SUCCESS: 0 }, PdfMatrix: class {}, PdfDocument: class {
      loadDocument() { return options.parseFailure ? 1 : 0; } getPageCount() { return options.pages || 2; }
      getPage(index) { return { getWidth: () => 2000, getHeight: () => 4000,
        getAreaPixelMap(matrix, width, height) { renders.push({ index, matrix, width, height }); return pixels(); },
        release() { released.push('page'); } }; } releaseDocument() { released.push('document'); }
    } } },
  }, { filesDir: '/files', cacheDir: '/cache', tempDir: '/temp' }, { applicationContext: options.applicationContext });
  const recognize = (args = {}) => native.call('recognize', { id: 'request', kind: 'image', path: '/cache/photo.png', maxPages: 1, ...args });
  return { ...native, recognize, released, handles, renders, get decodeOptions() { return decodeOptions; }, get calls() { return calls; } };
}
test('识别 path_provider 的应用目录，同时保持 Ability 目录及链接和越界约束', async () => {
  const options = { applicationContext: { filesDir: '/application/files', cacheDir: '/application/cache', tempDir: '/application/temp' }, symlink: true };
  const f = fixture(options);
  for (const path of ['/application/files/a.png', '/application/cache/a.png', '/application/temp/a.png', '/cache/a.png']) {
    assert.equal(await f.recognize({ path }), '中文内容');
  }
  for (const path of ['/application/cache-other/a.png', '/application/cache/../a.png', '/application/cache/link/a.png']) {
    await assert.rejects(f.recognize({ path }), { code: 'ocr_error' });
  }
  assert.equal(f.handles.size, 0);
});
test('图片按上限等比解码，释放像素、解码器、句柄和识别服务后返回', async () => {
  const f = fixture(); assert.equal(await f.recognize(), '中文内容');
  assert.deepEqual({ ...f.decodeOptions.desiredSize }, { width: 4096, height: 2048 });
  assert.deepEqual(f.released, ['pixels', 'decoder', 'service']); assert.equal(f.handles.size, 0);
  const blank = fixture({ text: '' }); assert.equal(await blank.recognize(), '');
});
test('逐页识别 PDF 并限制页数及渲染尺寸，标注截断且逐页释放', async () => {
  const f = fixture({ pages: 21 }); const result = await f.recognize({ kind: 'pdf', path: '/files/test.pdf', maxPages: 20 });
  assert.equal(f.renders.length, 20); assert.match(result, /共 21 页.*前 20 页/);
  assert.equal(f.renders[0].width, 1536); assert.equal(f.renders[0].height, 3072);
  assert.equal(f.released.filter(x => x === 'page').length, 20);
  assert.equal(f.released.filter(x => x === 'pixels').length, 20);
  assert.equal(f.released.filter(x => x === 'normalized').length, 20);
  assert.equal(f.decodeOptions.desiredPixelFormat, 3);
  assert.deepEqual(f.released.slice(-2), ['document', 'service']); assert.equal(f.handles.size, 0);
});
test('PDF 像素规范化失败或编码超限时释放所有资源，不返回部分正文', async () => {
  for (const options of [{ failPacking: true }, { packedBytes: 0 }, { packedBytes: 33554433 }]) {
    const f = fixture(options);
    await assert.rejects(f.recognize({ kind: 'pdf', maxPages: 1 }), { code: 'ocr_error' });
    assert.equal(f.calls, 0); assert.equal(f.handles.size, 0);
    for (const label of ['packer', 'pixels', 'page', 'document', 'service']) assert.ok(f.released.includes(label));
  }
});
test('解析失败、某页失败不返回部分正文且关闭资源', async () => {
  for (const options of [{ parseFailure: true }, { failAt: 2 }]) {
    const f = fixture(options); await assert.rejects(f.recognize({ kind: 'pdf', maxPages: 2 }), { code: 'ocr_error' });
    assert.equal(f.handles.size, 0); assert.ok(f.released.includes('document')); assert.equal(f.released.at(-1), 'service');
    assert.equal(f.released.filter(x => x === 'page').length, options.failAt ? 2 : 0);
  }
});
test('沙箱边界、符号链接、文件大小、像素数和文本上限均在原生侧检查', async () => {
  for (const path of ['/outside/a.png', '/cache/../a.png', '/cache//a.png', '/cache/link/a.png']) {
    const f = fixture({ symlink: true }); await assert.rejects(f.recognize({ path }), { code: 'ocr_error' }); assert.equal(f.handles.size, 0);
  }
  for (const options of [{ size: 21 * 1024 * 1024 }, { dimensions: { width: 10000, height: 10000 } }, { text: 'a'.repeat(1000001) }]) {
    const f = fixture(options); await assert.rejects(f.recognize(), { code: 'ocr_error' }); assert.equal(f.handles.size, 0); assert.ok(f.released.includes('service'));
  }
  await assert.rejects(fixture().recognize({ maxPages: 21 }), { code: 'ocr_error' });
});
test('取消按请求 ID 隔离，拒绝并发，后台取消不回传迟到正文', async () => {
  let resume; const f = fixture({ text: new Promise(r => { resume = r; }) });
  const pending = f.recognize(); await tick(); await f.call('cancel', { id: 'old' });
  await assert.rejects(f.recognize({ id: 'second' }), { code: 'ocr_busy' });
  await f.call('cancel', { id: 'request' }); resume('迟到正文');
  await assert.rejects(pending, { code: 'ocr_error' }); assert.equal(f.handles.size, 0);
  const g = fixture(); g.plugin.suspend(); // 新请求重置取消标志
  assert.equal(await g.recognize(), '中文内容');
});
test('释放服务期间切后台同样拒绝结果，再次调用可以成功', async () => {
  let resume; const f = fixture({ release: new Promise(r => { resume = r; }) });
  const pending = f.recognize(); await tick(); f.plugin.suspend(); resume();
  await assert.rejects(pending, { code: 'ocr_error' }); assert.equal(f.handles.size, 0);
  assert.equal(await f.recognize(), '中文内容');
});
