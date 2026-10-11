import 'dart:async';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/checklist_state_coordinator.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'interactive_card_test.dart'
    show checklistJson, comparisonJson, cardFence;
import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/ui/interactive_card_view.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'dart:convert';
import 'dart:io';
import 'support/fake_composer_chat.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';

import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late HiDBManager storage;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late _GuestStorage auth;
  String? copied;
  late DatabaseFactory? previousFactory;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    LoginDao.resetHooksForTest();
    await AgentTaskExecutor.instance.cancelAll('离线测试清理');
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') {
        return copied == null ? null : {'text': copied};
      }
      return null;
    });
    temporary = await Directory.systemTemp.createTemp('chatai_page_draft_');
    previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath('${temporary.path}/database');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => temporary.path);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    AISettingsDao.resetSecureStateForTest();
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: auth = _GuestStorage(),
      onLogoutNavigate: () {},
    ));
    final ai = AISettings.defaults();
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor('guest'), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    theme = ThemeProvider();
    storage = await HiDBManager.instance(dbName: 'guest');
  });

  tearDown(() async {
    await AgentTaskExecutor.instance.cancelAll('离线测试清理');
    LoginDao.resetHooksForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await HiDBManager.closeAll();
    settings.dispose();
    theme.dispose();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    databaseFactory = previousFactory;
    await temporary.delete(recursive: true);
  });

  Future<void> letIoFinish(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<T> finishFuture<T>(WidgetTester tester, Future<T> future) async {
    var finished = false;
    T? value;
    Object? failure;
    future.then((result) {
      value = result;
      finished = true;
    }, onError: (Object error) {
      failure = error;
      finished = true;
    });
    for (var attempt = 0; attempt < 100 && !finished; attempt++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(finished, isTrue, reason: '页面 fake clock 与文件 I/O 必须共同推进');
    if (failure != null) throw failure!;
    return value as T;
  }

  Future<void> openPage(WidgetTester tester, ConversationModel model,
      {FakeComposerChat? chat, ChecklistStateCoordinator? coordinator}) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
      ],
      child: MaterialApp(
        home: ConversationPage(
          key: ValueKey('conversation_${model.cid}'),
          conversationModel: model,
          readAloudService: const NoopReadAloudService(),
          chatService: chat,
          checklistCoordinator: coordinator,
        ),
      ),
    ));
    for (var attempt = 0; attempt < 40; attempt++) {
      await letIoFinish(tester, rounds: 1);
      if (tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .enable) {
        break;
      }
    }
    expect(tester.takeException(), isNull);
  }

  ConversationModel conversation(int cid, {String? title}) => ConversationModel(
        cid: cid,
        icon: '',
        title: title,
        speechInputEnabled: false,
      );

  ConversationDraftStore draftFor(int cid) => ConversationDraftStore(
        conversationId: '$cid',
        accountHash: 'guest',
        directoryResolver: () async => temporary,
      );

  Future<void> closePage(WidgetTester tester) async {
    await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
    // dispose 保存、发送 finally 和防抖保存必须在当前 fake clock 生命周期中收尾。
    await finishFuture(tester, draftFor(0).whenIdle());
  }

  Future<void> configureFixture(WidgetTester tester,
      {int maxChars = 1000000, bool stream = true}) async {
    final ai = settings.settings.clone()
      ..mode = AIMode.local
      ..streamEnabled = stream
      ..attachmentTotalMaxChars = maxChars
      ..activeProviderId = 'fixture'
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '离线测试',
            type: 'openai',
            enabled: true,
            apiHost: 'https://example.invalid',
            apiKey: 'fixture-key',
            selectedModelId: 'gpt-4o',
            models: [AiModel(id: 'gpt-4o')])
      ];
    await tester.runAsync(() => settings.update(ai));
  }

  Future<ComposerReference> savedSource(
          WidgetTester tester, String content) async =>
      (await tester.runAsync(() async {
        await (await ConversationListDao.create(storage))
            .saveConversation(conversation(900, title: '来源资料'));
        final dao = await MessageDao.create(storage, cid: 900);
        final id = await dao.saveMessageWithBlocks(MessageModel(
            ownerType: OwnerType.receiver, content: content, createdAt: 1));
        return ComposerReference.history(
            (await MessageReferenceDao(storage, accountHash: 'guest')
                .snapshot(id))!);
      }))!;

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = Future<void>.value(tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!());
    });
    await finishFuture(tester, sending);
    await letIoFinish(tester);
    expect(tester.takeException(), isNull);
  }

  for (final stream in [false, true]) {
    for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
      testWidgets('${style.name} ${stream ? '流式' : '非流式'} 落盘可勾选、复制、重开，状态不进入历史',
          (tester) async {
        await configureFixture(tester, stream: stream);
        theme.setVisualStyle(style);
        final model = conversation(901);
        final raw = '正文前缀\n${cardFence(checklistJson())}正文尾部';
        final fake = FakeComposerChat(content: raw);
        await openPage(tester, model, chat: fake);
        await send(tester, '请给可勾选清单');
        expect(fake.calls, 1);
        expect(
            fake.histories.single
                .where((m) => m['role'] == 'system')
                .map((m) => m['content'])
                .join(),
            contains(interactiveCardSystemPrompt.trim()));
        expect(find.byType(InteractiveCardView), findsOneWidget);
        final check = find.byType(CheckboxListTile).first;
        expect(tester.widget<CheckboxListTile>(check).onChanged, isNotNull);
        await tester.ensureVisible(check);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(check);
        await letIoFinish(tester);
        expect(tester.widget<CheckboxListTile>(check).value, isTrue);
        expect(fake.calls, 1);
        final copy = find.descendant(
            of: find.byType(InteractiveCardView), matching: find.text('复制'));
        await tester.ensureVisible(copy);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(copy);
        await tester.pump();
        final clipboard =
            await tester.runAsync(() => Clipboard.getData('text/plain'));
        expect(clipboard!.text, contains('- [x] 确认车票'));
        expect(fake.calls, 1);
        final rows = (await tester.runAsync(() => storage.db.query(
            'tb_messages',
            where: 'cid = ?',
            whereArgs: [901],
            orderBy: 'id')))!;
        expect(rows.last['content'], raw);
        final saved = MessageBlock.decodeList(rows.last['blocks'] as String)
            .whereType<MainTextBlock>()
            .single;
        expect(saved.content, raw);
        expect(saved.localCardStates.values.single.checkedItemIds, {'ticket'});
        await closePage(tester);
        await openPage(tester, model, chat: fake);
        await letIoFinish(tester);
        expect(
            tester
                .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
                .value,
            isTrue);
        expect(fake.calls, 1);
        await send(tester, '继续讨论');
        expect(fake.calls, 2);
        final history = jsonEncode(fake.histories.last);
        expect(history, isNot(contains('localCardStates')));
        expect(history, isNot(contains('checkedItemIds')));
        expect(
            fake.histories.last
                .where((m) => m['role'] == 'assistant')
                .first['content'],
            raw);
        await closePage(tester);
      });
    }
  }

  testWidgets('真实勾选事务成功返回时下一轮仍生成，UI、复制与重开接纳已保存结果', (tester) async {
    await configureFixture(tester, stream: false);
    final model = conversation(906);
    final dao =
        (await tester.runAsync(() => MessageDao.create(storage, cid: 906)))!;
    final coordinator = _DelayedChecklistCoordinator(dao);
    final fake = FakeComposerChat(content: cardFence(checklistJson()));
    await openPage(tester, model, chat: fake, coordinator: coordinator);
    await send(tester, '给我可勾选清单');
    final check = find.byType(CheckboxListTile).first;
    await tester.ensureVisible(check);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(check);
    await finishFuture(tester, coordinator.saved.future);
    expect(tester.widget<CheckboxListTile>(check).value, isFalse);
    fake.pending = Completer<ChatCompletionResult>();
    await tester.enterText(find.byType(TextField).last, '主动发送下一轮');
    late Future<dynamic> sending;
    await tester.runAsync(() async {
      sending = Future<dynamic>.value(tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!());
    });
    for (var attempt = 0; attempt < 100 && fake.calls < 2; attempt++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(fake.calls, 2);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .enable,
        isFalse);
    coordinator.release.complete();
    await letIoFinish(tester);
    expect(tester.widget<CheckboxListTile>(check).value, isTrue);
    final copy = find.descendant(
        of: find.byType(InteractiveCardView), matching: find.text('复制'));
    await tester.ensureVisible(copy);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(copy);
    await tester.pump();
    expect(copied, contains('- [x] 确认车票'));
    fake.pending!.complete(const ChatCompletionResult(content: '下一轮普通回复'));
    await finishFuture(tester, Future<void>.value(sending));
    await closePage(tester);
    await openPage(tester, model, chat: fake);
    await letIoFinish(tester);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .value,
        isTrue);
    final rows = (await tester.runAsync(() => dao.getAllMessage()))!;
    final blocks = (await tester.runAsync(() => dao.getBlocksByCreatedAt([
          rows.where((m) => m.ownerType == OwnerType.receiver).first.createdAt
        ])))!;
    expect(
        MessageBlock.decodeList(blocks.values.single)
            .whereType<MainTextBlock>()
            .single
            .localCardStates
            .values
            .single
            .checkedItemIds,
        {'ticket'});
    expect(fake.calls, 2);
    await closePage(tester);
  });

  testWidgets('任务模式已保存回复立即显示卡，额外执行器通知不覆盖勾选与协议原文', (tester) async {
    await configureFixture(tester);
    final model = conversation(907, title: '离线任务');
    await tester.runAsync(() async {
      await (await ConversationListDao.create(storage)).saveConversation(model);
      final session =
          AgentTaskSession(cid: 907, store: await AgentTaskDao.create(storage));
      await session.setEnabled(true);
      session.dispose();
    });
    final raw = '任务结论\n${cardFence(checklistJson())}';
    final fake = FakeComposerChat(content: raw);
    await openPage(tester, model, chat: fake);
    await send(tester, '任务中给出可勾选清单');
    final run =
        AgentTaskExecutor.instance.lookup(const AgentTaskKey('guest', 907))!;
    await finishFuture(tester, run.finished);
    await letIoFinish(tester);
    expect(run.phase, AgentRunPhase.complete);
    expect(run.persistedReplyRowId, isNotNull);
    expect(find.byType(InteractiveCardView), findsOneWidget);
    final check = find.byType(CheckboxListTile).first;
    expect(tester.widget<CheckboxListTile>(check).onChanged, isNotNull);
    await tester.ensureVisible(check);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(check);
    await letIoFinish(tester);
    expect(tester.widget<CheckboxListTile>(check).value, isTrue);
    final dao =
        (await tester.runAsync(() => MessageDao.create(storage, cid: 907)))!;
    final beforeMap = (await tester
        .runAsync(() => dao.getBlocksByCreatedAt([run.reply!.createdAt])))!;
    final before = MessageBlock.decodeList(beforeMap.values.single)
        .whereType<MainTextBlock>()
        .single;
    run.notifyListeners();
    AgentTaskExecutor.instance.notifyListeners();
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(check).value, isTrue);
    expect(fake.calls, 1);
    final afterMap = (await tester
        .runAsync(() => dao.getBlocksByCreatedAt([run.reply!.createdAt])))!;
    final after = MessageBlock.decodeList(afterMap.values.single)
        .whereType<MainTextBlock>()
        .single;
    expect(after.content, raw);
    expect(after.protocolMessages, before.protocolMessages);
    expect(after.localCardStates.values.single.checkedItemIds, {'ticket'});
    await closePage(tester);
    await openPage(tester, model, chat: fake);
    await letIoFinish(tester);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .value,
        isTrue);
    expect(fake.calls, 1);
    await closePage(tester);
  });

  testWidgets('插入保留草稿与 @引用，仅再次发送才把本地勾选文本加入请求', (tester) async {
    await configureFixture(tester, stream: false);
    final raw = '${cardFence(checklistJson())}${cardFence(comparisonJson())}';
    final fake = FakeComposerChat(content: raw);
    await openPage(tester, conversation(902), chat: fake);
    await send(tester, '请给清单及对比卡');
    final check = find.byType(CheckboxListTile).first;
    await tester.ensureVisible(check);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(check);
    await letIoFinish(tester);
    final reference = await savedSource(tester, '已选历史资料');
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onReferencePicked!(reference);
    await tester.enterText(find.byType(TextField).last, '现有草稿');
    await tester.pump();
    final insert = find.descendant(
        of: find.byType(InteractiveCardView).first,
        matching: find.text('插入输入框'));
    await tester.ensureVisible(insert);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(insert);
    await tester.pump();
    final input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    final exported = exportInteractiveCard(
        InteractiveCardParser.tryParseJson(jsonEncode(checklistJson()))!,
        checked: {'ticket'});
    expect(input.controller!.text, '现有草稿\n\n$exported');
    expect(
        input.controller!.selection.baseOffset, input.controller!.text.length);
    expect(input.references.single.sourceIdentity, reference.sourceIdentity);
    expect(fake.calls, 1);
    await tester.pump(const Duration(milliseconds: 400));
    await letIoFinish(tester);
    final draft = await finishFuture(tester, draftFor(902).load());
    expect(draft!.text, input.controller!.text);
    expect(draft.references.single.sourceIdentity, reference.sourceIdentity);
    await tester.runAsync(() async => await input.onSend!());
    await letIoFinish(tester);
    expect(fake.calls, 2);
    expect(fake.prompts.last, contains('- [x] 确认车票'));
    expect(fake.attachmentsReceived.last!.extraText, contains('已选历史资料'));
    await closePage(tester);
  });

  testWidgets('勾选保存失败回滚，输入锁定拒绝过期插入，切会话拒绝旧回调', (tester) async {
    await configureFixture(tester, stream: false);
    final fake = FakeComposerChat(content: cardFence(checklistJson()));
    final model = conversation(903);
    await openPage(tester, model, chat: fake);
    await send(tester, '可勾选清单');
    final oldView =
        tester.widget<InteractiveCardView>(find.byType(InteractiveCardView));
    await tester.runAsync(() => storage.db.execute(
        "create trigger reject_card before update of blocks on tb_messages begin select raise(abort, 'fixture failure'); end"));
    final check = find.byType(CheckboxListTile).first;
    await tester.ensureVisible(check);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(check);
    await letIoFinish(tester);
    expect(tester.widget<CheckboxListTile>(check).value, isFalse);
    expect(find.text('清单保存失败，已保留上次勾选状态'), findsOneWidget);
    expect(fake.calls, 1);
    fake.pending = Completer<ChatCompletionResult>();
    await tester.enterText(find.byType(TextField).last, '下一轮');
    final pendingSend = tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onSend!();
    await letIoFinish(tester);
    oldView.onInsert!('过期插入');
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .controller!
            .text,
        isNot(contains('过期插入')));
    fake.pending!.complete(const ChatCompletionResult(content: '普通回复'));
    await finishFuture(tester, Future<void>.value(pendingSend));
    await letIoFinish(tester);
    await closePage(tester);
    await openPage(tester, conversation(904), chat: fake);
    oldView.onInsert!('跨会话插入');
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .controller!
            .text,
        isEmpty);
    await closePage(tester);
  });

  testWidgets('账号切换拒绝已捕获的卡片操作，用户正文不开启卡片', (tester) async {
    await configureFixture(tester, stream: false);
    final fake = FakeComposerChat(content: cardFence(checklistJson()));
    await openPage(tester, conversation(905), chat: fake);
    await send(tester, cardFence(checklistJson()));
    expect(find.byType(InteractiveCardView), findsOneWidget);
    final view =
        tester.widget<InteractiveCardView>(find.byType(InteractiveCardView));
    final before = await tester.runAsync(() =>
        storage.db.query('tb_messages', where: 'cid = ?', whereArgs: [905]));
    auth.account = 'second-account';
    expect(view.isCurrent(), isFalse);
    view.onInsert!('跨账号插入');
    await tester.runAsync(() => view.onCheck!('ticket', true));
    expect(fake.calls, 1);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .controller!
            .text,
        isEmpty);
    expect(
        await tester.runAsync(() => storage.db
            .query('tb_messages', where: 'cid = ?', whereArgs: [905])),
        before);
    auth.account = 'guest';
    await closePage(tester);
  });
  Future<PersonalMemoryDao> personalForPage(WidgetTester tester,
          {bool suggestions = true}) async =>
      (await tester.runAsync(() async {
        final dao =
            await PersonalMemoryDao.create(storage, accountHash: 'guest');
        final prefs = await dao.preferences();
        await dao.setPreferences(
            revision: prefs.revision,
            enabled: true,
            suggestionsEnabled: suggestions);
        return dao;
      }))!;

  for (final stream in [false, true]) {
    testWidgets('个人记忆实际页面${stream ? '流式' : '非流式'}成功落盘才生成pending；重开不回扫，引用不采集',
        (tester) async {
      await configureFixture(tester, stream: stream);
      final personal = await personalForPage(tester);
      final fake = FakeComposerChat(content: '成功合成回复');
      final model = conversation(970);
      await openPage(tester, model, chat: fake);
      await send(tester, '我希望回答简短清楚');
      final candidates = (await tester.runAsync(personal.list))!;
      expect(candidates, hasLength(1));
      expect(candidates.single.status, PersonalMemoryStatus.pending);
      expect(candidates.single.content, '我希望回答简短清楚');
      final rows = (await tester
          .runAsync(() => storage.db.query('tb_messages', where: 'cid=970')))!;
      expect(rows, hasLength(2));
      expect(
          rows
              .where((r) => r['ownerType'] == OwnerType.receiver.toString())
              .single['content'],
          '成功合成回复');
      expect(fake.calls, 1);
      expect(jsonEncode(fake.histories), isNot(contains('个人记忆/')));
      await closePage(tester);
      await openPage(tester, model, chat: fake);
      expect(fake.calls, 1);
      expect((await tester.runAsync(personal.list))!.single.memoryId,
          candidates.single.memoryId);
      final reference = await savedSource(tester, '我希望回答详细');
      await tester.runAsync(() async {
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .onReferencePicked!(reference);
      });
      await send(tester, '参考这条资料');
      expect(await tester.runAsync(personal.list), hasLength(1));
      expect(fake.calls, 2);
      await closePage(tester);
    });
    testWidgets('个人记忆页面${stream ? '流式' : '非流式'}失败回复不采集', (tester) async {
      await configureFixture(tester, stream: stream);
      final personal = await personalForPage(tester);
      final fake = FakeComposerChat()..fail = true;
      await openPage(tester, conversation(971), chat: fake);
      await send(tester, '我希望回答详细');
      expect(await tester.runAsync(personal.list), isEmpty);
      expect(fake.calls, 1);
      await closePage(tester);
    });
  }
  testWidgets('个人记忆页面生成中关闭再开启使已开始轮次失效', (tester) async {
    await configureFixture(tester, stream: false);
    final personal = await personalForPage(tester);
    final fake = FakeComposerChat()
      ..pending = Completer<ChatCompletionResult>();
    await openPage(tester, conversation(972), chat: fake);
    await tester.enterText(find.byType(TextField).last, '我希望回答详细');
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = Future<void>.value(tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!());
    });
    for (var i = 0; i < 40 && fake.calls == 0; i++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(fake.calls, 1);
    await tester.runAsync(() async {
      final prefs = await personal.preferences();
      await personal.setPreferences(
          revision: prefs.revision, enabled: false, suggestionsEnabled: false);
      final disabled = await personal.preferences();
      await personal.setPreferences(
          revision: disabled.revision, enabled: true, suggestionsEnabled: true);
    });
    fake.pending!.complete(const ChatCompletionResult(content: '完成合成回复'));
    await finishFuture(tester, sending);
    expect(await tester.runAsync(personal.list), isEmpty);
    await closePage(tester);
  });
  testWidgets('个人记忆页面停止挂起回复不采集', (tester) async {
    await configureFixture(tester, stream: false);
    final personal = await personalForPage(tester);
    final fake = FakeComposerChat()
      ..pending = Completer<ChatCompletionResult>();
    await openPage(tester, conversation(973), chat: fake);
    await tester.enterText(find.byType(TextField).last, '我希望回答详细');
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = Future<void>.value(tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!());
    });
    for (var i = 0; i < 40 && fake.calls == 0; i++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(fake.calls, 1);
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onStop!();
    await letIoFinish(tester, rounds: 2);
    fake.pending!.complete(const ChatCompletionResult(content: '晚到合成回复'));
    await finishFuture(tester, sending);
    expect(await tester.runAsync(personal.list), isEmpty);
    await closePage(tester);
  });
  testWidgets('个人记忆页面助手落盘失败不采集', (tester) async {
    await configureFixture(tester, stream: false);
    final personal = await personalForPage(tester);
    final fake = FakeComposerChat(content: '未保存的合成回复');
    await openPage(tester, conversation(975), chat: fake);
    await tester.runAsync(() => storage.db.execute(
        "CREATE TRIGGER fail_assistant_insert BEFORE INSERT ON tb_messages "
        "WHEN NEW.content = '未保存的合成回复' "
        "BEGIN SELECT RAISE(ABORT, 'synthetic save failure'); END"));
    await send(tester, '我希望回答详细');
    expect(fake.calls, 1);
    expect(await tester.runAsync(personal.list), isEmpty);
    final rows = await tester.runAsync(() =>
        storage.db.query('tb_messages', where: 'cid = ?', whereArgs: [975]));
    expect(rows, hasLength(2));
    expect(rows!.where((r) => r['content'] == '未保存的合成回复'), isEmpty);
    expect(
        rows.where((r) => r['ownerType'] == 'OwnerType.sender'), hasLength(1));
    await closePage(tester);
  });
  testWidgets('个人记忆页面开启建议后重新生成旧轮次不采集', (tester) async {
    await configureFixture(tester, stream: false);
    final personal = await personalForPage(tester, suggestions: false);
    final fake = FakeComposerChat(content: '用于重新生成的合成回复');
    await openPage(tester, conversation(974), chat: fake);
    await send(tester, '我希望回答详细');
    await tester.runAsync(() async {
      final p = await personal.preferences();
      await personal.setPreferences(
          revision: p.revision, enabled: true, suggestionsEnabled: true);
    });
    final reply = find.byWidgetPredicate((widget) =>
        widget is DefaultMessageWidget &&
        widget.message.content == '用于重新生成的合成回复');
    final actions =
        find.descendant(of: reply, matching: find.byTooltip('消息操作'));
    await tester.ensureVisible(actions);
    await tester.tap(actions);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重新生成'));
    await tester.pump();
    for (var i = 0; i < 80 && fake.calls < 2; i++) {
      await letIoFinish(tester, rounds: 1);
    }
    await letIoFinish(tester);
    expect(fake.calls, 2);
    expect(await tester.runAsync(personal.list), isEmpty);
    await closePage(tester);
  });
}

