import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_assistant.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_repository.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_runtime.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/fake_composer_chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager db;
  late KnowledgeRepository repo;
  late AISettingsProvider settings;
  late int doc;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    LoginSdkConfig.install(
        LoginSdkConfig.instance.copyWith(storage: HiCacheTokenStorage()));
    await LoginSdkConfig.instance.storage.writeProfile(
        token: 'guest-mode',
        userName: 'guest',
        extras: {'accountHash': 'guest', 'guest': true});
    AISettingsDao.resetSecureStateForTest();
    final ai = AISettings.defaults()
      ..mode = AIMode.local
      ..activeProviderId = 'fixture'
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '合成模型',
            type: 'openai',
            enabled: true,
            apiKey: 'synthetic-fixture-key',
            apiHost: 'http://127.0.0.1:1',
            selectedModelId: 'gpt-4o',
            models: [AiModel(id: 'gpt-4o')])
      ];
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor('guest'), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    db = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    repo = await KnowledgeRepository.create(db);
    doc = (await repo.knowledge.addDocument('政策', '7 天内可申请退款。'))!;
  });
  tearDown(() async {
    settings.dispose();
    await db.db.close();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
  });
  test('生产适配器沿用原模型/作用域、请求许可和真实用量接口，不调用工具或自动重试', () async {
    final chat =
        FakeComposerChat(content: '{"status":"insufficient","claims":[]}');
    final assistant = KnowledgeAssistant(
        repository: repo,
        isCurrent: () => true,
        complete: knowledgeRuntime(
            repository: repo,
            settings: settings,
            account: 'guest',
            transportFactory: (selected) {
              expect(selected.effectiveModel, 'gpt-4o');
              return chat;
            }));
    final result = await assistant.ask('退款期限', {doc});
    expect(result.model, 'gpt-4o');
    expect(chat.calls, 1);
    final messages = chat.histories.single;
    expect(messages.map((m) => m['role']), ['system', 'user']);
    expect(messages.first['content'], contains('禁止联网、调用工具'));
    expect(chat.requests.single.maxAutoRetries, 0);
    expect(chat.requests.single.maxOutputTokensOverride, 2048);
    expect(chat.requests.single.abortTrigger, isNotNull);
    final usage = await db.db.query('tb_usage');
    expect(usage.single['providerId'], 'fixture');
    expect(usage.single['promptTokens'], 100);
    expect(usage.single['completionTokens'], 12);
    assistant.dispose();
  });
  test('最终派发前撤销页面许可，不发送、不保存、不新增用量', () async {
    final chat = FakeComposerChat();
    var current = true;
    final complete = knowledgeRuntime(
        repository: repo,
        settings: settings,
        account: 'guest',
        transportFactory: (_) {
          current = false;
          return chat;
        });
    await expectLater(
        complete(
            prompt: '{}',
            abort: Completer<void>().future,
            isCurrent: () => current,
            beforeDispatch: () async {}),
        throwsA(anything));
    expect(chat.calls, 0);
    expect(await repo.history(), isEmpty);
  });
}
