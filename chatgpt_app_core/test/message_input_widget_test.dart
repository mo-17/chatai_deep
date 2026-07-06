import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  test('语音识别语言为空时不返回空 localeId', () {
    final locales = [
      stt.LocaleName('', '空语言'),
      stt.LocaleName('zh_CN', '中文'),
      stt.LocaleName('en_US', 'English'),
    ];

    final picked = pickSpeechLocaleId(
      locales,
      preferredLocale: '   ',
      systemLocale: '',
    );
    expect(picked, isNot(isEmpty));
    expect(['zh_CN', 'en_US'], contains(picked));
    expect(
      pickSpeechLocaleId(
        [stt.LocaleName('', '空语言')],
        preferredLocale: '',
        systemLocale: '',
      ),
      isNull,
    );
  });

  test('语音识别语言兼容横线和下划线', () {
    final locales = [
      stt.LocaleName('en_US', 'English'),
      stt.LocaleName('zh_CN', '中文'),
    ];

    expect(
      pickSpeechLocaleId(locales, preferredLocale: 'zh-CN'),
      'zh_CN',
    );
    expect(
      pickSpeechLocaleId(locales, preferredLocale: 'en-GB'),
      'en_US',
    );
  });
}
