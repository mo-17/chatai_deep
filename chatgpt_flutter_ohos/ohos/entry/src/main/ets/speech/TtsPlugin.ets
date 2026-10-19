import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface TtsVoice { name: string; identifier: string; locale: string; gender: string; }

export default class TtsPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private language = '';
  private person = -1;
  private epoch = 0;
  private sequence = 0;
  private request = '';
  private pending: MethodResult | null = null;
  private timer: number = -1;
  getUniqueClassName(): string { return 'ChataiDeepTtsPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.hzb.flutter_ai/tts');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.suspend(); this.engine?.shutdown(); this.engine = null;
    this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  suspend(): void { this.epoch++; this.settle(0); try { this.engine?.stop(); } catch (_) {} }
  private settle(value: number, error: boolean = false): void {
    const result = this.pending;
    this.pending = null; this.request = '';
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    if (error) result?.error('tts_error', '系统朗读未能完成，请检查系统音色服务', null);
    else result?.success(value);
  }
  private async ensure(language: string, person: number, epoch: number): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.engine !== null && this.language === language && this.person === person) return this.engine;
    this.engine?.shutdown(); this.engine = null;
    const engine = await textToSpeech.createEngine({ language, person, online: 1 });
    if (this.channel === null || epoch !== this.epoch) { engine.shutdown(); throw new Error('TTS cancelled'); }
    engine.setListener({
      onStart: (): void => {},
      onComplete: (id: string, response: textToSpeech.CompleteResponse): void => {
        // type=0 仅合成结束，type=1 才是声音播放结束。
        if (id === this.request && response.type === 1) this.settle(1);
      },
      onStop: (id: string): void => { if (id === this.request) this.settle(0); },
      onError: (id: string): void => { if (id === this.request) this.settle(0, true); },
    });
    this.engine = engine; this.language = language; this.person = person;
    return engine;
  }
  private number(call: MethodCall, key: string, min: number, max: number): number {
    const value = call.argument(key) as number;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) throw new Error('Invalid TTS option');
    return value;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.execute(call, result); }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      if (call.method === 'stop') { this.suspend(); result.success(1); return; }
      if (call.method === 'voices') {
        // 使用 API 11 的引擎接口，避免依赖 API 19 才新增的静态 listVoices。
        const engine = this.engine ?? await this.ensure('zh-CN', 0, this.epoch);
        const voices = await engine.listVoices({ requestId: `voices_${this.sequence++}`, online: 1 });
        const output: TtsVoice[] = voices.map((voice: textToSpeech.VoiceInfo): TtsVoice => ({ name: `${voice.person}`, identifier: `${voice.person}`, locale: voice.language, gender: voice.gender }));
        result.success(output);
        return;
      }
      if (call.method !== 'speak') { result.notImplemented(); return; }
      this.suspend();
      const epoch = this.epoch;
      const text = call.argument('text') as string;
      const language = call.argument('language') as string;
      const person = this.number(call, 'person', 0, 1000);
      const speed = this.number(call, 'speed', 0.5, 2);
      const pitch = this.number(call, 'pitch', 0.5, 2);
      const volume = this.number(call, 'volume', 0, 1);
      if (typeof text !== 'string' || text.length === 0 || text.length > 1000 || !/^[a-z]{2,3}-[A-Z]{2}$/.test(language)) throw new Error('Invalid TTS text or language');
      const engine = await this.ensure(language, person, epoch);
      if (epoch !== this.epoch) { result.success(0); return; }
      this.request = `tts_${Date.now()}_${this.sequence++}`;
      this.pending = result;
      this.timer = setTimeout(() => { if (this.pending === result) { this.settle(0, true); engine.stop(); } }, Math.max(30000, text.length * 500 + 20000));
      engine.speak(text, { requestId: this.request, extraParams: { speed, pitch, volume } });
    } catch (error) {
      if (this.pending === result) this.settle(0, true);
      else result.error('tts_error', `系统朗读不可用 (${(error as BusinessError).code ?? 'service'})`, null);
    }
  }
}
