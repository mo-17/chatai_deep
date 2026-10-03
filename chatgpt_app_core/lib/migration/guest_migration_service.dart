import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/skill_catalog_dao.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:sqflite/sqflite.dart';

/// 一次迁移的统计。
class GuestMigrationResult {
  final int conversations;
  final int messages;
  final int assistants;
  final int favorites;
  final int projects;
  final int memories;

  /// 是否套用了游客的 AI 设置（仅在账号原本没有设置时才会）。
  final bool settingsImported;

  const GuestMigrationResult({
    this.conversations = 0,
    this.messages = 0,
    this.assistants = 0,
    this.favorites = 0,
    this.projects = 0,
    this.memories = 0,
    this.settingsImported = false,
  });
}

typedef GuestMigrationStorageResolver = Future<HiDBManager> Function(
  String hash,
);

/// 游客数据一次性迁移（登录正式账号时把游客模式攒下的会话/AI 设置导入新账号）。
///
/// 游客的本地数据独立存在 `guest` 账号分区下（会话库 `guest.db` +
/// AI 设置 key `ai_settings_v1_guest`），登出/登录都不会删除它。本服务在
/// 用户首次以正式账号进入主页时检测这批数据，弹窗征得同意后整体导入。
///
/// 采用**行级合并**（追加，不覆盖）：助手/长期记忆/消息/收藏走追加写入；会话
/// 以唯一 `cid` 为业务键，与账号既有 cid 冲突时重映射到新 cid，并同步改写消息
/// 与长期记忆的 cid、assistantId 引用。因此对**已有数据的账号**也安全。
/// AI 设置只在账号原本没有设置时才套用，避免覆盖已配置账号。
class GuestMigrationService {
  /// 游客分区固定 hash（与 [LoginDao.loginAsGuest] 写入的 accountHash 一致）。
  static const guestHash = 'guest';
  static const _migrationJournalTable = 'tb_guest_migration_journal';
  static const _guestImportJournalKey = 'guest_import_v1';

  /// 「已处理过」标记 key（导入或拒绝后都置位，之后不再提示）。
  static String doneKey(String hash) => 'guest_migrated_$hash';

  /// 是否应向当前账号提示迁移：
  /// - 当前为正式账号（非游客）且能取到 accountHash；
  /// - 该账号尚未处理过（无 done 标记）；
  /// - 游客侧确有可迁移的数据（有会话、有效长期记忆或 AI 设置）。
  ///
  /// 不再要求目标账号为空——行级合并对已有数据的账号同样安全。
  static Future<bool> shouldPrompt({
    GuestMigrationStorageResolver? storageResolver,
  }) async {
    if (LoginDao.isGuest()) return false;
    final hash = LoginDao.getAccountHash();
    if (hash == null || hash == guestHash) return false;
    if (HiCache.getInstance().get(doneKey(hash)) != null) return false;

    final resolve = storageResolver ??
        (String value) => HiDBManager.instance(dbName: value);
    final guest = await resolve(guestHash);
    if (await _conversationCount(guest) > 0 ||
        await _validMemoryCount(guest) > 0 ||
        await _hasValidSkillCatalog(guest)) {
      return true;
    }
    // 系统恢复可能只留下 secure v2 快照；先强一致准备，才能恢复普通 marker。
    await AISettingsDao.loadForAsync(guestHash);
    return AISettingsDao.hasSettings(guestHash);
  }