class _DelayedChecklistCoordinator extends ChecklistStateCoordinator {
  final saved = Completer<void>();
  final release = Completer<void>();
  _DelayedChecklistCoordinator(MessageDao dao)
      : super(dao: dao, accountHash: 'guest', isCurrent: () => true);

  @override
  Future<ChecklistWriteResult> setChecked({
    required int createdAt,
    required String blockId,
    required String expectedContent,
    required String cardKey,
    required String itemId,
    required bool checked,
    required int expectedRowId,
    required bool Function() messageIsCurrent,
  }) async {
    // 真实事务及账号租约已完成，只延迟结果交付，不人为占住账号写入队列。
    final result = await super.setChecked(
        createdAt: createdAt,
        blockId: blockId,
        expectedContent: expectedContent,
        cardKey: cardKey,
        itemId: itemId,
        checked: checked,
        expectedRowId: expectedRowId,
        messageIsCurrent: messageIsCurrent);
    saved.complete();
    await release.future;
    return result;
  }
}

final class _GuestStorage implements TokenStorage {
  String account = 'guest';
  static const profile = <String, dynamic>{
    'userName': '游客',
    'accountHash': 'guest',
    'guest': true,
    'boardingPass': 'guest-mode',
    'avatar': '',
  };
  @override
  Future<void> clear() async {}
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() =>
      {...profile, 'accountHash': account};
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => 'guest-mode';
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}
