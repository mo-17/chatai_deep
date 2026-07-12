import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
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
    await HiCache.getInstance().prefs?.clear();
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

  testWidgets('二次元输入栏保持可触控尺寸并可正常发送', (tester) async {
    tester.view.physicalSize = const Size(375, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    var sent = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MessageInputWidget(
                '请输入',
                showWebSearch: true,
                onToggleWebSearch: () {},
                onSend: () => sent += 1,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
        find.byKey(const ValueKey('anime_message_composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('anime_message_input')), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('anime_message_input')), '发送测试');
    await tester.pump();

    final composer = find.byKey(const ValueKey('anime_message_composer'));
    final buttons =
        find.descendant(of: composer, matching: find.byType(IconButton));
    for (final element in buttons.evaluate()) {
      final size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }

    await tester.tap(find.byKey(const ValueKey('anime_message_send')));
    await tester.pump();
    expect(sent, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('二次元输入栏在 320px 全工具场景分层布局且删除入口至少 44dp', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          themeAnimationDuration: Duration.zero,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: MessageInputWidget(
                  '请输入',
                  modelLabel: '测试服务商 / 一个很长的多模态模型名称',
                  onModelTap: () {},
                  showWebSearch: true,
                  onToggleWebSearch: () {},
                  onImagesPicked: (_) {},
                  onFilesPicked: (_) {},
                  pendingFiles: [
                    for (var i = 0; i < 10; i++) '/tmp/example_$i.txt',
                  ],
                  onRemoveFile: (_) {},
                  speechInputEnabled: true,
                  onSend: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('anime_message_input')),
      '窄屏输入仍然清晰',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('anime_message_compact_layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime_message_tools_scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime_pending_files_scroll')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('anime_message_input'))).width,
      greaterThan(180),
    );
    final removeFile = find.byTooltip('移除文件').first;
    expect(tester.getSize(removeFile).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(removeFile).height, greaterThanOrEqualTo(44));
    final modelTap = find.ancestor(
      of: find.text('测试服务商 / 一个很长的多模态模型名称'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(modelTap).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });
}
