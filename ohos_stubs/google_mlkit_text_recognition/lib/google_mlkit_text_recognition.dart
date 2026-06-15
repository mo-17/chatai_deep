/// HarmonyOS 空实现 stub：仅提供 [OcrService] 用到的公开 API 形状，
/// 任何真正识别的调用都抛 [UnsupportedError]（OHOS 上被 isSupported 守卫，不会触发）。
library google_mlkit_text_recognition;

const _msg = 'OCR（ML Kit）在 HarmonyOS 上不可用';

/// 文字识别脚本（与上游枚举同名，OcrService 仅用到 [chinese]）。
enum TextRecognitionScript { latin, chinese, devanagiri, japanese, korean }

/// 输入图片占位。
class InputImage {
  InputImage._();

  factory InputImage.fromFilePath(String filePath) => InputImage._();
}

/// 识别结果占位（含 `text` 字段，与上游一致）。
class RecognizedText {
  final String text;

  const RecognizedText({this.text = ''});
}

/// 文字识别器占位。[processImage] 在 OHOS 上不可用。
class TextRecognizer {
  final TextRecognitionScript script;

  TextRecognizer({this.script = TextRecognitionScript.latin});

  Future<RecognizedText> processImage(InputImage inputImage) =>
      throw UnsupportedError(_msg);

  Future<void> close() async {}
}
