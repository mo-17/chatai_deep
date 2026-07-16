import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_evidence_loader.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late HiDBManager storage;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    storage = HiDBManager.test(database);
    await database.execute(
      'create table tb_conversation_list ('
      'id integer primary key autoincrement, title text, stickTime integer)',
    );
  });

  tearDown(() => database.close());

  test('标题非空的普通或置顶会话都算历史；空白标题不算', () async {
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (_) => false,
    );

    await database.insert(
      'tb_conversation_list',
      {'title': '普通会话', 'stickTime': 0},
    );
    var evidence = await loader.load(
      accountHash: 'account',
      storage: storage,
      settings: AISettings.defaults(),
    );
    expect(evidence.hasConversationHistory, isTrue);

    await database.delete('tb_conversation_list');
    await database.insert(
      'tb_conversation_list',
      {'title': '置顶会话', 'stickTime': 100},
    );
    evidence = await loader.load(
      accountHash: 'account',
      storage: storage,
      settings: AISettings.defaults(),
    );
    expect(evidence.hasConversationHistory, isTrue);

    await database.delete('tb_conversation_list');
    await database.insert(
      'tb_conversation_list',
      {'title': '   ', 'stickTime': 100},
    );
    evidence = await loader.load(
      accountHash: 'account',
      storage: storage,
      settings: AISettings.defaults(),
    );
    expect(evidence.hasConversationHistory, isFalse);
  });

  test('stored settings reader 严格接收当前 accountHash', () async {
    String? inspectedAccount;
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (accountHash) {
        inspectedAccount = accountHash;
        return accountHash == 'account-with-settings';
      },
    );

    final evidence = await loader.load(
      accountHash: 'account-with-settings',
      storage: storage,
      settings: AISettings.defaults(),
    );

    expect(inspectedAccount, 'account-with-settings');
    expect(evidence.hasStoredSettings, isTrue);
  });

  test('任意 non-system provider 都算自定义 provider', () async {
    final settings = AISettings.defaults();
    settings.providers.add(
      AiProvider(
        id: 'custom-1',
        type: 'openai',
        name: 'Custom',
      ),
    );
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (_) => false,
    );

    final evidence = await loader.load(
      accountHash: 'account',
      storage: storage,
      settings: settings,
    );

    expect(evidence.hasCustomProvider, isTrue);
  });

  test('当前或非当前模型任一 success 都算成功健康检查', () async {
    final settings = AISettings.defaults();
    final active = settings.activeProvider;
    active.models.first.lastTestStatus = 'unknown';
    active.models.last.lastTestStatus = 'success';
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (_) => false,
    );

    var evidence = await loader.load(
      accountHash: 'account',
      storage: storage,
      settings: settings,
    );
    expect(evidence.hasSuccessfulHealthCheck, isTrue);

    for (final provider in settings.providers) {
      for (final model in provider.models) {
        model.lastTestStatus = 'unknown';
      }
    }
    active.models.first.lastTestStatus = 'success';
    evidence = await loader.load(
      accountHash: 'account',
      storage: storage,
      settings: settings,
    );
    expect(evidence.hasSuccessfulHealthCheck, isTrue);
  });

  test('空数据库和默认设置的四项证据全为 false', () async {
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (_) => false,
    );

    final evidence = await loader.load(
      accountHash: 'fresh-account',
      storage: storage,
      settings: AISettings.defaults(),
    );

    expect(evidence, AIOnboardingEvidence.empty);
  });

  test('会话表尚未创建时按没有历史处理', () async {
    await database.execute('drop table tb_conversation_list');
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (_) => false,
    );

    final evidence = await loader.load(
      accountHash: 'fresh-account',
      storage: storage,
      settings: AISettings.defaults(),
    );

    expect(evidence.hasConversationHistory, isFalse);
  });

  test('非 no-such-table 的数据库错误会上抛而不是误判新账号', () async {
    await database.close();
    final loader = AIOnboardingEvidenceLoader(
      hasStoredSettings: (_) => false,
    );

    await expectLater(
      loader.load(
        accountHash: 'legacy-account',
        storage: storage,
        settings: AISettings.defaults(),
      ),
      throwsA(anything),
    );

    // 让通用 tearDown 关闭一个有效句柄，避免重复关闭干扰其它测试。
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });
}
