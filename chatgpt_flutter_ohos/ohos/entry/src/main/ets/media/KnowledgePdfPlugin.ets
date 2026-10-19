import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { pdfService } from '@kit.PDFKit';

/** 使用与 Android/iOS 相同的原件预览通道；单次仅渲染一页，不接收 provider URI。 */
export default class KnowledgePdfPlugin implements FlutterPlugin, MethodCallHandler {
  private context: common.UIAbilityContext;
  private applicationContext: common.Context | null = null;
  private channel: MethodChannel | null = null;
  private generation = 0;
  private busy = false;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepKnowledgePdfPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'aipu/knowledge-pdf');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.suspend(); this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  suspend(): void { this.generation++; }
  private current(generation: number): void {
    if (generation !== this.generation || this.channel === null) throw new Error('PDF preview cancelled');
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'render') { result.notImplemented(); return; }
    if (this.busy) { result.error('pdf_busy', '原件正在渲染，请稍后重试', null); return; }
    this.busy = true;
    this.render(call, this.generation).then((bytes: Uint8Array) => {
      this.busy = false; result.success(bytes);
    }).catch(() => {
      this.busy = false; result.error('pdf_render_error', '原件预览未完成，请查看引文快照', null);
    });
  }
  private async input(path: string): Promise<fs.File> {
    if (typeof path !== 'string' || path.includes('\0') || path.includes('\\')) throw new Error('Invalid PDF path');
    const roots = [this.context.filesDir, this.context.cacheDir, this.context.tempDir];
    if (this.applicationContext !== null) {
      roots.push(this.applicationContext.filesDir, this.applicationContext.cacheDir, this.applicationContext.tempDir);
    }
    const root = roots.find(
      (value: string) => path.startsWith(`${value}/`));
    if (root === undefined) throw new Error('PDF outside sandbox');
    let current = root;
    for (const segment of path.substring(root.length + 1).split('/')) {
      if (!segment || segment === '.' || segment === '..') throw new Error('Invalid PDF path');
      current += `/${segment}`;
      if ((await fs.lstat(current)).isSymbolicLink()) throw new Error('PDF symbolic link rejected');
    }
    const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > 64 * 1024 * 1024) throw new Error('Invalid PDF size');
      return file;
    } catch (_) { await fs.close(file); throw new Error('Invalid PDF file'); }
  }
  private async render(call: MethodCall, generation: number): Promise<Uint8Array> {
    const index = call.argument('page') as number;
    if (!Number.isInteger(index) || index < 0 || index >= 1000) throw new Error('Invalid page');
    const path = call.argument('path') as string;
    const file = await this.input(path);
    let document: pdfService.PdfDocument | null = null;
    let page: pdfService.PdfPage | null = null;
    let pixels: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      this.current(generation);
      document = new pdfService.PdfDocument();
      if (document.loadDocument(path) !== pdfService.ParseResult.PARSE_SUCCESS) throw new Error('Invalid PDF');
      if (index >= document.getPageCount()) throw new Error('Missing page');
      page = document.getPage(index);
      const width = page.getWidth(), height = page.getHeight();
      if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || width > 20000 || height > 20000) throw new Error('Invalid page size');
      const ratio = Math.min(2, 3072 / Math.max(width, height));
      const matrix = new pdfService.PdfMatrix();
      matrix.x = 0; matrix.y = 0; matrix.width = width; matrix.height = height; matrix.rotate = 0;
      pixels = page.getAreaPixelMap(matrix, Math.max(1, Math.floor(width * ratio)), Math.max(1, Math.floor(height * ratio)), false, true);
      this.current(generation);
      packer = image.createImagePacker();
      const bytes = await packer.packing(pixels, { format: 'image/png', quality: 100 });
      this.current(generation);
      if (bytes.byteLength === 0 || bytes.byteLength > 32 * 1024 * 1024) throw new Error('PDF output too large');
      return new Uint8Array(bytes);
    } finally {
      try { if (packer !== null) await packer.release(); }
      finally { try { if (pixels !== null) await pixels.release(); }
        finally { try { page?.release(); }
          finally { try { document?.releaseDocument(); } finally { await fs.close(file); } }
        }
      }
      this.current(generation);
    }
  }
}