  /// 执行迁移：把游客库合并进当前（正式）账号库，必要时套用游客 AI 设置，
  /// 刷新会话列表并置位标记。调用前应已通过 [shouldPrompt]。失败会抛出。
  static Future<GuestMigrationResult> migrate({
    GuestMigrationStorageResolver? storageResolver,
  }) async {
    final hash = LoginDao.getAccountHash();
    if (hash == null || hash == guestHash) {
      throw StateError('当前不是正式账号，无法迁移游客数据');
    }

    final resolve = storageResolver ??
        (String value) => HiDBManager.instance(dbName: value);
    return LoginDao.runWithStableAccount<GuestMigrationResult>(
      expectedAccountHash: hash,
      action: () async {
        // 先强一致读取 guest secrets；失败时不得先合并数据库，否则重试会重复追加。
        final candidate = await AISettingsDao.loadForAsync(guestHash);
        final guestSettings =
            AISettingsDao.hasSettings(guestHash) ? candidate : null;

        final guest = await resolve(guestHash);
        final to = await resolve(hash);
        final counts = await mergeGuestData(
          from: guest,
          to: to,
          idempotencyKey: _guestImportJournalKey,
        );

        // prepare/check/write 在 AISettingsDao 的同账号队列中原子完成，不能覆盖
        // lease 期间已经排队或落盘的目标账号设置。
        final settingsImported = guestSettings != null &&
            await AISettingsDao.saveForIfAbsent(hash, guestSettings);

        // 通知会话列表等常驻页面重新加载，并只给捕获到的账号置位。
        BackupService.restoreTick.value++;
        await _markDoneFor(hash);
        AILogger.log('guest migration done -> $hash: '
            '${counts.conversations} conversations, '
            '${counts.messages} messages, ${counts.projects} projects, '
            '${counts.memories} memories, settings=$settingsImported');
        return GuestMigrationResult(
          conversations: counts.conversations,
          messages: counts.messages,
          assistants: counts.assistants,
          favorites: counts.favorites,
          projects: counts.projects,
          memories: counts.memories,
          settingsImported: settingsImported,
        );
      },
    );
  }

  /// 用户拒绝迁移时，标记当前账号已处理，之后不再提示。
  static Future<void> markDone() async {
    final hash = LoginDao.getAccountHash();
    if (hash == null) return;
    await _markDoneFor(hash);
  }

  static Future<void> _markDoneFor(String hash) async {
    final prefs = HiCache.getInstance().prefs;
    if (prefs == null || !await prefs.setString(doneKey(hash), '1')) {
      throw StateError('游客迁移完成标记写入失败');
    }
  }

