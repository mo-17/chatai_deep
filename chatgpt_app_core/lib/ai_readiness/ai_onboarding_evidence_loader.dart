import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:sqflite/sqflite.dart';

typedef AIOnboardingStoredSettingsReader = bool Function(String accountHash);
typedef AIOnboardingConversationHistoryReader = Future<bool> Function(
  HiDBManager storage,
);

/// 从指定账号已经打开的 DB 和已加载设置中读取旧用户证据。
///
/// 本类不会自行推导数据库名、打开 guest DB 或切换账号。
final class AIOnboardingEvidenceLoader {
  final AIOnboardingStoredSettingsReader _hasStoredSettings;
  final AIOnboardingConversationHistoryReader _hasConversationHistory;

  AIOnboardingEvidenceLoader({
    AIOnboardingStoredSettingsReader? hasStoredSettings,
    AIOnboardingConversationHistoryReader? hasConversationHistory,
  })  : _hasStoredSettings = hasStoredSettings ?? AISettingsDao.hasSettings,
        _hasConversationHistory =
            hasConversationHistory ?? _readConversationHistory;

  Future<AIOnboardingEvidence> load({
    required String accountHash,
    required HiDBManager storage,
    required AISettings settings,
  }) async {
    final hasHistory = await _hasConversationHistory(storage);
    final hasCustomProvider =
        settings.providers.any((provider) => !provider.isSystem);
    final hasSuccessfulHealthCheck = settings.providers.any(
      (provider) => provider.models.any(
        (model) => model.lastTestStatus.trim().toLowerCase() == 'success',
      ),
    );

    return AIOnboardingEvidence(
      hasStoredSettings: _hasStoredSettings(accountHash),
      hasConversationHistory: hasHistory,
      hasCustomProvider: hasCustomProvider,
      hasSuccessfulHealthCheck: hasSuccessfulHealthCheck,
    );
  }

  static Future<bool> _readConversationHistory(HiDBManager storage) async {
    try {
      final rows = await storage.db.rawQuery(
        'select 1 from tb_conversation_list '
        "where title is not null and length(trim(title)) > 0 limit 1",
      );
      return rows.isNotEmpty;
    } on DatabaseException catch (error) {
      if (error.isNoSuchTableError('tb_conversation_list')) {
        // 新账号可能尚未触发会话 DAO 建表；这与“没有历史”语义相同。
        return false;
      }
      // 锁、I/O、损坏等错误不能被当作“新账号”，交给上层重试，避免把旧
      // 用户误分类后主动展示首次配置。
      rethrow;
    }
  }
}
