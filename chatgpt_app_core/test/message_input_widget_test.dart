import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  Future<void> mountPickerInput(
    WidgetTester tester, {
    required bool anime,
    required Widget Function(StateSetter setState) builder,
  }) async {
    final provider = ThemeProvider();
    if (anime) provider.setVisualStyle(AppVisualStyle.anime);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(
        theme: provider.getTheme(),
        themeAnimationDuration: Duration.zero,
        home: StatefulBuilder(builder: (context, setState) {
          return Scaffold(body: builder(setState));
        }),
      ),
    ));
  }

  const filePickerChannel =
      MethodChannel('miguelruivo.flutter.plugins.filepicker');
  const imagePickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  void mockPicker(WidgetTester tester, MethodChannel channel,
      Future<Object?> Function(MethodCall call) handler) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
  }

  Future<void> pickFromGallery(WidgetTester tester, bool anime) async {
    await tester.tap(anime
        ? find.byTooltip('添加图片')
        : find.byIcon(Icons.add_photo_alternate));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();
  }

  for (final anime in [false, true]) {
    final style = anime ? '二次元' : '经典';
    final fileButton =
        anime ? find.byTooltip('添加文件') : find.byIcon(Icons.attach_file);

    testWidgets('$style：500个文件使用有界水平懒加载列表，不撑高输入区域', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending =
          List.generate(500, (index) => '/tmp/long-attachment-$index.txt');
      await mountPickerInput(tester,
          anime: anime,
          builder: (_) => Align(
              alignment: Alignment.bottomCenter,
              child: MessageInputWidget('请输入',
                  pendingFiles: pending,
                  onFilesPicked: (_) {},
                  onRemoveFile: (_) {},
                  speechInputEnabled: false)));
      final input = find.byType(MessageInputWidget);
      final list = find.descendant(of: input, matching: find.byType(ListView));
      expect(list, findsOneWidget);
      expect(tester.widget<ListView>(list).scrollDirection, Axis.horizontal);
      expect(tester.getSize(input).height, lessThan(300));
      expect(find.byIcon(Icons.close).evaluate().length, lessThan(30));
      expect(tester.widget<MessageInputWidget>(input).pendingFiles, pending);
      await tester.drag(list, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      final scrollable =
          find.descendant(of: list, matching: find.byType(Scrollable));
      expect(tester.state<ScrollableState>(scrollable).position.pixels,
          greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：选择超过10个文件全部保留、路径去重，取消和发送拒绝保留草稿', (tester) async {
      final controller = TextEditingController(text: '保留这一轮草稿');
      addTearDown(controller.dispose);
      var pending = List.generate(10, (index) => '/tmp/old-$index.txt');
      final incoming = List.generate(12, (index) => '/tmp/new-$index.txt');
      final original = [...pending];
      var picks = 0;
      var delivered = 0;
      var sent = 0;
      mockPicker(tester, filePickerChannel, (call) async {
        expect(call.method, 'custom');
        expect((call.arguments as Map)['allowMultipleSelection'], isTrue);
        expect((call.arguments as Map)['withData'], isFalse);
        if (picks++ > 0) return null;
        return [
          for (final path in [original.first, ...incoming, incoming.first])
            {'path': path, 'name': path.split('/').last, 'size': 1},
          {'path': null, 'name': 'no-path.txt', 'size': 1},
        ];
      });
      await mountPickerInput(tester,
          anime: anime,
          builder: (setState) => MessageInputWidget('请输入',
              controller: controller,
              speechInputEnabled: false,
              pendingFiles: pending,
              onFilesPicked: (paths) {
                delivered++;
                setState(() => pending = paths);
              },
              onRemoveFile: (_) {},
              canSend: () => false,
              onSend: () => sent++));

      await tester.tap(fileButton);
      await tester.pumpAndSettle();
      expect(pending, [...original, ...incoming]);
      expect(delivered, 1);
      await tester.tap(fileButton);
      await tester.pumpAndSettle();
      expect(pending, [...original, ...incoming]);
      expect(delivered, 1);
      await tester.tap(anime
          ? find.byKey(const ValueKey('anime_message_send'))
          : find.byIcon(Icons.send));
      await tester.pump();
      expect(sent, 0);
      expect(controller.text, '保留这一轮草稿');
      expect(pending.length, 22);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：超过4张图片继续选择全部保留，取消不会删除已有图片', (tester) async {
      late Directory directory;
      // 真实文件 I/O 在 FakeAsync 外完成，否则原生 Future 不会随 pump 推进。
      final allPaths = (await tester.runAsync(() async {
        directory =
            await Directory.systemTemp.createTemp('unlimited-image-picker-');
        final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8ioAAAAASUVORK5CYII=');
        final paths = <String>[];
        for (var index = 0; index < 9; index++) {
          final file = File('${directory.path}/image-$index.png');
          await file.writeAsBytes(bytes);
          paths.add(file.path);
        }
        return paths;
      }))!;
      addTearDown(() => directory.delete(recursive: true));
      var pending = allPaths.take(4).toList();
      var pickIndex = 4;
      var delivered = 0;
      mockPicker(tester, imagePickerChannel, (call) async {
        expect(call.method, 'pickImage');
        return pickIndex < allPaths.length ? allPaths[pickIndex++] : null;
      });
      await mountPickerInput(tester,
          anime: anime,
          builder: (setState) => MessageInputWidget('请输入',
                  speechInputEnabled: false,
                  pendingImages: pending, onImagesPicked: (paths) {
                delivered++;
                setState(() => pending = paths);
              }, onRemoveImage: (_) {}));
      for (var index = 0; index < 5; index++) {
        await pickFromGallery(tester, anime);
      }
      expect(pending, allPaths);
      expect(delivered, 5);
      await pickFromGallery(tester, anime);
      expect(pending, allPaths);
      expect(delivered, 5);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：文件选择未返回时编辑锁往返，不接入过期结果且保留草稿', (tester) async {
      final selected = Completer<Object?>();
      final controller = TextEditingController(text: '发送中的原草稿');
      addTearDown(controller.dispose);
      var editing = true;
      var delivered = 0;
      late StateSetter update;
      const pending = ['/tmp/existing.txt'];
      mockPicker(tester, filePickerChannel, (call) => selected.future);
      await mountPickerInput(tester, anime: anime, builder: (setState) {
        update = setState;
        return MessageInputWidget('请输入',
            controller: controller,
            speechInputEnabled: false,
            editingEnabled: editing,
            pendingFiles: pending,
            onFilesPicked: (_) => delivered++,
            onRemoveFile: (_) {});
      });
      await tester.tap(fileButton);
      await tester.pump();
      update(() => editing = false);
      await tester.pump();
      update(() => editing = true);
      await tester.pump();
      selected.complete([
        {'path': '/tmp/stale.txt', 'name': 'stale.txt', 'size': 1}
      ]);
      await tester.pumpAndSettle();
      expect(delivered, 0);
      expect(controller.text, '发送中的原草稿');
      expect(
          tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .pendingFiles,
          pending);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：相册未返回时编辑锁往返，不接入过期图片且保留草稿', (tester) async {
      final selected = Completer<Object?>();
      final controller = TextEditingController(text: '等待图片时的草稿');
      addTearDown(controller.dispose);
      var editing = true;
      var delivered = 0;
      late StateSetter update;
      mockPicker(tester, imagePickerChannel, (call) => selected.future);
      await mountPickerInput(tester, anime: anime, builder: (setState) {
        update = setState;
        return MessageInputWidget('请输入',
            controller: controller,
            speechInputEnabled: false,
            editingEnabled: editing,
            onImagesPicked: (_) => delivered++);
      });
      await pickFromGallery(tester, anime);
      update(() => editing = false);
      await tester.pump();
      update(() => editing = true);
      await tester.pump();
      selected.complete('/tmp/stale-image.png');
      await tester.pumpAndSettle();
      expect(delivered, 0);
      expect(controller.text, '等待图片时的草稿');
      expect(
          tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .pendingImages,
          isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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

  testWidgets('发送闸门拒绝时保留输入且不调用 onSend', (tester) async {
    final controller = TextEditingController(text: '请保留这段输入');
    addTearDown(controller.dispose);
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
              canSend: () => false,
              onSend: () => sent++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(sent, 0);
    expect(controller.text, '请保留这段输入');
    expect(find.text('请保留这段输入'), findsOneWidget);
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
