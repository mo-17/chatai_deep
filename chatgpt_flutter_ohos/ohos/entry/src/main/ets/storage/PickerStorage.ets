import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export const FILE_CACHE_LIMIT = 512 * 1024 * 1024;
const DAY = 24 * 60 * 60 * 1000;
export interface StorageEntry { path: string; name: string; bytes: number; created: number; kind: string; }
export interface StorageInventory { token: string; entries: StorageEntry[]; fileBytes: number; imageBytes: number; }
export interface StorageCleanup { removed: number; bytes: number; retained: number; }
interface ScanBudget { count: number; }
interface RecoveryFile { path: string; }
interface RecoveryRecord { scope: string; id: string; created: number; phase: string; images: string[]; files: RecoveryFile[]; }
export class PickerCacheFullError extends Error {}

/** 文件选择与图片选择共用运行期租约。只删除有完整引用扫描证明的专属副本。 */
export default class PickerStorage {
  private static sequence = 0;
  private static epoch = 0;
  private static active = new Set<string>();
  private static leases = new Map<string, Set<string>>();
  private static cleaning = false;
  private snapshot: StorageInventory | null = null;
  private snapshotEpoch = 0;
  private snapshotTime = 0;
  private context: common.UIAbilityContext;
  private stamps = new Map<string, string>();
  constructor(context: common.UIAbilityContext) { this.context = context; }
  static owner(): string { return `picker_${PickerStorage.sequence++}`; }
  static begin(owner: string): void {
    if (PickerStorage.cleaning) throw new Error('Storage busy');
    PickerStorage.active.add(owner); PickerStorage.epoch++;
  }
  static end(owner: string): void { PickerStorage.active.delete(owner); }
  static hold(owner: string, path: string): void {
    let paths = PickerStorage.leases.get(owner);
    if (paths === undefined) { paths = new Set<string>(); PickerStorage.leases.set(owner, paths); }
    paths.add(path); PickerStorage.epoch++;
  }
  static release(owner: string, path: string): void { PickerStorage.leases.get(owner)?.delete(path); PickerStorage.epoch++; }
  static detach(owner: string): void { PickerStorage.active.delete(owner); PickerStorage.leases.delete(owner); PickerStorage.epoch++; }
  static get unavailable(): boolean { return PickerStorage.cleaning; }
  private directory(path: string): boolean {
    if (!fs.accessSync(path)) return false;
    const stat = fs.lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Invalid storage root');
    return true;
  }
  private tree(path: string, depth: number, budget: ScanBudget): string[] {
    if (depth > 14 || ++budget.count > 20000) throw new Error('Storage scan budget');
    const stat = fs.lstatSync(path);
    if (stat.isSymbolicLink()) throw new Error('Storage link');
    if (stat.isFile()) return [`${stat.size}`, `${stat.mtime}`];
    if (!stat.isDirectory()) throw new Error('Storage special entry');
    let bytes = 0; const stamps: string[] = [];
    const names = fs.listFileSync(path).sort();
    if (names.length > 20000) throw new Error('Storage scan budget');
    for (const name of names) {
      if (name === '.' || name === '..' || /[\\/\x00-\x1f]/.test(name)) throw new Error('Storage entry');
      const child = this.tree(`${path}/${name}`, depth + 1, budget);
      bytes += Number(child[0]); stamps.push(`${name}:${child[1]}`);
    }
    return [`${bytes}`, stamps.join('|')];
  }
  fileBytes(): number {
    const root = `${this.context.cacheDir}/chatai_file_picker`;
    return this.directory(root) ? Number(this.tree(root, 0, { count: 0 })[0]) : 0;
  }
  inventory(images: boolean): StorageInventory {
    if (PickerStorage.active.size > 0 || PickerStorage.cleaning) throw new Error('Storage busy');
    const entries: StorageEntry[] = [];
    this.stamps.clear();
    let fileBytes = 0, imageBytes = 0;
    const files = `${this.context.cacheDir}/chatai_file_picker`;
    const budget: ScanBudget = { count: 0 };
    if (this.directory(files)) {
      const names = fs.listFileSync(files);
      if (names.length > 2000) throw new Error('Too many storage batches');
      for (const name of names) {
        const path = `${files}/${name}`, data = this.tree(path, 0, budget);
        fileBytes += Number(data[0]);
        const matched = /^(?:tree_)?([0-9]+)_[0-9]+$/.exec(name);
        if (matched !== null && fs.lstatSync(path).isDirectory()) {
          entries.push({ path, name, bytes: Number(data[0]), created: Number(matched[1]), kind: 'file' }); this.stamps.set(path, data[1]);
        }
      }
    }
    if (images) {
      const roots = [`${this.context.filesDir}/chatai_picked_images`, `${this.context.cacheDir}/chatai_image_picker`];
      for (const root of roots) {
        if (!this.directory(root)) continue;
        const names = fs.listFileSync(root);
        if (names.length > 5000) throw new Error('Too many stored images');
        for (const name of names) {
          const path = `${root}/${name}`, data = this.tree(path, 0, budget);
          imageBytes += Number(data[0]);
          const matched = /^image_([0-9]+)_[0-9]+\.(png|jpg)$/.exec(name);
          if (matched !== null && fs.lstatSync(path).isFile()) {
            entries.push({ path, name, bytes: Number(data[0]), created: Number(matched[1]), kind: 'image' }); this.stamps.set(path, data[1]);
          }
        }
      }
    }
    if (entries.length > 5000) throw new Error('Too many storage candidates');
    const result: StorageInventory = { token: `${Date.now()}_${PickerStorage.sequence++}`, entries, fileBytes, imageBytes };
    this.snapshot = result; this.snapshotEpoch = PickerStorage.epoch; this.snapshotTime = Date.now();
    return result;
  }
  private recoveryPaths(): Set<string> {
    const paths = new Set<string>();
    const root = `${this.context.filesDir}/chatai_picker_recovery`;
    if (!this.directory(root)) return paths;
    const names = fs.listFileSync(root); let bytes = 0;
    if (names.length > 1024) throw new Error('Too many recovery records');
    for (const name of names) {
      if (!/^[a-f0-9]{64}\.json$/.test(name)) throw new Error('Unknown recovery record');
      const path = `${root}/${name}`, stat = fs.lstatSync(path);
      bytes += stat.size;
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024 || bytes > 16 * 1024 * 1024) throw new Error('Invalid recovery record');
      const record = JSON.parse(fs.readTextSync(path)) as RecoveryRecord;
      if (record.scope !== name.substring(0, 64) || typeof record.id !== 'string' || !Number.isFinite(record.created) ||
        !['pending', 'ready'].includes(record.phase) || !Array.isArray(record.images) || !Array.isArray(record.files) ||
        record.images.length > 1000 || record.files.length > 10 ||
        record.images.some((value: string) => typeof value !== 'string') ||
        record.files.some((file: RecoveryFile) => file === null || typeof file.path !== 'string')) throw new Error('Invalid recovery record');
      if (Date.now() - record.created > DAY) continue;
      for (const value of record.images) paths.add(value);
      for (const file of record.files) paths.add(file.path);
    }
    return paths;
  }
  async cleanup(token: string, referenced: string[], manual: boolean): Promise<StorageCleanup> {
    const snapshot = this.snapshot; this.snapshot = null;
    if (snapshot === null || token !== snapshot.token || PickerStorage.epoch !== this.snapshotEpoch ||
      Date.now() - this.snapshotTime > 60000 || PickerStorage.active.size > 0 || PickerStorage.cleaning) throw new Error('Storage changed');
    if (!Array.isArray(referenced) || referenced.length > 5000 || referenced.some((value: string) => typeof value !== 'string')) throw new Error('Invalid references');
    PickerStorage.cleaning = true;
    try {
      const protectedPaths = this.recoveryPaths();
      for (const paths of PickerStorage.leases.values()) for (const path of paths) protectedPaths.add(path);
      const protectedNames = new Set<string>(referenced);
      const eligible: StorageEntry[] = [];
      // 先完成所有验证再开始删除；任何损坏/未知状态都保留现有文件。
      for (const entry of snapshot.entries) {
        const held = Array.from(protectedPaths).some((path: string) => path === entry.path || path.startsWith(`${entry.path}/`));
        const age = entry.kind === 'image' ? 7 * DAY : (manual ? 0 : DAY);
        if (held || protectedNames.has(entry.name) || Date.now() - entry.created < age) continue;
        const data = this.tree(entry.path, 0, { count: 0 });
        if (Number(data[0]) !== entry.bytes || data[1] !== this.stamps.get(entry.path)) throw new Error('Storage changed');
        eligible.push(entry);
      }
      let removed = 0, bytes = 0;
      for (const entry of eligible) {
        if (PickerStorage.epoch !== this.snapshotEpoch) throw new Error('Storage changed');
        if (entry.kind === 'file') await fs.rmdir(entry.path);
        else fs.unlinkSync(entry.path);
        removed++; bytes += entry.bytes;
      }
      return { removed, bytes, retained: snapshot.entries.length - removed };
    } finally { PickerStorage.cleaning = false; }
  }
}
