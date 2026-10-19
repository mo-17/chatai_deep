const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
function fixture({ selected = ['photo://1'], capture = { resultCode: 0, resultUri: 'photo://camera' },
  beforeDecode = async () => {}, size = 100, failPack = false, failDecode = false, failDecodeAt = 0, mime = 'image/jpeg', orientation = 'Top-left', dimensions = { width: 4000, height: 2000 }, files = new Map(), sizes = {}, links = new Set(), failRetain = false } = {}) {
  const handles = new Map(), released = [];
  let next = 0, decodeOptions, packOptions, cameraProfile, selectOptions, decodes = 0;
  const transforms = [];
  const pixel = { async release() { released.push('pixels'); }, async flip(x, y) { transforms.push(['flip', x, y]); }, async rotate(angle) { transforms.push(['rotate', angle]); } };
  const decoder = { async getImageInfo() { const current = ++decodes; await beforeDecode(current); if (failDecode || current === failDecodeAt) throw new Error('decode'); return { size: dimensions, mimeType: mime }; },
    async getImageProperty() { return orientation; }, async createPixelMap(options) { decodeOptions = options; return pixel; }, async release() { released.push('decoder'); } };
  const dirs = new Set();
  const directory = p => dirs.has(p) || [...files.keys()].some(k => k.startsWith(p + '/'));
  const io = {
    OpenMode: { READ_ONLY: 1, CREATE: 2, READ_WRITE: 4, TRUNC: 8 },
    async open(path, mode) { const h = { fd: ++next, path }; handles.set(h.fd, h); if (mode & 2) files.set(path, Buffer.alloc(0)); return h; },
    async stat() { return { size, isFile: () => true }; },
    accessSync: p => files.has(p) || directory(p), mkdirSync(p) {dirs.add(p);},
    listFileSync(p) {return [...new Set([...files.keys()].filter(k=>k.startsWith(p+'/')).map(k=>k.substring(p.length+1).split('/')[0]))];},
    copyFileSync(a,b) {if(failRetain) throw new Error('retain');files.set(b,Buffer.from(files.get(a)));},
    async write(fd, bytes) { const h = handles.get(fd), b = Buffer.from(bytes).subarray(0, 2); files.set(h.path, Buffer.concat([files.get(h.path), b])); return b.length; },
    async unlink(p) { files.delete(p); }, async close(h) { handles.delete(h.fd); },
    openSync(path,mode) { const h={fd:++next,path};handles.set(h.fd,h);if(mode&2)files.set(path,Buffer.alloc(0));return h; },
    closeSync(h) { handles.delete(h.fd); },
    writeSync(fd,data) { const path=handles.get(fd).path,b=Buffer.from(data);files.set(path,Buffer.concat([files.get(path),b]));return b.length; },
    fsyncSync() {},renameSync(a,b) { files.set(b,files.get(a));files.delete(a); },
    unlinkSync(p) { files.delete(p); },
    lstatSync(p) { if(!files.has(p) && !directory(p))throw new Error('missing');return {size:sizes[p] ?? files.get(p)?.length ?? 0,isFile:()=>files.has(p),isDirectory:()=>directory(p),isSymbolicLink:()=>links.has(p)}; },
    readTextSync(p) { return files.get(p).toString(); },
  };
  const native = load('ImagePickerPlugin', {
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkTS': {util:{TextEncoder:class {encodeInto(text){return new Uint8Array(Buffer.from(text));}}}},
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoViewMIMETypes: { IMAGE_TYPE: 'image' }, PhotoSelectOptions: class {},
      PhotoViewPicker: class { async select(options) { selectOptions = options; return { photoUris: await selected }; } } } },
    '@kit.CameraKit': { camera: { CameraPosition: { CAMERA_POSITION_FRONT: 1, CAMERA_POSITION_BACK: 0 } },
      cameraPicker: { PickerMediaType: { PHOTO: 'photo' }, async pick(ctx, types, profile) { cameraProfile = profile; return capture; } } },
    '@kit.ImageKit': { image: { PropertyKey: { ORIENTATION: 'Orientation' }, createImageSource() { return decoder; }, createImagePacker() { return {
      async packing(pixels, options) { packOptions = options; if (failPack) throw new Error('packing'); return new Uint8Array([1, 2, 3, 4, 5]).buffer; },
      async release() { released.push('packer'); },
    }; } } },
  }, { cacheDir: '/cache', filesDir:'/files' });
  return { ...native, files, handles, released, transforms, get decodeOptions() { return decodeOptions; },
    get packOptions() { return packOptions; }, get cameraProfile() { return cameraProfile; }, get selectOptions() { return selectOptions; } };
}
test('相册图像等比缩小且处理短写，完成后关闭所有资源', async () => {
  const f = fixture(); const picked = await f.call('pickImage', { source: 'gallery', maxWidth: 512, maxHeight: 512, quality: 80 });
  assert.equal(picked.mimeType, 'image/jpeg'); assert.deepEqual({ ...f.decodeOptions.desiredSize }, { width: 512, height: 256 });
  assert.deepEqual([...f.files.get(picked.path)], [1, 2, 3, 4, 5]);
  assert.equal(f.handles.size, 0); assert.deepEqual(f.released, ['packer', 'pixels', 'decoder']);
});
test('EXIF 八种方向按 SDK 顺序归一，旋转图片遵守视觉宽高限制', async () => {
  const expected = {
    'Top-left': [], 'Top-right': [['flip', true, false]], 'Bottom-right': [['rotate', 180]],
    'Bottom-left': [['flip', false, true]], 'Left-top': [['flip', true, false], ['rotate', 270]],
    'Right-top': [['rotate', 90]], 'Right-bottom': [['flip', true, false], ['rotate', 90]], 'Left-bottom': [['rotate', 270]],
  };
  for (const [orientation, transforms] of Object.entries(expected)) {
    const f = fixture({ orientation }); await f.call('pickImage', { source: 'gallery', maxWidth: 512, maxHeight: 256 });
    assert.deepEqual(f.transforms, transforms);
    if (['Left-top', 'Right-top', 'Right-bottom', 'Left-bottom'].includes(orientation)) {
      assert.equal(f.decodeOptions.desiredSize.width, 256);
    }
  }
});
test('PNG 保持透明格式，拍照前后置选项正确', async () => {
  const f = fixture({ mime: 'image/png' });
  assert.equal((await f.call('pickImage', { source: 'camera', frontCamera: true })).mimeType, 'image/png');
  assert.equal(f.cameraProfile.cameraPosition, 1); assert.equal(f.packOptions.format, 'image/png');
});
test('相册取消不读文件，超限或解码失败均关闭句柄', async () => {
  const cancelled = fixture({ selected: [] }); assert.equal(await cancelled.call('pickImage', { source: 'gallery' }), null);
  assert.equal(cancelled.released.length, 0);
  for (const options of [{ size: 21 * 1024 * 1024 }, { failPack: true }, { failDecode: true }]) {
    const f = fixture(options); await assert.rejects(f.call('pickImage', { source: 'gallery' }), { code: 'image_picker_error' });
    assert.equal(f.handles.size, 0); assert.equal(f.files.size, 0);
  }
});
test('并发、无效选项和 engine 销毁拒绝迟到结果', async () => {
  let resume; const selected = new Promise(resolve => { resume = resolve; });
  const f = fixture({ selected }), pending = f.call('pickImage', { source: 'gallery' });
  await assert.rejects(f.call('pickImage'), { code: 'picker_busy' });
  f.plugin.onDetachedFromEngine({}); resume(['photo://1']);
  await assert.rejects(pending, { code: 'image_picker_error' }); assert.equal(f.handles.size, 0);
  await assert.rejects(fixture().call('pickImage', { source: 'gallery', maxWidth: 100000 }), { code: 'image_picker_error' });
});

