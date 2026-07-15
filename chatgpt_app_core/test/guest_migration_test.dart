import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 游客数据**行级合并** [GuestMigrationService.mergeGuestData] 验收：
/// 追加到空账号 / 追加到已有数据且 cid+助手 id 冲突的账号（重映射正确）。
/// 走真实 DAO（HiDBManager.test 注入 ffi 临时文件库——两库需同时打开，
/// 不能用共享的 :memory:）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;

  setUpAll(() async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    tmpDir = await Directory.systemTemp.createTemp('guest_mig_test');
  });

  setUp(() async {
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
    LoginSdkConfig.reset();
    await HiCache.getInstance().prefs?.clear();
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
    LoginSdkConfig.reset();
  });

  tearDownAll(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  var seq = 0;
  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${tmpDir.path}/db_${seq++}.db'));

  Future<_MemorySecureStore> seedGuestSecureOnlySettings(String suffix) async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final guestSettings = AISettings.defaults();
    guestSettings.activeProvider.apiKey = 'guest-$suffix-secret';
    await AISettingsDao.saveFor(GuestMigrationService.guestHash, guestSettings);
    await HiCache.getInstance().prefs?.remove(
          AISettingsDao.keyFor(GuestMigrationService.guestHash),
        );
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    expect(
      AISettingsDao.hasSettings(GuestMigrationService.guestHash),
      isFalse,
    );
    return secureStore;
  }

  /// 在 [storage] 里造一个「助手 + 绑定它的会话(cid) + 一条消息 + 一条收藏」。
  /// 返回 (助手 id)。
  Future<int> seedOne(
    HiDBManager storage, {
    required int cid,
    required String assistantName,
    required String convTitle,
    required String msgContent,
    String? projectName,
  }) async {
    final assistantDao = await AssistantDao.create(storage);
    final aid = await assistantDao
        .saveAssistant(AssistantModel(name: assistantName, prompt: 'p'));
    final convDao = await ConversationListDao.create(storage);
    int? projectId;
    if (projectName != null) {
      final projectDao = await ProjectDao.create(storage);
      final project = ProjectModel(name: projectName, defaultAssistantId: aid);
      await projectDao.saveProject(project);
      projectId = project.id;
    }
    await convDao.saveConversation(ConversationModel(
        cid: cid, icon: '', assistantId: aid, projectId: projectId)
      ..title = convTitle
      ..stickTime = 0
      ..updateAt = 1);
    await MessageDao.create(storage, cid: cid);
    await storage.db.insert('tb_messages', {
      'cid': cid,
      'content': msgContent,
      'createdAt': 111,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await FavoriteDao.create(storage);
    await storage.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '收藏-$convTitle', 'createdAt': 333});
    return aid!;
  }

  test('合并到空账号：计数正确，助手绑定（重映射 id）保留', () async {
    final guest = await newDb();
    final gAid = await seedOne(guest,
        cid: 2001,
        assistantName: '游客助手',
        convTitle: '游客会话',
        msgContent: '游客问题',
        projectName: '游客项目');

    final account = await newDb();
    final r =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);
    await guest.db.close();

    expect(r.conversations, 1);
    expect(r.messages, 1);
    expect(r.assistants, 1);
    expect(r.favorites, 1);
    expect(r.projects, 1);

    final conv =
        await account.db.query('tb_conversation_list', where: 'cid = 2001');
    final newAid = conv.single['assistantId'] as int;
    final assistant =
        await (await AssistantDao.create(account)).getAssistant(newAid);
    expect(assistant!.name, '游客助手');
    final project = (await account.db.query('tb_project',
            where: 'id = ?', whereArgs: [conv.single['projectId']]))
        .single;
    expect(project['name'], '游客项目');
    expect(project['defaultAssistantId'], newAid);
    // 空账号无冲突：助手 id 仍从 1 起，guest 原 id 也是 1，这里只验证名字对得上。
    expect(gAid, isNotNull);
    await account.db.close();
  });

  test('合并到已有数据账号：cid 与助手 id 冲突时重映射，账号原数据不动', () async {
    // 账号已有：助手(id=1) + 会话 cid=2001。
    final account = await newDb();
    final accAid = await seedOne(account,
        cid: 2001,
        assistantName: '账号助手',
        convTitle: '账号会话',
        msgContent: '账号消息',
        projectName: '账号项目');

    // 游客也有：助手(id=1) + 会话 cid=2001（与账号冲突）。
    final guest = await newDb();
    await seedOne(guest,
        cid: 2001,
        assistantName: '游客助手',
        convTitle: '游客会话',
        msgContent: '游客消息',
        projectName: '游客项目');

    final r =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);
    await guest.db.close();
    expect(r.conversations, 1);

    // 现在账号应有 2 个会话、2 个助手、2 条消息、2 条收藏。
    final convs = await account.db.query('tb_conversation_list');
    expect(convs.length, 2);
    final assistants = await account.db.query('tb_assistant');
    expect(assistants.length, 2);
    expect((await account.db.query('tb_messages')).length, 2);
    expect((await account.db.query('tb_favorite')).length, 2);
    expect((await account.db.query('tb_project')).length, 2);

    // 账号原会话 cid=2001 仍在，且仍绑账号助手（名字=账号助手）。
    final accConv =
        (await account.db.query('tb_conversation_list', where: 'cid = 2001'))
            .single;
    expect(accConv['assistantId'], accAid);
    final accAssistant = await (await AssistantDao.create(account))
        .getAssistant(accConv['assistantId'] as int);
    expect(accAssistant!.name, '账号助手');

    // 游客会话被重映射到新 cid（≠2001），绑定的是新插入的「游客助手」，
    // 且其消息也跟到了新 cid。
    final guestConv = (await account.db.query('tb_conversation_list',
            where: 'title = ?', whereArgs: ['游客会话']))
        .single;
    final guestCid = guestConv['cid'] as int;
    expect(guestCid, isNot(2001));
    final guestAssistant = await (await AssistantDao.create(account))
        .getAssistant(guestConv['assistantId'] as int);
    expect(guestAssistant!.name, '游客助手');
    final guestMsgs = await account.db
        .query('tb_messages', where: 'cid = ?', whereArgs: [guestCid]);
    expect(guestMsgs.single['content'], '游客消息');
    final guestProject = (await account.db.query('tb_project',
            where: 'id = ?', whereArgs: [guestConv['projectId']]))
        .single;
    expect(guestProject['name'], '游客项目');
    expect(guestProject['defaultAssistantId'], guestConv['assistantId']);
    await account.db.close();
  });

  test('合并游客长期记忆时重映射助手、会话与冲突 memoryId', () async {
    final account = await newDb();
    final accountAid = await seedOne(
      account,
      cid: 2001,
      assistantName: '账号助手',
      convTitle: '账号会话',
      msgContent: '账号消息',
    );
    final accountMemoryDao = await AssistantMemoryDao.create(account);
    await accountMemoryDao.saveMemory(AssistantMemoryModel(
      assistantId: accountAid,
      content: '账号原记忆',
      memoryId: 'shared-memory-id',
      assistantSyncId: 'legacy:$accountAid',
      sourceConversationId: '2001',
      sourceMessageId: '111',
    ));

    final guest = await newDb();
    final guestAid = await seedOne(
      guest,
      cid: 2001,
      assistantName: '游客助手',
      convTitle: '游客会话',
      msgContent: '游客消息',
    );
    final guestMemoryDao = await AssistantMemoryDao.create(guest);
    await guestMemoryDao.saveMemory(AssistantMemoryModel(
      assistantId: guestAid,
      content: '游客长期记忆',
      memoryId: 'shared-memory-id',
      assistantSyncId: 'legacy:$guestAid',
      sourceConversationId: '2001',
      sourceMessageId: '111',
    ));
    await guestMemoryDao.saveMemory(AssistantMemoryModel(
      assistantId: guestAid,
      content: '游客稳定引用记忆',
      source: 'assistant',
      memoryId: 'stable-memory-id',
      assistantSyncId: 'assistant-stable-id',
      sourceType: 'conversation',
      sourceConversationId: 'conversation-stable-id',
      sourceMessageId: 'message-stable-id',
      status: AssistantMemoryStatus.rejected,
      confirmedByUser: false,
      revision: 7,
    ));
    await guestMemoryDao.saveMemory(AssistantMemoryModel(
      assistantId: 999999,
      content: '游客悬空记忆',
      memoryId: 'dangling-memory-id',
      assistantSyncId: 'legacy:999999',
    ));
    final stableSourceMemory = (await guest.db.query(
      'tb_assistant_memory',
      where: 'content = ?',
      whereArgs: ['游客稳定引用记忆'],
    ))
        .single;
    addTearDown(() async {
      await guest.db.close();
      await account.db.close();
    });

    final result =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);

    expect(result.memories, 2);

    final guestAssistant = (await account.db.query(
      'tb_assistant',
      where: 'name = ?',
      whereArgs: ['游客助手'],
    ))
        .single;
    final migratedConversation = (await account.db.query(
      'tb_conversation_list',
      where: 'title = ?',
      whereArgs: ['游客会话'],
    ))
        .single;
    final migratedMemory = (await account.db.query(
      'tb_assistant_memory',
      where: 'content = ?',
      whereArgs: ['游客长期记忆'],
    ))
        .single;

    expect(migratedMemory['assistantId'], guestAssistant['id']);
    expect(
      migratedMemory['assistantSyncId'],
      'legacy:${guestAssistant['id']}',
    );
    expect(migratedMemory['memoryId'], isNot('shared-memory-id'));
    expect(
      migratedMemory['sourceConversationId'],
      '${migratedConversation['cid']}',
    );
    expect(migratedMemory['sourceMessageId'], '111');
    expect(
      migratedMemory['memoryId'],
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      )),
    );

    final stableMemory = (await account.db.query(
      'tb_assistant_memory',
      where: 'content = ?',
      whereArgs: ['游客稳定引用记忆'],
    ))
        .single;
    expect(stableMemory['assistantId'], guestAssistant['id']);
    expect(stableMemory['memoryId'], 'stable-memory-id');
    expect(stableMemory['assistantSyncId'], 'assistant-stable-id');
    for (final field in const [
      'content',
      'source',
      'createdAt',
      'updatedAt',
      'sourceType',
      'sourceConversationId',
      'sourceMessageId',
      'status',
      'confirmedByUser',
      'revision',
    ]) {
      expect(stableMemory[field], stableSourceMemory[field], reason: field);
    }

    expect(
      await account.db.query(
        'tb_assistant_memory',
        where: 'content = ?',
        whereArgs: ['游客悬空记忆'],
      ),
      isEmpty,
    );

    final accountMemory = (await account.db.query(
      'tb_assistant_memory',
      where: 'content = ?',
      whereArgs: ['账号原记忆'],
    ))
        .single;
    expect(accountMemory['assistantId'], accountAid);
    expect(accountMemory['memoryId'], 'shared-memory-id');
  });

  test('shouldPrompt：仅有效助手长期记忆触发，空库与悬空记忆不触发', () async {
    const accountHash = 'account-memory-prompt';
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'real-token',
      userName: 'account-user',
      extras: const {'accountHash': accountHash},
    );
    final guest = await newDb();
    addTearDown(guest.db.close);
    Future<HiDBManager> resolve(String hash) async {
      if (hash == GuestMigrationService.guestHash) return guest;
      throw StateError('unexpected account hash: $hash');
    }

    expect(
      await GuestMigrationService.shouldPrompt(storageResolver: resolve),
      isFalse,
    );

    final memoryDao = await AssistantMemoryDao.create(guest);
    await memoryDao.saveMemory(AssistantMemoryModel(
      assistantId: 999999,
      content: '没有助手的悬空记忆',
      memoryId: 'dangling-prompt-memory-id',
    ));
    expect(
      await GuestMigrationService.shouldPrompt(storageResolver: resolve),
      isFalse,
    );

    final assistantId = await (await AssistantDao.create(guest)).saveAssistant(
      AssistantModel(name: '有效记忆助手', prompt: 'p'),
    );
    await memoryDao.saveMemory(AssistantMemoryModel(
      assistantId: assistantId!,
      content: '仅靠这条有效记忆触发迁移',
      memoryId: 'valid-prompt-memory-id',
    ));
    expect(
      await GuestMigrationService.shouldPrompt(storageResolver: resolve),
      isTrue,
    );
  });

  test('shouldPrompt：仅 secure v2 设置且普通 key 丢失时仍提示迁移', () async {
    const accountHash = 'account-secure-only-prompt';
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'real-token',
      userName: 'account-user',
      extras: const {'accountHash': accountHash},
    );
    final guest = await newDb();
    addTearDown(guest.db.close);
    await seedGuestSecureOnlySettings('prompt');

    final shouldPrompt = await GuestMigrationService.shouldPrompt(
      storageResolver: (hash) async {
        if (hash == GuestMigrationService.guestHash) return guest;
        throw StateError('unexpected account hash: $hash');
      },
    );

    expect(shouldPrompt, isTrue);
    expect(
      AISettingsDao.hasSettings(GuestMigrationService.guestHash),
      isTrue,
    );
    expect(
      (await AISettingsDao.loadForAsync(GuestMigrationService.guestHash))
          .activeProvider
          .apiKey,
      'guest-prompt-secret',
    );
  });

  test('doneKey 形如 guest_migrated_<hash>', () {
    expect(GuestMigrationService.doneKey('acc-new'), 'guest_migrated_acc-new');
  });

  test('migrate：LoginDao 队列中的账号切换等待迁移完成且不污染新账号', () async {
    const accountAHash = 'account-queued-a';
    const accountBHash = 'account-queued-b';
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'token-a',
      userName: 'user-a',
      extras: const {'accountHash': accountAHash},
    );
    final guest = await newDb();
    final accountA = await newDb();
    final accountB = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await accountA.db.close();
      await accountB.db.close();
    });
    await seedOne(
      guest,
      cid: 8001,
      assistantName: '队列切换游客助手',
      convTitle: '队列切换游客会话',
      msgContent: '队列切换游客消息',
    );
    final guestSettings = AISettings.defaults();
    guestSettings.activeProvider.apiKey = 'queued-guest-secret';
    await AISettingsDao.saveFor(GuestMigrationService.guestHash, guestSettings);

    final resolverEntered = Completer<void>();
    final releaseResolver = Completer<void>();
    Future<HiDBManager> resolve(String hash) async {
      if (hash == GuestMigrationService.guestHash) {
        resolverEntered.complete();
        await releaseResolver.future;
        return guest;
      }
      if (hash == accountAHash) return accountA;
      if (hash == accountBHash) return accountB;
      throw StateError('unexpected account hash: $hash');
    }

    final migration = GuestMigrationService.migrate(storageResolver: resolve);
    await resolverEntered.future;
    var switchCompleted = false;
    final switchAccount = LoginDao.saveAuthToken(
      'token-b',
      userName: 'user-b',
      extras: const {'accountHash': accountBHash},
    ).then((_) => switchCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(switchCompleted, isFalse);
    expect(LoginDao.getAccountHash(), accountAHash);
    releaseResolver.complete();
    final result = await migration;
    await switchAccount;

    expect(result.settingsImported, isTrue);
    expect(LoginDao.getAccountHash(), accountBHash);
    expect(
      HiCache.getInstance().get(GuestMigrationService.doneKey(accountAHash)),
      '1',
    );
    expect(
      HiCache.getInstance().get(GuestMigrationService.doneKey(accountBHash)),
      isNull,
    );
    expect(AISettingsDao.hasSettings(accountBHash), isFalse);
    expect(
      (await AISettingsDao.loadForAsync(accountAHash)).activeProvider.apiKey,
      'queued-guest-secret',
    );
    expect(
      await accountA.db.query(
        'tb_conversation_list',
        where: 'title = ?',
        whereArgs: ['队列切换游客会话'],
      ),
      hasLength(1),
    );
    await ConversationListDao.create(accountB);
    expect(await accountB.db.query('tb_conversation_list'), isEmpty);
  });

  test('migrate：绕过 LoginDao 直接切换 storage 时新账号不接收设置或 done', () async {
    const accountAHash = 'account-bypass-a';
    const accountBHash = 'account-bypass-b';
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'token-a',
      userName: 'user-a',
      extras: const {'accountHash': accountAHash},
    );
    final guest = await newDb();
    final accountA = await newDb();
    final accountB = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await accountA.db.close();
      await accountB.db.close();
    });
    await seedOne(
      guest,
      cid: 8101,
      assistantName: '绕过切换游客助手',
      convTitle: '绕过切换游客会话',
      msgContent: '绕过切换游客消息',
    );
    final guestSettings = AISettings.defaults();
    guestSettings.activeProvider.apiKey = 'bypass-guest-secret';
    await AISettingsDao.saveFor(GuestMigrationService.guestHash, guestSettings);

    final resolverEntered = Completer<void>();
    final releaseResolver = Completer<void>();
    Future<HiDBManager> resolve(String hash) async {
      if (hash == GuestMigrationService.guestHash) {
        resolverEntered.complete();
        await releaseResolver.future;
        return guest;
      }
      if (hash == accountAHash) return accountA;
      if (hash == accountBHash) return accountB;
      throw StateError('unexpected account hash: $hash');
    }

    final migration = GuestMigrationService.migrate(storageResolver: resolve);
    await resolverEntered.future;
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'token-b',
      userName: 'user-b',
      extras: const {'accountHash': accountBHash},
    );
    final migrationExpectation = expectLater(
      migration,
      throwsA(isA<LoginAccountChangedException>()),
    );
    releaseResolver.complete();
    await migrationExpectation;

    expect(LoginDao.getAccountHash(), accountBHash);
    expect(
      HiCache.getInstance().get(GuestMigrationService.doneKey(accountBHash)),
      isNull,
    );
    expect(AISettingsDao.hasSettings(accountBHash), isFalse);
    expect(
      HiCache.getInstance().get(GuestMigrationService.doneKey(accountAHash)),
      '1',
    );
    expect(
      (await AISettingsDao.loadForAsync(accountAHash)).activeProvider.apiKey,
      'bypass-guest-secret',
    );
    expect(
      await accountA.db.query(
        'tb_conversation_list',
        where: 'title = ?',
        whereArgs: ['绕过切换游客会话'],
      ),
      hasLength(1),
    );
    await ConversationListDao.create(accountB);
    expect(await accountB.db.query('tb_conversation_list'), isEmpty);
  });

  test('migrate：secure v2 设置在普通 key 丢失后仍可强一致导入', () async {
    const accountHash = 'account-secure-only-import';
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'real-token',
      userName: 'account-user',
      extras: const {'accountHash': accountHash},
    );
    final guest = await newDb();
    final account = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await account.db.close();
    });
    await seedOne(
      guest,
      cid: 8201,
      assistantName: 'secure-only 游客助手',
      convTitle: 'secure-only 游客会话',
      msgContent: 'secure-only 游客消息',
    );
    await seedGuestSecureOnlySettings('import');

    final result = await GuestMigrationService.migrate(
      storageResolver: (hash) async {
        if (hash == GuestMigrationService.guestHash) return guest;
        if (hash == accountHash) return account;
        throw StateError('unexpected account hash: $hash');
      },
    );

    expect(result.conversations, 1);
    expect(result.settingsImported, isTrue);
    expect(
      (await AISettingsDao.loadForAsync(accountHash)).activeProvider.apiKey,
      'guest-import-secret',
    );
    expect(
      await account.db.query(
        'tb_conversation_list',
        where: 'title = ?',
        whereArgs: ['secure-only 游客会话'],
      ),
      hasLength(1),
    );
  });

  test('migrate：secure-v2-only guest secrets 不可读时不合并数据库且不写 doneKey', () async {
    const accountHash = 'account-secure-failure';
    final guest = await newDb();
    final account = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await account.db.close();
    });
    await seedOne(
      guest,
      cid: 4001,
      assistantName: '游客助手',
      convTitle: '不得提前合并的游客会话',
      msgContent: '游客消息',
      projectName: '游客项目',
    );
    await seedOne(
      account,
      cid: 5001,
      assistantName: '账号助手',
      convTitle: '账号原会话',
      msgContent: '账号原消息',
      projectName: '账号原项目',
    );
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'real-token',
      userName: 'account-user',
      extras: const {'accountHash': accountHash},
    );
    expect(LoginDao.getAccountHash(), accountHash);

    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final guestSettings = AISettings.defaults();
    guestSettings.activeProvider.apiKey = 'guest-secret';
    await AISettingsDao.saveFor(GuestMigrationService.guestHash, guestSettings);

    await HiCache.getInstance().prefs?.remove(
          AISettingsDao.keyFor(GuestMigrationService.guestHash),
        );

    AISettingsDao.resetSecureStateForTest();
    secureStore.failReads = true;
    AISettingsDao.configureSecretStore(secureStore);
    expect(
      AISettingsDao.hasSettings(GuestMigrationService.guestHash),
      isFalse,
    );
    final tables = <String, int>{
      for (final table in const [
        'tb_conversation_list',
        'tb_messages',
        'tb_assistant',
        'tb_favorite',
        'tb_project',
      ])
        table: (await account.db.query(table)).length,
    };
    final schemaBefore = await account.db.query(
      'sqlite_master',
      columns: ['type', 'name', 'sql'],
      orderBy: 'type, name',
    );
    final tickBefore = BackupService.restoreTick.value;
    var storageResolved = false;

    await expectLater(
      GuestMigrationService.migrate(
        storageResolver: (hash) async {
          storageResolved = true;
          if (hash == GuestMigrationService.guestHash) return guest;
          if (hash == accountHash) return account;
          throw StateError('unexpected account hash: $hash');
        },
      ),
      throwsA(isA<AISecretsUnavailableException>()),
    );

    for (final entry in tables.entries) {
      expect((await account.db.query(entry.key)).length, entry.value);
    }
    expect(
      await account.db.query(
        'tb_conversation_list',
        where: 'title = ?',
        whereArgs: ['不得提前合并的游客会话'],
      ),
      isEmpty,
    );
    expect(
      HiCache.getInstance().get(GuestMigrationService.doneKey(accountHash)),
      isNull,
    );
    expect(BackupService.restoreTick.value, tickBefore);
    expect(storageResolved, isFalse);
    expect(
      await account.db.query(
        'sqlite_master',
        columns: ['type', 'name', 'sql'],
        orderBy: 'type, name',
      ),
      schemaBefore,
    );
    expect(AISettingsDao.hasSettings(accountHash), isFalse);
  });

  test('migrate：doneKey 丢失后重试不会重复追加已提交的游客数据', () async {
    const accountHash = 'account-idempotent';
    final guest = await newDb();
    final account = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await account.db.close();
    });
    final guestAid = await seedOne(
      guest,
      cid: 6001,
      assistantName: '只迁移一次的助手',
      convTitle: '只迁移一次的会话',
      msgContent: '只迁移一次的消息',
      projectName: '只迁移一次的项目',
    );
    final guestMemoryDao = await AssistantMemoryDao.create(guest);
    await guestMemoryDao.saveMemory(AssistantMemoryModel(
      assistantId: guestAid,
      content: '只迁移一次的记忆',
      memoryId: 'idempotent-memory-id',
      assistantSyncId: 'legacy:$guestAid',
      sourceConversationId: '6001',
      sourceMessageId: '111',
    ));
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'real-token',
      userName: 'account-user',
      extras: const {'accountHash': accountHash},
    );
    Future<HiDBManager> resolve(String hash) async =>
        hash == GuestMigrationService.guestHash ? guest : account;

    final first = await GuestMigrationService.migrate(storageResolver: resolve);
    expect(first.conversations, 1);
    expect(first.messages, 1);
    expect(first.assistants, 1);
    expect(first.favorites, 1);
    expect(first.projects, 1);
    expect(first.memories, 1);
    final afterFirst = <String, int>{
      for (final table in const [
        'tb_conversation_list',
        'tb_messages',
        'tb_assistant',
        'tb_favorite',
        'tb_project',
        'tb_assistant_memory',
      ])
        table: (await account.db.query(table)).length,
    };
    await HiCache.getInstance()
        .prefs!
        .remove(GuestMigrationService.doneKey(accountHash));

    final second =
        await GuestMigrationService.migrate(storageResolver: resolve);

    for (final entry in afterFirst.entries) {
      expect((await account.db.query(entry.key)).length, entry.value);
    }
    expect(second.conversations, first.conversations);
    expect(second.messages, first.messages);
    expect(second.assistants, first.assistants);
    expect(second.favorites, first.favorites);
    expect(second.projects, first.projects);
    expect(second.memories, first.memories);
    expect(
      HiCache.getInstance().get(GuestMigrationService.doneKey(accountHash)),
      '1',
    );
    final journal = await account.db.query('tb_guest_migration_journal');
    expect(journal.length, 1);
    expect(journal.single['memories'], 1);
  });

  test('mergeGuestData：中途失败时 journal 与业务数据一同回滚', () async {
    final guest = await newDb();
    final account = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await account.db.close();
    });
    final guestAid = await seedOne(
      guest,
      cid: 7001,
      assistantName: '必须回滚的助手',
      convTitle: '必须回滚的会话',
      msgContent: '触发失败的消息',
      projectName: '必须回滚的项目',
    );
    final guestMemoryDao = await AssistantMemoryDao.create(guest);
    await guestMemoryDao.saveMemory(AssistantMemoryModel(
      assistantId: guestAid,
      content: '必须随事务回滚的记忆',
      memoryId: 'rollback-memory-id',
      assistantSyncId: 'legacy:$guestAid',
      sourceConversationId: '7001',
    ));

    await AssistantDao.create(account);
    await ConversationListDao.create(account);
    await MessageDao.create(account, cid: 0);
    await FavoriteDao.create(account);
    await ProjectDao.create(account);
    await AssistantMemoryDao.create(account);
    await account.db.execute('''
      create trigger reject_guest_message
      before insert on tb_messages
      begin
        select raise(abort, 'forced migration failure');
      end
    ''');

    await expectLater(
      GuestMigrationService.mergeGuestData(
        from: guest,
        to: account,
        idempotencyKey: 'rollback-test',
      ),
      throwsA(isA<DatabaseException>()),
    );

    for (final table in const [
      'tb_conversation_list',
      'tb_messages',
      'tb_assistant',
      'tb_favorite',
      'tb_project',
      'tb_assistant_memory',
    ]) {
      expect(await account.db.query(table), isEmpty, reason: table);
    }
    final journalTables = await account.db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' and name = ?",
      whereArgs: ['tb_guest_migration_journal'],
    );
    expect(journalTables, isEmpty);
  });

  test('mergeGuestData：旧 journal 自动补 memories 默认列并保持幂等', () async {
    final guest = await newDb();
    final account = await newDb();
    addTearDown(() async {
      await guest.db.close();
      await account.db.close();
    });
    await seedOne(
      guest,
      cid: 7101,
      assistantName: '不应重复迁移的助手',
      convTitle: '不应重复迁移的会话',
      msgContent: '不应重复迁移的消息',
    );
    await account.db.execute('''
      create table tb_guest_migration_journal (
        migrationKey text primary key,
        conversations integer not null,
        messages integer not null,
        assistants integer not null,
        favorites integer not null,
        projects integer not null,
        committedAt integer not null
      )
    ''');
    await account.db.insert('tb_guest_migration_journal', {
      'migrationKey': 'old-journal',
      'conversations': 9,
      'messages': 8,
      'assistants': 7,
      'favorites': 6,
      'projects': 5,
      'committedAt': 1,
    });

    final result = await GuestMigrationService.mergeGuestData(
      from: guest,
      to: account,
      idempotencyKey: 'old-journal',
    );

    expect(result.conversations, 9);
    expect(result.messages, 8);
    expect(result.assistants, 7);
    expect(result.favorites, 6);
    expect(result.projects, 5);
    expect(result.memories, 0);
    final journalColumns = await account.db
        .rawQuery('pragma table_info(tb_guest_migration_journal)');
    expect(
      journalColumns.map((row) => row['name']),
      contains('memories'),
    );
    final journal = (await account.db.query(
      'tb_guest_migration_journal',
      where: 'migrationKey = ?',
      whereArgs: ['old-journal'],
    ))
        .single;
    expect(journal['memories'], 0);
    expect(await account.db.query('tb_assistant'), isEmpty);
    expect(await account.db.query('tb_assistant_memory'), isEmpty);
  });

  test('mergeGuestData：来源数据库旧会话表（无 projectId）可正常迁移', () async {
    final guest = await newDb();
    // 先制造一套旧版会话表：无 projectId 列。
    await guest.db.execute('drop table if exists tb_conversation_list');
    await guest.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer, assistantId integer)');

    // 其余表照常创建，用于完整迁移通路。
    await AssistantDao.create(guest);
    await MessageDao.create(guest, cid: 3001);
    await FavoriteDao.create(guest);

    final assistantDao = await AssistantDao.create(guest);
    final assistId = await assistantDao
        .saveAssistant(AssistantModel(name: '旧版助手', prompt: 'p'));
    await guest.db.insert('tb_conversation_list', {
      'cid': 3001,
      'title': '旧 schema 会话',
      'icon': '',
      'updateAt': 1,
      'messageCount': 1,
      'stickTime': 0,
      'assistantId': assistId,
    });
    await guest.db.insert('tb_messages', {
      'cid': 3001,
      'content': '旧 schema 消息',
      'createdAt': 10,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await guest.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '旧 schema 收藏', 'createdAt': 11});

    final account = await newDb();
    final result =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);
    expect(result.conversations, 1);
    expect(result.messages, 1);
    expect(result.assistants, 1);
    expect(result.favorites, 1);
    expect(result.projects, 0);

    final conv = await account.db
        .query('tb_conversation_list', where: 'cid = ?', whereArgs: [3001]);
    expect(conv.single['assistantId'], isNotNull);
    expect(conv.single['projectId'], isNull);

    await guest.db.close();
    await account.db.close();
  });
}

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('secure read failed');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
