import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

const MAX_FILE_BYTES = 64 * 1024 * 1024;
const MAX_BATCH_BYTES = 128 * 1024 * 1024;
const MAX_CACHE_BYTES = 512 * 1024 * 1024;
const RETAIN_MILLIS = 24 * 60 * 60 * 1000;

/** 分享独立副本保留 24 小时供接收应用读取；只在下一次分享时清理过期副本。 */
export default class SharePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private applicationContext: common.Context | null = null;
  private sequence = 0;
  private busy = false;
  private cancelPending: (() => void) | null = null;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepSharePlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.hzb.flutter_ai/share');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.cancelPending?.();
    this.cancelPending = null;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'share') { result.notImplemented(); return; }
    if (this.busy) { result.error('share_busy', '分享面板正在使用中', null); return; }
    this.busy = true;
    this.execute(call, result);
  }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const status = await this.share(call);
      this.busy = false;
      result.success(status);
    } catch (error) {
      this.busy = false;
      result.error('share_error', `分享失败 (${(error as BusinessError).code ?? 'io'})`, null);
    }
  }
  private root(): string { return `${this.context.cacheDir}/chatai_share`; }
  private safeName(value: string): string {
    const name = value.replace(/[\\/\x00-\x1f\x7f]/g, '_').slice(0, 160);
    return name.length === 0 || name === '.' || name === '..' ? 'export' : name;
  }
  private async validatePath(path: string): Promise<void> {
    if (typeof path !== 'string' || path.includes('\0') || path.includes('\\')) throw new Error('Invalid path');
    const roots = [this.context.filesDir, this.context.cacheDir, this.context.tempDir];
    if (this.applicationContext !== null) {
      roots.push(this.applicationContext.filesDir, this.applicationContext.cacheDir, this.applicationContext.tempDir);
    }
    const root = roots.find((value: string) => path.startsWith(`${value}/`));
    if (root === undefined) throw new Error('File outside sandbox');
    const segments = path.substring(root.length + 1).split('/');
    if (segments.some((part: string) => part === '' || part === '.' || part === '..')) throw new Error('Invalid path');
    let current = root;
    for (const segment of segments) {
      current += `/${segment}`;
      if ((await fs.lstat(current)).isSymbolicLink()) throw new Error('Symbolic link not allowed');
    }
  }
  private async cleanupExpired(): Promise<void> {
    const root = this.root();
    if (!fs.accessSync(root)) { fs.mkdirSync(root); return; }
    for (const name of fs.listFileSync(root)) {
      // 仅删除我们命名的过期批次，绝不跟随导入内容的路径。
      if (!/^\d+_\d+$/.test(name)) continue;
      if (Date.now() - Number(name.split('_')[0]) > RETAIN_MILLIS) {
        await fs.rmdir(`${root}/${name}`);
      }
    }
  }
  private async cacheBytes(directory: string): Promise<number> {
    let total = 0;
    for (const name of fs.listFileSync(directory)) {
      const path = `${directory}/${name}`;
      const stat = await fs.lstat(path);
      if (stat.isSymbolicLink()) throw new Error('Invalid share cache');
      total += stat.isDirectory() ? await this.cacheBytes(path) : stat.size;
      if (total > MAX_CACHE_BYTES) break;
    }
    return total;
  }
  private async share(call: MethodCall): Promise<string> {
    const text = call.argument('text') as string | null;
    const title = call.argument('title') as string | null;
    const entries = call.argument('files') as Map<string, string>[] | null;
    if ((text !== null && (typeof text !== 'string' || text.length > 100000)) ||
      (title !== null && (typeof title !== 'string' || title.length > 1000)) ||
      (entries !== null && (!Array.isArray(entries) || entries.length > 10))) throw new Error('Invalid share data');
    const records: systemShare.SharedRecord[] = [];
    if (text !== null && text.trim().length > 0) records.push({
      utd: utd.UniformDataType.PLAIN_TEXT, content: text, title: title ?? '',
    });
    let batch = '';
    try {
      if (entries !== null && entries.length > 0) {
        await this.cleanupExpired();
        const retainedBytes = await this.cacheBytes(this.root());
        batch = `${this.root()}/${Date.now()}_${this.sequence++}`;
        fs.mkdirSync(batch);
        let total = 0;
        for (let index = 0; index < entries.length; index++) {
          const entry = entries[index];
          if (!(entry instanceof Map)) throw new Error('Invalid share file');
          const path = entry.get('path');
          const requestedName = entry.get('name');
          if (typeof path !== 'string' || typeof requestedName !== 'string') throw new Error('Invalid share file');
          await this.validatePath(path);
          const source = await fs.open(path, fs.OpenMode.READ_ONLY);
          try {
            const stat = await fs.stat(source.fd);
            if (!stat.isFile() || stat.size < 0 || stat.size > MAX_FILE_BYTES || total + stat.size > MAX_BATCH_BYTES) throw new Error('Share too large');
            const name = this.safeName(requestedName);
            const directory = `${batch}/${index}`;
            fs.mkdirSync(directory);
            const output = `${directory}/${name}`;
            const target = await fs.open(output, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
            let copied = 0;
            try {
              const buffer = new ArrayBuffer(64 * 1024);
              while (true) {
                const count = await fs.read(source.fd, buffer);
                if (count === 0) break;
                copied += count;
                if (copied > MAX_FILE_BYTES || total + copied > MAX_BATCH_BYTES ||
                  retainedBytes + total + copied > MAX_CACHE_BYTES) throw new Error('Share too large');
                let written = 0;
                while (written < count) {
                  const bytes = await fs.write(target.fd, buffer.slice(written, count));
                  if (bytes <= 0) throw new Error('Short share write');
                  written += bytes;
                }
              }
            } finally { await fs.close(target); }
            total += copied;
            const extension = name.includes('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
            records.push({ utd: extension.length > 0
              ? utd.getUniformDataTypeByFilenameExtension(extension) : utd.UniformDataType.FILE,
              uri: fileUri.getUriFromPath(output), title: name });
          } finally { await fs.close(source); }
        }
      }
      if (records.length === 0 || this.channel === null) throw new Error('Empty share or detached');
      const data = new systemShare.SharedData(records[0]);
      for (let index = 1; index < records.length; index++) data.addRecord(records[index]);
      return await this.show(new systemShare.ShareController(data));
    } catch (error) {
      if (batch.length > 0 && fs.accessSync(batch)) await fs.rmdir(batch);
      throw new Error('无法准备或展示分享内容');
    }
  }
  private show(controller: systemShare.ShareController): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      let settled = false;
      let shared = false;
      const onCompleted = (): void => { shared = true; };
      const finish = (status: string): void => {
        if (settled) return;
        settled = true;
        controller.off('dismiss', onDismiss);
        controller.off('shareCompleted', onCompleted);
        this.cancelPending = null;
        resolve(status);
      };
      const onDismiss = (): void => finish(shared ? 'success' : 'dismissed');
      this.cancelPending = () => finish('unavailable');
      controller.on('shareCompleted', onCompleted);
      controller.on('dismiss', onDismiss);
      // show() 成功仅表示面板已展示；必须等 dismiss，才能判断用户是否选择了目标。
      controller.show(this.context, { selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL }).catch((error: BusinessError) => {
        if (settled) return;
        settled = true;
        controller.off('dismiss', onDismiss); controller.off('shareCompleted', onCompleted);
        this.cancelPending = null;
        reject(new Error(`Share panel failed (${error.code})`));
      });
    });
  }
}
