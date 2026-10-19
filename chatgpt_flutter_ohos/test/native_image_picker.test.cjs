const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
function fixture({ selected = ['photo://1'], capture = { resultCode: 0, resultUri: 'photo://camera' },
  size = 100, failPack = false, failDecode = false, mime = 'image/jpeg', orientation = 'Top-left', dimensions = { width: 4000, height: 2000 } } = {}) {
  const files = new Map(), handles = new Map(), released = [];
  let next = 0, decodeOptions, packOptions, cameraProfile;
  const transforms = [];
  const pixel = { async release() { released.push('pixels'); }, async flip(x, y) { transforms.push(['flip', x, y]); }, async rotate(angle) { transforms.push(['rotate', angle]); } };
  const decoder = { async getImageInfo() { if (failDecode) throw new Error('decode'); return { size: dimensions, mimeType: mime }; },
    async getImageProperty() { return orientation; }, async createPixelMap(options) { decodeOptions = options; return pixel; }, async release() { released.push('decoder'); } };
  const io = {
    OpenMode: { READ_ONLY: 1, CREATE: 2, READ_WRITE: 4, TRUNC: 8 },
    async open(path, mode) { const h = { fd: ++next, path }; handles.set(h.fd, h); if (mode & 2) files.set(path, Buffer.alloc(0)); return h; },
    async stat() { return { size, isFile: () => true }; },
    accessSync: p => files.has(p), mkdirSync() {},
    async write(fd, bytes) { const h = handles.get(fd), b = Buffer.from(bytes).subarray(0, 2); files.set(h.path, Buffer.concat([files.get(h.path), b])); return b.length; },
    async unlink(p) { files.delete(p); }, async close(h) { handles.delete(h.fd); },
  };
  const native = load('ImagePickerPlugin', {
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoViewMIMETypes: { IMAGE_TYPE: 'image' }, PhotoSelectOptions: class {},
      PhotoViewPicker: class { async select() { return { photoUris: await selected }; } } } },
    '@kit.CameraKit': { camera: { CameraPosition: { CAMERA_POSITION_FRONT: 1, CAMERA_POSITION_BACK: 0 } },
      cameraPicker: { PickerMediaType: { PHOTO: 'photo' }, async pick(ctx, types, profile) { cameraProfile = profile; return capture; } } },
    '@kit.ImageKit': { image: { PropertyKey: { ORIENTATION: 'Orientation' }, createImageSource() { return decoder; }, createImagePacker() { return {
      async packing(pixels, options) { packOptions = options; if (failPack) throw new Error('packing'); return new Uint8Array([1, 2, 3, 4, 5]).buffer; },
      async release() { released.push('packer'); },
    }; } } },
  }, { cacheDir: '/cache' });
  return { ...native, files, handles, released, transforms, get decodeOptions() { return decodeOptions; },
    get packOptions() { return packOptions; }, get cameraProfile() { return cameraProfile; } };
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
