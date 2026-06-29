import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
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

  /// 是否套用了游客的 AI 设置（仅在账号原本没有设置时才会）。
  final bool settingsImported;

  const GuestMigrationResult({
    this.conversations = 0,
    this.messages = 0,
    this.assistants = 0,
    this.favorites = 0,
    this.projects = 0,
    this.settingsImported = false,
  });
}

/// 游客数据一次性迁移（登录正式账号时把游客模式攒下的会话/AI 设置导入新账号）。
///
/// 游客的本地数据独立存在 `guest` 账号分区下（会话库 `guest.db` +
/// AI 设置 key `ai_settings_v1_guest`），登出/登录都不会删除它。本服务在
/// 用户首次以正式账号进入主页时检测这批数据，弹窗征得同意后整体导入。
///
/// 采用**行级合并**（追加，不覆盖）：助手/消息/收藏走自增 id 追加；会话以
/// 唯一 `cid` 为业务键，与账号既有 cid 冲突时重映射到新 cid，并同步改写其
/// 消息的 cid 与会话引用的 assistantId。因此对**已有数据的账号**也安全。
/// AI 设置只在账号原本没有设置时才套用，避免覆盖已配置账号。
class GuestMigrationService {
  /// 游客分区固定 hash（与 [LoginDao.loginAsGuest] 写入的 accountHash 一致）。
  static const guestHash = 'guest';

  /// 「已处理过」标记 key（导入或拒绝后都置位，之后不再提示）。
  static String doneKey(String hash) => 'guest_migrated_$hash';

  /// 是否应向当前账号提示迁移：
  /// - 当前为正式账号（非游客）且能取到 accountHash；
  /// - 该账号尚未处理过（无 done 标记）；
  /// - 游客侧确有可迁移的数据（有会话或有 AI 设置）。
  ///
  /// 不再要求目标账号为空——行级合并对已有数据的账号同样安全。
  static Future<bool> shouldPrompt() async {
    if (LoginDao.isGuest()) return false;
    final hash = LoginDao.getAccountHash();
    if (hash == null || hash == guestHash) return false;
    if (HiCache.getInstance().get(doneKey(hash)) != null) return false;

    final guest = await HiDBManager.instance(dbName: guestHash);
    return await _conversationCount(guest) > 0 ||
        AISettingsDao.hasSettings(guestHash);
  }

  /// 执行迁移：把游客库合并进当前（正式）账号库，必要时套用游客 AI 设置，
  /// 刷新会话列表并置位标记。调用前应已通过 [shouldPrompt]。失败会抛出。
  static Future<GuestMigrationResult> migrate() async {
    final hash = LoginDao.getAccountHash();
    if (hash == null || hash == guestHash) {
      throw StateError('当前不是正式账号，无法迁移游客数据');
    }
    final guest = await HiDBManager.instance(dbName: guestHash);
    final to = await HiDBManager.instance(dbName: hash);
    final counts = await mergeGuestData(from: guest, to: to);

    // AI 设置：仅当账号原本没有设置时才套用游客设置（含 key，不脱敏）。
    var settingsImported = false;
    if (!AISettingsDao.hasSettings(hash) &&
        AISettingsDao.hasSettings(guestHash)) {
      await AISettingsDao.save(AISettingsDao.loadFor(guestHash));
      settingsImported = true;
    }

    // 通知会话列表等常驻页面重新加载。
    BackupService.restoreTick.value++;
    await markDone();
    AILogger.log('guest migration done -> $hash: '
        '${counts.conversations} conversations, ${counts.messages} messages, '
        '${counts.projects} projects, '
        'settings=$settingsImported');
    return GuestMigrationResult(
      conversations: counts.conversations,
      messages: counts.messages,
      assistants: counts.assistants,
      favorites: counts.favorites,
      projects: counts.projects,
      settingsImported: settingsImported,
    );
  }

  /// 标记当前账号已处理（导入成功或用户拒绝都调用），之后不再提示。
  static Future<void> markDone() async {
    final hash = LoginDao.getAccountHash();
    if (hash == null) return;
    await HiCache.getInstance().setString(doneKey(hash), '1');
  }

  /// 行级合并核心（纯库操作，便于单测）：把 [from] 库的会话/消息/助手/收藏
  /// **追加**进 [to] 库，处理 id/cid 冲突重映射。不动 AI 设置、不置标记。
  static Future<GuestMigrationResult> mergeGuestData({
    required HiDBManager from,
    required HiDBManager to,
  }) async {
    await _ensureSchema(from);
    await _ensureSchema(to);

    final assistants = await from.db.query('tb_assistant');
    final conversations = await from.db.query('tb_conversation_list');
    final messages = await from.db.query('tb_messages');
    final favorites = await from.db.query('tb_favorite');
    final projects = await from.db.query('tb_project');
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

    var conv = 0, msg = 0, ast = 0, fav = 0, prj = 0;
    await to.db.transaction((txn) async {
      // 助手：丢弃原 id，自增插入，记录 旧id→新id。
      final assistantIdMap = <int, int>{};
      for (final a in assistants) {
        final row = Map<String, Object?>.from(a);
        final oldId = row.remove('id') as int?;
        final newId = await txn.insert('tb_assistant', row);
        if (oldId != null) assistantIdMap[oldId] = newId;
        ast++;
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
    });

    return GuestMigrationResult(
      conversations: conv,
      messages: msg,
      assistants: ast,
      favorites: fav,
      projects: prj,
    );
  }

  /// 通过各 DAO 静态工厂确保四张表存在且 schema 最新（含历史 ALTER）。
  static Future<void> _ensureSchema(HiDBManager storage) async {
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await AssistantDao.create(storage);
    await FavoriteDao.create(storage);
    await ProjectDao.create(storage);
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
      Database db, String table, String column) async {
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
}
