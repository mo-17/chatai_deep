import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

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

/** 只操作用户在系统选择器中授权的 URI，导入后返回可供 Dart 读取的缓存副本。 */
export default class FilePickerPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private busy = false;
  private sequence = 0;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) { this.context = context; }

  getUniqueClassName(): string { return 'ChataiDeepFilePickerPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (!['pickFiles', 'saveFile', 'clearTemporaryFiles'].includes(call.method)) {
      result.notImplemented();
      return;
    }
    if (this.busy) {
      result.error('picker_busy', '文件选择器正在使用中', null);
      return;
    }
    this.busy = true;
    this.execute(call, result);
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let output: PickedFile[] | string | boolean | null = null;
      if (call.method === 'pickFiles') output = await this.pick(call);
      else if (call.method === 'saveFile') output = await this.save(call);
      else {
        const directory = this.cacheRoot();
        if (fs.accessSync(directory)) await fs.rmdir(directory);
        output = true;
      }
      // 回调到 Dart 前释放门闩，允许取消后立即发起下一次操作。
      this.busy = false;
      result.success(output);
    } catch (error) {
      this.busy = false;
      const failure = error as BusinessError;
      // 取消通过空数组返回；权限/IO/构建错误不能伪装成取消。
      result.error('file_picker_error', `文件操作失败 (${failure.code ?? 'io'})`, null);
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

  private async pick(call: MethodCall): Promise<PickedFile[] | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = call.argument('allowMultiple') === true ? MAX_FILES : 1;
    const suffixes = this.suffixes(call);
    if (suffixes.length > 0) options.fileSuffixFilters = [suffixes.join(',')];
    const uris = await new picker.DocumentViewPicker(this.context).select(options);
    if (uris.length === 0) return null;
    if (this.channel === null || uris.length > options.maxSelectNumber) throw new Error('Picker detached');
    const root = this.cacheRoot();
    if (!fs.accessSync(root)) fs.mkdirSync(root);
    const batch = `${root}/${Date.now()}_${this.sequence++}`;
    fs.mkdirSync(batch);
    const files: PickedFile[] = [];
    let total = 0;
    try {
      for (let index = 0; index < uris.length; index++) {
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
              const count = await fs.read(source.fd, buffer);
              if (count === 0) break;
              copied += count;
              if (copied > MAX_FILE_BYTES || total + copied > MAX_BATCH_BYTES) throw new Error('File too large');
              await this.writeAll(target.fd, buffer.slice(0, count));
            }
          } finally { await fs.close(target); }
          total += copied;
          files.push({ path, name, size: copied });
        } finally { await fs.close(source); }
      }
      if (this.channel === null) throw new Error('Picker detached');
      return files;
    } catch (error) {
      await fs.rmdir(batch);
      throw new Error('无法复制选中的文件');
    }
  }

  private async writeAll(fd: number, bytes: ArrayBuffer): Promise<void> {
    let written = 0;
    while (written < bytes.byteLength) {
      const count = await fs.write(fd, bytes.slice(written));
      if (count <= 0) throw new Error('Short write');
      written += count;
    }
  }

  private async save(call: MethodCall): Promise<string | null> {
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
    if (this.channel === null || uris.length !== 1) throw new Error('Picker detached');
    const target = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      for (let offset = 0; offset < bytes.byteLength; offset += BUFFER_BYTES) {
        const chunk = bytes.slice(offset, Math.min(offset + BUFFER_BYTES, bytes.byteLength));
        await this.writeAll(target.fd, chunk.buffer as ArrayBuffer);
      }
      await fs.fsync(target.fd);
    } finally { await fs.close(target); }
    return uris[0];
  }
}