test('多图选择遵守单批限制并对重复 URI 去重，按顺序生成独立副本', async () => {
  const f = fixture({selected:['photo://1','photo://2','photo://1']});
  const picked = await f.call('pickImages',{source:'gallery',limit:4});
  assert.equal(f.selectOptions.maxSelectNumber,4); assert.equal(picked.length,2);
  assert.notEqual(picked[0].path,picked[1].path); assert.equal(f.files.size,2);
  assert.equal(f.handles.size,0); assert.equal(f.released.length,6);
  assert.equal((await fixture({selected:[]}).call('pickImages',{source:'gallery',limit:4})).length,0);
});
test('批内任一图片失败或超过整批字节上限时清理已创建的副本', async () => {
  for (const options of [
    {selected:['photo://1','photo://2'],failDecodeAt:2},
    {selected:Array.from({length:7},(_,i)=>'photo://'+i),size:20*1024*1024},
  ]) {
    const f=fixture(options);await assert.rejects(f.call('pickImages',{source:'gallery',limit:10}),{code:'image_picker_error'});
    assert.equal(f.files.size,0);assert.equal(f.handles.size,0);
  }
});
test('多图拒绝无效数量、超出选择结果及相机批量请求', async()=>{
  for(const args of [{limit:1},{limit:11},{limit:2.5},{source:'camera'}]) {
    await assert.rejects(fixture().call('pickImages',{source:'gallery',...args}),{code:'image_picker_error'});
  }
  await assert.rejects(fixture({selected:['1','2','3']}).call('pickImages',{source:'gallery',limit:2}),{code:'image_picker_error'});
});
test('engine 重建后旧相册回调不能冒充新选择返回', async()=>{
  let resume;const f=fixture({selected:new Promise(resolve=>{resume=resolve;})});
  const pending=f.call('pickImages',{source:'gallery',limit:4});
  f.plugin.onDetachedFromEngine({});f.plugin.onAttachedToEngine({getBinaryMessenger(){}});
  resume(['photo://1']);await assert.rejects(pending,{code:'image_picker_error'});
  assert.equal(f.files.size,0);assert.equal(f.handles.size,0);
});

