import 'dart:async';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/pages/personal_memory_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

class _GatedMemory implements IPersonalMemory {
  final PersonalMemoryDao real;
  Completer<void>? gate;
  _GatedMemory(this.real);
  @override
  Future<PersonalMemoryPreferences> preferences() => real.preferences();
  @override
  Future<PersonalMemoryPreferences> setPreferences(
          {required int revision,
          required bool enabled,
          required bool suggestionsEnabled}) =>
      real.setPreferences(
          revision: revision,
          enabled: enabled,
          suggestionsEnabled: suggestionsEnabled);
  @override
  Future<List<PersonalMemory>> list(
          {PersonalMemoryStatus? status, int page = 0}) =>
      real.list(status: status, page: page);
  @override
  Future<PersonalMemory> save(String content,
      {PersonalMemory? existing,
      PersonalMemorySource? source,
      int? expectedEpoch,
      bool confirmCandidate = false}) async {
    await gate?.future;
    return real.save(content,
        existing: existing,
        source: source,
        expectedEpoch: expectedEpoch,
        confirmCandidate: confirmCandidate);
  }

  @override
  Future<void> delete(PersonalMemory memory, {int? expectedEpoch}) =>
      real.delete(memory, expectedEpoch: expectedEpoch);
  @override
  Future<void> setStatus(PersonalMemory memory, PersonalMemoryStatus status,
          {int? expectedEpoch}) =>
      real.setStatus(memory, status, expectedEpoch: expectedEpoch);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late PersonalMemoryDao dao;
  late _GatedMemory facade;
  late PersonalMemoryTestAccount auth;
  setUp(() async {
    sqfliteFfiInit();
    auth = PersonalMemoryTestAccount('a')..install();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 7, title: '合成来源', icon: ''));
    await MessageDao.create(storage, cid: 7);
    dao = await PersonalMemoryDao.create(storage, accountHash: 'a');
    facade = _GatedMemory(dao);
  });
  tearDown(() async {
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  Future<void> io(WidgetTester tester, {int rounds = 15}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> page(WidgetTester tester, AppVisualStyle style) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: ThemeData(extensions: [
          style == AppVisualStyle.anime
              ? AppVisualTheme.anime
              : AppVisualTheme.classic
        ]),
        home: PersonalMemoryPage(dao: facade)));
    await io(tester);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 300));
    await io(tester);
  }

  Future<void> add(WidgetTester tester, String content) async {
    await tap(tester, find.byTooltip('新增个人记忆'));
    await tester.enterText(
        find.byKey(const ValueKey('personal-memory-editor')), content);
    await tap(tester, find.widgetWithText(FilledButton, '保存'));
  }

  Future<void> enable() async {
    final p = await dao.preferences();
    await dao.setPreferences(
        revision: p.revision, enabled: true, suggestionsEnabled: true);
  }

  Future<void> candidate() async {
    await enable();
    final messageDao = await MessageDao.create(storage, cid: 7);
    const text = '我希望回答简短清楚';
    await messageDao.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, content: text, createdAt: 10));
    await messageDao.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.receiver, content: '合成完成', createdAt: 11));
    final turn = (await dao.beginTurn(
        cid: 7,
        assistantId: null,
        taskMode: false,
        rawInput: text,
        startedAt: DateTime.now().millisecondsSinceEpoch))!;
    await dao.suggestAfterPersist(turn, userCreatedAt: 10, replyCreatedAt: 11);
  }

  for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
    testWidgets('$style 320pt CRUD/停用启用/明确范围和开关披露', (tester) async {
      await page(tester, style);
      expect(find.textContaining('助手、角色、故事房间和 Agent'), findsOneWidget);
      await add(tester, '合成个人回答偏好');
      expect((await tester.runAsync(dao.list))!.single.confirmedByUser, isTrue);
      await tap(tester, find.text('编辑'));
      await tester.enterText(
          find.byKey(const ValueKey('personal-memory-editor')), '编辑后的合成偏好');
      await tap(tester, find.widgetWithText(FilledButton, '保存'));
      await tap(tester, find.widgetWithText(TextButton, '停用'));
      expect((await tester.runAsync(dao.list))!.single.status,
          PersonalMemoryStatus.archived);
      await tap(tester, find.widgetWithText(TextButton, '启用'));
      expect((await tester.runAsync(dao.list))!.single.status,
          PersonalMemoryStatus.active);
      await tap(tester, find.byKey(const ValueKey('personal-memory-enabled')));
      expect(find.textContaining('当前配置的模型服务'), findsOneWidget);
      await tap(tester, find.widgetWithText(FilledButton, '确认'));
      expect((await tester.runAsync(dao.preferences))!.enabled, isTrue);
      await tap(
          tester, find.byKey(const ValueKey('personal-memory-suggestions')));
      expect(find.textContaining('固定的回答风格和语言偏好'), findsOneWidget);
      await tap(tester, find.widgetWithText(FilledButton, '确认'));
      expect(
          (await tester.runAsync(dao.preferences))!.suggestionsEnabled, isTrue);
      await tap(tester, find.text('删除'));
      await tap(tester, find.widgetWithText(FilledButton, '确认'));
      expect(await tester.runAsync(dao.list), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('候选显示具体来源/日期，编辑确认后才生效', (tester) async {
    await tester.runAsync(candidate);
    await page(tester, AppVisualStyle.classic);
    final before = (await tester.runAsync(dao.list))!.single;
    expect(find.textContaining('会话 7 · 消息 ${before.sourceMessageId}'),
        findsOneWidget);
    expect(find.textContaining('更新 '), findsOneWidget);
    await tap(tester, find.text('确认'));
    await tester.enterText(
        find.byKey(const ValueKey('personal-memory-editor')), '确认编辑后的合成偏好');
    await tap(tester, find.widgetWithText(FilledButton, '保存'));
    final saved = (await tester.runAsync(dao.list))!.single;
    expect(saved.memoryId, before.memoryId);
    expect(saved.revision, greaterThan(before.revision));
    expect(saved.status, PersonalMemoryStatus.active);
    expect(saved.confirmedByUser, isTrue);
  });
  testWidgets('CRUD实际落盘失败保留旧UI/DB；凭证在编辑器拒绝', (tester) async {
    await tester.runAsync(() => dao.save('原已保存内容'));
    await page(tester, AppVisualStyle.classic);
    await tester.runAsync(() => storage.db.execute(
        "create trigger fail_memory before update on tb_personal_memory begin select raise(abort,'synthetic failure'); end"));
    await tap(tester, find.text('编辑'));
    await tester.enterText(
        find.byKey(const ValueKey('personal-memory-editor')), '失败更新内容');
    await tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect((await tester.runAsync(dao.list))!.single.content, '原已保存内容');
    expect(find.text('原已保存内容'), findsOneWidget);
    await tap(tester, find.byTooltip('新增个人记忆'));
    await tester.enterText(find.byKey(const ValueKey('personal-memory-editor')),
        'api_key=synthetic-secret');
    await tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect(
        find.byKey(const ValueKey('personal-memory-editor')), findsOneWidget);
    expect(find.textContaining('凭证'), findsWidgets);
  });
  testWidgets('候选弹窗期间关闭再开启/restore刷新，旧确认不生效', (tester) async {
    await tester.runAsync(candidate);
    await page(tester, AppVisualStyle.classic);
    await tap(tester, find.text('确认'));
    await tester.runAsync(() async {
      final p = await dao.preferences();
      await dao.setPreferences(
          revision: p.revision, enabled: false, suggestionsEnabled: false);
      await enable();
    });
    BackupService.restoreTick.value++;
    await io(tester);
    await tap(tester, find.widgetWithText(FilledButton, '保存'));
    expect((await tester.runAsync(dao.list))!.single.status,
        PersonalMemoryStatus.archived);
  });
  testWidgets('保存等待期间切账号，旧DAO拒绝写入且UI不宣告成功', (tester) async {
    await page(tester, AppVisualStyle.classic);
    facade.gate = Completer<void>();
    await add(tester, '延迟保存合成偏好');
    auth.account = 'b';
    facade.gate!.complete();
    await io(tester);
    expect(await tester.runAsync(() => storage.db.query('tb_personal_memory')),
        isEmpty);
    expect(find.text('个人记忆已保存'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
