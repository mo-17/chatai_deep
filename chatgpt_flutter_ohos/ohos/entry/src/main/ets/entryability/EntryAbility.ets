
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import SecureStoragePlugin from '../security/SecureStoragePlugin';
import FilePickerPlugin from '../files/FilePickerPlugin';
import ImagePickerPlugin from '../media/ImagePickerPlugin';
import SharePlugin from '../media/SharePlugin';
import SpeechRecognizerPlugin from '../speech/SpeechRecognizerPlugin';
import TtsPlugin from '../speech/TtsPlugin';
import OcrPlugin from '../ocr/OcrPlugin';

export default class EntryAbility extends FlutterAbility {
  private speech: SpeechRecognizerPlugin | null = null;
  private tts: TtsPlugin | null = null;
  private ocr: OcrPlugin | null = null;
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new SecureStoragePlugin())
    flutterEngine.getPlugins()?.add(new FilePickerPlugin(this.context))
    flutterEngine.getPlugins()?.add(new ImagePickerPlugin(this.context))
    flutterEngine.getPlugins()?.add(new SharePlugin(this.context))
    this.speech = new SpeechRecognizerPlugin(this.context)
    this.tts = new TtsPlugin()
    this.ocr = new OcrPlugin(this.context)
    flutterEngine.getPlugins()?.add(this.speech)
    flutterEngine.getPlugins()?.add(this.tts)
    flutterEngine.getPlugins()?.add(this.ocr)
  }
  onBackground() {
    this.speech?.suspend()
    this.tts?.suspend()
    this.ocr?.suspend()
    super.onBackground()
  }
}
