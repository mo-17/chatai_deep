import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { audio } from '@kit.AudioKit';

/** 只在系统同时将识别输入和播报输出路由至通话耳机时开放说话打断。 */
export default class VoiceAudioPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private manager = audio.getAudioManager();
  private routing = this.manager.getRoutingManager();
  private session = this.manager.getSessionManager();
  private generation = 0;
  private busy = false;
  private ownsSession = false;
  private deactivating = false;
  private inputChanged = false;
  private previousInput: audio.AudioDeviceDescriptor | null = null;
  private ready = false;
  private cleanup: Promise<void> = Promise.resolve();
  private onLost: () => void;
  constructor(onLost: () => void = (): void => {}) { this.onLost = onLost; }
  get active(): boolean { return this.ready; }
  getUniqueClassName(): string { return 'ChataiDeepVoiceAudioPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'aipu/voice-audio');
    this.channel.setMethodCallHandler(this);
    this.session.on('audioSessionDeactivated', this.deactivated);
    this.session.on('audioSessionStateChanged', this.stateChange);
    this.session.on('currentInputDeviceChanged', this.inputChange);
    this.session.on('currentOutputDeviceChanged', this.outputChange);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.suspend();
    this.session.off('audioSessionDeactivated', this.deactivated);
    this.session.off('audioSessionStateChanged', this.stateChange);
    this.session.off('currentInputDeviceChanged', this.inputChange);
    this.session.off('currentOutputDeviceChanged', this.outputChange);
    this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  private deactivated = (): void => { if (!this.deactivating) this.invalidate(); };
  private stateChange = (event: audio.AudioSessionStateChangedEvent): void => {
    if ([audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE,
      audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP,
      audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_TIME_OUT_STOP].includes(event.stateChangeHint)) this.invalidate();
  };
  private inputChange = (event: audio.CurrentInputDeviceChangedEvent): void => {
    if (!this.headsets(event.devices)) this.invalidate();
  };
  private outputChange = (event: audio.CurrentOutputDeviceChangedEvent): void => {
    if (!this.headsets(event.devices)) this.invalidate();
  };
  private headset(device: audio.AudioDeviceDescriptor): boolean {
    return [audio.DeviceType.WIRED_HEADSET, audio.DeviceType.USB_HEADSET,
      audio.DeviceType.BLUETOOTH_SCO].includes(device.deviceType);
  }
  private headsets(devices: audio.AudioDeviceDescriptors): boolean {
    return devices.length > 0 && devices.every((device: audio.AudioDeviceDescriptor) => this.headset(device));
  }
  private invalidate(): void {
    if (!this.ready && !this.ownsSession) return;
    this.ready = false;
    // 先停麦克风和回放，再异步恢复会话，缩短耳机拔出后的外放窗口。
    this.onLost();
    this.suspend();
  }
  suspend(): void { this.generation++; this.ready = false; this.release().catch((): void => {}); }
  private async present(devices: audio.AudioDeviceDescriptors): Promise<boolean> {
    const connected = await this.routing.getDevices(audio.DeviceFlag.ALL_DEVICES_FLAG);
    return devices.length > 0 && devices.every((device: audio.AudioDeviceDescriptor): boolean => connected.some(
      (current: audio.AudioDeviceDescriptor): boolean => current.id === device.id &&
        current.deviceType === device.deviceType && current.deviceRole === device.deviceRole));
  }
  private async headsetOutputEnabled(): Promise<boolean> {
    const outputs = await this.routing.getPreferOutputDeviceForRendererInfo({
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 });
    // 蓝牙尚未切入通话时可使用 A2DP；这里仅检查用户已允许耳机输出，随后仍完整验证 SCO 收放音。
    return outputs.length > 0 && outputs.every((device: audio.AudioDeviceDescriptor): boolean =>
      this.headset(device) || device.deviceType === audio.DeviceType.BLUETOOTH_A2DP) && await this.present(outputs);
  }
  private async routesSafe(): Promise<boolean> {
    const input = await this.routing.getPreferredInputDeviceForCapturerInfo({
      source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 });
    const speech = await this.routing.getPreferOutputDeviceForRendererInfo({
      usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION, rendererFlags: 0 });
    const media = await this.routing.getPreferOutputDeviceForRendererInfo({
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 });
    // 首选路由可能短暂保留已拔出设备；必须同时出现在当前连接清单，且设备身份与方向一致。
    // A2DP 只有播放能力；无麦克风的耳机和扬声器均不能当作安全双工路由。
    return this.headsets(input) && this.headsets(speech) && this.headsets(media) &&
      await this.present(input.concat(speech, media));
  }
  private release(): Promise<void> {
    const next = this.cleanup.catch((): void => {}).then(() => this.releaseNow());
    this.cleanup = next;
    return next;
  }
  private async releaseNow(): Promise<void> {
    this.ready = false;
    try {
      if (this.inputChanged) {
        const previous = this.previousInput;
        if (previous !== null && previous.deviceType !== audio.DeviceType.INVALID) {
          try { await this.session.selectMediaInputDevice(previous); }
          catch (_) { await this.session.clearSelectedMediaInputDevice(); }
        } else await this.session.clearSelectedMediaInputDevice();
        this.inputChanged = false; this.previousInput = null;
      }
    } finally {
      if (this.ownsSession) {
        this.deactivating = true;
        try {
          await this.session.deactivateAudioSession();
          this.ownsSession = false;
          this.session.setAudioSessionScene(audio.AudioSessionScene.AUDIO_SESSION_SCENE_MEDIA);
        } finally { this.deactivating = false; }
      }
    }
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.execute(call, result); }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method === 'release') {
      this.generation++; this.ready = false;
      try { await this.release(); result.success(null); }
      catch (_) { result.error('audio_release_error', '通信音频会话未能释放', null); }
      return;
    }
    if (call.method === 'headsetConnected') {
      try {
        const generation = this.generation;
        const safe = this.ready && this.session.isAudioSessionActivated() && await this.routesSafe();
        if (!safe) this.invalidate();
        result.success(safe && generation === this.generation);
      } catch (_) { this.invalidate(); result.success(false); }
      return;
    }
    if (call.method !== 'prepareHeadset') { result.notImplemented(); return; }
    if (this.busy) { result.success({ safeDuplex: false }); return; }
    this.busy = true;
    const generation = ++this.generation;
    try {
      await this.release();
      if (this.session.isAudioSessionActivated()) throw new Error('Session already owned');
      // 必须在激活通信会话之前检查；不能擅自重新开启超级终端等系统界面已关闭的耳机音频通路。
      if (!(await this.headsetOutputEnabled())) throw new Error('Headset audio output disabled');
      this.session.setAudioSessionScene(audio.AudioSessionScene.AUDIO_SESSION_SCENE_VOICE_COMMUNICATION);
      await this.session.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS });
      this.ownsSession = true;
      if (generation !== this.generation) throw new Error('Audio cancelled');
      const inputs = this.session.getAvailableDevices(audio.DeviceUsage.MEDIA_INPUT_DEVICES);
      const input = inputs.find((device: audio.AudioDeviceDescriptor) => this.headset(device));
      if (input === undefined) throw new Error('No headset microphone');
      this.previousInput = this.session.getSelectedMediaInputDevice();
      this.inputChanged = true;
      await this.session.selectMediaInputDevice(input);
      const safe = await this.routesSafe();
      if (!safe || generation !== this.generation || this.channel === null) throw new Error('Route not safe');
      this.ready = true;
      result.success({ safeDuplex: true });
    } catch (_) {
      await this.release().catch((): void => {});
      result.success({ safeDuplex: false });
    } finally { this.busy = false; }
  }
}
