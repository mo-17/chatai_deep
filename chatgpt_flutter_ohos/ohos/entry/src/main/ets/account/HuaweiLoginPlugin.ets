import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** 登录只申请身份标识；授权码由服务端兑换并验证，不信任客户端 UnionID。 */
export default class HuaweiLoginPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;
  private generation = 0;
  private busy = false;
  private pending: MethodResult | null = null;
  private timer: number = -1;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepHuaweiLoginPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.hzb.flutter_ai/huawei_login');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.generation++;
    this.finishError('huawei_cancelled');
    this.busy = false;
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'signIn') { result.notImplemented(); return; }
    if (this.channel === null) { result.error('huawei_unavailable', '账号服务不可用', null); return; }
    if (!canIUse('SystemCapability.AuthenticationServices.HuaweiID.Auth')) {
      result.error('huawei_unavailable', '账号服务不可用', null); return;
    }
    const clientId = this.context.currentHapModuleInfo.metadata?.find(
      (item) => item.name === 'client_id')?.value ?? '';
    if (!/^[0-9]{1,64}$/.test(clientId)) {
      result.error('huawei_not_configured', '账号服务未配置', null); return;
    }
    if (this.busy) { result.error('huawei_busy', '授权正在进行中', null); return; }
    this.busy = true;
    this.pending = result;
    const generation = ++this.generation;
    // Account Kit 没有取消 executeRequest 的接口；超时结束 Flutter 等待，但直到
    // 原生请求返回前仍拒绝并发，防止重复弹出系统账号页。
    this.timer = setTimeout(() => {
      if (generation === this.generation) this.finishError('huawei_timeout');
    }, 120000);
    this.signIn(generation);
  }
  private finishError(code: string): void {
    clearTimeout(this.timer);
    this.timer = -1;
    const result = this.pending;
    this.pending = null;
    result?.error(code, '华为账号授权未完成', null);
  }
  private async signIn(generation: number): Promise<void> {
    try {
      const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
      request.forceLogin = true;
      const state = util.generateRandomUUID();
      request.state = state;
      const controller = new authentication.AuthenticationController(this.context);
      const response = await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;
      if (generation !== this.generation || this.pending === null) return;
      if (response.state !== state) { this.finishError('huawei_invalid_response'); return; }
      const code = response.data?.authorizationCode;
      if (typeof code !== 'string' || code.trim().length === 0 || code.length > 16384) {
        this.finishError('huawei_invalid_response'); return;
      }
      const result = this.pending;
      this.pending = null;
      result.success(new Map<string, string>([['authCode', code]]));
    } catch (error) {
      if (generation !== this.generation) return;
      const code = (error as BusinessError).code;
      let category = 'huawei_authorization_failed';
      if (code === 1001502012) category = 'huawei_cancelled';
      else if (code === 1001502005) category = 'huawei_network';
      else if (code === 1001502001) category = 'huawei_account_required';
      else if (code === 1001500001 || code === 1001502002 || code === 1001502014) category = 'huawei_not_configured';
      this.finishError(category);
    } finally {
      if (generation === this.generation) {
        clearTimeout(this.timer);
        this.timer = -1;
        this.busy = false;
      }
    }
  }
}
