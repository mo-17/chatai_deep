import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });

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

  testWidgets('外部 controller 可填入文本并在发送后清空', (tester) async {
    final controller = TextEditingController();
    var changed = '';
    var sent = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: MessageInputWidget(
              '请输入',
              controller: controller,
              speechInputEnabled: false,
              onChanged: (value) => changed = value,
              onSend: () => sent++,
            ),
          ),
        ),
      ),
    );

    controller.text = '快捷回复内容';
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    await tester.pump();

    expect(changed, '快捷回复内容');
    expect(find.text('快捷回复内容'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, 1);
    expect(controller.text, isEmpty);
    expect(changed, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
