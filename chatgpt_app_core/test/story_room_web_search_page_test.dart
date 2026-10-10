import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/story_room_tool_runner.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
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
  late _RecordingRunner runner;
  late StoryRoomDao dao;
  late HiDBManager storage;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late DatabaseFactory? previousFactory;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    LoginDao.resetHooksForTest();
    account = "room-search-default-test-${++sequence}";
    loginStorage = _GuestStorage(account);
    runner = _RecordingRunner();
    temporary =
        await Directory.systemTemp.createTemp('chatai_room_search_default_');
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
    dao = await StoryRoomDao.create(storage);
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

  Future<void> mount(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ThemeProvider>.value(value: theme),
    ], child: MaterialApp(home: page)));
    await letIoFinish(tester);
  }

  Future<void> openRoom(WidgetTester tester, StoryRoomModel room) async {
    await mount(
        tester,
        StoryRoomPage(
            key: ValueKey('room_${room.id}'),
            room: room,
            toolRunner: runner,
            readAloudService: const NoopReadAloudService()));
    for (var i = 0;
        i < 50 && find.byType(MessageInputWidget).evaluate().isEmpty;
        i++) {
      await letIoFinish(tester, rounds: 1);
    }
    expect(find.byType(MessageInputWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  MessageInputWidget input(WidgetTester tester) =>
      tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await letIoFinish(tester);
  }

  Future<void> choose(WidgetTester tester, int choice) async {
    await tester.tap(find.byTooltip('房间设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('联网搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('room_web_search_$choice')));
    await letIoFinish(tester);
  }

  testWidgets('全局默认 UI 缺省关闭、点击保存、重开保留、账号隔离', (tester) async {
    await mount(tester, const AISettingsPage());
    final finder = find.byKey(const ValueKey('default_web_search_setting'));
    await tester.scrollUntilVisible(finder, 350);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(finder).value, isFalse);
    expect(find.text('默认开启联网搜索'), findsOneWidget);
    expect(find.textContaining('跟随全局默认的新旧会话'), findsOneWidget);
    await tester.tap(finder);
    await letIoFinish(tester);
    expect(settings.settings.webSearchEnabled, isTrue);
    await close(tester);
    await finishFuture(tester, settings.load());
    await mount(tester, const AISettingsPage());
    await tester.scrollUntilVisible(finder, 350);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(finder).value, isTrue);
    await close(tester);
    loginStorage.account = '$account-other';
    await finishFuture(tester, settings.load());
    expect(settings.settings.webSearchEnabled, isFalse);
    loginStorage.account = account;
    await finishFuture(tester, settings.load());
    expect(settings.settings.webSearchEnabled, isTrue);
  });

  for (final override in <bool?>[null, false, true]) {
    testWidgets('房间=$override：全局变化、生效请求链路、单独切换和重开持久化', (tester) async {
      await settings.update(settings.settings.clone()
        ..webSearchEnabled = false
        ..tavilyApiKey = 'offline-test-key');
      final room = StoryRoomModel(title: '离线测试房间', webSearchEnabled: override);
      await finishFuture(tester, dao.saveRoom(room));
      await openRoom(tester, room);
      expect(input(tester).webSearchEnabled, override ?? false);
      await finishFuture(tester,
          settings.update(settings.settings.clone()..webSearchEnabled = true));
      expect(input(tester).webSearchEnabled, override ?? true);
      // 真正执行页面发送到 runner 的整段链路；runner 不连接任何服务。
      await tester.enterText(find.byType(TextField).last, '离线验证请求设置');
      input(tester).onSend!();
      for (var i = 0;
          i < 70 && (runner.flags.isEmpty || input(tester).isStreaming);
          i++) {
        await letIoFinish(tester, rounds: 1);
      }
      expect(runner.flags, [override ?? true]);
      expect(runner.settingsReceived.single.webSearchEnabled, override ?? true);
      final before = input(tester).webSearchEnabled;
      await tester.tap(find.byKey(const ValueKey('web_search_toggle')));
      await letIoFinish(tester);
      expect(room.webSearchEnabled, !before);
      expect(input(tester).webSearchEnabled, !before);
      expect(settings.settings.webSearchEnabled, isTrue);
      final saved = (await finishFuture(tester, dao.getRoom(room.id!)))!;
      expect(saved.webSearchEnabled, !before);
      await close(tester);
      await openRoom(tester, saved);
      expect(input(tester).webSearchEnabled, !before);
      await finishFuture(tester,
          settings.update(settings.settings.clone()..webSearchEnabled = false));
      expect(input(tester).webSearchEnabled, !before);
      await choose(tester, -1);
      expect(saved.webSearchEnabled, isNull);
      expect(input(tester).webSearchEnabled, isFalse);
      await finishFuture(tester,
          settings.update(settings.settings.clone()..webSearchEnabled = true));
      expect(input(tester).webSearchEnabled, isTrue);
      expect(
          (await finishFuture(tester, dao.getRoom(room.id!)))!.webSearchEnabled,
          isNull);
      await close(tester);
    });
  }

  testWidgets('切换房间不串值，同 ID 不同账号隔离，账号切换后旧回调不能保存', (tester) async {
    await settings
        .update(settings.settings.clone()..tavilyApiKey = 'offline-test-key');
    final first = StoryRoomModel(title: 'A1');
    final second = StoryRoomModel(title: 'A2');
    await finishFuture(tester, dao.saveRoom(first));
    await finishFuture(tester, dao.saveRoom(second));
    await openRoom(tester, first);
    await tester.tap(find.byKey(const ValueKey('web_search_toggle')));
    await letIoFinish(tester);
    expect(first.webSearchEnabled, isTrue);
    await close(tester);
    await openRoom(tester, second);
    expect(input(tester).webSearchEnabled, isFalse);
    await close(tester);
    await openRoom(
        tester, (await finishFuture(tester, dao.getRoom(first.id!)))!);
    expect(input(tester).webSearchEnabled, isTrue);
    final staleToggle = input(tester).onToggleWebSearch!;
    loginStorage.account = '$account-other';
    await finishFuture(tester, settings.load());
    staleToggle();
    await letIoFinish(tester);
    expect(
        (await finishFuture(tester, dao.getRoom(first.id!)))!.webSearchEnabled,
        isTrue);
    await close(tester);
    final otherStorage = await finishFuture(
        tester, HiDBManager.instance(dbName: loginStorage.account));
    final otherDao =
        await finishFuture(tester, StoryRoomDao.create(otherStorage));
    final other = StoryRoomModel(title: 'B1', webSearchEnabled: false);
    await finishFuture(tester, otherDao.saveRoom(other));
    expect(other.id, first.id);
    await finishFuture(
        tester,
        settings.update(settings.settings.clone()
          ..tavilyApiKey = 'offline-test-key'
          ..webSearchEnabled = true));
    await openRoom(tester, other);
    expect(input(tester).webSearchEnabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('web_search_toggle')));
    await letIoFinish(tester);
    expect(
        (await finishFuture(tester, otherDao.getRoom(other.id!)))!
            .webSearchEnabled,
        isTrue);
    expect(
        (await finishFuture(tester, dao.getRoom(second.id!)))!.webSearchEnabled,
        isNull);
    await close(tester);
    // 第二个账号的连接在 fake clock 内创建，也在同一时钟内完成关闭。
    await finishFuture(tester, HiDBManager.closeAll());
  });

  testWidgets('保存失败不伪造成功状态，也不修改全局设置', (tester) async {
    await settings
        .update(settings.settings.clone()..tavilyApiKey = 'offline-test-key');
    final room = StoryRoomModel(title: '删除后保存失败');
    await finishFuture(tester, dao.saveRoom(room));
    await openRoom(tester, room);
    await finishFuture(
        tester,
        storage.db.delete(StoryRoomDao.roomTable,
            where: 'id = ?', whereArgs: [room.id]));
    await tester.tap(find.byKey(const ValueKey('web_search_toggle')));
    await letIoFinish(tester);
    expect(room.webSearchEnabled, isNull);
    expect(settings.settings.webSearchEnabled, isFalse);
    expect(find.text('联网搜索设置未保存，请重试'), findsOneWidget);
    await close(tester);
  });
}

class _RecordingRunner extends StoryRoomToolRunner {
  final flags = <bool>[];
  final settingsReceived = <AISettings>[];
  @override
  Stream<StreamEvent> run(
      {required int? speakerAssistantId,
      required AISettings settings,
      required List<Map<String, dynamic>> history,
      required String prompt,
      ChatAttachments? attachments,
      StoryRoomToolConfirm? confirm,
      int? projectId,
      bool forceWebSearch = false}) async* {
    flags.add(forceWebSearch);
    settingsReceived.add(settings.clone());
    yield StreamEvent.text('离线测试回复');
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