  /// 行级合并核心（纯库操作，便于单测）：把 [from] 库的会话/消息/助手/长期
  /// 记忆/收藏/项目**追加**进 [to] 库，处理 id/cid 冲突重映射。不动 AI 设置、
  /// 不置标记。
  static Future<GuestMigrationResult> mergeGuestData({
    required HiDBManager from,
    required HiDBManager to,
    String? idempotencyKey,
  }) async {
    await _ensureSchema(from);
    await _ensureSchema(to);

    final assistants = await from.db.query('tb_assistant');
    final skillCatalog =
        await BackupService.readSkillCatalogRows(from, assistants: assistants);
    final conversations = await from.db.query('tb_conversation_list');
    final messages = await from.db.query('tb_messages');
    final favorites = await from.db.query('tb_favorite');
    final projects = await from.db.query('tb_project');
    final memories = await from.db.query('tb_assistant_memory');
    final hasProjectIdColumn =
        await _hasColumn(to.db, 'tb_conversation_list', 'projectId');
    final normalizedConversations = conversations
        .map((c) => _normalizeConversationRow(c, hasProjectIdColumn))
        .toList();

    // 账号现有 cid，用于冲突检测 + 生成新 cid。
    final existing =
        await to.db.query('tb_conversation_list', columns: ['cid']);
    final usedCids = <int>{
      for (final r in existing)
        if (r['cid'] != null) r['cid'] as int,
    };
    var maxCid =
        usedCids.isEmpty ? 0 : usedCids.reduce((a, b) => a > b ? a : b);
    int freshCid() {
      maxCid++;
      while (usedCids.contains(maxCid)) {
        maxCid++;
      }
      return maxCid;
    }

    var conv = 0, msg = 0, ast = 0, fav = 0, prj = 0, mem = 0;
    GuestMigrationResult? journalResult;
    await to.db.transaction((txn) async {
      if (idempotencyKey != null) {
        // journal 的 schema、幂等检查和业务插入必须在同一事务中：
        // 任何中途失败都不得留下「已开始迁移」的局部状态。
        await _ensureMigrationJournal(txn);
        final committed = await txn.query(
          _migrationJournalTable,
          where: 'migrationKey = ?',
          whereArgs: [idempotencyKey],
          limit: 1,
        );
        if (committed.isNotEmpty) {
          journalResult = _resultFromJournal(committed.single);
          return;
        }
      }

      // 助手：丢弃原 id，自增插入，记录 旧id→新id。
      final assistantIdMap = <int, int>{};
      for (final a in assistants) {
        final row = Map<String, Object?>.from(a);
        final oldId = row.remove('id') as int?;
        final newId = await txn.insert('tb_assistant', row);
        if (oldId != null) assistantIdMap[oldId] = newId;
        ast++;
      }

      // Skill 正文和引用跟随助手同事务迁移；创建时间保留，只改助手 id。
      for (final skill in skillCatalog) {
        final newId = assistantIdMap[_intValue(skill['assistantId'])];
        if (newId == null) continue;
        await txn.insert('tb_skill_catalog', {
          ...skill,
          'assistantId': newId,
        });
      }

      // 项目：丢弃原 id，自增插入，记录 旧id→新id。
      final projectIdMap = <int, int>{};
      for (final p in projects) {
        final row = Map<String, Object?>.from(p);
        final oldId = row.remove('id') as int?;
        final defaultAssistantId = row['defaultAssistantId'] as int?;
        if (defaultAssistantId != null) {
          row['defaultAssistantId'] = assistantIdMap[defaultAssistantId];
        }
        final newId = await txn.insert('tb_project', row);
        if (oldId != null) projectIdMap[oldId] = newId;
        prj++;
      }

      // 会话：cid 冲突重映射，assistantId 按助手映射改写，丢弃自增 id。
      final cidMap = <int, int>{};
      for (final c in normalizedConversations) {
        final row = Map<String, Object?>.from(c);
        row.remove('id');
        final oldCid = row['cid'] as int?;
        if (oldCid != null) {
          final target = usedCids.contains(oldCid) ? freshCid() : oldCid;
          usedCids.add(target);
          cidMap[oldCid] = target;
          row['cid'] = target;
        }
        final aid = row['assistantId'] as int?;
        if (aid != null) {
          // 找不到对应助手时回落「无助手」而不是悬空引用。
          row['assistantId'] = assistantIdMap[aid];
        }
        final pid = row['projectId'] as int?;
        if (pid != null) {
          // 找不到对应项目时回落「未分类」。
          row['projectId'] = projectIdMap[pid];
        }
        await txn.insert('tb_conversation_list', row);
        conv++;
      }

      // 长期记忆：只迁移已成功映射的助手，稳定 memoryId 无冲突时保留；
      // 与目标库或本批次冲突时生成新的 UUID v4。
      final existingMemoryRows = await txn.query(
        'tb_assistant_memory',
        columns: ['memoryId'],
      );
      final usedMemoryIds = <String>{
        for (final row in existingMemoryRows)
          if (row['memoryId'] != null && row['memoryId'].toString().isNotEmpty)
            row['memoryId'].toString(),
      };
      for (final memory in memories) {
        final row = Map<String, Object?>.from(memory);
        row.remove('id');
        final oldAssistantId = _intValue(row['assistantId']);
        final newAssistantId =
            oldAssistantId == null ? null : assistantIdMap[oldAssistantId];
        if (newAssistantId == null) continue;
        row['assistantId'] = newAssistantId;

        if (row['assistantSyncId']?.toString() == 'legacy:$oldAssistantId') {
          row['assistantSyncId'] = 'legacy:$newAssistantId';
        }

        final sourceConversationId =
            row['sourceConversationId']?.toString() ?? '';
        final sourceCid = int.tryParse(sourceConversationId);
        final mappedSourceCid = sourceCid == null ? null : cidMap[sourceCid];
        if (mappedSourceCid != null) {
          row['sourceConversationId'] = '$mappedSourceCid';
        }

        var memoryId = row['memoryId']?.toString() ?? '';
        if (memoryId.isEmpty || usedMemoryIds.contains(memoryId)) {
          do {
            memoryId = generateUuidV4();
          } while (usedMemoryIds.contains(memoryId));
          row['memoryId'] = memoryId;
        }
        usedMemoryIds.add(memoryId);
        await txn.insert('tb_assistant_memory', row);
        mem++;
      }

      // 消息：cid 按会话映射改写，丢弃自增 id。
      for (final m in messages) {
        final row = Map<String, Object?>.from(m);
        row.remove('id');
        final oldCid = row['cid'] as int?;
        if (oldCid != null) {
          row['cid'] = cidMap[oldCid] ?? oldCid;
        }
        await txn.insert('tb_messages', row);
        msg++;
      }

      // 收藏：无外键，丢弃自增 id 直接追加。
      for (final f in favorites) {
        final row = Map<String, Object?>.from(f);
        row.remove('id');
        await txn.insert('tb_favorite', row);
        fav++;
      }

      if (idempotencyKey != null) {
        await txn.insert(_migrationJournalTable, {
          'migrationKey': idempotencyKey,
          'conversations': conv,
          'messages': msg,
          'assistants': ast,
          'favorites': fav,
          'projects': prj,
          'memories': mem,
          'committedAt': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });

    if (journalResult != null) return journalResult!;
    return GuestMigrationResult(
      conversations: conv,
      messages: msg,
      assistants: ast,
      favorites: fav,
      projects: prj,
      memories: mem,
    );
  }

  static Future<void> _ensureMigrationJournal(DatabaseExecutor db) async {
    await db.execute('''
      create table if not exists $_migrationJournalTable (
        migrationKey text primary key,
        conversations integer not null,
        messages integer not null,
        assistants integer not null,
        favorites integer not null,
        projects integer not null,
        memories integer not null default 0,
        committedAt integer not null
      )
    ''');
    if (await _hasColumn(db, _migrationJournalTable, 'memories')) return;
    try {
      await db.execute(
        'alter table $_migrationJournalTable '
        'add column memories integer not null default 0',
      );
    } catch (_) {
      // 并发/历史升级若已补列可继续；其它失败必须让事务回滚。
      if (!await _hasColumn(db, _migrationJournalTable, 'memories')) rethrow;
    }
  }

  static GuestMigrationResult _resultFromJournal(Map<String, Object?> row) =>
      GuestMigrationResult(
        conversations: (row['conversations'] as num?)?.toInt() ?? 0,
        messages: (row['messages'] as num?)?.toInt() ?? 0,
        assistants: (row['assistants'] as num?)?.toInt() ?? 0,
        favorites: (row['favorites'] as num?)?.toInt() ?? 0,
        projects: (row['projects'] as num?)?.toInt() ?? 0,
        memories: (row['memories'] as num?)?.toInt() ?? 0,
      );

  /// 通过各 DAO 静态工厂确保迁移表存在且 schema 最新（含历史 ALTER）。
  static Future<void> _ensureSchema(HiDBManager storage) async {
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await AssistantDao.create(storage);
    await FavoriteDao.create(storage);
    await ProjectDao.create(storage);
    await AssistantMemoryDao.create(storage);
    await SkillCatalogDao.create(storage);
    await _ensureConversationProjectIdColumn(storage.db);
  }

  static Future<void> _ensureConversationProjectIdColumn(Database db) async {
    if (await _hasColumn(db, 'tb_conversation_list', 'projectId')) return;
    try {
      await db.execute(
          'alter table tb_conversation_list add column projectId integer');
    } catch (_) {
      // 列已存在时 SQLite 报 duplicate column，可忽略。
    }
  }

  static Future<bool> _hasColumn(
      DatabaseExecutor db, String table, String column) async {
    final rows = await db.rawQuery('pragma table_info($table)');
    return rows.any((r) => (r['name'] ?? '').toString() == column);
  }

  static Map<String, Object?> _normalizeConversationRow(
    Map<String, dynamic> row,
    bool hasProjectIdColumn,
  ) {
    final r = Map<String, Object?>.from(row);
    if (!hasProjectIdColumn) {
      r.remove('projectId');
      return r;
    }
    if (r.containsKey('projectId') && r['projectId'] != null) {
      final rawProjectId = r['projectId'];
      r['projectId'] =
          rawProjectId is int ? rawProjectId : int.tryParse('$rawProjectId');
    }
    return r;
  }

  static Future<int> _conversationCount(HiDBManager storage) async {
    await ConversationListDao.create(storage);
    final rows = await storage.db
        .rawQuery('select count(*) as c from tb_conversation_list');
    return (rows.first['c'] as int?) ?? 0;
  }

  static Future<int> _validMemoryCount(HiDBManager storage) async {
    await AssistantDao.create(storage);
    await AssistantMemoryDao.create(storage);
    final rows = await storage.db.rawQuery(
      'select count(*) as c from tb_assistant_memory memory '
      'inner join tb_assistant assistant '
      'on assistant.id = memory.assistantId',
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  static Future<bool> _hasValidSkillCatalog(HiDBManager storage) async {
    final tables = await storage.db.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ? and name = ?',
      whereArgs: ['table', 'tb_skill_catalog'],
      limit: 1,
    );
    if (tables.isEmpty) return false;
    final rows = await storage.db.rawQuery('''
      select c.assistantId from tb_skill_catalog c
      inner join tb_assistant a on a.id = c.assistantId
        and a.createdAt = c.assistantCreatedAt
        and a.prompt = c.body
      limit 1
    ''');
    return rows.isNotEmpty;
  }

  static int? _intValue(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }
}
