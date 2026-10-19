import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

const MAX_BYTES = 20 * 1024 * 1024;
const CACHE_LIMIT = 512 * 1024 * 1024;
const CACHE_TTL = 24 * 60 * 60 * 1000;

class ImageCacheFullError extends Error {}

interface PickedImage { path: string; name: string; mimeType: string; }
interface PickerRecovery {
  scope: string; id: string; created: number; phase: string;
  text: string; images: string[]; files: PickedImage[];
}

export default class ImagePickerPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private busy = false;
  private sequence = 0;
  private generation = 0;
  private cacheBytes = 0;
  private recovery: PickerRecovery | null = null;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepImagePickerPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.hzb.flutter_ai/image_picker');
    this.channel.setMethodCallHandler(this);
    try { this.cleanupCache(); } catch (_) { /* 缓存异常不阻止应用启动。 */ }
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.generation++;
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (['setRecoveryContext', 'retrieveLostData', 'ackRecovery'].includes(call.method)) {
      try { this.recoveryCall(call, result); }
      catch (_) { result.error('recovery_error', '图片恢复记录不可用', null); }
      return;
    }
    if (call.method === 'cleanupCache') {
      if (this.busy) { result.error('picker_busy', '图片选择器正在使用中', null); return; }
      try { result.success(this.cleanupCache()); }
      catch (_) { result.error('image_cache_error', '无法清理图片缓存，已保留现有文件', null); }
      return;
    }
    if (call.method !== 'pickImage' && call.method !== 'pickImages') { result.notImplemented(); return; }
    if (this.busy) { result.error('picker_busy', '图片选择器正在使用中', null); return; }
    this.busy = true;
    this.execute(call, result);
  }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    const recovery = this.recovery; this.recovery = null;
    try {
      if (recovery !== null) this.saveRecovery(recovery);
      this.cleanupCache();
      if (this.cacheBytes >= CACHE_LIMIT) throw new ImageCacheFullError('Image cache full');
      const picked = await this.pick(call, this.generation, recovery);
      if (recovery !== null) { recovery.files = picked; recovery.phase = 'ready'; this.saveRecovery(recovery); }
      this.busy = false;
      result.success(call.method === 'pickImage' ? (picked[0] ?? null) : picked);
    } catch (error) {
      this.busy = false;
      if (error instanceof ImageCacheFullError) result.error('image_cache_full', '图片临时缓存已满，待恢复草稿已保留，请稍后重试', null);
      else result.error('image_picker_error', `选取图片失败 (${(error as BusinessError).code ?? 'io'})`, null);
    }
  }
  private scope(call: MethodCall): string {
    const scope = call.argument('scope') as string;
    if (typeof scope !== 'string' || !/^[a-f0-9]{64}$/.test(scope)) throw new Error('Invalid scope');
    return scope;
  }
  private recoveryPath(scope: string): string {
    const root = `${this.context.filesDir}/chatai_picker_recovery`;
    if (!fs.accessSync(root)) fs.mkdirSync(root);
    const stat = fs.lstatSync(root);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Invalid recovery root');
    return `${root}/${scope}.json`;
  }
  private saveRecovery(record: PickerRecovery): void {
    const path = this.recoveryPath(record.scope), temporary = `${path}.tmp`;
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(record));
    if (bytes.byteLength > 1024 * 1024) throw new Error('Draft too large');
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < bytes.byteLength) {
        const count = fs.writeSync(file.fd, bytes.buffer.slice(written));
        if (count <= 0) throw new Error('Short journal write');
        written += count;
      }
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    fs.renameSync(temporary, path);
  }
  private readRecovery(scope: string): PickerRecovery | null {
    const path = this.recoveryPath(scope);
    if (!fs.accessSync(path)) return null;
    const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024) throw new Error('Invalid journal');
    const record = JSON.parse(fs.readTextSync(path)) as PickerRecovery;
    if (record.scope !== scope || typeof record.id !== 'string' ||
      typeof record.text !== 'string' || record.text.length > 200000 ||
      !Array.isArray(record.files) || record.files.length > 10 ||
      !Array.isArray(record.images) || record.images.length > 1000 ||
      !['pending', 'ready'].includes(record.phase) || !Number.isFinite(record.created)) {
      throw new Error('Invalid journal');
    }
    if (Date.now() - record.created > CACHE_TTL) {
      fs.unlinkSync(path); return null;
    }
    const valid = (path: string): boolean => {
      if (typeof path !== 'string' || ![`${this.context.cacheDir}/chatai_image_picker/`, `${this.context.filesDir}/chatai_picked_images/`].some((root: string) => path.startsWith(root)) ||
        path.includes('\0') || path.split('/').includes('..')) return false;
      try { const stat = fs.lstatSync(path); return stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size <= MAX_BYTES; }
      catch (_) { return false; }
    };
    record.files = record.files.filter((file: PickedImage) => valid(file.path));
    record.images = record.images.filter(valid);
    return record;
  }
  private recoveryCall(call: MethodCall, result: MethodResult): void {
    // 无作用域调用不能读取另一个账号或会话的选择结果。
    if (call.method === 'retrieveLostData' && call.argument('scope') == null) { result.success(null); return; }
    const scope = this.scope(call);
    if (call.method === 'retrieveLostData') {
      const record = this.busy ? null : this.readRecovery(scope);
      if (record !== null) {
        for (let index = 0; index < record.files.length; index++) this.promote(record.files, index, record, []);
        const drafts: PickedImage[] = record.images.map((path: string): PickedImage => {
          const draft: PickedImage = {
            path, name: path.substring(path.lastIndexOf('/') + 1), mimeType: path.endsWith('.png') ? 'image/png' : 'image/jpeg',
          };
          return draft;
        });
        for (let index = 0; index < drafts.length; index++) this.promote(drafts, index, record, [], true);
      }
      result.success(record); return;
    }
    if (call.method === 'ackRecovery') {
      if (this.recovery?.scope === scope && this.recovery.id === call.argument('id')) this.recovery = null;
      const record = this.readRecovery(scope);
      if (record !== null && record.id === call.argument('id')) fs.unlinkSync(this.recoveryPath(scope));
      result.success(null); return;
    }
    if (this.busy) throw new Error('Picker busy');
    const text = call.argument('text') as string;
    const images = call.argument('images') as string[];
    if (typeof text !== 'string' || text.length > 200000 || !Array.isArray(images) || images.length > 1000 ||
      !images.every((path: string) => typeof path === 'string' && path.length < 4096)) throw new Error('Invalid draft');
    // 直到下一个 pick 调用才写入；取消弹窗不会产生虚假的恢复任务。
    this.recovery = { scope, id: `${Date.now()}_${this.sequence++}`, created: Date.now(), phase: 'pending', text, images, files: [] };
    result.success(this.recovery.id);
  }
  /// 只回收新版本自己管理的 staging 文件；历史缓存可能已被聊天或头像引用。
  private cleanupCache(): number {
    const protectedPaths = new Set<string>();
    const journals = `${this.context.filesDir}/chatai_picker_recovery`;
    let safe = true, journalBytes = 0;
    if (fs.accessSync(journals)) {
      const names = fs.listFileSync(journals);
      if (names.length > 1024) safe = false;
      else for (const name of names) {
        if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
        try {
          const stat = fs.lstatSync(`${journals}/${name}`);
          journalBytes += stat.size;
          if (!stat.isFile() || stat.isSymbolicLink() || journalBytes > 16 * 1024 * 1024) { safe = false; break; }
          const record = this.readRecovery(name.substring(0, 64));
          if (record !== null) {
            for (const path of record.images) protectedPaths.add(path);
            for (const file of record.files) protectedPaths.add(file.path);
          }
        } catch (_) { safe = false; }
      }
    }
    const root = `${this.context.cacheDir}/chatai_image_picker`;
    this.cacheBytes = 0;
    if (!fs.accessSync(root)) return 0;
    const rootStat = fs.lstatSync(root);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('Invalid cache root');
    const entries = fs.listFileSync(root);
    if (entries.length > 5000) throw new ImageCacheFullError('Image cache full');
    let removed = 0;
    for (const name of entries) {
      const path = `${root}/${name}`;
      const stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Invalid cache entry');
      const managed = /^pending_image_([0-9]+)_[0-9]+\.(png|jpg)$/.exec(name);
      if (safe && managed !== null && Date.now() - Number(managed[1]) > CACHE_TTL && !protectedPaths.has(path)) {
        fs.unlinkSync(path); removed++;
      } else if (managed !== null) { this.cacheBytes += stat.size; }
    }
    return removed;
  }

  /// 返回 Flutter 前将新副本保存为持久文件。清缓存不能使已发送消息/头像失效。
  private promote(images: PickedImage[], index: number, record: PickerRecovery | null, created: string[], draft: boolean = false): void {
    const original = images[index];
    const prefix = `${this.context.cacheDir}/chatai_image_picker/pending_image_`;
    if (!original.path.startsWith(prefix)) return;
    const root = `${this.context.filesDir}/chatai_picked_images`;
    if (!fs.accessSync(root)) fs.mkdirSync(root);
    const rootStat = fs.lstatSync(root);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('Invalid retained image root');
    const basename = original.path.substring(original.path.lastIndexOf('/') + 1);
    if (!/^pending_image_[0-9]+_[0-9]+\.(png|jpg)$/.test(basename)) throw new Error('Invalid image name');
    const name = basename.replace(/^pending_/, '');
    const target = `${root}/${name}`;
    if (fs.accessSync(target)) throw new Error('Image target already exists');
    const before = fs.lstatSync(original.path);
    if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_BYTES) throw new Error('Invalid image source');
    try {
      fs.copyFileSync(original.path, target);
      created.push(target);
      if (fs.lstatSync(target).size !== before.size) throw new Error('Incomplete image copy');
      images[index] = { path: target, name, mimeType: original.mimeType };
      // 先保存新路径，再删除旧 staging。进程终止时至少仍有一个可恢复副本。
      if (record !== null) {
        if (draft) record.images = images.map((file: PickedImage) => file.path);
        else record.files = images;
        this.saveRecovery(record);
      }
    } catch (_) {
      images[index] = original;
      if (fs.accessSync(target)) fs.unlinkSync(target);
      throw new Error('Unable to retain image');
    }
    try { fs.unlinkSync(original.path); this.cacheBytes -= before.size; } catch (_) { /* 留给下次过期清理。 */ }
  }

  private number(call: MethodCall, key: string, fallback: number, min: number, max: number): number {
    const value = call.argument(key) as number | null;
    if (value === null || value === undefined) return fallback;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
      throw new Error('Invalid image option');
    }
    return Math.floor(value);
  }
  private current(generation: number): void {
    if (generation !== this.generation || this.channel === null) throw new Error('Picker detached');
  }
  private async pick(call: MethodCall, generation: number, recovery: PickerRecovery | null): Promise<PickedImage[]> {
    const width = this.number(call, 'maxWidth', 2048, 1, 4096);
    const height = this.number(call, 'maxHeight', 2048, 1, 4096);
    const quality = this.number(call, 'quality', 85, 0, 100);
    const source = call.argument('source') as string;
    const multiple = call.method === 'pickImages';
    const limit = multiple ? this.number(call, 'limit', 10, 2, 10) : 1;
    if (multiple && call.argument('limit') != null && call.argument('limit') !== limit) throw new Error('Invalid selection limit');
    let uris: string[] = [];
    if (source === 'gallery') {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = limit;
      const selection = await new photoAccessHelper.PhotoViewPicker().select(options);
      if (selection.photoUris.length > limit) throw new Error('Invalid selection');
      uris = Array.from(new Set(selection.photoUris));
    } else if (source === 'camera' && !multiple) {
      const profile: cameraPicker.PickerProfile = {
        cameraPosition: call.argument('frontCamera') === true
          ? camera.CameraPosition.CAMERA_POSITION_FRONT : camera.CameraPosition.CAMERA_POSITION_BACK,
      };
      const capture = await cameraPicker.pick(this.context, [cameraPicker.PickerMediaType.PHOTO], profile);
      if (capture.resultCode !== 0) {
        if (capture.resultCode === -1) return [];
        throw new Error('Camera failed');
      }
      uris = [capture.resultUri];
    } else { throw new Error('Invalid source'); }
    this.current(generation);
    const created: string[] = [];
    const images: PickedImage[] = [];
    let sourceBytes = 0, outputBytes = 0;
    try {
      for (const uri of uris) {
        this.current(generation);
        if (typeof uri !== 'string' || uri.length === 0) throw new Error('Invalid image URI');
        const picked = await this.copyImage(uri, width, height, quality, generation, created,
          (input: number, output: number) => {
            sourceBytes += input; outputBytes += output;
            if (sourceBytes > 128 * 1024 * 1024 || outputBytes > 128 * 1024 * 1024) throw new Error('Image batch too large');
          });
        images.push(picked);
        // 每张沙箱副本写完即持久化；进程在转换下一张时终止也可恢复已完成部分。
        if (recovery !== null) { recovery.files = images; this.saveRecovery(recovery); }
      }
      this.current(generation);
      for (let index = 0; index < images.length; index++) this.promote(images, index, recovery, created);
      return images;
    } catch (error) {
      for (const path of created) {
        try { if (fs.accessSync(path)) await fs.unlink(path); } catch (_) { /* 继续清理本批其余副本。 */ }
      }
      if (error instanceof ImageCacheFullError) throw error;
      throw new Error('无法读取或转换选中的图片');
    }
  }
  private async copyImage(uri: string, width: number, height: number, quality: number,
    generation: number, created: string[], accountBytes: (input: number, output: number) => void): Promise<PickedImage> {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    let decoder: image.ImageSource | null = null;
    let pixels: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let output = '';
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_BYTES) throw new Error('Image too large');
      accountBytes(stat.size, 0);
      decoder = image.createImageSource(file.fd);
      const info = await decoder.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0 ||
        info.size.width * info.size.height > 64 * 1024 * 1024) throw new Error('Image dimensions too large');
      let orientation = 'Top-left';
      try { orientation = await decoder.getImageProperty(image.PropertyKey.ORIENTATION); }
      catch (_) { /* 无 EXIF 的图片沿用默认方向。 */ }
      const swap = ['Left-top', 'Right-top', 'Right-bottom', 'Left-bottom'].includes(orientation);
      const ratio = Math.min(1, (swap ? height : width) / info.size.width,
        (swap ? width : height) / info.size.height);
      pixels = await decoder.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.floor(info.size.width * ratio)),
        height: Math.max(1, Math.floor(info.size.height * ratio)),
      } });
      // 按 SDK PropertyKey.ORIENTATION 的定义先翻转再旋转，重新编码后不依赖 EXIF。
      if (['Top-right', 'Left-top', 'Right-bottom'].includes(orientation)) await pixels.flip(true, false);
      if (orientation === 'Bottom-left') await pixels.flip(false, true);
      if (orientation === 'Bottom-right') await pixels.rotate(180);
      if (orientation === 'Right-top' || orientation === 'Right-bottom') await pixels.rotate(90);
      if (orientation === 'Left-top' || orientation === 'Left-bottom') await pixels.rotate(270);
      const png = info.mimeType === 'image/png';
      const mime = png ? 'image/png' : 'image/jpeg';
      packer = image.createImagePacker();
      const bytes = await packer.packing(pixels, { format: mime, quality });
      this.current(generation);
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_BYTES) throw new Error('Image too large');
      accountBytes(0, bytes.byteLength);
      const root = `${this.context.cacheDir}/chatai_image_picker`;
      if (!fs.accessSync(root)) fs.mkdirSync(root);
      const name = `pending_image_${Date.now()}_${this.sequence++}.${png ? 'png' : 'jpg'}`;
      if (this.cacheBytes + bytes.byteLength > CACHE_LIMIT) throw new ImageCacheFullError('Image cache full');
      this.cacheBytes += bytes.byteLength;
      output = `${root}/${name}`;
      created.push(output);
      const target = await fs.open(output, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        let written = 0;
        while (written < bytes.byteLength) {
          const count = await fs.write(target.fd, bytes.slice(written));
          if (count <= 0) throw new Error('Short image write');
          written += count;
        }
      } finally { await fs.close(target); }
      this.current(generation);
      return { path: output, name, mimeType: mime };
    } catch (error) {
      if (output.length > 0 && fs.accessSync(output)) await fs.unlink(output);
      if (error instanceof ImageCacheFullError) throw error;
      throw new Error('无法读取或转换选中的图片');
    } finally {
      // 即使某个解码资源释放失败，也继续关闭文件描述符。
      try { if (packer !== null) await packer.release(); }
      finally {
        try { if (pixels !== null) await pixels.release(); }
        finally {
          try { if (decoder !== null) await decoder.release(); }
          finally { await fs.close(file); }
        }
      }
    }
  }
}
