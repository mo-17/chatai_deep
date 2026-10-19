
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import SecureStoragePlugin from '../security/SecureStoragePlugin';
import FilePickerPlugin from '../files/FilePickerPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new SecureStoragePlugin())
    flutterEngine.getPlugins()?.add(new FilePickerPlugin(this.context))
  }
}
