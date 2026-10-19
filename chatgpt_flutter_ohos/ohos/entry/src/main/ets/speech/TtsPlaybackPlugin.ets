import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import VoiceAudioPlugin from './VoiceAudioPlugin';

interface Playback {
  id: string; player: media.AVPlayer; file: fs.File; result: MethodResult;
  timer: number; settled: boolean;
}

export default class TtsPlaybackPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private current: Playback | null = null;
  private generation = 0;
  private creatingId = '';
  private cleanup: Promise<void> = Promise.resolve();
  private releaseFailed = false;
  private context: common.UIAbilityContext;
  private route: VoiceAudioPlugin;
  constructor(context: common.UIAbilityContext, route: VoiceAudioPlugin) { this.context = context; this.route = route; }
  getUniqueClassName(): string { return 'ChataiDeepTtsPlaybackPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'aipu/tts-playback');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.suspend(); this.channel?.setMethodCallHandler(null); this.channel = null;
  }
  suspend(): void { this.generation++; this.creatingId = ''; this.finish(this.current, false); }
  private finish(task: Playback | null, failed: boolean): void {
    if (task === null || task.settled) return;
    task.settled = true; clearTimeout(task.timer);
    if (this.current === task) this.current = null;
    // release 完成前文件描述符必须保持有效。
    this.cleanup = task.player.release().catch((): void => { this.releaseFailed = true; }).then((): void => {
      try { fs.closeSync(task.file); } catch (_) { this.releaseFailed = true; }
      if (failed || this.releaseFailed) task.result.error('playback_error', '离线语音播放失败或已被系统中断', null);
      else task.result.success(null);
    });
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.execute(call, result); }
  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    const id = call.argument('id') as string;
    if (call.method === 'stop') {
      // 旧播放器的 stop 不得停止另一个请求。
      if (this.current?.id === id || this.creatingId === id) this.suspend();
      await this.cleanup;
      if (this.releaseFailed) result.error('playback_release_error', '播放器未能释放，请重新打开应用', null);
      else result.success(null);
      return;
    }
    if (call.method !== 'play') { result.notImplemented(); return; }
    this.suspend(); const generation = this.generation;
    this.creatingId = id;
    let file: fs.File | null = null;
    let player: media.AVPlayer | null = null;
    try {
      await this.cleanup;
      if (this.releaseFailed || generation !== this.generation || this.channel === null) throw new Error('Player not available');
      const path = call.argument('path') as string;
      if (typeof id !== 'string' || !/^\d+_\d+$/.test(id) || typeof path !== 'string' ||
        !path.startsWith(`${this.context.cacheDir}/tts_audio_cache/`) ||
        path.includes('\0') || path.split('/').includes('..') || !path.endsWith('.wav')) throw new Error('Invalid playback');
      file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      const stat = fs.statSync(file.fd);
      if (!stat.isFile() || stat.size <= 44 || stat.size > 32 * 1024 * 1024) throw new Error('Invalid WAV');
      player = await media.createAVPlayer();
      if (generation !== this.generation || this.channel === null) throw new Error('Playback cancelled');
      const task: Playback = { id, player, file, result, timer: -1, settled: false };
      this.current = task;
      this.creatingId = '';
      player.on('stateChange', (state: string): void => {
        if (task.settled || this.current !== task) return;
        if (state === 'initialized') {
          task.player.audioRendererInfo = {
            usage: this.route.active ? audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION : audio.StreamUsage.STREAM_USAGE_MUSIC,
            rendererFlags: 0 };
          task.player.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
          task.player.prepare().catch((): void => { this.finish(task, true); });
        } else if (state === 'prepared') {
          task.player.play().catch((): void => { this.finish(task, true); });
        } else if (state === 'completed') this.finish(task, false);
      });
      player.on('error', (): void => { this.finish(task, true); });
      player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if ([audio.InterruptHint.INTERRUPT_HINT_PAUSE, audio.InterruptHint.INTERRUPT_HINT_STOP].includes(event.hintType)) this.finish(task, true);
      });
      task.timer = setTimeout((): void => { this.finish(task, true); }, 180000);
      player.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
    } catch (_) {
      if (this.creatingId === id) this.creatingId = '';
      if (this.current?.id === id) this.finish(this.current, true);
      else {
        if (player !== null) await player.release().catch((): void => {});
        if (file !== null) try { fs.closeSync(file); } catch (_) {}
        result.error('playback_error', '离线语音文件不可用', null);
      }
    }
  }
}
