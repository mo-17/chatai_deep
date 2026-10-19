import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface SpeechAlternate { recognizedWords: string; confidence: number; }
interface SpeechResult { alternates: SpeechAlternate[]; finalResult: boolean; }

/** 复用 speech_to_text 的标准通道和回调协议，保留共享核心的进程级租约。 */
export default class SpeechRecognizerPlugin implements FlutterPlugin, MethodCallHandler {
  private context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private language = '';
  private session = '';
  private completed = '';
  private lastText = '';
  private generation = 0;
  private sequence = 0;
  private timer: number = -1;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  getUniqueClassName(): string { return 'ChataiDeepSpeechRecognizerPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'plugin.csdcorp.com/speech_to_text');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.suspend(); this.engine?.shutdown(); this.engine = null;
    this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  suspend(): void {
    this.generation++;
    const id = this.session;
    this.session = ''; this.completed = ''; this.lastText = '';
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    if (id.length > 0) { try { this.engine?.cancel(id); } catch (_) {} this.emit('notifyStatus', 'done'); }
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.execute(call, result); }
  private emit(method: string, value: string): void { this.channel?.invokeMethod(method, value); }
  private text(value: string, final: boolean): void {
    const alternate: SpeechAlternate = { recognizedWords: value, confidence: -1.0 };
    const result: SpeechResult = { alternates: [alternate], finalResult: final };
    this.emit('textRecognition', JSON.stringify(result));
  }
  private async permission(request: boolean): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    if (!request) return (await manager.checkAccessToken(this.context.applicationInfo.accessTokenId, 'ohos.permission.MICROPHONE')) === 0;
    const response = await manager.requestPermissionsFromUser(this.context, ['ohos.permission.MICROPHONE']);
    return response.authResults.length === 1 && response.authResults[0] === 0;
  }
  private async ensure(language: string): Promise<speechRecognizer.SpeechRecognitionEngine> {
    if (this.engine !== null && this.language === language) return this.engine;
    this.engine?.shutdown(); this.engine = null;
    const generation = this.generation;
    // 系统离线识别；不自动切换在线服务或上传录音。
    const engine = await speechRecognizer.createEngine({ language, online: 1 });
    if (this.channel === null || generation !== this.generation) { engine.shutdown(); throw new Error('Recognizer cancelled'); }
    engine.setListener({
      onStart: (id: string): void => { if (id === this.session) this.emit('notifyStatus', 'listening'); },
      onEvent: (): void => {},
      onResult: (id: string, response: speechRecognizer.SpeechRecognitionResult): void => {
        if (id !== this.session) return;
        const text = this.completed + response.result;
        this.lastText = text;
        if (response.isFinal && !response.isLast) this.completed = text;
        this.text(text, response.isLast);
        if (response.isLast) this.finish(id);
      },
      onComplete: (id: string): void => {
        if (id !== this.session) return;
        // 某些服务先结束再给最后标志，用当前已收到文本结算，绝不接受已取消会话。
        this.text(this.lastText, true);
        this.finish(id);
      },
      onError: (id: string, code: number): void => {
        if (id !== this.session) return;
        this.emit('notifyError', JSON.stringify({ errorMsg: `ohos_speech_${code}`, permanent: true }));
        this.finish(id);
      },
    });
    this.engine = engine; this.language = language;
    return engine;
  }
  private finish(id: string): void {
    if (id !== this.session) return;
    this.session = '';
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    try { this.engine?.cancel(id); } catch (_) {}
    this.emit('notifyStatus', 'done');
  }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    let generation = this.generation;
    try {
      switch (call.method) {
        case 'has_permission': result.success(await this.permission(false)); return;
        case 'initialize':
          if (!(await this.permission(true))) { result.success(false); return; }
          if (generation !== this.generation) { result.success(false); return; }
          await this.ensure('zh-CN'); result.success(true); return;
        case 'locales': {
          const engine = await this.ensure(this.language || 'zh-CN');
          const languages = await engine.listLanguages({ sessionId: `languages_${this.sequence++}` });
          result.success(languages.map((language: string) => `${language}:${language}`)); return;
        }
        case 'cancel': this.suspend(); result.success(null); return;
        case 'stop':
          if (this.session.length > 0) this.engine?.finish(this.session);
          result.success(null); return;
        case 'listen': {
          this.suspend();
          generation = this.generation;
          if (!(await this.permission(false))) { result.success(false); return; }
          if (generation !== this.generation) { result.success(false); return; }
          const raw = call.argument('localeId') as string | null;
          const language = (raw ?? 'zh-CN').replace(/_/g, '-');
          if (!/^[a-z]{2,3}-[A-Z]{2}$/.test(language)) throw new Error('Invalid speech locale');
          const engine = await this.ensure(language);
          if (generation !== this.generation || this.channel === null) { result.success(false); return; }
          const id = `speech_${Date.now()}_${this.sequence++}`;
          this.session = id; this.completed = ''; this.lastText = '';
          engine.startListening({ sessionId: id, audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
            extraParams: { recognitionMode: 0, vadBegin: 5000, vadEnd: 2000, maxAudioDuration: 20000 } });
          if (this.session === id) this.timer = setTimeout(() => { if (this.session === id) this.suspend(); }, 24000);
          result.success(true); return;
        }
        default: result.notImplemented();
      }
    } catch (error) {
      if (generation !== this.generation) { result.success(call.method === 'locales' ? [] : false); return; }
      this.suspend();
      result.error('speech_error', `语音识别不可用 (${(error as BusinessError).code ?? 'service'})`, null);
    }
  }
}
