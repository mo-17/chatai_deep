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

const MAX_BYTES = 20 * 1024 * 1024;

interface PickedImage { path: string; name: string; mimeType: string; }

export default class ImagePickerPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private busy = false;
  private sequence = 0;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepImagePickerPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.hzb.flutter_ai/image_picker');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'pickImage') { result.notImplemented(); return; }
    if (this.busy) { result.error('picker_busy', '图片选择器正在使用中', null); return; }
    this.busy = true;
    this.execute(call, result);
  }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const picked = await this.pick(call);
      this.busy = false;
      result.success(picked);
    } catch (error) {
      this.busy = false;
      result.error('image_picker_error', `选取图片失败 (${(error as BusinessError).code ?? 'io'})`, null);
    }
  }
  private number(call: MethodCall, key: string, fallback: number, min: number, max: number): number {
    const value = call.argument(key) as number | null;
    if (value === null || value === undefined) return fallback;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
      throw new Error('Invalid image option');
    }
    return Math.floor(value);
  }
  private async pick(call: MethodCall): Promise<PickedImage | null> {
    const width = this.number(call, 'maxWidth', 2048, 1, 4096);
    const height = this.number(call, 'maxHeight', 2048, 1, 4096);
    const quality = this.number(call, 'quality', 85, 0, 100);
    const source = call.argument('source') as string;
    let uri = '';
    if (source === 'gallery') {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const selection = await new photoAccessHelper.PhotoViewPicker().select(options);
      if (selection.photoUris.length === 0) return null;
      if (selection.photoUris.length !== 1) throw new Error('Invalid selection');
      uri = selection.photoUris[0];
    } else if (source === 'camera') {
      const profile: cameraPicker.PickerProfile = {
        cameraPosition: call.argument('frontCamera') === true
          ? camera.CameraPosition.CAMERA_POSITION_FRONT : camera.CameraPosition.CAMERA_POSITION_BACK,
      };
      const capture = await cameraPicker.pick(this.context, [cameraPicker.PickerMediaType.PHOTO], profile);
      if (capture.resultCode !== 0) {
        if (capture.resultCode === -1) return null;
        throw new Error('Camera failed');
      }
      uri = capture.resultUri;
    } else { throw new Error('Invalid source'); }
    if (this.channel === null || uri.length === 0) throw new Error('Picker detached');
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    let decoder: image.ImageSource | null = null;
    let pixels: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let output = '';
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_BYTES) throw new Error('Image too large');
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
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_BYTES || this.channel === null) throw new Error('Image too large or detached');
      const root = `${this.context.cacheDir}/chatai_image_picker`;
      if (!fs.accessSync(root)) fs.mkdirSync(root);
      const name = `image_${Date.now()}_${this.sequence++}.${png ? 'png' : 'jpg'}`;
      output = `${root}/${name}`;
      const target = await fs.open(output, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        let written = 0;
        while (written < bytes.byteLength) {
          const count = await fs.write(target.fd, bytes.slice(written));
          if (count <= 0) throw new Error('Short image write');
          written += count;
        }
      } finally { await fs.close(target); }
      if (this.channel === null) throw new Error('Picker detached');
      return { path: output, name, mimeType: mime };
    } catch (error) {
      if (output.length > 0 && fs.accessSync(output)) await fs.unlink(output);
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
