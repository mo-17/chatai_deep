import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/assistant_conversation_factory.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/chat/application/composer_prediction_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'support/fake_composer_chat.dart';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
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
  var sequence = 0;
  late String account;
  late _GuestStorage loginStorage;
  late FakeComposerChat mainChat;
  late FakeComposerChat predictionChat;
  late HiDBManager storage;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late DatabaseFactory? previousFactory;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    LoginDao.resetHooksForTest();
    account = "search-highlight-test-${++sequence}";
    loginStorage = _GuestStorage(account);
    mainChat = FakeComposerChat(content: "这是测试回答，单元测试可以验证行为。");
    predictionChat = FakeComposerChat();
    temporary =
        await Directory.systemTemp.createTemp('chatai_search_highlight_');
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
      storage: loginStorage,
      onLogoutNavigate: () {},
    ));
    final ai = AISettings.defaults();
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor(account), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    theme = ThemeProvider();
    storage = await HiDBManager.instance(dbName: account);
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
    for (var attempt = 0; attempt < 100 && !finished; attempt++) {
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
          chatService: mainChat,
          predictionService:
              ComposerPredictionService(chatFactory: (_) => predictionChat),
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
    expect(
        tester
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .enable,
        isTrue,
        reason: "会话初始化必须完成");
    expect(tester.takeException(), isNull);
  }

  ConversationModel conversation(int cid, {String? title}) => ConversationModel(
        cid: cid,
        icon: '',
        title: title,
        speechInputEnabled: false,
      );

  for (final projectDefault in <bool?>[null, false, true]) {
    testWidgets('项目默认=$projectDefault：全局变化仅影响跟随会话，项目修改只影响后来新建的会话',
        (tester) async {
      await settings
          .update(settings.settings.clone()..tavilyApiKey = 'offline-test-key');
      final projects = await finishFuture(tester, ProjectDao.create(storage));
      final project =
          ProjectModel(name: '默认值测试', defaultUseWebSearch: projectDefault);
      await finishFuture(tester, projects.saveProject(project));
      final persistedProject =
          (await finishFuture(tester, projects.getProject(project.id!)))!;
      final model = AssistantConversationFactory.create(
          cid: 902,
          icon: '',
          projectId: project.id,
          webSearchEnabled: persistedProject.defaultUseWebSearch)
        ..title = '项目会话'
        ..speechInputEnabled = false;
      final dao =
          await finishFuture(tester, ConversationListDao.create(storage));
      await finishFuture(tester, dao.saveConversation(model));
      await openPage(tester, model);
      for (final global in [false, true, false]) {
        await finishFuture(
            tester,
            settings
                .update(settings.settings.clone()..webSearchEnabled = global));
        expect(
            tester
                .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                .webSearchEnabled,
            projectDefault ?? global);
        expect(model.webSearchEnabled, projectDefault);
      }
      project.defaultUseWebSearch = !(projectDefault ?? false);
      await finishFuture(tester, projects.saveProject(project));
      final old =
          (await finishFuture(tester, dao.getConversationList())).single;
      expect(old.webSearchEnabled, projectDefault);
      final later = AssistantConversationFactory.create(
          cid: 903,
          icon: '',
          projectId: project.id,
          webSearchEnabled: project.defaultUseWebSearch);
      expect(later.webSearchEnabled, !(projectDefault ?? false));
      await tester.pumpWidget(const SizedBox.shrink());
      await letIoFinish(tester);
      await openPage(tester, old);
      expect(
          tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .webSearchEnabled,
          projectDefault ?? false);
      expect(mainChat.calls, 0);
      expect(predictionChat.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await letIoFinish(tester);
    });
  }

  for (final global in [false, true]) {
    for (final override in <bool?>[null, false, true]) {
      testWidgets('全局=$global / 会话=$override：显示生效值，切换并重开保留，全局不变',
          (tester) async {
        await settings.update(settings.settings.clone()
          ..webSearchEnabled = global
          ..tavilyApiKey = 'offline-test-key');
        final model = conversation(901, title: '搜索状态测试')
          ..webSearchEnabled = override;
        final dao =
            await finishFuture(tester, ConversationListDao.create(storage));
        await finishFuture(tester, dao.saveConversation(model));
        await openPage(tester, model);
        MessageInputWidget input() =>
            tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
        final expected = override ?? global;
        expect(input().showWebSearch, isTrue);
        expect(input().webSearchEnabled, expected);
        final finder = find.byKey(const ValueKey('web_search_toggle'));
        expect(tester.widget<IconButton>(finder).isSelected, expected);
        await tester.tap(finder);
        await letIoFinish(tester);
        expect(model.webSearchEnabled, !expected);
        expect(input().webSearchEnabled, !expected);
        expect(tester.widget<IconButton>(finder).isSelected, !expected);
        expect(settings.settings.webSearchEnabled, global);
        final saved =
            (await finishFuture(tester, dao.getConversationList())).single;
        expect(saved.webSearchEnabled, !expected);
        await tester.pumpWidget(const SizedBox.shrink());
        await letIoFinish(tester);
        await openPage(tester, saved);
        expect(input().webSearchEnabled, !expected);
        expect(tester.widget<IconButton>(finder).isSelected, !expected);
        expect(settings.settings.webSearchEnabled, global);
        expect(mainChat.calls, 0);
        expect(predictionChat.calls, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await letIoFinish(tester);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

final class _GuestStorage implements TokenStorage {
  String account;
  _GuestStorage(this.account);
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
