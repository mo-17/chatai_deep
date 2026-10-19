import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { bundleManager, common } from '@kit.AbilityKit';

/** 只查询本应用元数据，不读取签名证书或已安装应用列表。 */
export default class PackageInfoPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private generation = 0;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepPackageInfoPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dev.fluttercommunity.plus/package_info');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.generation++;
    this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'getAll') { result.notImplemented(); return; }
    this.read(result, this.generation);
  }
  private async read(result: MethodResult, generation: number): Promise<void> {
    try {
      const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let name = info.name;
      if (info.appInfo.labelId > 0) {
        try { name = await this.context.resourceManager.getStringValue(info.appInfo.labelId); }
        catch (_) { /* 缺少本地化资源时显示包名；版本仍来自实际安装包。 */ }
      }
      if (!info.name || !info.versionName || !Number.isInteger(info.versionCode) || info.versionCode < 0) throw new Error('Invalid package metadata');
      if (generation !== this.generation || this.channel === null) throw new Error('Detached');
      result.success(new Map<string, string>([
        ['appName', name], ['packageName', info.name], ['version', info.versionName],
        ['buildNumber', String(info.versionCode)], ['buildSignature', ''],
      ]));
    } catch (_) { result.error('package_info_error', '应用版本信息暂不可用', null); }
  }
}
