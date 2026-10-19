
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import SecureStoragePlugin from '../security/SecureStoragePlugin';
import FilePickerPlugin from '../files/FilePickerPlugin';
import ImagePickerPlugin from '../media/ImagePickerPlugin';
import SharePlugin from '../media/SharePlugin';
import SpeechRecognizerPlugin from '../speech/SpeechRecognizerPlugin';
import TtsPlugin from '../speech/TtsPlugin';
import OcrPlugin from '../ocr/OcrPlugin';
import HuaweiLoginPlugin from '../account/HuaweiLoginPlugin';
import PackageInfoPlugin from '../media/PackageInfoPlugin';
import KnowledgePdfPlugin from '../media/KnowledgePdfPlugin';
import VoiceAudioPlugin from '../speech/VoiceAudioPlugin';
import TtsPlaybackPlugin from '../speech/TtsPlaybackPlugin';

export default class EntryAbility extends FlutterAbility {
  private speech: SpeechRecognizerPlugin | null = null;
  private tts: TtsPlugin | null = null;
  private ocr: OcrPlugin | null = null;
  private pdf: KnowledgePdfPlugin | null = null;
  private audio: VoiceAudioPlugin | null = null;
  private playback: TtsPlaybackPlugin | null = null;
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new SecureStoragePlugin())
    flutterEngine.getPlugins()?.add(new FilePickerPlugin(this.context))
    flutterEngine.getPlugins()?.add(new ImagePickerPlugin(this.context))
    flutterEngine.getPlugins()?.add(new SharePlugin(this.context))
    flutterEngine.getPlugins()?.add(new HuaweiLoginPlugin(this.context))
    flutterEngine.getPlugins()?.add(new PackageInfoPlugin(this.context))
    this.pdf = new KnowledgePdfPlugin(this.context)
    flutterEngine.getPlugins()?.add(this.pdf)
    this.speech = new SpeechRecognizerPlugin(this.context)
    this.tts = new TtsPlugin()
    this.ocr = new OcrPlugin(this.context)
    this.audio = new VoiceAudioPlugin((): void => {
      this.speech?.suspend(); this.tts?.suspend(); this.playback?.suspend();
    })
    this.playback = new TtsPlaybackPlugin(this.context, this.audio)
    flutterEngine.getPlugins()?.add(this.audio)
    flutterEngine.getPlugins()?.add(this.playback)
    flutterEngine.getPlugins()?.add(this.speech)
    flutterEngine.getPlugins()?.add(this.tts)
    flutterEngine.getPlugins()?.add(this.ocr)
  }
  onBackground() {
    this.speech?.suspend()
    this.tts?.suspend()
    this.ocr?.suspend()
    this.pdf?.suspend()
    this.playback?.suspend()
    this.audio?.suspend()
    super.onBackground()
  }
}
