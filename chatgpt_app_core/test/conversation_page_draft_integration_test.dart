import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
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
  late DatabaseFactory? previousFactory;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

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
  });

  tearDown(() async {
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
    for (var attempt = 0; attempt < 400 && !finished; attempt++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(finished, isTrue, reason: '页面 fake clock 与文件 I/O 必须共同推进');
    if (failure != null) throw failure!;
    return value as T;
  }

  Future<void> openPage(WidgetTester tester, ConversationModel model) async {
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
    // enable 先于草稿恢复开放；等待真实文件 I/O 和账号队列完成。
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

  testWidgets('详情导航迟到切账号时不显示旧标题草稿、不加载任务且可安全销毁', (tester) async {
    final model = conversation(109, title: '旧账号的私有任务标题');
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
      ],
      child: MaterialApp(
          home: ConversationPage(
        conversationModel: model,
        expectedAccountHash: 'previous-account',
        initialPrompt: '旧账号草稿内容',
        resumeAgentTask: true,
        initialTargetCreatedAt: 10,
        initialAgentTaskGeneration: 1,
        readAloudService: const NoopReadAloudService(),
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('登录或会话环境已变化，请返回并重新打开'), findsOneWidget);
    expect(find.text('旧账号的私有任务标题'), findsNothing);
    expect(find.text('旧账号草稿内容'), findsNothing);
    expect(find.byType(MessageInputWidget), findsNothing);
    final tables = await tester.runAsync(() => storage.db.rawQuery(
        "select name from sqlite_master where name='tb_agent_task_session'"));
    expect(tables, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('思考等级会话保存、重开恢复、取消保留和默认清除', (tester) async {
    final ai = settings.settings.clone()..activeProviderId = 'deepseek';
    ai.setActiveModel('deepseek-flash');
    await tester.runAsync(() => settings.update(ai));
    final model = conversation(104, title: '思考等级验收');
    await tester.runAsync(() async {
      await (await ConversationListDao.create(storage)).saveConversation(model);
    });
    await openPage(tester, model);
    expect(find.text('思考：默认'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('conversation_reasoning_effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reasoning_effort_max')));
    await letIoFinish(tester);
    expect(find.text('思考：最高'), findsOneWidget);
    expect(model.deepSeekReasoningEffort, DeepSeekReasoningEffort.max);
    expect(settings.settings.deepSeekReasoningEffort, isNull,
        reason: '会话选择不能改变其他对话的默认值');
    await tester
        .tap(find.byKey(const ValueKey('conversation_reasoning_effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.deepSeekReasoningEffort, DeepSeekReasoningEffort.max);
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
    final reloaded = await tester.runAsync(() async =>
        (await (await ConversationListDao.create(storage))
                .getConversationList())
            .single);
    expect(reloaded!.deepSeekReasoningEffort, DeepSeekReasoningEffort.max);
    await openPage(tester, reloaded);
    expect(find.text('思考：最高'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('conversation_reasoning_effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reasoning_effort_default')));
    await letIoFinish(tester);
    expect(find.text('思考：默认'), findsOneWidget);
    final rows = await tester.runAsync(() => storage.db.query(
        'tb_conversation_list',
        where: 'cid = ?',
        whereArgs: [model.cid]));
    expect(rows!.single['deepSeekReasoningEffort'], isNull);
    expect(rows.single['title'], '思考等级验收');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
  });

  testWidgets('320 像素窄屏下 DeepSeek 模型和思考入口可用', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ai = settings.settings.clone()..activeProviderId = 'deepseek';
    ai.activeProvider.models.add(AiModel(id: 'deepseek-v4-flash-vision-exp'));
    ai.setActiveModel('deepseek-v4-flash-vision-exp');
    await tester.runAsync(() => settings.update(ai));
    await openPage(tester, conversation(105));
    expect(find.byKey(const ValueKey('conversation_reasoning_effort')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester
        .tap(find.byKey(const ValueKey('conversation_reasoning_effort')));
    await tester.pumpAndSettle();
    expect(find.text('思考强度'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
  });

  testWidgets('不支持等级的模型隐藏入口', (tester) async {
    final ai = settings.settings.clone()..activeProviderId = 'openai';
    ai.setActiveModel('gpt-4o');
    await tester.runAsync(() => settings.update(ai));
    await openPage(tester, conversation(106));
    expect(find.byKey(const ValueKey('conversation_reasoning_effort')),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
  });

  testWidgets('旧无 blocks 消息重开恢复草稿，原记录保持一致且初始化后可发送', (tester) async {
    final ai = settings.settings.clone()..activeProviderId = 'deepseek';
    ai.setActiveModel('deepseek-flash');
    await tester.runAsync(() => settings.update(ai));
    final model = conversation(101, title: '旧对话');
    final drafts = ConversationDraftStore(
        conversationId: '${model.cid}',
        accountHash: 'guest',
        directoryResolver: () async => temporary);
    final before = await tester.runAsync(() async {
      final conversations = await ConversationListDao.create(storage);
      await conversations.saveConversation(model);
      final messages = await MessageDao.create(storage, cid: model.cid);
      await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender,
        ownerName: '旧用户',
        avatar: '',
        content: '旧问题',
        createdAt: 1000,
      ));
      await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: '旧助手',
        avatar: '',
        content: '旧回答',
        createdAt: 2000,
      ));
      await drafts.save(text: '还没有发送的草稿');
      return storage.db.query('tb_messages',
          where: 'cid = ?', whereArgs: [model.cid], orderBy: 'id');
    });
    await openPage(tester, model);
    final input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    expect(input.controller!.text, '还没有发送的草稿');
    expect(input.enable, isTrue);
    expect(input.editingEnabled, isTrue);
    expect(input.canSend!(), isTrue);
    expect(find.text('查看本轮上下文'), findsOneWidget);
    expect(find.text('旧问题'), findsWidgets);
    expect(find.text('旧回答'), findsWidgets);
    await tester
        .tap(find.byKey(const ValueKey('conversation_reasoning_effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reasoning_effort_high')));
    await letIoFinish(tester);
    expect(find.text('思考：高'), findsOneWidget);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .controller!
            .text,
        '还没有发送的草稿');
    final after = await tester.runAsync(() => storage.db.query('tb_messages',
        where: 'cid = ?', whereArgs: [model.cid], orderBy: 'id'));
    expect(after, before);
    await tester.enterText(find.byType(TextField), '编辑后未发送的草稿');
    await tester.pump(const Duration(milliseconds: 400));
    await letIoFinish(tester);
    expect((await finishFuture(tester, drafts.load()))!.text, '编辑后未发送的草稿');
    await tester.pumpWidget(const SizedBox.shrink());
    await finishFuture(tester, drafts.load());
    expect(
        (await tester.runAsync(() => storage.db.query('tb_messages',
            where: 'cid = ?', whereArgs: [model.cid], orderBy: 'id'))),
        before);
    await openPage(tester, model);
    expect(find.text('思考：高'), findsOneWidget);
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .controller!
            .text,
        '编辑后未发送的草稿');
    await tester.pumpWidget(const SizedBox.shrink());
    await finishFuture(tester, drafts.load());
  });

  testWidgets('本轮累计文字超限保留输入和附件，不保存消息或发网络请求', (tester) async {
    final ai = settings.settings.clone()
      ..mode = AIMode.local
      ..attachmentTotalMaxChars = 1024
      ..attachmentTextMaxChars = 2000
      ..activeProviderId = 'batch-test'
      ..providers = [
        AiProvider(
          id: 'batch-test',
          name: '附件预算测试',
          type: 'openai',
          enabled: true,
          apiHost: 'https://example.invalid',
          apiKey: 'fixture-key',
          selectedModelId: 'gpt-4o',
          models: [AiModel(id: 'gpt-4o')],
        ),
      ];
    await tester.runAsync(() => settings.update(ai));
    final files = await tester.runAsync(() async {
      final paths = <String>[];
      for (var i = 0; i < 2; i++) {
        final file = File('${temporary.path}/正文$i.txt');
        await file.writeAsString('${List.filled(600, '文').join()}$i');
        paths.add(file.path);
      }
      return paths;
    });
    final model = conversation(110, title: '附件累计预算验收');
    await openPage(tester, model);
    final previousHttp = HttpOverrides.current;
    final noNetwork = _RejectHttpOverrides();
    HttpOverrides.global = noNetwork;
    addTearDown(() => HttpOverrides.global = previousHttp);
    await tester.runAsync(() async {
      tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onFilesPicked!(files!);
      await draftFor(model.cid).whenIdle();
    });
    await tester.enterText(find.byType(TextField), '保留这条待发送问题');
    try {
      // 真实文件流必须在真实异步区运行，避免 FakeAsync 挂起文件流的检查点。
      await tester.runAsync(() async {
        await tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .onSend!();
      });
      await finishFuture(
          tester,
          ConversationGenerationService.instance
              .lookup('guest', model.cid)!
              .finished);
      final input =
          tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
      expect(input.controller!.text, '保留这条待发送问题');
      expect(input.pendingFiles, hasLength(2));
      expect(input.isStreaming, isFalse);
      expect(find.text('请求未完成，可查看错误后明确重试'), findsWidgets);
      final run =
          ConversationGenerationService.instance.lookup('guest', model.cid)!;
      expect(
          run.preparationFailure,
          isA<AttachmentBatchLimitException>()
              .having((error) => error.toString(), '附件预算原因', contains('总字数')));
      expect(noNetwork.clients, 0);
      final count = await tester.runAsync(() async =>
          (await MessageDao.create(storage, cid: model.cid)).getMessageCount());
      expect(count, 0);
      final saved = await finishFuture(tester, draftFor(model.cid).load());
      expect(saved!.text, '保留这条待发送问题');
      expect(saved.filePaths, hasLength(2));
    } finally {
      // 当前 fake clock 内明确完成 dispose 保存，再关闭数据库和文件目录。
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      await finishFuture(tester, draftFor(model.cid).whenIdle());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('新会话草稿自动建立列表入口，同时不伪造历史消息', (tester) async {
    final model = conversation(102);
    await openPage(tester, model);
    await tester.enterText(find.byType(TextField), '待发送的新问题');
    await tester.pump(const Duration(milliseconds: 400));
    expect((await finishFuture(tester, draftFor(model.cid).load()))!.text,
        '待发送的新问题');
    await letIoFinish(tester, rounds: 3);
    final rows = await tester.runAsync(() => storage.db.query(
        'tb_conversation_list',
        where: 'cid = ?',
        whereArgs: [model.cid]));
    expect(rows, hasLength(1));
    expect(rows!.single['title'], '待发送的新问题');
    expect(rows.single['lastMessage'], '[草稿] 待发送的新问题');
    expect(rows.single['messageCount'], 0);
    final count = await tester.runAsync(() async =>
        (await MessageDao.create(storage, cid: model.cid)).getMessageCount());
    expect(count, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await finishFuture(tester, draftFor(model.cid).load());
  });

  testWidgets('新草稿清空后在防抖前立即离开，不保留空草稿索引', (tester) async {
    final model = conversation(103);
    await openPage(tester, model);
    await tester.enterText(find.byType(TextField), '稍后会清空的草稿');
    await tester.pump(const Duration(milliseconds: 400));
    expect((await finishFuture(tester, draftFor(model.cid).load()))!.text,
        '稍后会清空的草稿');
    await letIoFinish(tester, rounds: 3);
    final initial = await tester.runAsync(() => storage.db.query(
        'tb_conversation_list',
        where: 'cid = ?',
        whereArgs: [model.cid]));
    expect(initial, hasLength(1));
    await tester.enterText(find.byType(TextField), '');
    // 不推进350ms防抖时间，模拟快速返回列表/离开助手入口。
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
    final after = await tester.runAsync(() => storage.db.query(
        'tb_conversation_list',
        where: 'cid = ?',
        whereArgs: [model.cid]));
    expect(after, isEmpty);
    expect(model.title, isNull);
    expect(model.lastMessage, isNull);
    final drafts = ConversationDraftStore(
        conversationId: '${model.cid}',
        accountHash: 'guest',
        directoryResolver: () async => temporary);
    expect(await finishFuture(tester, drafts.load()), isNull);
  });
}

final class _RejectHttpOverrides extends HttpOverrides {
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError('附件检查失败前不得发出 HTTP 请求');
  }
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