test('进程重启恢复已完成副本及原草稿，隔离账号/会话，确认后只消费一次',async()=>{
  const f=fixture(),scope='a'.repeat(64);
  const id=await f.call('setRecoveryContext',{scope,text:'原始提问',images:[]});
  const picked=await f.call('pickImages',{source:'gallery',limit:4});
  const restarted=fixture({files:f.files});
  assert.equal(await restarted.call('retrieveLostData'),null);
  assert.equal(await restarted.call('retrieveLostData',{scope:'b'.repeat(64)}),null);
  const recovered=await restarted.call('retrieveLostData',{scope});
  assert.equal(recovered.id,id);assert.equal(recovered.text,'原始提问');
  assert.equal(recovered.files[0].path,picked[0].path);assert.equal(recovered.phase,'ready');
  await restarted.call('ackRecovery',{scope,id:'old'});
  assert.ok(await restarted.call('retrieveLostData',{scope}));
  await restarted.call('ackRecovery',{scope,id});
  assert.equal(await restarted.call('retrieveLostData',{scope}),null);
  assert.ok(f.files.has(picked[0].path),'ack 不删除已回填草稿的图片');
});
test('系统尚未返回的选择恢复为中断状态，丢失缓存不返回失效图片',async()=>{
  const f=fixture({selected:new Promise(()=>{})}),scope='c'.repeat(64);
  await f.call('setRecoveryContext',{scope,text:'继续输入',images:[]});
  void f.call('pickImage',{source:'gallery'});
  const restarted=fixture({files:f.files});
  const record=await restarted.call('retrieveLostData',{scope});
  assert.equal(record.phase,'pending');assert.equal(record.files.length,0);assert.equal(record.text,'继续输入');
  const g=fixture();await g.call('setRecoveryContext',{scope,text:'',images:[]});
  const picked=await g.call('pickImage',{source:'gallery'});g.files.delete(picked.path);
  assert.equal((await fixture({files:g.files}).call('retrieveLostData',{scope})).files.length,0);
});

