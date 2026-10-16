import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'support/fake_composer_chat.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';

import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
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
  late ConversationGenerationService generation;
  WidgetTester? activeTester;
  late DatabaseFactory? previousFactory;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

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
    for (var attempt = 0; attempt < 400 && !finished; attempt++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(finished, isTrue, reason: '页面 fake clock 与文件 I/O 必须共同推进');
    if (failure != null) throw failure!;
    return value as T;
  }

  void pageTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        // 在test自身fake clock仍可pump时结算；tearDown不再推进已结束测试。
        await finishFuture(
            tester,
            Future.wait(generation.runs
                .where((r) => !r.retired)
                .map((r) => r.retire('legacy fixture completion'))));
        expect(generation.runs.every((r) => r.ticket.released), isTrue);
      }
    });
  }

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    LoginDao.resetHooksForTest();
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
      storage: _GuestStorage(),
      onLogoutNavigate: () {},
    ));
    final ai = AISettings.defaults();
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor('guest'), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    theme = ThemeProvider();
    storage = await HiDBManager.instance(dbName: 'guest');
    generation = ConversationGenerationService(observeApplication: false);
  });

  Future<void> cleanup() async {
    final tester = activeTester;
    if (tester != null) {
      await Future.wait(generation.runs
              .where((r) => !r.retired)
              .map((r) => r.retire('legacy fixture completion')))
          .timeout(const Duration(seconds: 8));
      expect(generation.runs.every((r) => r.ticket.released), isTrue);
    }
    generation.dispose();
    activeTester = null;
    LoginDao.resetHooksForTest();
    await HiDBManager.closeAll();
    settings.dispose();
    theme.dispose();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    databaseFactory = previousFactory;
    await temporary.delete(recursive: true);
  }

  tearDown(() async {
    final tester = activeTester;
    if (tester == null) {
      await cleanup();
    } else {
      final cleaned = await tester.runAsync(() async {
        await cleanup().timeout(const Duration(seconds: 10));
        return true;
      });
      expect(cleaned, isTrue, reason: '失败路径也必须结算原run并释放票据');
    }
  });

  Future<void> openPage(WidgetTester tester, ConversationModel model,
      {FakeComposerChat? chat,
      ConversationDraftStore? draftStore,
      ValueChanged<Object>? onPreparationError}) async {
    activeTester = tester;
    await tester.runAsync(() => tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
            ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ],
          child: MaterialApp(
            home: ConversationPage(
              key: ValueKey('conversation_${model.cid}'),
              conversationModel: model,
              generationService: generation,
              readAloudService: const NoopReadAloudService(),
              chatService: chat,
              draftStore: draftStore,
              onSendPreparationError: onPreparationError,
            ),
          ),
        )));
    for (var attempt = 0; attempt < 40; attempt++) {
      await letIoFinish(tester, rounds: 1);
      if (tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .enable) {
        break;
      }
    }
    await letIoFinish(tester);
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
      {int maxChars = 1000000}) async {
    final ai = settings.settings.clone()
      ..mode = AIMode.local
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

  for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
    for (final change in ['selection', 'composing', 'text']) {
      pageTest('${style.name}：冻结等待中 $change 保留点击快照与后续新草稿', (tester) async {
        await configureFixture(tester);
        theme.setVisualStyle(style);
        final reference = await savedSource(tester, '合成冻结正文');
        final gate = _GateDraftStore(temporary);
        final oldOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = (await tester
            .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
        var lists = 0;
        await tester.runAsync(() async {
          server.listen((request) async {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            if (body['method'] == 'notifications/initialized') {
              request.response.statusCode = 202;
            } else {
              if (body['method'] == 'tools/list') {
                lists++;
                // run-owned准备现在直接冻结值；保留旧真实草稿冻结校验，
                // 同时由实际目录HTTP响应挂住新准备入口（不调用任何工具）。
                await gate.freezeForSend(text: '原始草稿', references: [reference]);
              }
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': body['method'] == 'initialize'
                    ? {
                        'protocolVersion': '2024-11-05',
                        'capabilities': {'tools': {}},
                        'serverInfo': {'name': 'fixture', 'version': '1'}
                      }
                    : {'tools': []}
              }));
            }
            await request.response.close();
          });
          await settings.update(settings.settings.clone()
            ..streamEnabled = true
            ..mcpServers = [
              McpServerConfig(
                  id: 'fixture',
                  name: 'fixture',
                  url: 'http://127.0.0.1:${server.port}/',
                  trusted: true)
            ]);
        });
        try {
          final errors = <Object>[];
          final fake = FakeComposerChat(content: '离线回复');
          await openPage(tester, conversation(920),
              chat: fake, draftStore: gate, onPreparationError: errors.add);
          final input = tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget));
          input.onReferencePicked!(reference);
          await tester.enterText(find.byType(TextField).last, '原始草稿');
          late Future<void> sending;
          await tester.runAsync(() async {
            sending = Future<void>.value(tester
                .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                .onSend!());
          });
          final run = generation.lookup('guest', 920)!;
          // 入口只提交run；真实冻结和收尾都必须属于这次点击的同一对象。
          await finishFuture(tester, gate.frozen.future);
          expect(run.acceptedUser, isNull);
          expect(errors, isEmpty);
          expect(generation.lookup('guest', 920), same(run));
          final controller = input.controller!;
          controller.value = switch (change) {
            'selection' => controller.value
                .copyWith(selection: const TextSelection.collapsed(offset: 1)),
            'composing' => controller.value
                .copyWith(composing: const TextRange(start: 0, end: 1)),
            _ => const TextEditingValue(
                text: '真实新正文', selection: TextSelection.collapsed(offset: 5)),
          };
          await tester.pump();
          gate.release.complete();
          await finishFuture(tester, sending);
          await finishFuture(tester, run.finished);
          await letIoFinish(tester);
          expect(fake.calls, 1);
          expect(fake.prompts.single, '原始草稿');
          expect(
              fake.attachmentsReceived.single!.extraText, contains('合成冻结正文'));
          expect(errors, isEmpty);
          if (change == 'text') {
            expect(controller.text, '真实新正文');
            final newerDraft = await finishFuture(tester, draftFor(920).load());
            expect(newerDraft!.text, '真实新正文');
            expect(
                tester
                    .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                    .references,
                hasLength(1));
          } else {
            expect(errors, isEmpty);
            expect(fake.calls, 1);
            expect(fake.prompts.single, '原始草稿');
            expect(
                fake.attachmentsReceived.single!.extraText, contains('合成冻结正文'));
          }
          expect(lists, 1);
          await closePage(tester);
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
          await tester.runAsync(() async {
            await Future.wait(generation.runs
                .where((r) => !r.retired)
                .map((r) => r.retire('freeze fixture cleanup')));
            await server.close(force: true);
          });
          HttpOverrides.global = oldOverrides;
        }
      });
    }
  }

  pageTest('纯历史引用可发送，来源删除后重开上下文与重新生成使用相同快照', (tester) async {
    await configureFixture(tester);
    final reference = await savedSource(tester, '所选完整历史资料：冻结事实A');
    final model = conversation(901);
    final chat = FakeComposerChat(content: '离线模拟回答');
    await openPage(tester, model, chat: chat);
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onReferencePicked!(reference);
    await tester.pump();
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    await finishFuture(tester, generation.lookup('guest', 901)!.finished);
    expect(chat.calls, 1);
    expect(chat.attachmentsReceived.single!.extraText, contains('冻结事实A'));
    expect(chat.attachmentsReceived.single!.extraText,
        isNot(contains(reference.historySnapshot!.accountToken)));
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .references,
        isEmpty);
    final rows = (await tester.runAsync(() => storage.db.query('tb_messages',
        where: 'cid = ?', whereArgs: [901], orderBy: 'id')))!;
    expect(rows, hasLength(2));
    final blocks = MessageBlock.decodeList(rows.first['blocks'] as String?);
    expect(
        blocks
            .whereType<ReferenceBlock>()
            .single
            .reference
            .historySnapshot!
            .content,
        reference.historySnapshot!.content);
    await closePage(tester);
    await tester.runAsync(() =>
        storage.db.delete('tb_messages', where: 'cid = ?', whereArgs: [900]));
    await openPage(tester, model, chat: chat);
    final chatList = tester.widget<ChatList>(find.byType(ChatList));
    chatList.onBubbleLongPress!(
        chatList.chatController.initialMessageList.first,
        tester.element(find.text('离线模拟回答').first));
    await tester.pumpAndSettle();
    final firstRun = generation.lookup('guest', 901)!;
    await tester.runAsync(() => tester.tap(find.text('重新生成')));
    final retryRun = generation.lookup('guest', 901)!;
    expect(retryRun, isNot(same(firstRun)));
    expect(retryRun.input.existingUserRowId, isNotNull);
    await finishFuture(tester, retryRun.finished);
    await letIoFinish(tester);
    expect(chat.calls, 2);
    expect(chat.attachmentsReceived.last!.extraText,
        chat.attachmentsReceived.first!.extraText);
    await tester.enterText(find.byType(TextField), '继续讨论');
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    await finishFuture(tester, generation.lookup('guest', 901)!.finished);
    expect(chat.calls, 3);
    expect(chat.histories.last.toString(), contains('冻结事实A'));
    await closePage(tester);
  });

  pageTest('预算降低后重生成不请求模型，保留已有提问和回复', (tester) async {
    await configureFixture(tester);
    final reference = await savedSource(tester, '文' * 1200);
    final model = conversation(904);
    final chat = FakeComposerChat(content: '离线答复保留');
    await openPage(tester, model, chat: chat);
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onReferencePicked!(reference);
    await tester.pump();
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    await finishFuture(tester, generation.lookup('guest', 904)!.finished);
    expect(chat.calls, 1);
    final before = await tester.runAsync(() => storage.db.query('tb_messages',
        where: 'cid = ?', whereArgs: [904], orderBy: 'id'));
    await configureFixture(tester, maxChars: 1024);
    final list = tester.widget<ChatList>(find.byType(ChatList));
    list.onBubbleLongPress!(list.chatController.initialMessageList.first,
        tester.element(find.text('离线答复保留').first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新生成'));
    await letIoFinish(tester);
    expect(chat.calls, 1);
    expect(
        await tester.runAsync(() => storage.db.query('tb_messages',
            where: 'cid = ?', whereArgs: [904], orderBy: 'id')),
        before);
    expect(find.text('离线答复保留'), findsWidgets);
    await closePage(tester);
  });

  pageTest('超过草稿128K字符的普通发送仍按配置进入既有请求', (tester) async {
    await configureFixture(tester);
    final chat = FakeComposerChat(content: '大正文已发送');
    await openPage(tester, conversation(907), chat: chat);
    final text = 'A' * (ConversationDraftStore.maxTextCharacters + 1);
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInputWidget),
            matching: find.byType(TextField)),
        text);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    await finishFuture(tester, generation.lookup('guest', 907)!.finished);
    expect(chat.calls, 1);
    expect(chat.prompts.single.length, text.length);
    expect(chat.prompts.single == text, isTrue);
    await closePage(tester);
  });

  pageTest('350ms内修改文字加历史引用后立即预览，未发送未dispose也保存最新草稿', (tester) async {
    await configureFixture(tester);
    final original = await tester.runAsync(() =>
        File('${temporary.path}/preview-save.txt').writeAsString('预览文件冻结正文'));
    final initial = await tester.runAsync(() => draftFor(908).save(
            text: '旧文字',
            files: [
              original!.path
            ],
            references: [
              ComposerReference.attachment(original.path, photo: false)
            ]));
    final history = await savedSource(tester, '新加入的历史正文');
    final chat = FakeComposerChat();
    await openPage(tester, conversation(908), chat: chat);
    final fakeTime = tester.binding.clock.now();
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInputWidget),
            matching: find.byType(TextField)),
        '最新文字');
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onReferencePicked!(history);
    await tester.pump();
    final input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    await tester.runAsync(() async {
      unawaited(input.onPreviewReference!(input.references
          .firstWhere((r) => r.kind == ComposerReferenceKind.file)));
    });
    for (var i = 0; i < 30 && find.byTooltip('关闭').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(); // 不推进350ms防抖，磁盘保存必须由预览流程完成。
    }
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(tester.binding.clock.now(), fakeTime);
    await tester.runAsync(() => draftFor(908).whenIdle());
    final saved = await tester.runAsync(() => draftFor(908).load());
    expect(chat.calls, 0);
    expect(find.byType(ConversationPage), findsOneWidget,
        reason: '断言前不dispose、不发送、不再次编辑');
    expect(saved!.text, '最新文字');
    expect(saved.references, hasLength(2));
    expect(
        saved.references
            .firstWhere((r) => r.kind == ComposerReferenceKind.file)
            .snapshotDigest,
        initial!.references.single.snapshotDigest);
    expect(
        saved.references
            .firstWhere((r) => r.kind == ComposerReferenceKind.historyMessage)
            .toJson(),
        history.toJson());
    expect(
        await tester
            .runAsync(() => File(saved.filePaths.single).readAsString()),
        '预览文件冻结正文');
    // 前面的断言已证明没有推进防抖；只在验收结束后等待弹层进入再关闭。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('关闭'));
    await closePage(tester);
  });

  for (final damage in ['删除', '摘要不符']) {
    pageTest('附件$damage导致立即预览失败，未发送未dispose仍保存最新文字和不可用标签', (tester) async {
      await configureFixture(tester);
      const cid = 910;
      final original = await tester.runAsync(() =>
          File('${temporary.path}/preview-failure.txt')
              .writeAsString('原始冻结正文'));
      final initial = await tester.runAsync(() => draftFor(cid).save(
              text: '旧文字',
              files: [
                original!.path
              ],
              references: [
                ComposerReference.attachment(original.path, photo: false)
              ]));
      final chat = FakeComposerChat();
      await openPage(tester, conversation(cid), chat: chat);
      final managed = File(initial!.filePaths.single);
      await tester.runAsync(() async {
        if (damage == '删除') {
          await managed.delete();
        } else {
          await managed.writeAsString('篡改后的正文');
        }
      });
      final fakeTime = tester.binding.clock.now();
      await tester.enterText(
          find.descendant(
              of: find.byType(MessageInputWidget),
              matching: find.byType(TextField)),
          '预览失败前的最新文字');
      await tester.pump();
      final input =
          tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
      await tester
          .runAsync(() => input.onPreviewReference!(input.references.single));
      await tester.pump();
      expect(tester.binding.clock.now(), fakeTime,
          reason: '失败分支直接保存，不依赖350ms防抖');
      await tester.runAsync(() => draftFor(cid).whenIdle());
      final saved = await tester.runAsync(() => draftFor(cid).load());
      expect(chat.calls, 0);
      expect(find.byType(ConversationPage), findsOneWidget,
          reason: '读存储前不发送、不dispose、不再次编辑');
      expect(saved!.text, '预览失败前的最新文字');
      expect(saved.filePaths, isEmpty);
      expect(saved.references, hasLength(1));
      expect(saved.references.single.toJson(),
          initial.references.single.asUnavailable().toJson());
      expect(find.textContaining('引用无法冻结或已合并'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsNothing);
      await closePage(tester);
    });
  }

  pageTest('失败预览的草稿保存也失败时明确提示，零模型调用并保留不可用标签', (tester) async {
    await configureFixture(tester);
    final original = await tester.runAsync(() =>
        File('${temporary.path}/preview-save-failure.txt')
            .writeAsString('旧正文'));
    final initial = await tester.runAsync(() => draftFor(911).save(
            text: '旧文字',
            files: [
              original!.path
            ],
            references: [
              ComposerReference.attachment(original.path, photo: false)
            ]));
    final chat = FakeComposerChat();
    await openPage(tester, conversation(911), chat: chat);
    await tester.runAsync(() => File(initial!.filePaths.single).delete());
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInputWidget),
            matching: find.byType(TextField)),
        'A' * (ConversationDraftStore.maxTextCharacters + 1));
    await tester.pump();
    final input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    await tester
        .runAsync(() => input.onPreviewReference!(input.references.single));
    await tester.pump();
    expect(chat.calls, 0);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .references
            .single
            .available,
        isFalse);
    expect(find.textContaining('草稿未能保存'), findsWidgets);
    await closePage(tester);
  });

  pageTest('预览保存超过草稿字符容量仅提示，仍可预览并合法发送', (tester) async {
    await configureFixture(tester);
    final original = await tester.runAsync(() =>
        File('${temporary.path}/capacity-preview.txt')
            .writeAsString('容量失败仍可预览'));
    final chat = FakeComposerChat(content: '已发送');
    await openPage(tester, conversation(909), chat: chat);
    await tester.runAsync(() async {
      tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onFilesPicked!([original!.path]);
      await draftFor(909).whenIdle();
    });
    final text = 'A' * (ConversationDraftStore.maxTextCharacters + 1);
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInputWidget),
            matching: find.byType(TextField)),
        text);
    final input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    await tester.runAsync(() async {
      unawaited(input.onPreviewReference!(input.references.single));
    });
    await letIoFinish(tester);
    expect(find.textContaining('容量失败仍可预览', findRichText: true), findsOneWidget);
    expect(chat.calls, 0);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .references
            .single
            .available,
        isTrue);
    await tester.tap(find.byTooltip('关闭'));
    await letIoFinish(tester);
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    await finishFuture(tester, generation.lookup('guest', 909)!.finished);
    expect(chat.calls, 1);
    expect(chat.prompts.single == text, isTrue);
    await closePage(tester);
  });

  pageTest('延迟托管期间源变化，预览和发送使用同一冻结正文；原文件删除仍可发送', (tester) async {
    await configureFixture(tester);
    final model = conversation(905);
    final chat = FakeComposerChat(content: '离线冻结验收');
    await openPage(tester, model, chat: chat);
    final original = await tester.runAsync(
        () => File('${temporary.path}/race.txt').writeAsString('选择时正文'));
    final resolver = Completer<String>();
    final started = Completer<void>();
    var held = true;
    addTearDown(() {
      held = false;
      if (!resolver.isCompleted) resolver.complete(temporary.path);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async {
      if (held) {
        if (!started.isCompleted) started.complete();
        return resolver.future;
      }
      return temporary.path;
    });
    var input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    input.onFilesPicked!([original!.path]);
    await tester.pump();
    await finishFuture(tester, started.future);
    input = tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    await tester.runAsync(() async {
      unawaited(input.onPreviewReference!(input.references.single));
      await Future<void>.delayed(const Duration(milliseconds: 15));
    });
    await tester.runAsync(() => original.writeAsString('托管冻结正文'));
    held = false;
    resolver.complete(temporary.path);
    await letIoFinish(tester, rounds: 30);
    expect(find.textContaining('托管冻结正文', findRichText: true), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' | '));
    await tester.runAsync(() => original.writeAsString('后续源变化不进入请求'));
    await tester.runAsync(original.delete);
    await tester.tap(find.byTooltip('关闭'));
    await letIoFinish(tester);
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester, rounds: 30);
    expect(chat.calls, 1);
    expect(chat.attachmentsReceived.single!.extraText, contains('托管冻结正文'));
    expect(
        chat.attachmentsReceived.single!.extraText, isNot(contains('后续源变化')));
    await closePage(tester);
  });

  pageTest('快速选择发送，托管等待中源被删除时零请求且保留不可用标签', (tester) async {
    await configureFixture(tester);
    final chat = FakeComposerChat();
    await openPage(tester, conversation(906), chat: chat);
    final original = await tester.runAsync(
        () => File('${temporary.path}/missing.txt').writeAsString('待冻结'));
    final resolver = Completer<String>();
    final started = Completer<void>();
    var held = true;
    addTearDown(() {
      held = false;
      if (!resolver.isCompleted) resolver.complete(temporary.path);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async {
      if (held) {
        if (!started.isCompleted) started.complete();
        return resolver.future;
      }
      return temporary.path;
    });
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onFilesPicked!([original!.path]);
    await tester.pump();
    await finishFuture(tester, started.future);
    final leaseEntered = Completer<void>(), leaseRelease = Completer<void>();
    late Future<void> lease;
    await tester.runAsync(() async {
      lease = LoginDao.runWithStableAccount(
          expectedAccountHash: 'guest',
          action: () async {
            leaseEntered.complete();
            await leaseRelease.future;
          });
    });
    await finishFuture(tester, leaseEntered.future);
    addTearDown(() {
      if (!leaseRelease.isCompleted) leaseRelease.complete();
    });
    await tester.runAsync(() async {
      tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    final submitted = generation.lookup('guest', 906)!;
    expect(submitted.acceptedUser, isNull);
    expect(submitted.input.user.content, isEmpty);
    await tester.runAsync(original.delete);
    held = false;
    resolver.complete(temporary.path);
    leaseRelease.complete();
    await finishFuture(tester, lease);
    await finishFuture(tester, submitted.finished);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await letIoFinish(tester, rounds: 30);
    expect(chat.calls, 0);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .references
            .single
            .available,
        isFalse);
    expect(
        await tester.runAsync(() => storage.db
            .query('tb_messages', where: 'cid = ?', whereArgs: [906])),
        isEmpty);
    await closePage(tester);
  });

  pageTest('引用字数合并预算超限与不可用引用均零请求、保留草稿', (tester) async {
    await configureFixture(tester, maxChars: 1024);
    final reference = await savedSource(tester, '文' * 1100);
    final model = conversation(902);
    final chat = FakeComposerChat();
    await openPage(tester, model, chat: chat);
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onReferencePicked!(reference);
    await tester.pump();
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    expect(chat.calls, 0);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .references,
        hasLength(1));
    expect((await finishFuture(tester, draftFor(902).load()))!.references,
        hasLength(1));
    expect(
        await tester.runAsync(() => storage.db
            .query('tb_messages', where: 'cid = ?', whereArgs: [902])),
        isEmpty);
    await closePage(tester);
    await finishFuture(
        tester,
        draftFor(902).save(
            text: '',
            references: [ComposerReference.unavailable('missing', '已失效附件')]));
    await openPage(tester, model, chat: chat);
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onSend!();
    await tester.pump();
    expect(chat.calls, 0);
    expect(find.textContaining('有不可用引用'), findsOneWidget);
    await closePage(tester);
  });

  pageTest('用户消息落库失败保留历史引用快照且不请求模型', (tester) async {
    await configureFixture(tester);
    final reference = await savedSource(tester, '入库失败仍须保留的快照');
    final model = conversation(903);
    final chat = FakeComposerChat();
    await openPage(tester, model, chat: chat);
    await tester.runAsync(() => storage.db.execute(
        "create trigger fixture_insert_failure before insert on tb_messages when new.cid = 903 begin select raise(ABORT, 'fixture storage failure'); end"));
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onReferencePicked!(reference);
    await tester.pump();
    await tester.runAsync(() async {
      await tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
    });
    await letIoFinish(tester);
    expect(chat.calls, 0);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .references
            .single
            .sourceIdentity,
        reference.sourceIdentity);
    expect(
        await tester.runAsync(() => storage.db
            .query('tb_messages', where: 'cid = ?', whereArgs: [903])),
        isEmpty);
    await closePage(tester);
  });
}

final class _GuestStorage implements TokenStorage {
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
  Map<String, dynamic>? readProfileSync() => Map.of(profile);
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

class _GateDraftStore extends ConversationDraftStore {
  final frozen = Completer<void>();
  final release = Completer<void>();
  _GateDraftStore(Directory directory)
      : super(
            conversationId: '920',
            accountHash: 'guest',
            directoryResolver: () async => directory);

  @override
  Future<FrozenComposerDraft?> freezeForSend(
      {required String text,
      List<String> images = const [],
      List<String> files = const [],
      List<ComposerReference> references = const [],
      AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    final result = await super.freezeForSend(
        text: text,
        images: images,
        files: files,
        references: references,
        limits: limits);
    expect(result, isNotNull, reason: '挂起前必须已取得真实冻结快照');
    expect(result!.missingAttachmentCount, 0);
    expect(result.references, hasLength(1));
    expect(result.references.every((reference) => reference.available), isTrue);
    frozen.complete();
    await release.future;
    return result;
  }
}
