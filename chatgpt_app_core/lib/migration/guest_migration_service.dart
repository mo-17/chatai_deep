import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 游客数据一次性迁移（登录正式账号时把游客模式攒下的会话/AI 设置导入新账号）。
///
/// 游客的本地数据独立存在 `guest` 账号分区下（会话库 `guest.db` +
/// AI 设置 key `ai_settings_v1_guest`），登出/登录都不会删除它。本服务在
/// 用户首次以正式账号进入主页时检测这批数据，弹窗征得同意后整体导入。
///
/// 复用 [BackupService] 的导出/导入（四表 + 设置），导入是**覆盖式**，因此
/// 只在目标账号「为空」时提示，避免误删账号既有数据。每个账号只问一次。
class GuestMigrationService {
  /// 游客分区固定 hash（与 [LoginDao.loginAsGuest] 写入的 accountHash 一致）。
  static const guestHash = 'guest';

  /// 「已处理过」标记 key（导入或拒绝后都置位，之后不再提示）。
  static String doneKey(String hash) => 'guest_migrated_$hash';

  /// 是否应向当前账号提示迁移：
  /// - 当前为正式账号（非游客）且能取到 accountHash；
  /// - 该账号尚未处理过（无 done 标记）；
  /// - 目标账号为空（无会话且未存过 AI 设置）——保证覆盖式导入不删数据；
  /// - 游客侧确有可迁移的数据（有会话或有 AI 设置）。
  static Future<bool> shouldPrompt() async {
    if (LoginDao.isGuest()) return false;
    final hash = LoginDao.getAccountHash();
    if (hash == null || hash == guestHash) return false;
    if (HiCache.getInstance().get(doneKey(hash)) != null) return false;

    // 目标账号必须是空账号
    final account = await HiDBManager.instance(dbName: hash);
    if (await _conversationCount(account) > 0) return false;
    if (AISettingsDao.hasSettings(hash)) return false;

    // 游客侧要有东西可迁
    final guest = await HiDBManager.instance(dbName: guestHash);
    final guestHasData = await _conversationCount(guest) > 0 ||
        AISettingsDao.hasSettings(guestHash);
    return guestHasData;
  }

  /// 执行迁移：把游客库 + 游客 AI 设置导入当前（正式）账号，落盘设置并置位标记。
  /// 调用前应已通过 [shouldPrompt]。失败会抛出，调用方据此决定是否提示重试。
  static Future<BackupRestoreResult> migrate() async {
    final hash = LoginDao.getAccountHash();
    if (hash == null || hash == guestHash) {
      throw StateError('当前不是正式账号，无法迁移游客数据');
    }
    final guest = await HiDBManager.instance(dbName: guestHash);
    final to = await HiDBManager.instance(dbName: hash);
    final result = await migrateBetween(
      from: guest,
      to: to,
      guestSettings: AISettingsDao.loadFor(guestHash),
      toAccountHash: hash,
    );
    // 把游客的 AI 设置（含 key，迁移时不脱敏）落到当前账号 key 下。
    if (result.settings != null) {
      await AISettingsDao.save(result.settings!);
    }
    await markDone();
    AILogger.log('guest migration done -> $hash: '
        '${result.conversations} conversations, ${result.messages} messages');
    return result;
  }

  /// 标记当前账号已处理（导入成功或用户拒绝都调用），之后不再提示。
  static Future<void> markDone() async {
    final hash = LoginDao.getAccountHash();
    if (hash == null) return;
    await HiCache.getInstance().setString(doneKey(hash), '1');
  }

  /// 迁移核心（纯库操作，便于单测）：用 [BackupService] 把 [from] 库 +
  /// [guestSettings] 不脱敏导出，再覆盖式导入 [to] 库。
  static Future<BackupRestoreResult> migrateBetween({
    required HiDBManager from,
    required HiDBManager to,
    required AISettings guestSettings,
    required String toAccountHash,
  }) async {
    final zip = await BackupService(from).exportArchive(
      settings: guestSettings,
      accountHash: guestHash,
      includeApiKeys: true,
    );
    return BackupService(to).importArchive(zip, accountHash: toAccountHash);
  }

  static Future<int> _conversationCount(HiDBManager storage) async {
    // 确保表存在（DAO 懒建表），空账号也能安全计数。
    await ConversationListDao.create(storage);
    final rows = await storage.db
        .rawQuery('select count(*) as c from tb_conversation_list');
    return (rows.first['c'] as int?) ?? 0;
  }
}