test('复制下一张时重启只恢复已落盘图片，不能返回未确认的批次结果', async () => {
  let resumeSecond, reachedSecond;
  const second = new Promise(resolve => { reachedSecond = resolve; });
  const gate = new Promise(resolve => { resumeSecond = resolve; });
  const f = fixture({ selected: ['photo://first', 'photo://second'],
    beforeDecode: async index => { if (index === 2) { reachedSecond(); await gate; } } });
  const scope = 'd'.repeat(64);
  const id = await f.call('setRecoveryContext', { scope, text: '复制中的原输入', images: [] });
  const picking = f.call('pickImages', { source: 'gallery', limit: 4 });
  await second;
  try {
    assert.equal(await f.call('retrieveLostData', { scope }), null, '旧进程忙碌时不能并发消费');
    f.plugin.onDetachedFromEngine({});
    const restarted = fixture({ files: f.files });
    const record = await restarted.call('retrieveLostData', { scope });
    assert.equal(record.id, id); assert.equal(record.phase, 'pending');
    assert.equal(record.text, '复制中的原输入'); assert.equal(record.files.length, 1);
    assert.deepEqual([...f.files.get(record.files[0].path)], [1, 2, 3, 4, 5]);
    assert.equal(await restarted.call('retrieveLostData', { scope: 'e'.repeat(64) }), null);
  } finally { resumeSecond(); }
  await assert.rejects(picking, { code: 'image_picker_error' });
  const complete = await fixture({ files: f.files }).call('retrieveLostData', { scope });
  assert.equal(complete.phase, 'pending'); assert.equal(complete.files.length, 1);
  assert.ok(f.files.has(complete.files[0].path), '旧 engine 清理不能删除新进程已恢复的持久副本');
});

test('确认旧恢复弹窗不能消费同作用域后来产生的恢复记录', async () => {
  const f = fixture(), scope = 'f'.repeat(64);
  const previous = await f.call('setRecoveryContext', { scope, text: '旧草稿', images: [] });
  await f.call('pickImage', { source: 'gallery' });
  const current = await f.call('setRecoveryContext', { scope, text: '新草稿', images: [] });
  await f.call('pickImage', { source: 'gallery' });
  assert.notEqual(current, previous);
  const restarted = fixture({ files: f.files });
  await restarted.call('ackRecovery', { scope, id: previous });
  const record = await restarted.call('retrieveLostData', { scope });
  assert.equal(record.id, current); assert.equal(record.text, '新草稿');
  await restarted.call('ackRecovery', { scope, id: current });
  assert.equal(await restarted.call('retrieveLostData', { scope }), null);
});

