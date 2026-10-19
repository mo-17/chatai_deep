import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { pdfService } from '@kit.PDFKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface PdfOcrPages { totalPages: number; pages: string[]; }

export default class OcrPlugin implements FlutterPlugin, MethodCallHandler {
  private context: common.UIAbilityContext;
  private applicationContext: common.Context | null = null;
  private channel: MethodChannel | null = null;
  private busy = false;
  private active = '';
  private cancelled = false;
  private reportProgress = false;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepOcrPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.hzb.flutter_ai/ocr');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.suspend(); this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  suspend(): void { this.cancelled = true; }
  private current(): void { if (this.cancelled || this.channel === null) throw new Error('OCR cancelled'); }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'cancel') {
      if (call.argument('id') === this.active) this.suspend();
      result.success(null); return;
    }
    if (call.method !== 'recognize') { result.notImplemented(); return; }
    if (this.busy) { result.error('ocr_busy', '文字识别正在进行中', null); return; }
    this.busy = true; this.cancelled = false;
    this.execute(call, result);
  }
  private async input(path: string, bytes: number): Promise<fs.File> {
    if (typeof path !== 'string' || path.includes('\0') || path.includes('\\')) throw new Error('Invalid OCR path');
    const roots = [this.context.filesDir, this.context.cacheDir, this.context.tempDir];
    // Flutter path_provider 返回应用目录，选择器返回 Ability 模块目录；两者都属于本应用。
    if (this.applicationContext !== null) {
      roots.push(this.applicationContext.filesDir, this.applicationContext.cacheDir, this.applicationContext.tempDir);
    }
    const root = roots.find((value: string) => path.startsWith(`${value}/`));
    if (root === undefined) throw new Error('OCR file outside sandbox');
    const parts = path.substring(root.length + 1).split('/');
    let current = root;
    for (const part of parts) {
      if (part === '' || part === '.' || part === '..') throw new Error('Invalid OCR path');
      current += `/${part}`;
      if ((await fs.lstat(current)).isSymbolicLink()) throw new Error('OCR symbolic link rejected');
    }
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > bytes) throw new Error('OCR file too large');
      return file;
    } catch (_) { await fs.close(file); throw new Error('Invalid OCR file'); }
  }
  private async recognize(pixels: image.PixelMap): Promise<string> {
    this.current();
    const result = await textRecognition.recognizeText({ pixelMap: pixels }, { isDirectionDetectionSupported: true });
    this.current();
    if (result.value.length > 1000000) throw new Error('OCR text too large');
    return result.value.trim();
  }
  private async image(path: string): Promise<string> {
    const file = await this.input(path, 20 * 1024 * 1024);
    let decoder: image.ImageSource | null = null;
    let pixels: image.PixelMap | null = null;
    try {
      decoder = image.createImageSource(file.fd);
      const info = await decoder.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0 || info.size.width * info.size.height > 64 * 1024 * 1024) throw new Error('OCR image too large');
      const ratio = Math.min(1, 4096 / Math.max(info.size.width, info.size.height));
      pixels = await decoder.createPixelMap({ desiredSize: { width: Math.max(1, Math.floor(info.size.width * ratio)), height: Math.max(1, Math.floor(info.size.height * ratio)) } });
      return await this.recognize(pixels);
    } finally {
      try { if (pixels !== null) await pixels.release(); }
      finally { try { if (decoder !== null) await decoder.release(); } finally { await fs.close(file); } }
    }
  }
  private async recognizePdfPixels(pixels: image.PixelMap): Promise<string> {
    // PDF Kit 的 PixelMap 在部分真机无法直接传给 Core Vision；经有界 PNG 重解码统一像素格式。
    const packer = image.createImagePacker();
    let decoder: image.ImageSource | null = null;
    let normalized: image.PixelMap | null = null;
    try {
      this.current();
      const encoded = await packer.packing(pixels, { format: 'image/png', quality: 100 });
      if (encoded.byteLength === 0 || encoded.byteLength > 32 * 1024 * 1024) throw new Error('PDF raster too large');
      this.current();
      decoder = image.createImageSource(encoded);
      normalized = await decoder.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      return await this.recognize(normalized);
    } finally {
      try { if (normalized !== null) await normalized.release(); }
      finally { try { if (decoder !== null) await decoder.release(); } finally { await packer.release(); } }
    }
  }
  private async pdf(path: string, maxPages: number, selected: number[] | null): Promise<PdfOcrPages> {
    const file = await this.input(path, 64 * 1024 * 1024);
    let document: pdfService.PdfDocument | null = null;
    try {
      document = new pdfService.PdfDocument();
      if (document.loadDocument(path) !== pdfService.ParseResult.PARSE_SUCCESS) throw new Error('PDF cannot be opened');
      const total = document.getPageCount();
      if (total < 1) throw new Error('PDF has no pages');
      const count = Math.min(total, maxPages);
      if (selected !== null && selected.some((page: number) => page > count)) throw new Error('Invalid PDF page');
      const texts: string[] = [];
      let length = 0;
      for (let index = 0; index < count; index++) {
        this.current();
        if (selected !== null && !selected.includes(index + 1)) { texts.push(''); continue; }
        const page = document.getPage(index);
        let pixels: image.PixelMap | null = null;
        try {
          const width = page.getWidth(), height = page.getHeight();
          if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || width > 20000 || height > 20000) throw new Error('Invalid PDF dimensions');
          const ratio = Math.min(2, 3072 / Math.max(width, height));
          const matrix = new pdfService.PdfMatrix();
          matrix.x = 0; matrix.y = 0; matrix.width = width; matrix.height = height; matrix.rotate = 0;
          pixels = page.getAreaPixelMap(matrix, Math.max(1, Math.floor(width * ratio)), Math.max(1, Math.floor(height * ratio)), false, true);
          const text = await this.recognizePdfPixels(pixels);
          length += text.length;
          if (length > 1000000) throw new Error('OCR text too large');
          texts.push(text);
          if (this.reportProgress) this.channel?.invokeMethod('progress', { id: this.active, page: index + 1, total: count });
        } finally { try { if (pixels !== null) await pixels.release(); } finally { page.release(); } }
      }
      return { totalPages: total, pages: texts };
    } finally { try { document?.releaseDocument(); } finally { await fs.close(file); } }
  }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    let initialized = false;
    try {
      const id = call.argument('id') as string;
      const kind = call.argument('kind') as string;
      const path = call.argument('path') as string;
      const pages = call.argument('maxPages') as number;
      if (typeof id !== 'string' || id.length === 0 || id.length > 100 || !['image', 'pdf', 'pdfPages'].includes(kind) || !Number.isInteger(pages) || pages < 1 || pages > 20) throw new Error('Invalid OCR request');
      const selected = (call.argument('pageNumbers') as number[] | null) ?? null;
      if (selected !== null && (kind !== 'pdfPages' || !Array.isArray(selected) || selected.length < 1 ||
        selected.length > pages || new Set(selected).size !== selected.length ||
        selected.some((page: number) => !Number.isInteger(page) || page < 1 || page > pages))) throw new Error('Invalid OCR pages');
      this.active = id;
      this.reportProgress = call.argument('reportProgress') === true;
      initialized = await textRecognition.init();
      if (!initialized) throw new Error('OCR unavailable');
      this.current();
      let text: string | PdfOcrPages;
      if (kind === 'image') text = await this.image(path);
      else {
        const recognized = await this.pdf(path, pages, selected);
        if (kind === 'pdfPages') text = recognized;
        else {
          const parts = recognized.pages.slice();
          if (recognized.totalPages > pages) parts.push(`[注：原文共 ${recognized.totalPages} 页，仅 OCR 前 ${pages} 页]`);
          text = parts.join('\n\n').trim();
        }
      }
      this.current();
      // 先释放全局识别服务，避免下一次调用在回调后抢到尚未释放的资源。
      await textRecognition.release(); initialized = false;
      this.current();
      this.busy = false; this.active = '';
      result.success(text);
    } catch (error) {
      if (initialized) { try { await textRecognition.release(); } catch (_) {} }
      this.busy = false; this.active = '';
      result.error(this.cancelled ? 'ocr_cancelled' : 'ocr_error', `文字识别未完成 (${(error as BusinessError).code ?? 'file_or_service'})`, null);
    }
  }
}
