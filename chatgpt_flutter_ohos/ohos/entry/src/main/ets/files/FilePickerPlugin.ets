import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import PickerStorage, { FILE_CACHE_LIMIT, PickerCacheFullError, StorageInventory, StorageCleanup } from '../storage/PickerStorage';

const CHANNEL = 'com.hzb.flutter_ai/file_picker';
const MAX_FILE_BYTES = 256 * 1024 * 1024;
const MAX_BATCH_BYTES = 512 * 1024 * 1024;
const MAX_FILES = 10;
const BUFFER_BYTES = 64 * 1024;

interface PickedFile {
  path: string;
  name: string;
  size: number;
}

interface DirectoryBudget { entries: number; files: number; bytes: number; names: Set<string>; deadline: number; generation: number; }

/** 只操作用户在系统选择器中授权的 URI，导入后返回可供 Dart 读取的缓存副本。 */
export default class FilePickerPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private busy = false;
  private sequence = 0;
  private generation = 0;
  private context: common.UIAbilityContext;
  private owner = PickerStorage.owner();
  private storage: PickerStorage;
  private cacheBytes = 0;

  constructor(context: common.UIAbilityContext) { this.context = context; this.storage = new PickerStorage(context); }

  getUniqueClassName(): string { return 'ChataiDeepFilePickerPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.generation++;
    PickerStorage.detach(this.owner);
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'supportsDirectories') { result.success(canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')); return; }
    if (call.method === 'getDirectoryPath' && !canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      result.error('directory_unsupported', '当前设备不支持选择文件夹，请使用 ZIP 或多选文件', null); return;
    }
    if (!['pickFiles', 'saveFile', 'getDirectoryPath', 'releaseDirectory', 'clearTemporaryFiles', 'storageInventory', 'cleanupStorage'].includes(call.method)) {
      result.notImplemented();
      return;
    }
    if (this.busy || PickerStorage.unavailable) {
      result.error('picker_busy', '文件选择器正在使用中', null);
      return;
    }
    this.busy = true;
    if (['pickFiles', 'saveFile', 'getDirectoryPath'].includes(call.method)) PickerStorage.begin(this.owner);
    this.execute(call, result, this.generation);
  }

  private async execute(call: MethodCall, result: MethodResult, generation: number): Promise<void> {
    try {
      let output: PickedFile[] | string | boolean | StorageInventory | StorageCleanup | null = null;
      if (call.method === 'pickFiles') output = await this.pick(call, generation);
      else if (call.method === 'saveFile') output = await this.save(call, generation);
      else if (call.method === 'getDirectoryPath') output = await this.pickDirectory(generation);
      else if (call.method === 'releaseDirectory') output = await this.releaseDirectory(call);
      else if (call.method === 'storageInventory') output = this.storage.inventory(call.argument('images') === true);
      else if (call.method === 'cleanupStorage') output = await this.storage.cleanup(call.argument('token') as string,
        call.argument('referenced') as string[], call.argument('manual') === true);
      else {
        // 没有完整引用扫描证明的通用清理调用不能删除在用附件。
        output = this.storage.fileBytes() === 0;
      }
      // 回调到 Dart 前释放门闩，允许取消后立即发起下一次操作。
      this.busy = false;
      PickerStorage.end(this.owner);
      result.success(output);
    } catch (error) {
      this.busy = false;
      PickerStorage.end(this.owner);
      const failure = error as BusinessError;
      // 取消通过空数组返回；权限/IO/构建错误不能伪装成取消。
      if (error instanceof PickerCacheFullError) result.error('file_cache_full', '文件缓存已满，使用中的附件已保留，请到存储管理清理后重试', null);
      else result.error('file_picker_error', `文件操作失败 (${failure.code ?? 'io'})`, null);
    }
  }

  private suffixes(call: MethodCall): string[] {
    const values = call.argument('allowedExtensions') as string[] | null;
    if (values === null || values === undefined) return [];
    if (!Array.isArray(values) || values.length > 100 ||
      values.some((value: string) => typeof value !== 'string' || !/^[a-zA-Z0-9]{1,16}$/.test(value))) {
      throw new Error('Invalid extensions');
    }
    return values.map((value: string) => `.${value.toLowerCase()}`);
  }

  private safeName(value: string): string {
    const name = value.replace(/[\\/\x00-\x1f\x7f]/g, '_').slice(0, 180);
    return name === '' || name === '.' || name === '..' ? 'file' : name;
  }

  private cacheRoot(): string { return `${this.context.cacheDir}/chatai_file_picker`; }

  private current(generation: number): void {
    if (this.channel === null || generation !== this.generation || PickerStorage.unavailable) throw new Error('Picker detached');
  }

  private prepareCache(): void {
    this.cacheBytes = this.storage.fileBytes();
    if (this.cacheBytes >= FILE_CACHE_LIMIT) throw new PickerCacheFullError('Cache full');
  }

  private async pick(call: MethodCall, generation: number): Promise<PickedFile[] | null> {
    this.prepareCache();
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = call.argument('allowMultiple') === true ? MAX_FILES : 1;
    const suffixes = this.suffixes(call);
    if (suffixes.length > 0) options.fileSuffixFilters = [suffixes.join(',')];
    const uris = await new picker.DocumentViewPicker(this.context).select(options);
    if (uris.length === 0) return null;
    this.current(generation);
    if (uris.length > options.maxSelectNumber) throw new Error('Invalid selection count');
    const root = this.cacheRoot();
    if (!fs.accessSync(root)) fs.mkdirSync(root);
    const batch = `${root}/${Date.now()}_${this.sequence++}`;
    fs.mkdirSync(batch);
    const files: PickedFile[] = [];
    let total = 0;
    try {
      for (let index = 0; index < uris.length; index++) {
        this.current(generation);
        const source = await fs.open(uris[index], fs.OpenMode.READ_ONLY);
        try {
          const stat = await fs.stat(source.fd);
          if (!stat.isFile() || stat.size > MAX_FILE_BYTES || total + stat.size > MAX_BATCH_BYTES) {
            throw new Error('File too large');
          }
          const name = this.safeName(source.name);
          if (suffixes.length > 0 && !suffixes.some((suffix: string) => name.toLowerCase().endsWith(suffix))) {
            throw new Error('File extension mismatch');
          }
          const path = `${batch}/${index}_${name}`;
          const target = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          let copied = 0;
          try {
            const buffer = new ArrayBuffer(BUFFER_BYTES);
            while (true) {
              this.current(generation);
              const count = await fs.read(source.fd, buffer);
              if (count === 0) break;
              copied += count;
              if (this.cacheBytes + total + copied > FILE_CACHE_LIMIT) throw new PickerCacheFullError('Cache full');
              if (copied > MAX_FILE_BYTES || total + copied > MAX_BATCH_BYTES) throw new Error('File too large');
              await this.writeAll(target.fd, buffer.slice(0, count));
            }
          } finally { await fs.close(target); }
          total += copied;
          files.push({ path, name, size: copied });
        } finally { await fs.close(source); }
      }
      this.current(generation);
      PickerStorage.hold(this.owner, batch);
      return files;
    } catch (error) {
      await fs.rmdir(batch);
      if (error instanceof PickerCacheFullError) throw error;
      throw new Error('无法复制选中的文件');
    }
  }

  private activeDirectory(budget: DirectoryBudget): void {
    if (this.channel === null || budget.generation !== this.generation || Date.now() > budget.deadline) throw new Error('Directory import cancelled or timed out');
  }

  private async pickDirectory(generation: number): Promise<string | null> {
    this.prepareCache();
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1; options.selectMode = picker.DocumentSelectMode.FOLDER;
    const uris = await new picker.DocumentViewPicker(this.context).select(options);
    if (uris.length === 0) return null;
    this.current(generation);
    if (uris.length !== 1 || !uris[0].startsWith('file://')) throw new Error('Invalid directory selection');
    const source = new fileUri.FileUri(uris[0]).path.replace(/\/+$/, '');
    const root = this.cacheRoot();
    if (!source.startsWith('/') || source.split('/').some((part: string) => part === '..' || part === '.') ||
      source.includes('\\') || source.includes('\0') || source === root || root.startsWith(`${source}/`) || source.startsWith(`${root}/`)) throw new Error('Invalid directory path');
    const stat = await fs.lstat(source);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('Selected entry is not a directory');
    if (!fs.accessSync(root)) fs.mkdirSync(root);
    const batch = `${root}/tree_${Date.now()}_${this.sequence++}`;
    fs.mkdirSync(batch);
    const budget: DirectoryBudget = { entries: 0, files: 0, bytes: 0, names: new Set<string>(), deadline: Date.now() + 120000, generation };
    try {
      await this.copyDirectory(source, batch, '', 0, budget);
      this.activeDirectory(budget);
      PickerStorage.hold(this.owner, batch);
      return batch;
    } catch (error) { await fs.rmdir(batch); if (error instanceof PickerCacheFullError) throw error; throw new Error('文件夹复制失败、包含链接或超过导入上限'); }
  }

  private async copyDirectory(source: string, target: string, prefix: string, depth: number, budget: DirectoryBudget): Promise<void> {
    this.activeDirectory(budget);
    if (depth > 12) throw new Error('Directory too deep');
    const names = await fs.listFile(source, { recursion: false, listNum: 1025 });
    budget.entries += names.length;
    if (budget.entries > 1024) throw new Error('Too many directory entries');
    for (const name of names) {
      this.activeDirectory(budget);
      if (name === '' || name === '.' || name === '..' || name.length > 180 || /[\\/\x00-\x1f\x7f]/.test(name)) throw new Error('Invalid directory entry');
      const relative = prefix + name;
      if (budget.names.has(relative.toLowerCase())) throw new Error('Conflicting directory entries');
      budget.names.add(relative.toLowerCase());
      const path = `${source}/${name}`, destination = `${target}/${name}`;
      const stat = await fs.lstat(path);
      if (stat.isSymbolicLink()) throw new Error('Symbolic links are not imported');
      if (stat.isDirectory()) {
        fs.mkdirSync(destination);
        await this.copyDirectory(path, destination, `${relative}/`, depth + 1, budget);
        continue;
      }
      if (!stat.isFile() || ++budget.files > 256 || stat.size > 64 * 1024 * 1024 || budget.bytes + stat.size > 128 * 1024 * 1024) throw new Error('Directory file budget exceeded');
      const input = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const opened = await fs.stat(input.fd);
        if (!opened.isFile() || opened.size !== stat.size) throw new Error('Directory entry changed');
        const output = await fs.open(destination, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        let size = 0;
        try {
          const buffer = new ArrayBuffer(BUFFER_BYTES);
          while (true) {
            this.activeDirectory(budget);
            const count = await fs.read(input.fd, buffer);
            if (count === 0) break;
            size += count;
            if (this.cacheBytes + budget.bytes + size > FILE_CACHE_LIMIT) throw new PickerCacheFullError('Cache full');
            if (size > stat.size || budget.bytes + size > 128 * 1024 * 1024) throw new Error('Directory file grew');
            await this.writeAll(output.fd, buffer.slice(0, count));
          }
          if (size !== stat.size) throw new Error('Directory file was truncated');
          budget.bytes += size;
        } finally { await fs.close(output); }
      } finally { await fs.close(input); }
    }
  }

  private async releaseDirectory(call: MethodCall): Promise<boolean> {
    const path = call.argument('path') as string;
    const root = this.cacheRoot() + '/';
    if (typeof path !== 'string' || !path.startsWith(root) || !/^tree_[0-9]+_[0-9]+$/.test(path.substring(root.length))) throw new Error('Invalid directory cache path');
    if (!fs.accessSync(path)) return true;
    const stat = await fs.lstat(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('Invalid directory cache');
    await fs.rmdir(path); PickerStorage.release(this.owner, path); return true;
  }

  private async writeAll(fd: number, bytes: ArrayBuffer): Promise<void> {
    let written = 0;
    while (written < bytes.byteLength) {
      const count = await fs.write(fd, bytes.slice(written));
      if (count <= 0) throw new Error('Short write');
      written += count;
    }
  }

  private async save(call: MethodCall, generation: number): Promise<string | null> {
    const bytes = call.argument('bytes') as Uint8Array;
    if (!(bytes instanceof Uint8Array) || bytes.byteLength > MAX_FILE_BYTES) throw new Error('Invalid bytes');
    const fileName = call.argument('fileName') as string;
    if (typeof fileName !== 'string') throw new Error('Invalid filename');
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [this.safeName(fileName)];
    const suffixes = this.suffixes(call);
    if (suffixes.length > 0) options.fileSuffixChoices = [suffixes.join(',')];
    const uris = await new picker.DocumentViewPicker(this.context).save(options);
    if (uris.length === 0) return null;
    this.current(generation);
    if (uris.length !== 1) throw new Error('Invalid save selection');
    const target = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      for (let offset = 0; offset < bytes.byteLength; offset += BUFFER_BYTES) {
        this.current(generation);
        const chunk = bytes.slice(offset, Math.min(offset + BUFFER_BYTES, bytes.byteLength));
        await this.writeAll(target.fd, chunk.buffer as ArrayBuffer);
      }
      await fs.fsync(target.fd);
    } finally { await fs.close(target); }
    return uris[0];
  }
}