test('新图片返回持久目录，失败清理本批副本且旧缓存不被回收', async () => {
  const legacy = '/cache/chatai_image_picker/image_1_0.jpg';
  const files = new Map([[legacy, Buffer.from('legacy')]]);
  const f = fixture({ files });
  const picked = await f.call('pickImage', { source: 'gallery' });
  assert.ok(picked.path.startsWith('/files/chatai_picked_images/'));
  assert.equal([...files.keys()].some(p => p.includes('/pending_image_')), false);
  assert.equal(files.get(legacy).toString(), 'legacy');
  const bad = fixture({ failRetain: true });
  await assert.rejects(bad.call('pickImage', { source: 'gallery' }), { code: 'image_picker_error' });
  assert.equal(bad.files.size, 0);
  assert.equal(bad.handles.size, 0);
});
test('只删除过期 staging，保护各作用域恢复记录和历史文件', async () => {
  const old = Date.now() - 25 * 3600 * 1000;
  const stale = `/cache/chatai_image_picker/pending_image_${old}_0.png`;
  const pinned = `/cache/chatai_image_picker/pending_image_${old}_1.png`;
  const fresh = `/cache/chatai_image_picker/pending_image_${Date.now()}_2.jpg`;
  const legacy = '/cache/chatai_image_picker/image_1_0.jpg';
  const scope = 'a'.repeat(64);
  const journal = `/files/chatai_picker_recovery/${scope}.json`;
  const files = new Map([[stale, Buffer.from('old')], [pinned, Buffer.from('pin')],
    [fresh, Buffer.from('new')], [legacy, Buffer.from('keep')], [journal, Buffer.from(JSON.stringify({
      scope, id: 'pending', created: Date.now(), phase: 'pending', text: '草稿', images: [],
      files: [{ path: pinned, name: '../../unexpected.png', mimeType: 'image/png' }],
    }))]]);
  const f = fixture({ files });
  assert.equal(files.has(stale), false, '启动时回收过期 staging');
  for (const path of [pinned, fresh, legacy]) assert.ok(files.has(path));
  const restored = await f.call('retrieveLostData', { scope });
  assert.ok(restored.files[0].path.startsWith('/files/chatai_picked_images/'));
  assert.equal(restored.files[0].name, pinned.split('/').pop().replace(/^pending_/, ''));
  assert.equal(files.has('/files/unexpected.png'), false, '恢复记录不能通过显示名称改写目标路径');
  assert.equal(files.has(pinned), false);
  await f.call('ackRecovery', { scope, id: restored.id });
  await f.call('cleanupCache');
  assert.ok(files.has(restored.files[0].path), '已恢复图片永久保存，清缓存不删除');
});
test('恢复原输入中的 staging 图片也先落盘再消费记录', async () => {
  const scope = 'e'.repeat(64), path = `/cache/chatai_image_picker/pending_image_${Date.now()}_3.png`;
  const files = new Map([[path, Buffer.from('draft')], [`/files/chatai_picker_recovery/${scope}.json`,
    Buffer.from(JSON.stringify({ scope, id: 'old-draft', created: Date.now(), phase: 'pending',
      text: '', images: [path], files: [] }))]]);
  const f = fixture({ files });
  const record = await f.call('retrieveLostData', { scope });
  assert.ok(record.images[0].startsWith('/files/chatai_picked_images/'));
  await f.call('ackRecovery', { scope, id: record.id });
  assert.ok(files.has(record.images[0]));
});
test('损坏恢复记录使清理保守跳过，超出 staging 总预算时明确拒绝新选择', async () => {
  const path = `/cache/chatai_image_picker/pending_image_${Date.now() - 25 * 3600 * 1000}_0.png`;
  const broken = `/files/chatai_picker_recovery/${'b'.repeat(64)}.json`;
  const files = new Map([[path, Buffer.from('keep')], [broken, Buffer.from('{broken')]]);
  const f = fixture({ files });
  await f.call('cleanupCache'); assert.ok(files.has(path));
  files.set(broken, Buffer.from(JSON.stringify({ scope: 'b'.repeat(64), images: [path] })));
  await f.call('cleanupCache'); assert.ok(files.has(path), 'JSON 可解码但结构损坏也必须保留草稿副本');
  assert.ok(files.has(broken), '损坏记录不能被静默丢弃后回收其图片');
  const full = fixture({ files, sizes: { [path]: 512 * 1024 * 1024 } });
  await assert.rejects(full.call('pickImage', { source: 'gallery' }), { code: 'image_cache_full' });
  assert.ok(files.has(path)); assert.equal(full.selectOptions, undefined);
});
test('清理不追踪缓存链接，损坏条目不会导致删除其它目录', async () => {
  const path = `/cache/chatai_image_picker/pending_image_${Date.now() - 25 * 3600 * 1000}_0.png`;
  const files = new Map([[path, Buffer.from('target')]]);
  const f = fixture({ files, links: new Set([path]) });
  await assert.rejects(f.call('cleanupCache'), { code: 'image_cache_error' });
  assert.ok(files.has(path));
});
