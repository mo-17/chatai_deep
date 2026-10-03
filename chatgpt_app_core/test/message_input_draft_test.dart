import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory attachmentRoot;
  late String imagePath;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    attachmentRoot =
        await Directory.systemTemp.createTemp('message_input_draft_');
    imagePath = '${attachmentRoot.path}/preview.png';
    await File(imagePath).writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8ioAAAAASUVORK5CYII='));
  });
  tearDown(() => attachmentRoot.delete(recursive: true));

  for (final anime in [false, true]) {
    final style = anime ? '二次元' : '经典';
    Future<void> mount(WidgetTester tester, MessageInputWidget input) async {
      final theme = ThemeProvider();
      if (anime) theme.setVisualStyle(AppVisualStyle.anime);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
          theme: theme.getTheme(),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(body: input),
        ),
      ));
    }

    Finder sendButton() => anime
        ? find.byKey(const ValueKey('anime_message_send'))
        : find.byIcon(Icons.send);

    testWidgets('$style：默认旧调用发送后立即清空，回调先获得原文本', (tester) async {
      final controller = TextEditingController(text: '旧行为');
      addTearDown(controller.dispose);
      var sentText = '';
      var changed = '';
      await mount(
          tester,
          MessageInputWidget(
            '请输入',
            controller: controller,
            speechInputEnabled: false,
            onChanged: (text) => changed = text,
            onSend: () => sentText = controller.text,
          ));
      await tester.tap(sendButton());
      expect(sentText, '旧行为');
      expect(controller.text, isEmpty);
      expect(changed, isEmpty);
      await tester.pump();
      expect(find.text('旧行为'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：clearOnSend=false 保留异步待发送文字，由外部确认后清空', (tester) async {
      final controller = TextEditingController(text: '尚未完成持久化');
      addTearDown(controller.dispose);
      final accepted = Completer<void>();
      var sent = 0;
      var changed = '';
      Future<void> acceptAndClear() async {
        await accepted.future;
        controller.clear();
      }

      await mount(
          tester,
          MessageInputWidget(
            '请输入',
            controller: controller,
            speechInputEnabled: false,
            clearOnSend: false,
            onChanged: (text) => changed = text,
            onSend: () {
              sent++;
              unawaited(acceptAndClear());
            },
          ));
      await tester.tap(sendButton());
      await tester.pump();
      expect(sent, 1);
      expect(controller.text, '尚未完成持久化');
      expect(changed, '尚未完成持久化');
      expect(find.text('尚未完成持久化'), findsOneWidget);
      accepted.complete();
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(changed, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：发送闸门拒绝时即使默认清空配置也保留文字', (tester) async {
      final controller = TextEditingController(text: '保留输入');
      addTearDown(controller.dispose);
      var sent = 0;
      await mount(
          tester,
          MessageInputWidget(
            '请输入',
            controller: controller,
            speechInputEnabled: false,
            canSend: () => false,
            onSend: () => sent++,
          ));
      await tester.tap(sendButton());
      await tester.pump();
      expect(sent, 0);
      expect(controller.text, '保留输入');
      final field = tester.widget<TextField>(find.byType(TextField));
      field.onSubmitted?.call(controller.text);
      await tester.pump();
      expect(sent, 0);
      expect(controller.text, '保留输入');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：enable=false 按钮和键盘提交均不会清空草稿', (tester) async {
      final controller = TextEditingController(text: '禁用时保留输入');
      addTearDown(controller.dispose);
      var sent = 0;
      await mount(
          tester,
          MessageInputWidget(
            '请输入',
            controller: controller,
            speechInputEnabled: false,
            enable: false,
            onSend: () => sent++,
          ));
      await tester.tap(sendButton());
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      field.onSubmitted?.call(controller.text);
      await tester.pump();
      expect(sent, 0);
      expect(controller.text, '禁用时保留输入');
      expect(find.text('禁用时保留输入'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：仅文件附件也显示发送按钮，异步策略保留待发送附件', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var sent = 0;
      var removed = 0;
      await mount(
          tester,
          MessageInputWidget('请输入',
              controller: controller,
              speechInputEnabled: false,
              clearOnSend: false,
              pendingFiles: const ['/tmp/only-file.txt'],
              onRemoveFile: (_) => removed++,
              onSend: () => sent++));
      expect(sendButton(), findsOneWidget);
      await tester.tap(sendButton());
      await tester.pump();
      expect(sent, 1);
      expect(removed, 0);
      expect(controller.text, isEmpty);
      expect(find.text('only-file.txt'), findsOneWidget);
      expect(
          tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .pendingFiles,
          ['/tmp/only-file.txt']);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：编辑锁保护文字及附件操作，停止按钮仍可触发', (tester) async {
      final controller = TextEditingController(text: '准备中的草稿');
      addTearDown(controller.dispose);
      final actions = <String>[];
      var stopped = 0;
      await mount(
          tester,
          MessageInputWidget(
            '请输入',
            controller: controller,
            editingEnabled: false,
            isStreaming: true,
            speechInputEnabled: true,
            clearOnSend: false,
            pendingImages: [imagePath],
            pendingFiles: const ['/tmp/note.txt'],
            onImagesPicked: (_) => actions.add('pickImage'),
            onFilesPicked: (_) => actions.add('pickFile'),
            onRemoveImage: (_) => actions.add('removeImage'),
            onRemoveFile: (_) => actions.add('removeFile'),
            modelLabel: '测试模型',
            onModelTap: () => actions.add('model'),
            showWebSearch: true,
            onToggleWebSearch: () => actions.add('search'),
            onSend: () => actions.add('send'),
            onStop: () => stopped++,
          ));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      field.onSubmitted?.call('尝试提交');
      await tester.tap(find.text('测试模型'));
      if (anime) {
        for (final tooltip in [
          '添加图片',
          '添加文件',
          '语音输入',
          '开启联网搜索',
          '移除图片',
          '移除文件'
        ]) {
          await tester.tap(find.byTooltip(tooltip));
        }
        await tester.tap(find.byKey(const ValueKey('anime_message_send')));
      } else {
        for (final icon in [
          Icons.add_photo_alternate,
          Icons.attach_file,
          Icons.mic_none,
          Icons.travel_explore
        ]) {
          await tester.tap(find.byIcon(icon));
        }
        for (final close in find.byIcon(Icons.close).evaluate().toList()) {
          await tester.tap(find.byWidget(close.widget));
        }
        await tester.tap(find.byIcon(Icons.stop));
      }
      await tester.pump();
      expect(stopped, 1);
      expect(actions, isEmpty);
      expect(controller.text, '准备中的草稿');
      expect(find.text('拍照'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style：编辑锁切换后恢复输入，默认enable=false仍保留旧的可编辑行为', (tester) async {
      final controller = TextEditingController(text: '草稿');
      addTearDown(controller.dispose);
      var locked = false;
      late StateSetter update;
      final theme = ThemeProvider();
      if (anime) theme.setVisualStyle(AppVisualStyle.anime);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(home: StatefulBuilder(builder: (context, setState) {
          update = setState;
          return Scaffold(
              body: MessageInputWidget('请输入',
                  controller: controller,
                  speechInputEnabled: false,
                  enable: false,
                  editingEnabled: !locked));
        })),
      ));
      expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
      update(() => locked = true);
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(controller.text, '草稿');
      update(() => locked = false);
      await tester.pump();
      expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
      await tester.enterText(find.byType(TextField), '继续输入');
      expect(controller.text, '继续输入');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
