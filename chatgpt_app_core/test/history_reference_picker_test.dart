import 'dart:async';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/widget/message_reference_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<HiDBManager> fixture(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        final storage = HiDBManager.test(db);
        await (await ConversationListDao.create(storage)).saveConversation(
            ConversationModel(cid: 1, title: '离线资料', icon: ''));
        await (await MessageDao.create(storage, cid: 1)).saveMessageWithBlocks(
            MessageModel(
                ownerType: OwnerType.receiver,
                createdAt: 1,
                content: '完整正文${'资料' * 200}'));
        return storage;
      }))!;

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  testWidgets('实际选择器读取完整正文，过期后立即隐藏旧结果与预览', (tester) async {
    final storage = await fixture(tester);
    var current = true;
    ComposerReference? selected;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      final result =
                          await showModalBottomSheet<ComposerReference>(
                              context: context,
                              isScrollControlled: true,
                              builder: (_) => HistoryReferencePicker(
                                  dao: MessageReferenceDao(storage,
                                      accountHash: 'fixture'),
                                  isCurrent: () => current));
                      selected = result ?? selected;
                    },
                    child: const Text('选择'))))));
    await tester.tap(find.text('选择'));
    await settleIo(tester);
    await tester.tap(find.byKey(const ValueKey('history_reference_1')));
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(selected!.historySnapshot!.content.length, greaterThan(160));
    await tester.tap(find.text('选择'));
    await settleIo(tester);
    current = false;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('选择已过期，请关闭后重新打开'), findsOneWidget);
    expect(find.byKey(const ValueKey('history_reference_1')), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    current = true;
    final context = tester.element(find.text('选择'));
    unawaited(
        showReferencePreview(context, selected!, isCurrent: () => current));
    await tester.pumpAndSettle();
    expect(find.text(selected!.historySnapshot!.content), findsOneWidget);
    current = false;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('账号已切换，请关闭预览'), findsOneWidget);
    expect(find.text(selected!.historySnapshot!.content), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(storage.db.close);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择时数据库失效显示错误，异步异常不外溢', (tester) async {
    final storage = await fixture(tester);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HistoryReferencePicker(
                dao: MessageReferenceDao(storage, accountHash: 'fixture'),
                isCurrent: () => true))));
    await settleIo(tester);
    await tester.runAsync(storage.db.close);
    await tester.tap(find.byKey(const ValueKey('history_reference_1')));
    await settleIo(tester);
    expect(find.text('历史消息读取失败，请重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('任意 file/photo 引用没有托管能力时不读取或显示外部路径内容', (tester) async {
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reference-untrusted-')))!;
    final external = (await tester.runAsync(
        () => File('${dir.path}/private.txt').writeAsString('外部文件秘密标记')))!;
    for (final photo in [false, true]) {
      final reference =
          ComposerReference.attachment(external.path, photo: photo);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showReferencePreview(context, reference),
                      child: const Text('预览'))))));
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.textContaining('附件尚未托管冻结'), findsOneWidget);
      expect(find.textContaining('外部文件秘密标记'), findsNothing);
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(external.delete);
    await tester.runAsync(dir.delete);
  });
}
