// 验收复用核心已解析依赖，不为测试重复增加壳层依赖。
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/interactive_card_view.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chatgpt_app_core/test/support/fake_composer_chat.dart';

/// 分 prepare / restore 两次启动；仅允许在本任务独立 Simulator 上运行。
/// 文件与相册在平台边界返回合成路径，所有选择、删除、取消和发送都点击实际 UI。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // iOS 平台首次请求 semantics 会持有自己的句柄。先完成实际首帧初始化，
  // 再让 testWidgets 记录基线；默认 semantics 与结束泄漏检查保持启用。
  setUpAll(() => _initializeNativeSemantics(binding));
  const forceRestoring =
      String.fromEnvironment('REFERENCE_UI_PHASE') == 'restore';
  const diagnosing = String.fromEnvironment('REFERENCE_UI_PHASE') == 'diagnose';
  const cardsEnabled = bool.fromEnvironment('REFERENCE_UI_CARDS');
  const cardReply = '离线合成卡片\n'
      '```chatai-card\n{"schema":"chatai.card","version":1,"type":"checklist","title":"阅读安排","items":[{"id":"read","text":"阅读笔记"},{"id":"review","text":"整理问题"}]}\n```\n'
      '```chatai-card\n{"schema":"chatai.card","version":1,"type":"comparison","title":"节奏比较","options":[{"id":"a","label":"每天"},{"id":"b","label":"周末"}],"rows":[{"id":"time","label":"用时","values":{"a":"二十分钟","b":"一小时"}}]}\n```\n';
  const account = 'reference_ui_isolated_fixture';
  testWidgets('合成引用与原生卡片实际界面验收', (tester) async {
    const speechChannel = MethodChannel('plugin.csdcorp.com/speech_to_text');
    const fileChannel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(speechChannel, (_) async => false);
    SharedPreferences.setPrefix('chatai_reference_ui.');
    final cache = await HiCache.preInit();
    // 同一二进制重启后进入恢复阶段，避免重新安装应用丢失容器。
    final restoring = forceRestoring || cache.get('restart_prepared') == true;
    if (!restoring) await cache.prefs!.clear();
    AISettingsDao.configureSecretStore(_MemorySecrets());
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'example.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: _FixtureLogin(account),
        onLogoutNavigate: () {}));
    final network = _NoNetwork();
    HttpOverrides.global = network;
    final ai = AISettings.defaults()
      ..mode = AIMode.local
      ..streamEnabled = restoring && cardsEnabled
      ..activeProviderId = 'fixture'
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '离线验收',
            type: 'openai',
            enabled: true,
            apiHost: 'https://example.invalid',
            apiKey: 'offline-fixture-only',
            selectedModelId: 'gpt-4o',
            models: [AiModel(id: 'gpt-4o')])
      ];
    await cache.setString(
        AISettingsDao.keyFor(account), jsonEncode(ai.toJson()));
    final settings = AISettingsProvider();
    await settings.update(ai);
    final theme = ThemeProvider();
    theme.setVisualStyle(
        restoring ? AppVisualStyle.anime : AppVisualStyle.classic);
    final storage = await HiDBManager.instance(dbName: account);
    final databasePath = storage.db.path;
    final draft =
        ConversationDraftStore(conversationId: '2', accountHash: account);
    final chat = FakeComposerChat(
        content: cardsEnabled ? cardReply : '离线验收答复：已读取三个引用快照。');
    final model =
        ConversationModel(cid: 2, icon: '', speechInputEnabled: false);
    final temporary = await Directory.systemTemp.createTemp('reference_ui_');
    final textFile =
        await File('${temporary.path}/阅读笔记.txt').writeAsString('离线文件：阅读笔记。');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 240, 160),
        Paint()..color = const Color(0xff176b87));
    canvas.drawCircle(
        const Offset(65, 70), 35, Paint()..color = const Color(0xffffcb74));
    final paragraph = (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 24))
          ..pushStyle(ui.TextStyle(color: Colors.white))
          ..addText('OFFLINE'))
        .build()
      ..layout(const ui.ParagraphConstraints(width: 200));
    canvas.drawParagraph(paragraph, const Offset(24, 118));
    final generated = await recorder.endRecording().toImage(240, 160);
    final photo = await File('${temporary.path}/资料相片.png').writeAsBytes(
        (await generated.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List());
    generated.dispose();
    final previousImages = ImagePickerPlatform.instance;
    final images = _SyntheticImages(photo.path);
    ImagePickerPlatform.instance = images;
    var cancelFile = false;
    var fileCalls = 0;
    messenger.setMockMethodCallHandler(fileChannel, (call) async {
      if (call.method != 'custom') throw StateError('fixture仅支持已授权文件选择入口');
      fileCalls++;
      if (cancelFile) {
        cancelFile = false;
        return null;
      }
      return [
        {
          'name': '阅读笔记.txt',
          'path': textFile.path,
          'size': await textFile.length()
        }
      ];
    });
    var historyRowId = 0;
    if (!restoring) {
      // 可重跑只清理这个合成账号，不访问原模拟器或其它账号。
      await draft.clear(discardAttachments: true);
      await ConversationListDao.create(storage);
      await MessageDao.create(storage, cid: 1);
      await storage.db.delete('tb_messages');
      await storage.db.delete('tb_conversation_list');
      await (await ConversationListDao.create(storage)).saveConversation(
          ConversationModel(cid: 1, icon: '', title: '周末阅读计划'));
      historyRowId = await (await MessageDao.create(storage, cid: 1))
          .saveMessageWithBlocks(MessageModel(
              ownerType: OwnerType.receiver,
              createdAt: 1,
              content: '周末阅读计划：\n1. 整理参考资料\n2. 阅读两篇文章\n3. 写自己的总结\n选择时冻结正文。'));
    } else if (restoring) {
      expect(cache.get('restart_prepared'), true, reason: '前一次原生进程已经保存草稿');
    }
    var narrow = false;
    late StateSetter viewport;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await draft.whenIdle();
      if (restoring) await draft.clear(discardAttachments: true);
      await HiDBManager.closeAll();
      settings.dispose();
      theme.dispose();
      LoginSdkConfig.reset();
      HttpOverrides.global = null;
      ImagePickerPlatform.instance = previousImages;
      messenger.setMockMethodCallHandler(speechChannel, null);
      messenger.setMockMethodCallHandler(fileChannel, null);
      await temporary.delete(recursive: true);
      if (restoring) {
        await cache.prefs!.clear();
        if (databasePath.contains(account) &&
            await File(databasePath).exists()) {
          await File(databasePath).delete();
        }
      }
    });
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme)
        ],
        child: StatefulBuilder(builder: (_, setter) {
          viewport = setter;
          return Center(
              child: SizedBox(
                  width: narrow ? 320 : null,
                  child: Consumer<ThemeProvider>(
                      builder: (_, appearance, __) => MaterialApp(
                          // 与真实应用一致，经典/二次元主题不做 TextStyle 插值。
                          themeAnimationDuration: Duration.zero,
                          theme: appearance.isAnime
                              ? AppThemeFactory.anime()
                              : AppThemeFactory.classic(Colors.pink),
                          home: ConversationPage(
                              conversationModel: model,
                              expectedAccountHash: account,
                              readAloudService: const NoopReadAloudService(),
                              onSendPreparationError: (error) => debugPrint(
                                  'REFERENCE_UI_PREPARATION_ERROR:${error.runtimeType}:$error'),
                              chatService: chat)))));
        })));
    MessageInputWidget input() =>
        tester.widget(find.byType(MessageInputWidget));
    Finder field() => find.descendant(
        of: find.byType(MessageInputWidget), matching: find.byType(TextField));
    await _until(tester, () => input().enable);
    Future<void> choose(String kind) async {
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await _idle(tester);
      await tester.tap(find.byKey(ValueKey('reference_choose_$kind')));
      if (kind == 'history') {
        await _until(
            tester,
            () => find
                .byKey(ValueKey('history_reference_$historyRowId'))
                .evaluate()
                .isNotEmpty);
        await _screen(tester, 'history-picker');
        await tester
            .tap(find.byKey(ValueKey('history_reference_$historyRowId')));
      }
      await _idle(tester);
    }

    Future<void> tapTag(String action, String id) async {
      final target = find.byKey(ValueKey('${action}_reference_$id'));
      final list = find
          .descendant(
              of: find.byKey(const ValueKey('composer_reference_tags')),
              matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(target, 140, scrollable: list);
      // 原生窄屏下滚动到标签后必须等一帧再命中；不能用旧布局中心点击。
      await _idle(tester);
      final center = tester.getCenter(target);
      final viewportRect = tester.getRect(list);
      expect(viewportRect.contains(center), isTrue,
          reason: '标签操作中心必须在当前横向标签视口内');
      await tester.tap(target);
    }

    Future<void> previewAll(String style) async {
      for (final kind in ComposerReferenceKind.values) {
        final reference = input().references.firstWhere((r) => r.kind == kind);
        await tapTag('preview', reference.id);
        await _until(tester, () => find.byTooltip('关闭').evaluate().isNotEmpty);
        if (kind == ComposerReferenceKind.photo) {
          final rendered = find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byWidgetPredicate(
                  (w) => w is Image && w.image is MemoryImage));
          await _until(tester, () => rendered.evaluate().isNotEmpty);
          final bytes =
              (tester.widget<Image>(rendered).image as MemoryImage).bytes;
          expect(sha256.convert(bytes).toString(), reference.snapshotDigest);
        } else {
          final body =
              kind == ComposerReferenceKind.file ? '离线文件：阅读笔记。' : '选择时冻结正文';
          await _until(
              tester,
              () => find
                  .textContaining(body, findRichText: true)
                  .evaluate()
                  .isNotEmpty);
        }
        await _screen(tester, '$style-${kind.name}-preview');
        await tester.tap(find.byTooltip('关闭'));
        await _idle(tester);
      }
    }

    Future<void> keyboardEvidence(String style) async {
      // enterText 的测试输入只用于准备合成正文；验收必须重新连接原生键盘。
      FocusManager.instance.primaryFocus?.unfocus();
      tester.binding.focusedEditable = null;
      tester.testTextInput.unregister();
      await _idle(tester);
      viewport(() => narrow = true);
      await _idle(tester);
      await tester.tap(field());
      await _idle(tester);
      // 使用真实平台通道显示软件键盘，不伪造 viewInsets；硬件键盘连接时可手动显示。
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      debugPrint('REFERENCE_UI_KEYBOARD_WAIT:$style;focus='
          '${editable.focusNode.hasFocus};mock=${tester.testTextInput.isRegistered};'
          'native-inset=${tester.view.viewInsets.bottom}');
      double pageKeyboardInset() =>
          MediaQuery.viewInsetsOf(tester.element(find.byType(ConversationPage)))
              .bottom;
      await _until(tester,
          () => tester.view.viewInsets.bottom > 0 && pageKeyboardInset() > 0,
          attempts: 450);
      expect(tester.getSize(find.byType(MessageInputWidget)).width,
          lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
      debugPrint('REFERENCE_UI_KEYBOARD:$style;inset='
          '${pageKeyboardInset()};width='
          '${tester.getSize(find.byType(MessageInputWidget)).width}');
      await _screen(tester, '$style-320-keyboard');
      final callsBefore = chat.calls;
      final history = input()
          .references
          .firstWhere((r) => r.kind == ComposerReferenceKind.historyMessage);
      await tapTag('remove', history.id);
      await _idle(tester);
      expect(input().references, hasLength(2));
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await _idle(tester);
      await _screen(tester, '$style-320-selector');
      await tester.tap(find.text('取消'));
      await _idle(tester);
      expect(input().references, hasLength(2));
      expect(chat.calls, callsBefore);
      expect(tester.takeException(), isNull);
      await _screen(tester, '$style-320-delete-cancel');
      await choose('history');
      await _until(tester, () => input().references.length == 3);
      FocusManager.instance.primaryFocus?.unfocus();
      viewport(() => narrow = false);
      await _idle(tester);
    }

    Future<void> send(bool anime) async {
      await tester.tap(anime
          ? find.byKey(const ValueKey('anime_message_send'))
          : find.byIcon(Icons.send));
      try {
        var lastNotice = '';
        await _until(tester, () {
          final notices = find
              .byType(SnackBar)
              .evaluate()
              .map((e) => find
                  .descendant(
                      of: find.byWidget(e.widget), matching: find.byType(Text))
                  .evaluate()
                  .map((t) => (t.widget as Text).data)
                  .join(' '))
              .join(' | ');
          if (notices.isNotEmpty && notices != lastNotice) {
            lastNotice = notices;
            debugPrint('REFERENCE_UI_SEND_NOTICE:$notices');
          }
          return chat.calls > 0 && input().enable && input().references.isEmpty;
        });
      } catch (_) {
        final notices = find
            .byType(SnackBar)
            .evaluate()
            .map((e) => find
                .descendant(
                    of: find.byWidget(e.widget), matching: find.byType(Text))
                .evaluate()
                .map((t) => (t.widget as Text).data)
                .join(' '))
            .join(' | ');
        final rows = await storage.db
            .query('tb_messages', where: 'cid = ?', whereArgs: [2]);
        debugPrint(
            'REFERENCE_UI_SEND_DIAG:requests=${chat.calls};network=${network.attempts};'
            'enabled=${input().enable};streaming=${input().isStreaming};'
            'references=${input().references.length};rows=${rows.length};notice=$notices');
        await _screen(tester, 'send-diagnostic-failure');
        rethrow;
      }
      expect(chat.attachmentsReceived.last!.extraText, contains('选择时冻结正文'));
      expect(chat.attachmentsReceived.last!.extraText, contains('阅读笔记'));
      expect(chat.attachmentsReceived.last!.images, hasLength(1));
      expect(
          chat.attachmentsReceived.last!.extraText, isNot(contains(account)));
      expect(network.attempts, 0);
      await _screen(tester, anime ? 'anime-sent' : 'classic-sent');
    }

    Future<void> cardEvidence(String style, {bool reopened = false}) async {
      if (!cardsEnabled) return;
      final calls = chat.calls;
      FocusManager.instance.primaryFocus?.unfocus();
      viewport(() => narrow = true);
      await _idle(tester);
      await _until(
          tester, () => find.byType(InteractiveCardView).evaluate().isNotEmpty);
      final card = find.byType(InteractiveCardView).first;
      final checkbox = find
          .descendant(of: card, matching: find.byType(CheckboxListTile))
          .first;
      await tester.ensureVisible(checkbox);
      await _idle(tester);
      expect(tester.widget<CheckboxListTile>(checkbox).onChanged, isNotNull);
      if (reopened) {
        expect(tester.widget<CheckboxListTile>(checkbox).value, true);
      } else {
        final control =
            find.descendant(of: checkbox, matching: find.byType(Checkbox));
        await tester.tap(control);
        await _until(tester,
            () => tester.widget<CheckboxListTile>(checkbox).value == true);
      }
      final rows = await storage.db.query('tb_messages',
          where: 'cid = ? and ownerType = ?',
          whereArgs: [2, OwnerType.receiver.toString()],
          orderBy: 'id desc');
      expect(rows.first['content'], cardReply);
      final main = MessageBlock.decodeList(rows.first['blocks'] as String)
          .whereType<MainTextBlock>()
          .first;
      expect(main.content, cardReply);
      expect(main.localCardStates.values.first.checkedItemIds, {'read'});
      await _screen(tester, '$style-320-cards-checked');
      final copy = find.descendant(of: card, matching: find.text('复制'));
      await tester.ensureVisible(copy);
      await _idle(tester);
      await tester.tap(copy);
      await _idle(tester);
      final copied = (await Clipboard.getData('text/plain'))!.text!;
      expect(copied, contains('- [x] 阅读笔记'));
      final beforeText = input().controller!.text;
      final beforeReferences =
          input().references.map((r) => r.toJson()).toList();
      final insert = find.descendant(of: card, matching: find.text('插入输入框'));
      await tester.ensureVisible(insert);
      await _idle(tester);
      await tester.tap(insert);
      await _idle(tester);
      expect(input().controller!.text,
          beforeText.isEmpty ? copied : '$beforeText\n\n$copied');
      expect(
          input().references.map((r) => r.toJson()).toList(), beforeReferences);
      expect(chat.calls, calls);
      expect(network.attempts, 0);
      expect(tester.takeException(), isNull);
      FocusManager.instance.primaryFocus?.unfocus();
      await _screen(tester, '$style-320-card-insert');
      viewport(() => narrow = false);
      await _idle(tester);
      debugPrint(
          'REFERENCE_UI_CARD_VERIFIED:$style;requests=$calls;network=0;reopened=$reopened');
    }

    if (diagnosing) {
      await choose('file');
      await choose('photo');
      await choose('history');
      await _until(tester, () => input().references.length == 3);
      await tester.enterText(field(), '诊断合成引用发送');
      tester.binding.focusedEditable = null;
      tester.testTextInput.unregister();
      viewport(() => narrow = true);
      await _idle(tester);
      await tester.tap(field());
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      await _until(tester, () => tester.view.viewInsets.bottom > 0,
          attempts: 450);
      FocusManager.instance.primaryFocus?.unfocus();
      viewport(() => narrow = false);
      await _idle(tester);
      await send(false);
      await cardEvidence('diagnostic');
      expect(network.attempts, 0);
    } else if (!restoring) {
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await _idle(tester);
      await _screen(tester, 'classic-selector');
      await tester.tap(find.text('取消'));
      await _idle(tester);
      expect(input().references, isEmpty);
      cancelFile = true;
      await choose('file');
      expect(fileCalls, 1);
      expect(input().references, isEmpty);
      await choose('file');
      expect(input().references, hasLength(1));
      final id = input().references.single.id;
      await tester.tap(find.byKey(ValueKey('remove_reference_$id')));
      await _idle(tester);
      expect(input().references, isEmpty);
      expect(chat.calls, 0);
      images.cancelOnce = true;
      await choose('photo');
      expect(input().references, isEmpty);
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await _idle(tester);
      await tester.tap(find.byKey(const ValueKey('reference_choose_history')));
      await _until(tester, () => find.byTooltip('关闭').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('关闭'));
      await _idle(tester);
      expect(input().references, isEmpty);
      await _screen(tester, 'classic-delete-cancel');
      await choose('file');
      await choose('photo');
      await choose('history');
      await _until(
          tester,
          () =>
              input().references.length == 3 &&
              input().references.every((r) => r.snapshotDigest.isNotEmpty));
      await tester.enterText(field(), '请参考这些资料，帮我整理阅读安排。');
      FocusManager.instance.primaryFocus?.unfocus();
      await _idle(tester);
      await _screen(tester, 'classic-tags');
      await previewAll('classic');
      await keyboardEvidence('classic');
      await send(false);
      expect(chat.calls, 1);
      await cardEvidence('classic');
      theme.setVisualStyle(AppVisualStyle.anime);
      await _idle(tester);
      await choose('file');
      await choose('photo');
      await choose('history');
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await _idle(tester);
      await tester.tap(find.text('取消'));
      await _idle(tester);
      expect(input().references, hasLength(3));
      final animeHistory = input()
          .references
          .firstWhere((r) => r.kind == ComposerReferenceKind.historyMessage);
      await tapTag('remove', animeHistory.id);
      await _idle(tester);
      expect(input().references, hasLength(2));
      expect(chat.calls, 1);
      await _screen(tester, 'anime-delete-cancel');
      await choose('history');
      await tester.enterText(field(), '重启后请参考这三份冻结资料。');
      FocusManager.instance.primaryFocus?.unfocus();
      await _idle(tester);
      await keyboardEvidence('anime');
      await _screen(tester, 'anime-tags-before-restart');
      await draft.whenIdle();
      final saved = (await draft.load())!;
      expect(saved.references, hasLength(3));
      await cache.setString(
          'restart_reference_ids', saved.references.map((r) => r.id).join('|'));
      await cache.setString('restart_reference_snapshot',
          jsonEncode(saved.references.map((r) => r.toJson()).toList()));
      await cache.prefs!.setBool('restart_prepared', true);
      await textFile.delete();
      await photo.delete();
      debugPrint(
          'REFERENCE_UI_RESTART_PREPARED:managed-only;requests=${chat.calls};network=${network.attempts}');
    } else {
      await _until(tester, () => input().references.length == 3);
      expect(input().references.map((r) => r.id).join('|'),
          cache.get('restart_reference_ids'));
      expect(input().references.map((r) => r.toJson()).toList(),
          jsonDecode(cache.get('restart_reference_snapshot') as String));
      expect(input().controller!.text, '重启后请参考这三份冻结资料。');
      expect(fileCalls, 0);
      expect(images.calls, 0);
      await _screen(tester, 'anime-process-restarted-tags');
      await cardEvidence('anime-reopened', reopened: true);
      await previewAll('anime-restarted');
      await send(true);
      expect(chat.calls, 1);
      await cardEvidence('anime-stream');
      expect(tester.takeException(), isNull);
      debugPrint(
          'REFERENCE_UI_RESTART_VERIFIED:references=3;native-picker-recalls=0;network=0');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _initializeNativeSemantics(
    IntegrationTestWidgetsFlutterBinding binding) async {
  final previousPolicy = binding.framePolicy;
  final owned = binding.ensureSemantics();
  debugPrint('REFERENCE_UI_SEMANTICS_WARMUP:owned=${identityHashCode(owned)};'
      'count=${binding.debugOutstandingSemanticsHandles};'
      'native=${ui.PlatformDispatcher.instance.semanticsEnabled}');
  try {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    runApp(const MaterialApp(
        home: Scaffold(body: SafeArea(child: TextField()))));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ui.PlatformDispatcher.instance.semanticsEnabled &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ui.PlatformDispatcher.instance.semanticsEnabled, isTrue,
        reason: '等待真实平台初始化，不覆盖平台标志');
    expect(binding.platformDispatcher.semanticsEnabled, isTrue);
    runApp(const SizedBox.shrink());
    await binding.endOfFrame.timeout(const Duration(seconds: 3));
  } finally {
    // 只释放本 fixture 创建的句柄，不触碰平台持有者。
    owned.dispose();
    binding.framePolicy = previousPolicy;
    debugPrint('REFERENCE_UI_SEMANTICS_READY:'
        'count=${binding.debugOutstandingSemanticsHandles};'
        'proxy=${binding.platformDispatcher.semanticsEnabled};'
        'native=${ui.PlatformDispatcher.instance.semanticsEnabled}');
  }
}

Future<void> _idle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready,
    {int attempts = 120}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  throw TestFailure('离线引用验收状态未完成');
}

Future<void> _screen(WidgetTester tester, String stage) async {
  await _idle(tester);
  debugPrint('REFERENCE_UI_SCREEN:$stage');
  if (const bool.fromEnvironment('REFERENCE_UI_CAPTURE')) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
  }
}

final class _SyntheticImages extends ImagePickerPlatform {
  final String path;
  int calls = 0;
  bool cancelOnce = false;
  _SyntheticImages(this.path);
  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source,
      ImagePickerOptions options = const ImagePickerOptions()}) async {
    calls++;
    if (cancelOnce) {
      cancelOnce = false;
      return null;
    }
    return XFile(path);
  }
}

final class _MemorySecrets implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

final class _FixtureLogin implements TokenStorage {
  final String account;
  _FixtureLogin(this.account);
  @override
  Map<String, dynamic> readProfileSync() => {
        'accountHash': account,
        'guest': true,
        'userName': '离线合成用户',
        'avatar': '',
        'boardingPass': 'guest-mode'
      };
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  String readTokenSync() => 'guest-mode';
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  Future<void> clear() async {}
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('离线 fixture 禁止真实网络');
  }
}
