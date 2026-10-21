// 一次安装执行离线主流程与真实 Android OCR。
import 'android_native_ocr_test.dart' as ocr;
import 'offline_smoke_test.dart' as offline;

void main() {
  offline.main();
  ocr.main();
}
