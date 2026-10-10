import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/composer_prediction_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
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
    account = "prediction-test-${++sequence}";
    loginStorage = _GuestStorage(account);
    mainChat = FakeComposerChat(content: "这是测试回答，单元测试可以验证行为。");
    predictionChat = FakeComposerChat();
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

  Future<void> startReply(WidgetTester tester,
      {bool enabled = true, bool streaming = false}) async {
    await settings.update(settings.settings.clone()
      ..composerPredictionsEnabled = enabled
      ..streamEnabled = streaming);
    await openPage(tester, conversation(801, title: '建议测试'));
    await tester.enterText(find.byType(TextField).last, '请解释单元测试。');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    for (var i = 0; i < 100; i++) {
      await letIoFinish(tester, rounds: 1);
      final input =
          tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
      if (mainChat.calls > 0 && input.enable) break;
    }
    await letIoFinish(tester);
  }

  for (final streaming in [false, true]) {
    testWidgets('${streaming ? '流式' : '非流式'}成功后只预测一次，用量落库、采纳不发送',
        (tester) async {
      await startReply(tester, streaming: streaming);
      expect(mainChat.calls, 1);
      expect(predictionChat.calls, 1);
      expect(find.byKey(const ValueKey('accept_composer_prediction')),
          findsOneWidget);
      expect((await finishFuture(tester, storage.db.query('tb_messages'))),
          hasLength(2));
      expect((await finishFuture(tester, storage.db.query('tb_usage'))),
          hasLength(2));
      await tester
          .tap(find.byKey(const ValueKey('accept_composer_prediction')));
      await letIoFinish(tester);
      expect(
          tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .controller!
              .text,
          '请给一个具体例子。');
      expect(mainChat.calls, 1);
      expect(predictionChat.calls, 1);
      expect(find.byKey(const ValueKey('composer_prediction')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await letIoFinish(tester);
    });
  }

  for (final outcome in ['关闭', '失败', '空回复']) {
    testWidgets('$outcome不触发预测', (tester) async {
      mainChat.fail = outcome == '失败';
      if (outcome == '空回复') mainChat.content = '';
      await startReply(tester, enabled: outcome != '关闭');
      expect(mainChat.calls, 1);
      expect(predictionChat.calls, 0);
      expect(find.byKey(const ValueKey('composer_prediction')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await letIoFinish(tester);
    });
  }

  testWidgets('用户停止回复后不预测，即使模型迟到返回正文', (tester) async {
    mainChat.pending = Completer<ChatCompletionResult>();
    await startReply(tester, streaming: true);
    expect(predictionChat.calls, 0);
    final input =
        tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
    expect(input.onStop, isNotNull);
    input.onStop!();
    mainChat.pending!.complete(const ChatCompletionResult(content: '迟到回答'));
    await letIoFinish(tester, rounds: 40);
    expect(predictionChat.calls, 0);
    expect(find.byKey(const ValueKey('composer_prediction')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
  });

  for (final action in ['输入草稿', '关闭开关', '更换模型', '切换账号', '切换会话', '退出页面']) {
    testWidgets('预测期间$action会取消并丢弃迟到结果', (tester) async {
      predictionChat.pending = Completer<ChatCompletionResult>();
      await startReply(tester);
      expect(predictionChat.calls, 1);
      var aborted = false;
      predictionChat.requests.single.abortTrigger!.then((_) => aborted = true);
      if (action == '输入草稿') {
        await tester.enterText(find.byType(TextField).last, '未发送的私密草稿');
      } else if (action == '关闭开关') {
        await finishFuture(
            tester,
            settings.update(
                settings.settings.clone()..composerPredictionsEnabled = false));
      } else if (action == '更换模型') {
        await finishFuture(
            tester,
            settings.update(
                settings.settings.clone()..setActiveModel('other-model')));
      } else if (action == '切换账号') {
        loginStorage.account = 'another-prediction-account';
        await finishFuture(tester, settings.reload());
      } else if (action == '切换会话') {
        await openPage(tester, conversation(802, title: '另一个会话'));
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await letIoFinish(tester);
      expect(aborted, isTrue);
      predictionChat.pending!
          .complete(ChatCompletionResult(content: predictionChat.content));
      await letIoFinish(tester);
      expect(find.byKey(const ValueKey('composer_prediction')), findsNothing);
      expect(jsonEncode(predictionChat.histories), isNot(contains('未发送的私密草稿')));
      if (action == '输入草稿') {
        expect(
            tester
                .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                .controller!
                .text,
            '未发送的私密草稿');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await letIoFinish(tester);
      expect(tester.takeException(), isNull);
    });
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
