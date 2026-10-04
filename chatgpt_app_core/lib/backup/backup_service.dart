import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/backup/backup_settings_merge.dart';
import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/story_tavern_preset_transfer.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/skill_catalog_dao.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_entry.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 一次导入的产物：各表行数统计 + 修复告警 + 备份内的 AI 设置。
/// 设置不在这里落库（HiCache/账号 key 属 UI 层关注），由调用方决定怎么应用。
class BackupRestoreResult {
  final int conversations;
  final int messages;
  final int assistants;
  final int assistantMemories;
  final int favorites;
  final int projects;
  final int knowledgeDocs;
  final int knowledgeChunks;
  final int projectKnowledge;
  final int storyTemplates;
  final int storyTemplateTranslationTasks;
  final int storyPersonas;
  final int storyRooms;
  final int storyParticipants;
  final int storyMessages;
  final int storyArtifacts;
  final int storyArtifactRevisions;
  final int generatedImageAssets;

  /// 备份里的 AI 设置（settings.json 缺失时为 null）。
  final AISettings? settings;

  /// 非致命问题（外键修复、账号不一致等），UI 可提示用户。
  final List<String> warnings;

  const BackupRestoreResult({
    this.conversations = 0,
    this.messages = 0,
    this.assistants = 0,
    this.assistantMemories = 0,
    this.favorites = 0,
    this.projects = 0,
    this.knowledgeDocs = 0,
    this.knowledgeChunks = 0,
    this.projectKnowledge = 0,
    this.storyTemplates = 0,
    this.storyTemplateTranslationTasks = 0,
    this.storyPersonas = 0,
    this.storyRooms = 0,
    this.storyParticipants = 0,
    this.storyMessages = 0,
    this.storyArtifacts = 0,
    this.storyArtifactRevisions = 0,
    this.generatedImageAssets = 0,
    this.settings,
    this.warnings = const [],
  });
}

/// 导出产物与仅作提示的规范化报告。导出时的历史孤儿过滤、
/// 重复 ID 重编只发生在 zip 副本中，不会回写 SQLite。
class BackupExportResult {
  final Uint8List bytes;
  final List<String> warnings;

  const BackupExportResult({
    required this.bytes,
    this.warnings = const [],
  });
}

typedef BackupAccountGuard = FutureOr<void> Function();

enum BackupImportMode {
  /// 当前默认行为：覆盖全部本地数据。
  overwriteAll,

  /// 仅导入项目、会话与消息；保留本地助手、收藏、知识库和 AI 设置。
  projectConversationsOnly,

  /// 仅导入助手，并清理当前会话/项目里无法匹配新助手集的引用。
  assistantsOnly,

  /// 仅导入知识库文档、切块和仍能匹配当前项目的知识库绑定。
  knowledgeBaseOnly,

  /// 追加合并导入：保留本地数据，将备份数据按新 id/cid 写入。
  mergeAppend,
}

/// 仅供故障注入测试使用：覆盖资源 staging、目录切换与 SQLite 提交之间的边界。
enum BackupImportFailurePoint {
  /// 所有数据库写入与资源 staging 已完成，尚未切换正式目录。
  beforeResourceSwap,

  /// 第一个资源目录已切换，用来验证部分目录切换也能完整补偿。
  afterFirstResourceDirectorySwap,

  /// 所有资源目录已切换，但 SQLite transaction 尚未提交。
  afterResourceSwap,
}

typedef BackupImportFailureInjector = Future<void> Function(
  BackupImportFailurePoint point,
);

/// 资源补偿阶段可独立失败的文件系统操作，仅供故障注入测试使用。
enum BackupResourceRollbackOperation {
  removeStagedTarget,
  restoreOriginal,
  removeStage,
  removeBackup,
}

typedef BackupResourceRollbackFailureInjector = Future<void> Function(
  int rollbackIndex,
  BackupResourceRollbackOperation operation,
);

/// 导入前预览：只解析 zip 与 manifest，不写数据库、不恢复资源。
class BackupPreview {
  final int formatVersion;
  final int exportedAt;
  final String accountHash;
  final bool includeApiKeys;
  final int conversations;
  final int messages;
  final int assistants;
  final int assistantMemories;
  final int favorites;
  final int projects;
  final int knowledgeDocs;
  final int knowledgeChunks;
  final int projectKnowledge;
  final int storyTemplates;
  final int storyTemplateTranslationTasks;
  final int storyPersonas;
  final int storyRooms;
  final int storyParticipants;
  final int storyMessages;
  final int storyArtifacts;
  final int storyArtifactRevisions;
  final int avatarAssets;
  final int fileAssets;
  final int generatedImageAssets;
  final bool hasSettings;
  final bool integrityVerified;
  final BackupConflictSummary conflictSummary;
  final List<String> warnings;

  const BackupPreview({
    required this.formatVersion,
    required this.exportedAt,
    required this.accountHash,
    required this.includeApiKeys,
    required this.conversations,
    required this.messages,
    required this.assistants,
    this.assistantMemories = 0,
    required this.favorites,
    required this.projects,
    required this.knowledgeDocs,
    required this.knowledgeChunks,
    required this.projectKnowledge,
    this.storyTemplates = 0,
    this.storyTemplateTranslationTasks = 0,
    this.storyPersonas = 0,
    this.storyRooms = 0,
    this.storyParticipants = 0,
    this.storyMessages = 0,
    this.storyArtifacts = 0,
    this.storyArtifactRevisions = 0,
    required this.avatarAssets,
    required this.fileAssets,
    this.generatedImageAssets = 0,
    required this.hasSettings,
    this.integrityVerified = false,
    this.conflictSummary = const BackupConflictSummary(),
    this.warnings = const [],
  });

  int get totalRows =>
      conversations +
      messages +
      assistants +
      assistantMemories +
      favorites +
      projects +
      knowledgeDocs +
      knowledgeChunks +
      projectKnowledge +
      storyTemplates +
      storyTemplateTranslationTasks +
      storyPersonas +
      storyRooms +
      storyParticipants +
      storyMessages +
      storyArtifacts +
      storyArtifactRevisions;

  BackupImportPlan planFor(BackupImportMode mode) {
    BackupTableConflict? table(String name) {
      for (final item in conflictSummary.tableConflicts) {
        if (item.table == name) return item;
      }
      return null;
    }

    BackupImportPlan sum(String scope, List<String> names) {
      var localRows = 0;
      var replacingRows = 0;
      var changedRows = 0;
      var localOnlyRows = 0;
      var backupOnlyRows = 0;
      for (final name in names) {
        final item = table(name);
        if (item == null) continue;
        localRows += item.localRows;
        replacingRows += item.replacingRows;
        changedRows += item.changedRows;
        localOnlyRows += item.localOnlyRows;
        backupOnlyRows += item.backupOnlyRows;
      }
      return BackupImportPlan(
        mode: mode,
        scope: scope,
        localRows: localRows,
        replacingRows: replacingRows,
        changedRows: changedRows,
        localOnlyRows: localOnlyRows,
        backupOnlyRows: backupOnlyRows,
      );
    }

    switch (mode) {
      case BackupImportMode.overwriteAll:
        return BackupImportPlan(
          mode: mode,
          scope: '覆盖全部数据',
          localRows: conflictSummary.localRows,
          replacingRows: conflictSummary.replacingRows,
          changedRows: conflictSummary.changedRows,
          localOnlyRows: conflictSummary.localOnlyRows,
          backupOnlyRows: conflictSummary.backupOnlyRows,
        );
      case BackupImportMode.projectConversationsOnly:
        return sum('仅项目、会话和消息',
            const ['tb_project', 'tb_conversation_list', 'tb_messages']);
      case BackupImportMode.assistantsOnly:
        return sum(
          '仅助手',
          const ['tb_assistant', 'tb_assistant_memory'],
        );
      case BackupImportMode.knowledgeBaseOnly:
        return sum('仅知识库', const ['tb_kb_doc', 'tb_kb_chunk', 'tb_project_kb']);
      case BackupImportMode.mergeAppend:
        final plan = sum('合并导入', const [
          'tb_project',
          'tb_conversation_list',
          'tb_messages',
          'tb_assistant',
          'tb_assistant_memory',
          'tb_favorite',
          'tb_kb_doc',
          'tb_kb_chunk',
          'tb_project_kb',
          'tb_story_template',
          'tb_story_template_translation_task',
          'tb_story_persona',
          'tb_story_room',
          'tb_story_participant',
          'tb_story_message',
          'tb_story_artifact',
          'tb_story_artifact_revision',
        ]);
        return BackupImportPlan(
          mode: mode,
          scope: plan.scope,
          localRows: plan.localRows,
          replacingRows: plan.replacingRows,
          changedRows: plan.changedRows,
          localOnlyRows: 0,
          backupOnlyRows: plan.backupOnlyRows + plan.replacingRows,
        );
    }
  }
}

/// 导入前与当前本地数据的粗粒度冲突/覆盖风险。
class BackupConflictSummary {
  final int localRows;
  final int replacingRows;
  final int localOnlyRows;
  final int backupOnlyRows;
  final int changedRows;
  final List<BackupTableConflict> tableConflicts;

  const BackupConflictSummary({
    this.localRows = 0,
    this.replacingRows = 0,
    this.localOnlyRows = 0,
    this.backupOnlyRows = 0,
    this.changedRows = 0,
    this.tableConflicts = const [],
  });

  bool get hasLocalData => localRows > 0;
  bool get hasConflict =>
      replacingRows > 0 || localOnlyRows > 0 || changedRows > 0;
}

class BackupImportPlan {
  final BackupImportMode mode;
  final String scope;
  final int localRows;
  final int replacingRows;
  final int changedRows;
  final int localOnlyRows;
  final int backupOnlyRows;

  const BackupImportPlan({
    required this.mode,
    required this.scope,
    this.localRows = 0,
    this.replacingRows = 0,
    this.changedRows = 0,
    this.localOnlyRows = 0,
    this.backupOnlyRows = 0,
  });
}

class BackupTableConflict {
  final String table;
  final int localRows;
  final int backupRows;
  final int replacingRows;
  final int localOnlyRows;
  final int backupOnlyRows;
  final int changedRows;
  final List<String> replacingSamples;
  final List<String> localOnlySamples;

  const BackupTableConflict({
    required this.table,
    required this.localRows,
    required this.backupRows,
    required this.replacingRows,
    required this.localOnlyRows,
    required this.backupOnlyRows,
    required this.changedRows,
    this.replacingSamples = const [],
    this.localOnlySamples = const [],
  });

  bool get hasConflict =>
      replacingRows > 0 || localOnlyRows > 0 || changedRows > 0;
}

/// 备份/恢复服务（阶段八）。对应源项目 `src/services/BackupService.ts`：
/// 把「会话 + 消息（含 blocks）+ 助手 + 收藏 + AI 设置」打成 zip 导出，
/// 导入时校验 manifest 后**覆盖式恢复**（先清表再写入，保留原始 id）。
///
/// 纯 Dart（archive 包无平台通道），文件读写与分享交给 UI 层，
/// 因此可以用 sqflite_common_ffi 内存库做 round-trip 单测。
class BackupService {
  /// 备份格式版本。导入时大于本值则拒绝（新版本备份导入旧 app）。
  static const int formatVersion = 11;

  static const _kManifest = 'manifest.json';
  static const _kConversations = 'conversations.json';
  static const _kMessages = 'messages.json';
  static const _kAssistants = 'assistants.json';
  static const _kAssistantMemories = 'assistant_memories.json';
  // v11 可选扩展：旧备份没有此 entry 时仍沿用助手原 prompt fallback。
  static const _kSkillCatalog = 'skill_catalog.json';
  // v11 可选扩展：正文和修订只存 SQLite，不根据 sourceKey 读取本机路径。
  static const _kWorkspaceFiles = 'workspace_files.json';
  static const _kWorkspaceRevisions = 'workspace_revisions.json';
  static const _kFavorites = 'favorites.json';
  static const _kProjects = 'projects.json';
  static const _kSettings = 'settings.json';
  static const _kKnowledgeDocs = 'knowledge_docs.json';
  static const _kKnowledgeChunks = 'knowledge_chunks.json';
  static const _kProjectKnowledge = 'project_knowledge.json';
  static const _kStoryTemplates = 'story_templates.json';
  static const _kStoryTemplateTranslationTasks =
      'story_template_translation_tasks.json';
  static const _kStoryPersonas = 'story_personas.json';
  static const _kStoryRooms = 'story_rooms.json';
  static const _kStoryParticipants = 'story_participants.json';
  static const _kStoryMessages = 'story_messages.json';
  static const _kStoryArtifacts = 'story_artifacts.json';
  static const _kStoryArtifactRevisions = 'story_artifact_revisions.json';
  static const _kAvatarPrefix = 'assets/avatars/';
  static const _kFilePrefix = 'assets/files/';
  static const _kGeneratedImagePrefix = 'assets/generated_images/';
  static const _kRoleCardAssetPrefix = 'assets/assistant_role_assets/';
  static const _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.gif'};
  static const Map<String, String> _v11RowCountKeys = {
    _kConversations: 'conversations',
    _kMessages: 'messages',
    _kAssistants: 'assistants',
    _kAssistantMemories: 'assistantMemories',
    _kFavorites: 'favorites',
    _kProjects: 'projects',
    _kKnowledgeDocs: 'knowledgeDocs',
    _kKnowledgeChunks: 'knowledgeChunks',
    _kProjectKnowledge: 'projectKnowledge',
    _kStoryTemplates: 'storyTemplates',
    _kStoryTemplateTranslationTasks: 'storyTemplateTranslationTasks',
    _kStoryPersonas: 'storyPersonas',
    _kStoryRooms: 'storyRooms',
    _kStoryParticipants: 'storyParticipants',
    _kStoryMessages: 'storyMessages',
    _kStoryArtifacts: 'storyArtifacts',
    _kStoryArtifactRevisions: 'storyArtifactRevisions',
  };
  static const Map<String, String> _v11ResourceCountKeys = {
    _kAvatarPrefix: 'avatarAssets',
    _kFilePrefix: 'fileAssets',
    _kGeneratedImagePrefix: 'generatedImageAssets',
    _kRoleCardAssetPrefix: 'roleCardAssets',
  };
  static const Map<String, int> _legacyRequiredRowSince = {
    _kConversations: 1,
    _kMessages: 1,
    _kAssistants: 1,
    _kFavorites: 1,
    _kProjects: 2,
    _kKnowledgeDocs: 2,
    _kKnowledgeChunks: 2,
    _kProjectKnowledge: 2,
    _kStoryTemplates: 3,
    _kStoryRooms: 4,
    _kStoryParticipants: 4,
    _kStoryMessages: 4,
    _kStoryArtifacts: 4,
    _kStoryArtifactRevisions: 4,
    _kStoryTemplateTranslationTasks: 5,
    _kStoryPersonas: 8,
  };

  /// 同一账号的恢复必须串行，避免两个 service 实例交错替换 SQLite 与资源目录。
  /// tail 无论成功失败都会完成并清理，前一次失败不会毒化后续恢复。
  static final Map<String, Future<void>> _importOperationTails = {};

  @visibleForTesting
  static Future<Directory> Function()? debugGeneratedImageDirectoryResolver;

  @visibleForTesting
  static RoleCardAssetDirectoryResolver? debugRoleCardAssetsDirectoryResolver;

  @visibleForTesting
  static BackupImportFailureInjector? debugImportFailureInjector;

  @visibleForTesting
  static BackupResourceRollbackFailureInjector?
      debugResourceRollbackFailureInjector;

  /// 导入完成后 +1，会话列表等常驻页面监听它重新加载数据
  /// （不强求重启，对应源项目 restore 后 resetAppInitializationState）。
  static final ValueNotifier<int> restoreTick = ValueNotifier<int>(0);

  final HiDBManager storage;

  BackupService(this.storage);

  // ---------------------------------------------------------------- 导出

  /// 导出当前账号的全部数据为 zip 字节。
  /// [includeApiKeys] 为 false（默认）时脱敏 openai/deepseek/tavily 的 key。
  Future<Uint8List> exportArchive({
    required AISettings settings,
    required String accountHash,
    bool includeApiKeys = false,
  }) async =>
      (await exportArchiveWithReport(
        settings: settings,
        accountHash: accountHash,
        includeApiKeys: includeApiKeys,
      ))
          .bytes;

  /// 与 [exportArchive] 兼容的导出 API，额外返回历史数据规范化告警。
  Future<BackupExportResult> exportArchiveWithReport({
    required AISettings settings,
    required String accountHash,
    bool includeApiKeys = false,
  }) async {
    // 表是 DAO 懒建的：先确保 schema 就绪（含 assistantId 列 ALTER），
    // 全新账号没建过的表导出为空列表而不是报错。
    await _ensureSchema(includeSkillCatalog: false);
    final conversations = await storage.db.query('tb_conversation_list');
    final messages = await storage.db.query('tb_messages');
    final workspace = await readWorkspaceRows(storage);
    final assistants = await storage.db.query('tb_assistant');
    final hasSkillCatalog = await _tableExists(storage.db, 'tb_skill_catalog');
    final skillCatalog =
        await readSkillCatalogRows(storage, assistants: assistants);
    final rawAssistantMemories = await storage.db.query('tb_assistant_memory');
    final favorites = await storage.db.query('tb_favorite');
    final projects = await storage.db.query('tb_project');
    final knowledgeDocs = await storage.db.query('tb_kb_doc');
    final knowledgeChunks = await storage.db.query('tb_kb_chunk');
    final projectKnowledge = await storage.db.query('tb_project_kb');
    final storyTemplates = await storage.db.query('tb_story_template');
    final storyTemplateTranslationTasks =
        await storage.db.query('tb_story_template_translation_task');
    final exportedStoryTemplateTranslationTasks =
        _sanitizeTranslationTasksForExport(storyTemplateTranslationTasks);
    final storyPersonas = await storage.db.query('tb_story_persona');
    final storyRooms = await storage.db.query('tb_story_room');
    final storyParticipants = await storage.db.query('tb_story_participant');
    final storyMessages = await storage.db.query('tb_story_message');
    final storyArtifacts = await storage.db.query('tb_story_artifact');
    final storyArtifactRevisions =
        await storage.db.query('tb_story_artifact_revision');
    final exportedStoryTemplates = includeApiKeys
        ? storyTemplates
        : _sanitizeStoryTemplatesForExport(storyTemplates);
    final exportedStoryRooms =
        includeApiKeys ? storyRooms : _sanitizeStoryRoomsForExport(storyRooms);
    final memoryExport = _normalizeAssistantMemoriesForExport(
      rawAssistantMemories,
      assistants,
    );
    final assistantMemories = memoryExport.rows;
    final avatarFiles = await _collectAvatarFiles([
      ...conversations,
      ...storyPersonas,
      for (final message in storyMessages)
        <String, Object?>{
          'avatarType': message['speakerAvatarType'],
          'avatarValue': message['speakerAvatarValue'],
        },
    ]);
    final attachmentFiles = await _collectAttachmentFiles(messages);
    final generatedImageFiles =
        await _collectGeneratedImageFiles(accountHash: accountHash);
    final roleCardAssetFiles = await _collectRoleCardAssetFiles(
      assistants,
      accountHash: accountHash,
    );

    final exportedSettings = settings.clone();
    if (!includeApiKeys) {
      // 脱敏导出：清空全部服务商 key + 联网搜索各家 key。
      for (final p in exportedSettings.providers) {
        p.apiKey = '';
      }
      exportedSettings
        ..tavilyApiKey = ''
        ..exaApiKey = ''
        ..bochaApiKey = ''
        ..zhipuApiKey = '';
      // MCP 直连 server 的请求头可能含鉴权 token，一并脱敏。
      for (var i = 0; i < exportedSettings.mcpServers.length; i++) {
        exportedSettings.mcpServers[i] =
            exportedSettings.mcpServers[i].copyWith(headers: const {});
      }
    }

    final entries = <String, List<int>>{
      _kConversations: _jsonBytes(conversations),
      _kMessages: _jsonBytes(messages),
      _kAssistants: _jsonBytes(assistants),
      _kAssistantMemories: _jsonBytes(assistantMemories),
      if (hasSkillCatalog) _kSkillCatalog: _jsonBytes(skillCatalog),
      _kWorkspaceFiles: _jsonBytes(workspace.files),
      _kWorkspaceRevisions: _jsonBytes(workspace.revisions),
      _kFavorites: _jsonBytes(favorites),
      _kProjects: _jsonBytes(projects),
      _kKnowledgeDocs: _jsonBytes(knowledgeDocs),
      _kKnowledgeChunks: _jsonBytes(knowledgeChunks),
      _kProjectKnowledge: _jsonBytes(projectKnowledge),
      _kStoryTemplates: _jsonBytes(exportedStoryTemplates),
      _kStoryTemplateTranslationTasks:
          _jsonBytes(exportedStoryTemplateTranslationTasks),
      _kStoryPersonas: _jsonBytes(storyPersonas),
      _kStoryRooms: _jsonBytes(exportedStoryRooms),
      _kStoryParticipants: _jsonBytes(storyParticipants),
      _kStoryMessages: _jsonBytes(storyMessages),
      _kStoryArtifacts: _jsonBytes(storyArtifacts),
      _kStoryArtifactRevisions: _jsonBytes(storyArtifactRevisions),
      _kSettings: _jsonBytes(exportedSettings.toJson()),
      for (final entry in avatarFiles.entries)
        '$_kAvatarPrefix${entry.key}': entry.value,
      for (final entry in attachmentFiles.entries)
        '$_kFilePrefix${entry.key}': entry.value,
      for (final entry in generatedImageFiles.entries)
        '$_kGeneratedImagePrefix${entry.key}': entry.value,
      for (final entry in roleCardAssetFiles.entries)
        '$_kRoleCardAssetPrefix${entry.key}': entry.value,
    };
    final entryDigests = digestEntries(entries);
    final manifest = {
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'accountHash': accountHash,
      'includeApiKeys': includeApiKeys,
      'counts': {
        'conversations': conversations.length,
        'messages': messages.length,
        'assistants': assistants.length,
        'assistantMemories': assistantMemories.length,
        'favorites': favorites.length,
        'projects': projects.length,
        'knowledgeDocs': knowledgeDocs.length,
        'knowledgeChunks': knowledgeChunks.length,
        'projectKnowledge': projectKnowledge.length,
        'storyTemplates': storyTemplates.length,
        'storyTemplateTranslationTasks': storyTemplateTranslationTasks.length,
        'storyPersonas': storyPersonas.length,
        'storyRooms': storyRooms.length,
        'storyParticipants': storyParticipants.length,
        'storyMessages': storyMessages.length,
        'storyArtifacts': storyArtifacts.length,
        'storyArtifactRevisions': storyArtifactRevisions.length,
        'avatarAssets': avatarFiles.length,
        'fileAssets': attachmentFiles.length,
        'generatedImageAssets': generatedImageFiles.length,
        'roleCardAssets': roleCardAssetFiles.length,
      },
      'entries': {
        for (final entry in entryDigests.entries)
          entry.key: entry.value.toJson(),
      },
    };

    final archive = Archive()
      ..addFile(ArchiveFile.bytes(_kManifest, _jsonBytes(manifest)));
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    AILogger.log('backup export: ${manifest['counts']}');
    return BackupExportResult(
      bytes: ZipEncoder().encodeBytes(archive),
      warnings: List.unmodifiable(memoryExport.warnings),
    );
  }

  // ---------------------------------------------------------------- 导入

  /// 导入前预览：读取数量、账号、资源与设置状态，但不修改当前数据库。
  Future<BackupPreview> previewArchive(
    List<int> zipBytes, {
    required String accountHash,
  }) async {
    final archive = _decodeArchive(zipBytes);
    final manifest = _readManifest(archive);
    final version = _validateFormatVersion(manifest, archive);

    final warnings = <String>[];
    final integrityVerified = _verifyArchiveIntegrity(
      archive,
      manifest,
      version,
      warnings,
      reportLegacyWarning: true,
    );
    final backupAccount = manifest['accountHash'] as String? ?? '';
    if (backupAccount.isNotEmpty && backupAccount != accountHash) {
      warnings.add('备份来自其他账号，导入会写入当前账号');
    }

    final strictV11 = version >= 11;
    final countsValue = manifest['counts'];
    final counts =
        countsValue is Map ? Map<String, dynamic>.from(countsValue) : null;
    final conversations =
        _readRowsForVersion(archive, _kConversations, version);
    final messages = _readRowsForVersion(archive, _kMessages, version);
    _readWorkspaceArchiveRows(archive);
    final assistants = _readRowsForVersion(archive, _kAssistants, version);
    _readSkillCatalog(archive, assistants);
    final assistantMemories = version >= 11
        ? _readRows(archive, _kAssistantMemories, strict: true)
        : <Map<String, dynamic>>[];
    final favorites = _readRowsForVersion(archive, _kFavorites, version);
    final projects = _readRowsForVersion(archive, _kProjects, version);
    final knowledgeDocs =
        _readRowsForVersion(archive, _kKnowledgeDocs, version);
    final knowledgeChunks =
        _readRowsForVersion(archive, _kKnowledgeChunks, version);
    final projectKnowledge =
        _readRowsForVersion(archive, _kProjectKnowledge, version);
    final storyTemplates =
        _readRowsForVersion(archive, _kStoryTemplates, version);
    final storyTemplateTranslationTasks =
        _normalizeTranslationTaskRunStates(_readRowsForVersion(
      archive,
      _kStoryTemplateTranslationTasks,
      version,
    ));
    final storyPersonas =
        _readRowsForVersion(archive, _kStoryPersonas, version);
    final storyRooms = _readRowsForVersion(archive, _kStoryRooms, version);
    final storyParticipants =
        _readRowsForVersion(archive, _kStoryParticipants, version);
    final storyMessages =
        _readRowsForVersion(archive, _kStoryMessages, version);
    final storyArtifacts =
        _readRowsForVersion(archive, _kStoryArtifacts, version);
    final storyArtifactRevisions =
        _readRowsForVersion(archive, _kStoryArtifactRevisions, version);
    final settingsJson = _readSettingsJson(archive, version);
    if (strictV11) {
      _validateV11ManifestCounts(archive, manifest, {
        _kConversations: conversations.length,
        _kMessages: messages.length,
        _kAssistants: assistants.length,
        _kAssistantMemories: assistantMemories.length,
        _kFavorites: favorites.length,
        _kProjects: projects.length,
        _kKnowledgeDocs: knowledgeDocs.length,
        _kKnowledgeChunks: knowledgeChunks.length,
        _kProjectKnowledge: projectKnowledge.length,
        _kStoryTemplates: storyTemplates.length,
        _kStoryTemplateTranslationTasks: storyTemplateTranslationTasks.length,
        _kStoryPersonas: storyPersonas.length,
        _kStoryRooms: storyRooms.length,
        _kStoryParticipants: storyParticipants.length,
        _kStoryMessages: storyMessages.length,
        _kStoryArtifacts: storyArtifacts.length,
        _kStoryArtifactRevisions: storyArtifactRevisions.length,
      });
    }
    final normalizedAssistantMemories =
        _validateAssistantMemories(assistantMemories, assistants);
    _normalizeStoryMessageBranches(
      storyRooms,
      storyParticipants,
      storyMessages,
      warnings,
    );
    int countOf(String key, String fileName) {
      final value = counts?[key];
      if (value is int) return value;
      switch (fileName) {
        case _kConversations:
          return conversations.length;
        case _kMessages:
          return messages.length;
        case _kAssistants:
          return assistants.length;
        case _kAssistantMemories:
          return assistantMemories.length;
        case _kFavorites:
          return favorites.length;
        case _kProjects:
          return projects.length;
        case _kKnowledgeDocs:
          return knowledgeDocs.length;
        case _kKnowledgeChunks:
          return knowledgeChunks.length;
        case _kProjectKnowledge:
          return projectKnowledge.length;
        case _kStoryTemplates:
          return storyTemplates.length;
        case _kStoryTemplateTranslationTasks:
          return storyTemplateTranslationTasks.length;
        case _kStoryPersonas:
          return storyPersonas.length;
        case _kStoryRooms:
          return storyRooms.length;
        case _kStoryParticipants:
          return storyParticipants.length;
        case _kStoryMessages:
          return storyMessages.length;
        case _kStoryArtifacts:
          return storyArtifacts.length;
        case _kStoryArtifactRevisions:
          return storyArtifactRevisions.length;
      }
      return 0;
    }

    final conflictSummary = await _previewConflicts(
      conversations: conversations,
      messages: messages,
      assistants: assistants,
      assistantMemories: normalizedAssistantMemories,
      favorites: favorites,
      projects: projects,
      knowledgeDocs: knowledgeDocs,
      knowledgeChunks: knowledgeChunks,
      projectKnowledge: projectKnowledge,
      storyTemplates: storyTemplates,
      storyTemplateTranslationTasks: storyTemplateTranslationTasks,
      storyPersonas: storyPersonas,
      storyRooms: storyRooms,
      storyParticipants: storyParticipants,
      storyMessages: storyMessages,
      storyArtifacts: storyArtifacts,
      storyArtifactRevisions: storyArtifactRevisions,
    );
    return BackupPreview(
      formatVersion: version,
      exportedAt: manifest['exportedAt'] as int? ?? 0,
      accountHash: backupAccount,
      includeApiKeys: manifest['includeApiKeys'] == true,
      conversations: countOf('conversations', _kConversations),
      messages: countOf('messages', _kMessages),
      assistants: countOf('assistants', _kAssistants),
      assistantMemories:
          version >= 11 ? countOf('assistantMemories', _kAssistantMemories) : 0,
      favorites: countOf('favorites', _kFavorites),
      projects: countOf('projects', _kProjects),
      knowledgeDocs: countOf('knowledgeDocs', _kKnowledgeDocs),
      knowledgeChunks: countOf('knowledgeChunks', _kKnowledgeChunks),
      projectKnowledge: countOf('projectKnowledge', _kProjectKnowledge),
      storyTemplates: countOf('storyTemplates', _kStoryTemplates),
      storyTemplateTranslationTasks: countOf(
        'storyTemplateTranslationTasks',
        _kStoryTemplateTranslationTasks,
      ),
      storyPersonas: countOf('storyPersonas', _kStoryPersonas),
      storyRooms: countOf('storyRooms', _kStoryRooms),
      storyParticipants: countOf('storyParticipants', _kStoryParticipants),
      storyMessages: countOf('storyMessages', _kStoryMessages),
      storyArtifacts: countOf('storyArtifacts', _kStoryArtifacts),
      storyArtifactRevisions:
          countOf('storyArtifactRevisions', _kStoryArtifactRevisions),
      avatarAssets: counts?['avatarAssets'] is int
          ? counts!['avatarAssets'] as int
          : archive.files
              .where((f) => f.isFile && f.name.startsWith(_kAvatarPrefix))
              .length,
      fileAssets: counts?['fileAssets'] is int
          ? counts!['fileAssets'] as int
          : archive.files
              .where((f) => f.isFile && f.name.startsWith(_kFilePrefix))
              .length,
      generatedImageAssets: counts?['generatedImageAssets'] is int
          ? counts!['generatedImageAssets'] as int
          : archive.files
              .where(
                  (f) => f.isFile && f.name.startsWith(_kGeneratedImagePrefix))
              .length,
      hasSettings: settingsJson is Map<String, dynamic>,
      integrityVerified: integrityVerified,
      conflictSummary: conflictSummary,
      warnings: warnings,
    );
  }

  /// 校验并恢复一个备份 zip。**覆盖式**：清空数据表后整批写回；普通表
  /// 保留原始 id/cid，故事工作台表按目标库新 id 重映射关联。
  /// 格式不合法 / 版本过新时抛 [FormatException]，不会动现有数据。
  Future<BackupRestoreResult> importArchive(
    List<int> zipBytes, {
    required String accountHash,
    BackupImportMode mode = BackupImportMode.overwriteAll,
    BackupAccountGuard? accountGuard,
  }) =>
      _serializeImport(
        accountHash,
        () => _importArchiveUnlocked(
          zipBytes,
          accountHash: accountHash,
          mode: mode,
          accountGuard: accountGuard,
        ),
      );

  Future<BackupRestoreResult> _importArchiveUnlocked(
    List<int> zipBytes, {
    required String accountHash,
    required BackupImportMode mode,
    BackupAccountGuard? accountGuard,
  }) async {
    final archive = _decodeArchive(zipBytes);
    final manifest = _readManifest(archive);
    final version = _validateFormatVersion(manifest, archive);

    final warnings = <String>[];
    _verifyArchiveIntegrity(archive, manifest, version, warnings);
    final backupAccount = manifest['accountHash'] as String? ?? '';
    if (backupAccount.isNotEmpty && backupAccount != accountHash) {
      warnings.add('备份来自其他账号，已导入当前账号');
    }

    final strictV11 = version >= 11;
    final conversations =
        _readRowsForVersion(archive, _kConversations, version);
    final messages = _readRowsForVersion(archive, _kMessages, version);
    final workspace = _readWorkspaceArchiveRows(archive);
    final assistants = _readRowsForVersion(archive, _kAssistants, version);
    final skillCatalog = _readSkillCatalog(archive, assistants);
    final assistantMemories = version >= 11
        ? _readRows(archive, _kAssistantMemories, strict: true)
        : <Map<String, dynamic>>[];
    final favorites = _readRowsForVersion(archive, _kFavorites, version);
    final projects = _readRowsForVersion(archive, _kProjects, version);
    final knowledgeDocs =
        _readRowsForVersion(archive, _kKnowledgeDocs, version);
    final knowledgeChunks =
        _readRowsForVersion(archive, _kKnowledgeChunks, version);
    final projectKnowledge =
        _readRowsForVersion(archive, _kProjectKnowledge, version);
    final storyTemplates =
        _readRowsForVersion(archive, _kStoryTemplates, version);
    final storyTemplateTranslationTasks =
        _normalizeTranslationTaskRunStates(_readRowsForVersion(
      archive,
      _kStoryTemplateTranslationTasks,
      version,
    ));
    final storyPersonas =
        _readRowsForVersion(archive, _kStoryPersonas, version);
    final storyRooms = _readRowsForVersion(archive, _kStoryRooms, version);
    final storyParticipants =
        _readRowsForVersion(archive, _kStoryParticipants, version);
    final storyMessages =
        _readRowsForVersion(archive, _kStoryMessages, version);
    final storyArtifacts =
        _readRowsForVersion(archive, _kStoryArtifacts, version);
    final storyArtifactRevisions =
        _readRowsForVersion(archive, _kStoryArtifactRevisions, version);
    final settingsJson = _readSettingsJson(archive, version);
    if (strictV11) {
      _validateV11ManifestCounts(archive, manifest, {
        _kConversations: conversations.length,
        _kMessages: messages.length,
        _kAssistants: assistants.length,
        _kAssistantMemories: assistantMemories.length,
        _kFavorites: favorites.length,
        _kProjects: projects.length,
        _kKnowledgeDocs: knowledgeDocs.length,
        _kKnowledgeChunks: knowledgeChunks.length,
        _kProjectKnowledge: projectKnowledge.length,
        _kStoryTemplates: storyTemplates.length,
        _kStoryTemplateTranslationTasks: storyTemplateTranslationTasks.length,
        _kStoryPersonas: storyPersonas.length,
        _kStoryRooms: storyRooms.length,
        _kStoryParticipants: storyParticipants.length,
        _kStoryMessages: storyMessages.length,
        _kStoryArtifacts: storyArtifacts.length,
        _kStoryArtifactRevisions: storyArtifactRevisions.length,
      });
    }
    final normalizedAssistantMemories =
        _validateAssistantMemories(assistantMemories, assistants);
    _normalizeStoryMessageBranches(
      storyRooms,
      storyParticipants,
      storyMessages,
      warnings,
    );
    final normalizedStoryPersonas =
        _dedupeStoryPersonas(storyPersonas, warnings);
    final guard = accountGuard;
    if (guard != null) await guard();
    if (mode == BackupImportMode.mergeAppend) {
      return _importMergeAppend(
        archive: archive,
        accountHash: accountHash,
        projects: projects,
        conversations: conversations,
        messages: messages,
        workspaceFiles: workspace.files,
        workspaceRevisions: workspace.revisions,
        assistants: assistants,
        assistantMemories: normalizedAssistantMemories,
        skillCatalog: skillCatalog,
        favorites: favorites,
        knowledgeDocs: knowledgeDocs,
        knowledgeChunks: knowledgeChunks,
        projectKnowledge: projectKnowledge,
        storyTemplates: storyTemplates,
        storyTemplateTranslationTasks: storyTemplateTranslationTasks,
        storyPersonas: normalizedStoryPersonas,
        storyRooms: storyRooms,
        storyParticipants: storyParticipants,
        storyMessages: storyMessages,
        storyArtifacts: storyArtifacts,
        storyArtifactRevisions: storyArtifactRevisions,
        warnings: warnings,
        accountGuard: accountGuard,
      );
    }
    if (mode == BackupImportMode.projectConversationsOnly) {
      return _importProjectConversationsOnly(
        archive: archive,
        accountHash: accountHash,
        projects: projects,
        conversations: conversations,
        messages: messages,
        workspaceFiles: workspace.files,
        workspaceRevisions: workspace.revisions,
        warnings: warnings,
        accountGuard: accountGuard,
      );
    }
    if (mode == BackupImportMode.assistantsOnly) {
      return _importAssistantsOnly(
        archive: archive,
        accountHash: accountHash,
        assistants: assistants,
        assistantMemories: normalizedAssistantMemories,
        skillCatalog: skillCatalog,
        warnings: warnings,
        accountGuard: accountGuard,
      );
    }
    if (mode == BackupImportMode.knowledgeBaseOnly) {
      return _importKnowledgeBaseOnly(
        knowledgeDocs: knowledgeDocs,
        knowledgeChunks: knowledgeChunks,
        projectKnowledge: projectKnowledge,
        warnings: warnings,
        accountGuard: accountGuard,
      );
    }

    // 只有“覆盖全部”会应用 settings。选择性/合并导入不解析旧
    // 备份中与其范围无关的 settings，保留 v1-v10 容错性。
    final settings = _parseSettings(settingsJson);
    _repairStoryPersonaBindings(
      normalizedStoryPersonas,
      storyRooms,
      warnings,
    );
    await _ensureSchema();
    final hasProjectColumn =
        await _hasColumn(storage.db, 'tb_conversation_list', 'projectId');
    final normalizedConversations = conversations
        .map((c) =>
            _normalizeConversationRow(c, hasProjectIdColumn: hasProjectColumn))
        .toList();

    // 外键修复（照源项目 restoreIndexedDbData 的做法）：会话引用了
    // 备份里不存在的助手 id 时置空，回落「无助手」而不是悬空。
    final assistantIds = {
      for (final a in assistants)
        if (a['id'] != null) a['id'],
    };
    var fixedConversations = 0;
    for (final c in normalizedConversations) {
      final aid = c['assistantId'];
      if (aid != null && !assistantIds.contains(aid)) {
        c['assistantId'] = null;
        fixedConversations++;
      }
    }
    if (fixedConversations > 0) {
      warnings.add('$fixedConversations 个会话引用的助手不在备份中，已解除绑定');
    }
    var fixedProjectAssistants = 0;
    for (final p in projects) {
      final aid = p['defaultAssistantId'];
      if (aid != null && !assistantIds.contains(aid)) {
        p['defaultAssistantId'] = null;
        fixedProjectAssistants++;
      }
    }
    if (fixedProjectAssistants > 0) {
      warnings.add('$fixedProjectAssistants 个项目引用的默认助手不在备份中，已清除');
    }
    final projectIds = {
      for (final p in projects)
        if (p['id'] != null) p['id'],
    };
    var fixedProjects = 0;
    for (final c in normalizedConversations) {
      final pid = c['projectId'];
      if (pid != null && !projectIds.contains(pid)) {
        c['projectId'] = null;
        fixedProjects++;
      }
    }
    if (fixedProjects > 0) {
      warnings.add('$fixedProjects 个会话引用的项目不在备份中，已移动到未分类');
    }
    final knowledgeDocIds = {
      for (final d in knowledgeDocs)
        if (d['id'] != null) d['id'],
    };
    var fixedProjectKnowledge = 0;
    projectKnowledge.removeWhere((row) {
      final invalid = !projectIds.contains(row['projectId']) ||
          !knowledgeDocIds.contains(row['docId']);
      if (invalid) fixedProjectKnowledge++;
      return invalid;
    });
    if (fixedProjectKnowledge > 0) {
      warnings.add('$fixedProjectKnowledge 条项目知识库绑定无效，已跳过');
    }

    final storyRoomIds = {
      for (final row in storyRooms)
        if (_intValue(row['id']) != null) _intValue(row['id'])!,
    };
    final normalizedStoryParticipants = <Map<String, dynamic>>[];
    var skippedStoryParticipants = 0;
    var fixedStoryParticipantAssistants = 0;
    for (final row in storyParticipants) {
      final roomId = _intValue(row['roomId']);
      if (roomId == null || !storyRoomIds.contains(roomId)) {
        skippedStoryParticipants++;
        continue;
      }
      final next = Map<String, dynamic>.from(row)..['roomId'] = roomId;
      final assistantId = _intValue(next['assistantId']);
      if (assistantId != null && !assistantIds.contains(assistantId)) {
        next['assistantId'] = null;
        fixedStoryParticipantAssistants++;
      }
      normalizedStoryParticipants.add(next);
    }
    final storyParticipantIds = {
      for (final row in normalizedStoryParticipants)
        if (_intValue(row['id']) != null) _intValue(row['id'])!,
    };
    final normalizedStoryMessages = <Map<String, dynamic>>[];
    var skippedStoryMessages = 0;
    var fixedStoryMessageSpeakers = 0;
    for (final row in storyMessages) {
      final roomId = _intValue(row['roomId']);
      if (roomId == null || !storyRoomIds.contains(roomId)) {
        skippedStoryMessages++;
        continue;
      }
      final next = Map<String, dynamic>.from(row)..['roomId'] = roomId;
      final speakerId = _intValue(next['speakerId']);
      if (speakerId != null && !storyParticipantIds.contains(speakerId)) {
        next['speakerId'] = null;
        fixedStoryMessageSpeakers++;
      }
      normalizedStoryMessages.add(next);
    }
    if (skippedStoryParticipants > 0) {
      warnings.add('$skippedStoryParticipants 个酒馆参与者找不到所属房间，已跳过');
    }
    if (fixedStoryParticipantAssistants > 0) {
      warnings.add('$fixedStoryParticipantAssistants 个酒馆参与者引用的助手不在备份中，已解除绑定');
    }
    if (skippedStoryMessages > 0) {
      warnings.add('$skippedStoryMessages 条酒馆消息找不到所属房间，已跳过');
    }
    if (fixedStoryMessageSpeakers > 0) {
      warnings.add('$fixedStoryMessageSpeakers 条酒馆消息引用的参与者不存在，已清除发言者绑定');
    }
    final storyRoomIdMap = <int, int>{};
    final storyParticipantIdMap = <int, int>{};
    final storyArtifactIdMap = <int, int>{};
    var skippedStoryArtifacts = 0;
    var skippedStoryArtifactRevisions = 0;
    var insertedStoryParticipants = 0;
    var insertedStoryMessages = 0;
    var insertedStoryArtifacts = 0;
    var insertedStoryArtifactRevisions = 0;
    var fixedTranslationTaskOutputRoomRefs = 0;
    final resources = _BackupResourceCoordinator();
    late final int generatedImageAssets;
    try {
      await _restoreAttachmentAssets(
        archive,
        messages,
        warnings,
        resources,
      );
      generatedImageAssets = await _restoreGeneratedImageAssets(
        archive,
        resources,
        accountHash: accountHash,
        replaceExisting: true,
      );
      await _restoreRoleCardAssets(
        archive,
        assistants,
        _identityAssistantIdMap(assistants),
        warnings,
        accountHash: accountHash,
        replaceExisting: true,
        resources: resources,
      );
      await _restoreAvatarAssets(
        archive,
        normalizedConversations,
        warnings,
        accountHash: accountHash,
        resources: resources,
        storyPersonas: normalizedStoryPersonas,
        storyMessages: normalizedStoryMessages,
      );
    } catch (_) {
      await resources.rollback();
      rethrow;
    }

    // 单事务覆盖式写入：任何一步失败整体回滚，不会留下半套数据。
    await _runResourceTransaction(resources, (txn) async {
      await _clearDerivedConversationState(txn);
      await txn.delete(AgentWorkspaceDao.revisionsTable);
      await txn.delete(AgentWorkspaceDao.filesTable);
      final workspaceCidMap = {
        for (final row in normalizedConversations)
          if (_intValue(row['cid']) != null)
            _intValue(row['cid'])!: _intValue(row['cid'])!,
      };
      final workspaceIdMap = await restoreWorkspaceRows(txn,
          files: workspace.files,
          revisions: workspace.revisions,
          cidMap: workspaceCidMap);
      await txn.delete('tb_story_artifact_revision');
      await txn.delete('tb_story_artifact');
      await txn.delete('tb_story_message');
      await txn.delete('tb_story_participant');
      await txn.delete('tb_story_room');
      await txn.delete('tb_story_persona');
      final batch = txn.batch();
      batch.delete('tb_project');
      batch.delete('tb_conversation_list');
      batch.delete('tb_messages');
      batch.delete('tb_assistant_memory');
      batch.delete('tb_skill_catalog');
      batch.delete('tb_assistant');
      batch.delete('tb_favorite');
      batch.delete('tb_project_kb');
      batch.delete('tb_story_template_translation_task');
      batch.delete('tb_story_template');
      batch.delete('tb_kb_chunk');
      batch.delete('tb_kb_doc');
      for (final row in projects) {
        batch.insert('tb_project', row);
      }
      for (final row in assistants) {
        batch.insert('tb_assistant', row);
      }
      for (final row in normalizedAssistantMemories) {
        batch.insert('tb_assistant_memory', row);
      }
      for (final row in skillCatalog) {
        batch.insert('tb_skill_catalog', row);
      }
      for (final row in normalizedConversations) {
        batch.insert('tb_conversation_list', row);
      }
      for (final row in messages) {
        batch.insert(
            'tb_messages',
            remapWorkspaceMessageReferences(row,
                files: workspace.files,
                fileIdMap: workspaceIdMap,
                cidMap: workspaceCidMap));
      }
      for (final row in favorites) {
        batch.insert('tb_favorite', row);
      }
      for (final row in knowledgeDocs) {
        batch.insert('tb_kb_doc', row);
      }
      for (final row in knowledgeChunks) {
        batch.insert('tb_kb_chunk', row);
      }
      for (final row in projectKnowledge) {
        batch.insert('tb_project_kb', row);
      }
      for (final row in storyTemplates) {
        batch.insert('tb_story_template', row);
      }
      for (final row in normalizedStoryPersonas) {
        batch.insert('tb_story_persona', _withoutId(row));
      }
      for (final row in storyRooms) {
        final oldId = _intValue(row['id']);
        final newId = await txn.insert('tb_story_room', _withoutId(row));
        if (oldId != null) storyRoomIdMap[oldId] = newId;
      }
      for (final row in storyTemplateTranslationTasks) {
        final next = Map<String, dynamic>.from(row);
        final oldOutputRoomId = _intValue(next['outputRoomId']);
        if (oldOutputRoomId != null) {
          final newOutputRoomId = storyRoomIdMap[oldOutputRoomId];
          next['outputRoomId'] = newOutputRoomId;
          if (newOutputRoomId == null) {
            fixedTranslationTaskOutputRoomRefs++;
          }
        }
        // batch 中的模板会先于任务写入；保留任务和模板原 ID，
        // 仅重映射重建时已去掉原 ID 的酒馆房间。
        batch.insert('tb_story_template_translation_task', next);
      }
      for (final row in normalizedStoryParticipants) {
        final oldRoomId = _intValue(row['roomId']);
        final newRoomId = oldRoomId == null ? null : storyRoomIdMap[oldRoomId];
        if (newRoomId == null) continue;
        final next = _withoutId(row)..['roomId'] = newRoomId;
        final newId = await txn.insert('tb_story_participant', next);
        final oldId = _intValue(row['id']);
        if (oldId != null) storyParticipantIdMap[oldId] = newId;
        insertedStoryParticipants++;
      }
      for (final row in normalizedStoryMessages) {
        final oldRoomId = _intValue(row['roomId']);
        final newRoomId = oldRoomId == null ? null : storyRoomIdMap[oldRoomId];
        if (newRoomId == null) continue;
        final next = _withoutId(row)..['roomId'] = newRoomId;
        final oldSpeakerId = _intValue(next['speakerId']);
        if (oldSpeakerId != null) {
          next['speakerId'] = storyParticipantIdMap[oldSpeakerId];
        }
        final newId = await txn.insert('tb_story_message', next);
        if (_intValue(row['id']) != null) {
          // 消息自身没有后续外键，但去掉旧 id 也避免与目标库序列冲突。
          assert(newId > 0);
        }
        insertedStoryMessages++;
      }
      for (final row in storyArtifacts) {
        final oldRoomId = _intValue(row['roomId']);
        final newRoomId = oldRoomId == null ? null : storyRoomIdMap[oldRoomId];
        if (newRoomId == null) {
          skippedStoryArtifacts++;
          continue;
        }
        final next = _withoutId(row)..['roomId'] = newRoomId;
        final newId = await txn.insert('tb_story_artifact', next);
        final oldId = _intValue(row['id']);
        if (oldId != null) storyArtifactIdMap[oldId] = newId;
        insertedStoryArtifacts++;
      }
      for (final row in storyArtifactRevisions) {
        final oldArtifactId = _intValue(row['artifactId']);
        final newArtifactId =
            oldArtifactId == null ? null : storyArtifactIdMap[oldArtifactId];
        if (newArtifactId == null) {
          skippedStoryArtifactRevisions++;
          continue;
        }
        await txn.insert(
          'tb_story_artifact_revision',
          _withoutId(row)..['artifactId'] = newArtifactId,
        );
        insertedStoryArtifactRevisions++;
      }
      await batch.commit(noResult: true);
    }, accountGuard: accountGuard);

    if (fixedTranslationTaskOutputRoomRefs > 0) {
      warnings.add('$fixedTranslationTaskOutputRoomRefs 个翻译任务找不到生成的酒馆房间，已清除引用');
    }
    if (skippedStoryArtifacts > 0) {
      warnings.add('$skippedStoryArtifacts 个创作资料找不到所属房间，已跳过');
    }
    if (skippedStoryArtifactRevisions > 0) {
      warnings.add('$skippedStoryArtifactRevisions 条创作资料修订找不到所属资料，已跳过');
    }

    AILogger.log('backup import: ${conversations.length} conversations'
        ', ${messages.length} messages, ${assistants.length} assistants'
        ', ${favorites.length} favorites, ${projects.length} projects'
        ', ${knowledgeDocs.length} kb docs, ${knowledgeChunks.length} kb chunks'
        ', ${projectKnowledge.length} project kb refs'
        ', ${storyTemplates.length} story templates'
        ', ${storyTemplateTranslationTasks.length} story template translation tasks'
        ', $insertedStoryArtifacts story artifacts'
        ', $insertedStoryArtifactRevisions story artifact revisions'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      conversations: conversations.length,
      messages: messages.length,
      assistants: assistants.length,
      assistantMemories: normalizedAssistantMemories.length,
      favorites: favorites.length,
      projects: projects.length,
      knowledgeDocs: knowledgeDocs.length,
      knowledgeChunks: knowledgeChunks.length,
      projectKnowledge: projectKnowledge.length,
      storyTemplates: storyTemplates.length,
      storyTemplateTranslationTasks: storyTemplateTranslationTasks.length,
      storyPersonas: normalizedStoryPersonas.length,
      storyRooms: storyRooms.length,
      storyParticipants: insertedStoryParticipants,
      storyMessages: insertedStoryMessages,
      storyArtifacts: insertedStoryArtifacts,
      storyArtifactRevisions: insertedStoryArtifactRevisions,
      generatedImageAssets: generatedImageAssets,
      settings: settings,
      warnings: warnings,
    );
  }

  // ---------------------------------------------------------------- 内部

  Future<BackupRestoreResult> _importProjectConversationsOnly({
    required Archive archive,
    required String accountHash,
    required List<Map<String, dynamic>> projects,
    required List<Map<String, dynamic>> conversations,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> workspaceFiles,
    required List<Map<String, dynamic>> workspaceRevisions,
    required List<String> warnings,
    BackupAccountGuard? accountGuard,
  }) async {
    await _ensureSchema();
    final hasProjectColumn =
        await _hasColumn(storage.db, 'tb_conversation_list', 'projectId');
    final normalizedConversations = conversations
        .map((c) =>
            _normalizeConversationRow(c, hasProjectIdColumn: hasProjectColumn))
        .toList();
    final assistantIds = {
      for (final a in await storage.db.query('tb_assistant'))
        if (a['id'] != null) a['id'],
    };

    var fixedConversations = 0;
    for (final c in normalizedConversations) {
      final aid = c['assistantId'];
      if (aid != null && !assistantIds.contains(aid)) {
        c['assistantId'] = null;
        fixedConversations++;
      }
    }
    if (fixedConversations > 0) {
      warnings.add('$fixedConversations 个会话引用的助手不在本地助手列表中，已解除绑定');
    }

    var fixedProjectAssistants = 0;
    for (final p in projects) {
      final aid = p['defaultAssistantId'];
      if (aid != null && !assistantIds.contains(aid)) {
        p['defaultAssistantId'] = null;
        fixedProjectAssistants++;
      }
    }
    if (fixedProjectAssistants > 0) {
      warnings.add('$fixedProjectAssistants 个项目引用的默认助手不在本地助手列表中，已清除');
    }

    final projectIds = {
      for (final p in projects)
        if (p['id'] != null) p['id'],
    };
    var fixedProjects = 0;
    for (final c in normalizedConversations) {
      final pid = c['projectId'];
      if (pid != null && !projectIds.contains(pid)) {
        c['projectId'] = null;
        fixedProjects++;
      }
    }
    if (fixedProjects > 0) {
      warnings.add('$fixedProjects 个会话引用的项目不在导入数据中，已移动到未分类');
    }

    final existingProjectKnowledge =
        await storage.db.query('tb_project_kb', limit: 1);
    if (existingProjectKnowledge.isNotEmpty) {
      warnings.add('项目知识库绑定未随项目/会话模式导入，已清空以避免旧项目引用失效');
    }

    final resources = _BackupResourceCoordinator();
    try {
      await _restoreAttachmentAssets(
        archive,
        messages,
        warnings,
        resources,
      );
      await _restoreAvatarAssets(
        archive,
        normalizedConversations,
        warnings,
        accountHash: accountHash,
        resources: resources,
      );
    } catch (_) {
      await resources.rollback();
      rethrow;
    }

    await _runResourceTransaction(resources, (txn) async {
      final batch = txn.batch();
      batch.delete('tb_project_kb');
      await _clearDerivedConversationState(txn);
      await txn.delete(AgentWorkspaceDao.revisionsTable);
      await txn.delete(AgentWorkspaceDao.filesTable);
      final workspaceCidMap = {
        for (final row in normalizedConversations)
          if (_intValue(row['cid']) != null)
            _intValue(row['cid'])!: _intValue(row['cid'])!,
      };
      final workspaceIdMap = await restoreWorkspaceRows(txn,
          files: workspaceFiles,
          revisions: workspaceRevisions,
          cidMap: workspaceCidMap);
      batch.delete('tb_project');
      batch.delete('tb_conversation_list');
      batch.delete('tb_messages');
      for (final row in projects) {
        batch.insert('tb_project', row);
      }
      for (final row in normalizedConversations) {
        batch.insert('tb_conversation_list', row);
      }
      for (final row in messages) {
        batch.insert(
            'tb_messages',
            remapWorkspaceMessageReferences(row,
                files: workspaceFiles,
                fileIdMap: workspaceIdMap,
                cidMap: workspaceCidMap));
      }
      await batch.commit(noResult: true);
    }, accountGuard: accountGuard);

    AILogger.log('backup import projects/conversations only: '
        '${projects.length} projects, ${conversations.length} conversations'
        ', ${messages.length} messages, warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      conversations: conversations.length,
      messages: messages.length,
      projects: projects.length,
      warnings: warnings,
    );
  }

  Future<BackupRestoreResult> _importMergeAppend({
    required Archive archive,
    required String accountHash,
    required List<Map<String, dynamic>> projects,
    required List<Map<String, dynamic>> conversations,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> workspaceFiles,
    required List<Map<String, dynamic>> workspaceRevisions,
    required List<Map<String, dynamic>> assistants,
    required List<Map<String, dynamic>> assistantMemories,
    required List<Map<String, dynamic>> skillCatalog,
    required List<Map<String, dynamic>> favorites,
    required List<Map<String, dynamic>> knowledgeDocs,
    required List<Map<String, dynamic>> knowledgeChunks,
    required List<Map<String, dynamic>> projectKnowledge,
    required List<Map<String, dynamic>> storyTemplates,
    required List<Map<String, dynamic>> storyTemplateTranslationTasks,
    required List<Map<String, dynamic>> storyPersonas,
    required List<Map<String, dynamic>> storyRooms,
    required List<Map<String, dynamic>> storyParticipants,
    required List<Map<String, dynamic>> storyMessages,
    required List<Map<String, dynamic>> storyArtifacts,
    required List<Map<String, dynamic>> storyArtifactRevisions,
    required List<String> warnings,
    BackupAccountGuard? accountGuard,
  }) async {
    await _ensureSchema();
    final hasProjectColumn =
        await _hasColumn(storage.db, 'tb_conversation_list', 'projectId');
    final normalizedConversations = conversations
        .map((c) =>
            _normalizeConversationRow(c, hasProjectIdColumn: hasProjectColumn))
        .toList();
    final localStoryNodeKeys = {
      for (final row in await storage.db.query(
        'tb_story_message',
        columns: const ['nodeKey'],
      ))
        if ('${row['nodeKey'] ?? ''}'.trim().isNotEmpty)
          '${row['nodeKey']}'.trim(),
    };
    final remappedBranchKeys = _remapStoryBranchKeyConflicts(
      storyRooms,
      storyMessages,
      localStoryNodeKeys,
    );
    if (remappedBranchKeys > 0) {
      warnings.add('$remappedBranchKeys 个故事分支节点与本地重复，已安全改键');
    }

    final assistantIdMap = <int, int>{};
    final projectIdMap = <int, int>{};
    final cidMap = <int, int>{};
    final docIdMap = <int, int>{};
    final storyRoomIdMap = <int, int>{};
    final storyParticipantIdMap = <int, int>{};
    final storyArtifactIdMap = <int, int>{};
    final storyTemplateIdMap = <int, int>{};
    var skippedMessages = 0;
    var skippedChunks = 0;
    var skippedProjectKnowledge = 0;
    var fixedConversationAssistants = 0;
    var fixedConversationProjects = 0;
    var fixedProjectAssistants = 0;
    var remappedCids = 0;
    var insertedProjectKnowledge = 0;
    var skippedStoryParticipants = 0;
    var skippedStoryMessages = 0;
    var fixedStoryParticipantAssistants = 0;
    var fixedStoryMessageSpeakers = 0;
    var insertedStoryParticipants = 0;
    var insertedStoryMessages = 0;
    var remappedStoryRooms = 0;
    var remappedStoryParticipants = 0;
    var remappedStoryMessages = 0;
    var remappedStoryArtifacts = 0;
    var skippedStoryArtifacts = 0;
    var skippedStoryArtifactRevisions = 0;
    var insertedStoryArtifacts = 0;
    var insertedStoryArtifactRevisions = 0;
    var fixedTranslationTaskTemplateRefs = 0;
    var fixedTranslationTaskOutputTemplateRefs = 0;
    var fixedTranslationTaskOutputRoomRefs = 0;
    var appliedStoryPersonas = 0;
    var insertedAssistantMemories = 0;
    var deduplicatedAssistantMemories = 0;
    var rekeyedAssistantMemories = 0;

    final resources = _BackupResourceCoordinator();
    late final int generatedImageAssets;
    try {
      await _restoreAttachmentAssets(
        archive,
        messages,
        warnings,
        resources,
      );
      generatedImageAssets = await _restoreGeneratedImageAssets(
        archive,
        resources,
        accountHash: accountHash,
        replaceExisting: false,
      );
      await _restoreAvatarAssets(
        archive,
        normalizedConversations,
        warnings,
        accountHash: accountHash,
        resources: resources,
        storyPersonas: storyPersonas,
        storyMessages: storyMessages,
      );
    } catch (_) {
      await resources.rollback();
      rethrow;
    }

    await _runResourceTransaction(resources, (txn) async {
      final localAssistantMemoryRows = await txn.query('tb_assistant_memory');
      final localAssistantMemories = {
        for (final row in localAssistantMemoryRows)
          if ('${row['memoryId'] ?? ''}'.trim().isNotEmpty)
            '${row['memoryId']}'.trim(): Map<String, Object?>.from(row),
      };
      final localStoryPersonaRows = await txn.query('tb_story_persona');
      final localStoryPersonas = {
        for (final row in localStoryPersonaRows)
          if ('${row['personaKey'] ?? ''}'.trim().isNotEmpty)
            '${row['personaKey']}'.trim(): Map<String, Object?>.from(row),
      };
      _repairStoryPersonaBindings(
        storyPersonas,
        storyRooms,
        warnings,
        additionalPersonaKeys: localStoryPersonas.keys,
      );
      for (final row in storyPersonas) {
        final personaKey = '${row['personaKey'] ?? ''}'.trim();
        if (personaKey.isEmpty) continue;
        final local = localStoryPersonas[personaKey];
        if (local == null) {
          await txn.insert('tb_story_persona', _withoutId(row));
          appliedStoryPersonas++;
          continue;
        }
        if ((_intValue(row['updatedAt']) ?? 0) >
            (_intValue(local['updatedAt']) ?? 0)) {
          await txn.update(
            'tb_story_persona',
            _withoutId(row),
            where: 'personaKey = ?',
            whereArgs: [personaKey],
          );
          appliedStoryPersonas++;
        }
      }
      final localStoryRoomIds = {
        for (final row in await txn.query('tb_story_room'))
          if (_intValue(row['id']) != null) _intValue(row['id'])!,
      };
      final localStoryParticipantIds = {
        for (final row in await txn.query('tb_story_participant'))
          if (_intValue(row['id']) != null) _intValue(row['id'])!,
      };
      final localStoryMessageIds = {
        for (final row in await txn.query('tb_story_message'))
          if (_intValue(row['id']) != null) _intValue(row['id'])!,
      };
      final localStoryArtifactIds = {
        for (final row in await txn.query('tb_story_artifact'))
          if (_intValue(row['id']) != null) _intValue(row['id'])!,
      };
      remappedStoryRooms = storyRooms.where((row) {
        final id = _intValue(row['id']);
        return id != null && localStoryRoomIds.contains(id);
      }).length;
      remappedStoryParticipants = storyParticipants.where((row) {
        final id = _intValue(row['id']);
        return id != null && localStoryParticipantIds.contains(id);
      }).length;
      remappedStoryMessages = storyMessages.where((row) {
        final id = _intValue(row['id']);
        return id != null && localStoryMessageIds.contains(id);
      }).length;

      for (final row in assistants) {
        final oldId = _intValue(row['id']);
        final newId = await txn.insert('tb_assistant', _withoutId(row));
        if (oldId != null) assistantIdMap[oldId] = newId;
      }

      for (final row in skillCatalog) {
        final newId = assistantIdMap[_intValue(row['assistantId'])];
        if (newId == null) continue;
        await txn.insert('tb_skill_catalog', {
          ...row,
          'assistantId': newId,
        });
      }

      for (final row in assistantMemories) {
        final oldAssistantId = _intValue(row['assistantId']);
        final newAssistantId =
            oldAssistantId == null ? null : assistantIdMap[oldAssistantId];
        if (newAssistantId == null) continue;
        final next = _withoutId(row)
          ..['assistantId'] = newAssistantId
          ..['assistantSyncId'] = 'legacy:$newAssistantId';
        final originalMemoryId = '${next['memoryId'] ?? ''}'.trim();
        final existing = localAssistantMemories[originalMemoryId];
        if (existing != null) {
          // merge 每次都新建助手；即使 memoryId/内容完全相同，
          // 也不能拿旧助手的记忆当成新助手已拥有。
          if (_intValue(existing['assistantId']) == newAssistantId &&
              _assistantMemoryStableKey(existing) ==
                  _assistantMemoryStableKey(next)) {
            deduplicatedAssistantMemories++;
            continue;
          }
          next['memoryId'] = generateUuidV4();
          rekeyedAssistantMemories++;
        }
        await txn.insert('tb_assistant_memory', next);
        localAssistantMemories['${next['memoryId']}'] = next;
        insertedAssistantMemories++;
      }

      for (final row in projects) {
        final oldId = _intValue(row['id']);
        final next = _withoutId(row);
        final oldAssistantId = _intValue(next['defaultAssistantId']);
        if (oldAssistantId != null) {
          final newAssistantId = assistantIdMap[oldAssistantId];
          next['defaultAssistantId'] = newAssistantId;
          if (newAssistantId == null) fixedProjectAssistants++;
        }
        final newId = await txn.insert('tb_project', next);
        if (oldId != null) projectIdMap[oldId] = newId;
      }

      for (final row in storyRooms) {
        final oldId = _intValue(row['id']);
        final newId = await txn.insert('tb_story_room', _withoutId(row));
        if (oldId != null) storyRoomIdMap[oldId] = newId;
      }

      for (final row in storyParticipants) {
        final oldRoomId = _intValue(row['roomId']);
        final newRoomId = oldRoomId == null ? null : storyRoomIdMap[oldRoomId];
        if (newRoomId == null) {
          skippedStoryParticipants++;
          continue;
        }
        final next = _withoutId(row)..['roomId'] = newRoomId;
        final oldAssistantId = _intValue(next['assistantId']);
        if (oldAssistantId != null) {
          final newAssistantId = assistantIdMap[oldAssistantId];
          next['assistantId'] = newAssistantId;
          if (newAssistantId == null) fixedStoryParticipantAssistants++;
        }
        final newId = await txn.insert('tb_story_participant', next);
        final oldId = _intValue(row['id']);
        if (oldId != null) storyParticipantIdMap[oldId] = newId;
        insertedStoryParticipants++;
      }

      final usedCids = {
        for (final row in await txn.query('tb_conversation_list'))
          if (_intValue(row['cid']) != null) _intValue(row['cid'])!,
        for (final row
            in await txn.query(AgentWorkspaceDao.filesTable, columns: ['cid']))
          if (_intValue(row['cid']) != null) _intValue(row['cid'])!,
      };
      var nextCid =
          usedCids.isEmpty ? 1 : usedCids.reduce((a, b) => a > b ? a : b) + 1;
      int allocateCid(int preferred) {
        if (!usedCids.contains(preferred)) {
          usedCids.add(preferred);
          return preferred;
        }
        while (usedCids.contains(nextCid)) {
          nextCid++;
        }
        final cid = nextCid;
        usedCids.add(cid);
        nextCid++;
        remappedCids++;
        return cid;
      }

      for (final row in normalizedConversations) {
        final oldCid = _intValue(row['cid']);
        final next = _withoutId(row);
        final newCid = allocateCid(oldCid ?? nextCid);
        next['cid'] = newCid;
        if (oldCid != null) cidMap[oldCid] = newCid;

        final oldAssistantId = _intValue(next['assistantId']);
        if (oldAssistantId != null) {
          final newAssistantId = assistantIdMap[oldAssistantId];
          next['assistantId'] = newAssistantId;
          if (newAssistantId == null) fixedConversationAssistants++;
        }

        final oldProjectId = _intValue(next['projectId']);
        if (oldProjectId != null) {
          final newProjectId = projectIdMap[oldProjectId];
          next['projectId'] = newProjectId;
          if (newProjectId == null) fixedConversationProjects++;
        }
        await txn.insert('tb_conversation_list', next);
      }

      final workspaceIdMap = await restoreWorkspaceRows(txn,
          files: workspaceFiles, revisions: workspaceRevisions, cidMap: cidMap);
      for (final row in messages) {
        final oldCid = _intValue(row['cid']);
        final newCid = oldCid == null ? null : cidMap[oldCid];
        if (newCid == null) {
          skippedMessages++;
          continue;
        }
        await txn.insert(
          'tb_messages',
          _withoutId(remapWorkspaceMessageReferences(row,
              files: workspaceFiles, fileIdMap: workspaceIdMap, cidMap: cidMap))
            ..['cid'] = newCid,
        );
      }

      for (final row in storyMessages) {
        final oldRoomId = _intValue(row['roomId']);
        final newRoomId = oldRoomId == null ? null : storyRoomIdMap[oldRoomId];
        if (newRoomId == null) {
          skippedStoryMessages++;
          continue;
        }
        final next = _withoutId(row)..['roomId'] = newRoomId;
        final oldSpeakerId = _intValue(next['speakerId']);
        if (oldSpeakerId != null) {
          final newSpeakerId = storyParticipantIdMap[oldSpeakerId];
          next['speakerId'] = newSpeakerId;
          if (newSpeakerId == null) fixedStoryMessageSpeakers++;
        }
        await txn.insert('tb_story_message', next);
        insertedStoryMessages++;
      }

      for (final row in storyArtifacts) {
        final oldRoomId = _intValue(row['roomId']);
        final newRoomId = oldRoomId == null ? null : storyRoomIdMap[oldRoomId];
        if (newRoomId == null) {
          skippedStoryArtifacts++;
          continue;
        }
        final next = _withoutId(row)..['roomId'] = newRoomId;
        final newId = await txn.insert('tb_story_artifact', next);
        final oldId = _intValue(row['id']);
        if (oldId != null) {
          storyArtifactIdMap[oldId] = newId;
          if (localStoryArtifactIds.contains(oldId)) remappedStoryArtifacts++;
        }
        insertedStoryArtifacts++;
      }

      for (final row in storyArtifactRevisions) {
        final oldArtifactId = _intValue(row['artifactId']);
        final newArtifactId =
            oldArtifactId == null ? null : storyArtifactIdMap[oldArtifactId];
        if (newArtifactId == null) {
          skippedStoryArtifactRevisions++;
          continue;
        }
        await txn.insert(
          'tb_story_artifact_revision',
          _withoutId(row)..['artifactId'] = newArtifactId,
        );
        insertedStoryArtifactRevisions++;
      }

      for (final row in favorites) {
        await txn.insert('tb_favorite', _withoutId(row));
      }

      for (final row in knowledgeDocs) {
        final oldId = _intValue(row['id']);
        final newId = await txn.insert('tb_kb_doc', _withoutId(row));
        if (oldId != null) docIdMap[oldId] = newId;
      }

      for (final row in knowledgeChunks) {
        final oldDocId = _intValue(row['docId']);
        final newDocId = oldDocId == null ? null : docIdMap[oldDocId];
        if (newDocId == null) {
          skippedChunks++;
          continue;
        }
        await txn.insert(
          'tb_kb_chunk',
          _withoutId(row)..['docId'] = newDocId,
        );
      }

      final seenProjectKnowledge = <String>{};
      for (final row in projectKnowledge) {
        final newProjectId = projectIdMap[_intValue(row['projectId'])];
        final newDocId = docIdMap[_intValue(row['docId'])];
        if (newProjectId == null || newDocId == null) {
          skippedProjectKnowledge++;
          continue;
        }
        final key = '$newProjectId:$newDocId';
        if (!seenProjectKnowledge.add(key)) continue;
        await txn.insert(
            'tb_project_kb',
            {
              'projectId': newProjectId,
              'docId': newDocId,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        insertedProjectKnowledge++;
      }

      for (final row in storyTemplates) {
        final oldId = _intValue(row['id']);
        final newId = await txn.insert('tb_story_template', _withoutId(row));
        if (oldId != null) storyTemplateIdMap[oldId] = newId;
      }

      for (final row in storyTemplateTranslationTasks) {
        final next = _withoutId(row);
        final oldTemplateId = _intValue(next['templateId']);
        if (oldTemplateId != null) {
          final newTemplateId = storyTemplateIdMap[oldTemplateId];
          next['templateId'] = newTemplateId;
          if (newTemplateId == null) fixedTranslationTaskTemplateRefs++;
        }
        final oldOutputTemplateId = _intValue(next['outputTemplateId']);
        if (oldOutputTemplateId != null) {
          final newOutputTemplateId = storyTemplateIdMap[oldOutputTemplateId];
          next['outputTemplateId'] = newOutputTemplateId;
          if (newOutputTemplateId == null) {
            fixedTranslationTaskOutputTemplateRefs++;
          }
        }
        final oldOutputRoomId = _intValue(next['outputRoomId']);
        if (oldOutputRoomId != null) {
          final newOutputRoomId = storyRoomIdMap[oldOutputRoomId];
          next['outputRoomId'] = newOutputRoomId;
          if (newOutputRoomId == null) fixedTranslationTaskOutputRoomRefs++;
        }
        await txn.insert('tb_story_template_translation_task', next);
      }

      await _restoreRoleCardAssets(
        archive,
        assistants,
        assistantIdMap,
        warnings,
        accountHash: accountHash,
        replaceExisting: false,
        resources: resources,
      );
      for (final row in assistants) {
        final oldId = _intValue(row['id']);
        final newId = oldId == null ? null : assistantIdMap[oldId];
        if (newId == null) continue;
        await txn.update(
          'tb_assistant',
          {'roleCardAssets': row['roleCardAssets']},
          where: 'id = ?',
          whereArgs: [newId],
        );
      }
    }, accountGuard: accountGuard);

    if (remappedCids > 0) {
      warnings.add('$remappedCids 个会话 cid 与本地冲突，已改用新 cid 合并导入');
    }
    if (remappedStoryRooms > 0) {
      warnings.add('$remappedStoryRooms 个酒馆房间 ID 与本地冲突，已重映射');
    }
    if (remappedStoryParticipants > 0) {
      warnings.add('$remappedStoryParticipants 个酒馆参与者 ID 与本地冲突，已重映射');
    }
    if (remappedStoryMessages > 0) {
      warnings.add('$remappedStoryMessages 条酒馆消息 ID 与本地冲突，已重映射');
    }
    if (remappedStoryArtifacts > 0) {
      warnings.add('$remappedStoryArtifacts 个创作资料 ID 与本地冲突，已重映射');
    }
    if (fixedConversationAssistants > 0) {
      warnings.add('$fixedConversationAssistants 个会话引用的助手不在备份中，已解除绑定');
    }
    if (fixedConversationProjects > 0) {
      warnings.add('$fixedConversationProjects 个会话引用的项目不在备份中，已移动到未分类');
    }
    if (fixedProjectAssistants > 0) {
      warnings.add('$fixedProjectAssistants 个项目引用的默认助手不在备份中，已清除');
    }
    if (skippedMessages > 0) {
      warnings.add('$skippedMessages 条消息找不到对应会话，已跳过');
    }
    if (skippedChunks > 0) {
      warnings.add('$skippedChunks 个知识库片段找不到对应文档，已跳过');
    }
    if (skippedProjectKnowledge > 0) {
      warnings.add('$skippedProjectKnowledge 条项目知识库绑定无法匹配合并后的项目或文档，已跳过');
    }
    if (skippedStoryParticipants > 0) {
      warnings.add('$skippedStoryParticipants 个酒馆参与者找不到所属房间，已跳过');
    }
    if (fixedStoryParticipantAssistants > 0) {
      warnings.add('$fixedStoryParticipantAssistants 个酒馆参与者引用的助手无法匹配，已解除绑定');
    }
    if (skippedStoryMessages > 0) {
      warnings.add('$skippedStoryMessages 条酒馆消息找不到所属房间，已跳过');
    }
    if (fixedStoryMessageSpeakers > 0) {
      warnings.add('$fixedStoryMessageSpeakers 条酒馆消息引用的参与者无法匹配，已清除发言者绑定');
    }
    if (skippedStoryArtifacts > 0) {
      warnings.add('$skippedStoryArtifacts 个创作资料找不到所属房间，已跳过');
    }
    if (skippedStoryArtifactRevisions > 0) {
      warnings.add('$skippedStoryArtifactRevisions 条创作资料修订找不到所属资料，已跳过');
    }
    if (fixedTranslationTaskTemplateRefs > 0) {
      warnings.add('$fixedTranslationTaskTemplateRefs 个翻译任务找不到源酒馆模板，已清除引用');
    }
    if (fixedTranslationTaskOutputTemplateRefs > 0) {
      warnings
          .add('$fixedTranslationTaskOutputTemplateRefs 个翻译任务找不到生成的酒馆模板，已清除引用');
    }
    if (fixedTranslationTaskOutputRoomRefs > 0) {
      warnings.add('$fixedTranslationTaskOutputRoomRefs 个翻译任务找不到生成的酒馆房间，已清除引用');
    }
    if (deduplicatedAssistantMemories > 0) {
      warnings.add('$deduplicatedAssistantMemories 条相同长期记忆已去重');
    }
    if (rekeyedAssistantMemories > 0) {
      warnings.add('$rekeyedAssistantMemories 条 memoryId 已被其它助手占用，已换用新 ID');
    }

    AILogger.log('backup import merge append: '
        '${projects.length} projects, ${conversations.length} conversations'
        ', ${messages.length - skippedMessages} messages'
        ', ${assistants.length} assistants, ${favorites.length} favorites'
        ', ${knowledgeDocs.length} kb docs'
        ', ${knowledgeChunks.length - skippedChunks} kb chunks'
        ', $insertedProjectKnowledge project kb refs'
        ', ${storyTemplates.length} story templates'
        ', ${storyTemplateTranslationTasks.length} story template translation tasks'
        ', $appliedStoryPersonas story personas'
        ', ${storyRooms.length} story rooms'
        ', $insertedStoryParticipants story participants'
        ', $insertedStoryMessages story messages'
        ', $insertedStoryArtifacts story artifacts'
        ', $insertedStoryArtifactRevisions story artifact revisions'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      conversations: conversations.length,
      messages: messages.length - skippedMessages,
      assistants: assistants.length,
      assistantMemories: insertedAssistantMemories,
      favorites: favorites.length,
      projects: projects.length,
      knowledgeDocs: knowledgeDocs.length,
      knowledgeChunks: knowledgeChunks.length - skippedChunks,
      projectKnowledge: insertedProjectKnowledge,
      storyTemplates: storyTemplates.length,
      storyTemplateTranslationTasks: storyTemplateTranslationTasks.length,
      storyPersonas: appliedStoryPersonas,
      storyRooms: storyRooms.length,
      storyParticipants: insertedStoryParticipants,
      storyMessages: insertedStoryMessages,
      storyArtifacts: insertedStoryArtifacts,
      storyArtifactRevisions: insertedStoryArtifactRevisions,
      generatedImageAssets: generatedImageAssets,
      warnings: warnings,
    );
  }

  Future<BackupRestoreResult> _importAssistantsOnly({
    required Archive archive,
    required String accountHash,
    required List<Map<String, dynamic>> assistants,
    required List<Map<String, dynamic>> assistantMemories,
    required List<Map<String, dynamic>> skillCatalog,
    required List<String> warnings,
    BackupAccountGuard? accountGuard,
  }) async {
    await _ensureSchema();
    final assistantIds = {
      for (final a in assistants)
        if (a['id'] != null) a['id'],
    };

    final resources = _BackupResourceCoordinator();
    try {
      await _restoreRoleCardAssets(
        archive,
        assistants,
        _identityAssistantIdMap(assistants),
        warnings,
        accountHash: accountHash,
        replaceExisting: true,
        resources: resources,
      );
    } catch (_) {
      await resources.rollback();
      rethrow;
    }

    await _runResourceTransaction(resources, (txn) async {
      await txn.delete('tb_assistant_memory');
      await txn.delete('tb_skill_catalog');
      await txn.delete('tb_assistant');
      for (final row in assistants) {
        await txn.insert('tb_assistant', row);
      }
      for (final row in assistantMemories) {
        await txn.insert('tb_assistant_memory', row);
      }
      for (final row in skillCatalog) {
        await txn.insert('tb_skill_catalog', row);
      }

      final fixedConversations = assistantIds.isEmpty
          ? await txn.update(
              'tb_conversation_list',
              {'assistantId': null},
              where: 'assistantId is not null',
            )
          : await txn.rawUpdate(
              'update tb_conversation_list set assistantId = null '
              'where assistantId is not null '
              'and assistantId not in (${List.filled(assistantIds.length, '?').join(',')})',
              assistantIds.toList(),
            );
      if (fixedConversations > 0) {
        warnings.add('$fixedConversations 个会话引用的助手不在导入数据中，已解除绑定');
      }

      final fixedProjectAssistants = assistantIds.isEmpty
          ? await txn.update(
              'tb_project',
              {'defaultAssistantId': null},
              where: 'defaultAssistantId is not null',
            )
          : await txn.rawUpdate(
              'update tb_project set defaultAssistantId = null '
              'where defaultAssistantId is not null '
              'and defaultAssistantId not in (${List.filled(assistantIds.length, '?').join(',')})',
              assistantIds.toList(),
            );
      if (fixedProjectAssistants > 0) {
        warnings.add('$fixedProjectAssistants 个项目引用的默认助手不在导入数据中，已清除');
      }
    }, accountGuard: accountGuard);

    AILogger.log(
        'backup import assistants only: ${assistants.length} assistants'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      assistants: assistants.length,
      assistantMemories: assistantMemories.length,
      warnings: warnings,
    );
  }

  Future<BackupRestoreResult> _importKnowledgeBaseOnly({
    required List<Map<String, dynamic>> knowledgeDocs,
    required List<Map<String, dynamic>> knowledgeChunks,
    required List<Map<String, dynamic>> projectKnowledge,
    required List<String> warnings,
    BackupAccountGuard? accountGuard,
  }) async {
    await _ensureSchema();
    final projectIds = {
      for (final p in await storage.db.query('tb_project'))
        if (p['id'] != null) p['id'],
    };
    final knowledgeDocIds = {
      for (final d in knowledgeDocs)
        if (d['id'] != null) d['id'],
    };
    var skippedProjectKnowledge = 0;
    final scopedProjectKnowledge = projectKnowledge.where((row) {
      final valid = projectIds.contains(row['projectId']) &&
          knowledgeDocIds.contains(row['docId']);
      if (!valid) skippedProjectKnowledge++;
      return valid;
    }).toList(growable: false);
    if (skippedProjectKnowledge > 0) {
      warnings.add('$skippedProjectKnowledge 条项目知识库绑定无法匹配当前项目，已跳过');
    }

    final resources = _BackupResourceCoordinator();
    await _runResourceTransaction(resources, (txn) async {
      final batch = txn.batch();
      batch.delete('tb_project_kb');
      batch.delete('tb_kb_chunk');
      batch.delete('tb_kb_doc');
      for (final row in knowledgeDocs) {
        batch.insert('tb_kb_doc', row);
      }
      for (final row in knowledgeChunks) {
        batch.insert('tb_kb_chunk', row);
      }
      for (final row in scopedProjectKnowledge) {
        batch.insert('tb_project_kb', row);
      }
      await batch.commit(noResult: true);
    }, accountGuard: accountGuard);

    AILogger.log('backup import knowledge only: ${knowledgeDocs.length} docs'
        ', ${knowledgeChunks.length} chunks'
        ', ${scopedProjectKnowledge.length} project kb refs'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      knowledgeDocs: knowledgeDocs.length,
      knowledgeChunks: knowledgeChunks.length,
      projectKnowledge: scopedProjectKnowledge.length,
      warnings: warnings,
    );
  }

  Future<T> _serializeImport<T>(
    String accountHash,
    Future<T> Function() action,
  ) {
    final queueKey = '${storage.db.path}\u0000$accountHash';
    final previous = _importOperationTails[queueKey] ?? Future<void>.value();
    final gate = Completer<void>();
    _importOperationTails[queueKey] = gate.future;
    final ready = previous.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return ready.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
      if (identical(_importOperationTails[queueKey], gate.future)) {
        _importOperationTails.remove(queueKey);
      }
    });
  }

  static Archive _decodeArchive(List<int> zipBytes) {
    return decodeBoundedZipArchive(zipBytes);
  }

  static bool _verifyArchiveIntegrity(
    Archive archive,
    Map<String, dynamic> manifest,
    int version,
    List<String> warnings, {
    bool reportLegacyWarning = false,
  }) {
    if (version < 11) {
      if (reportLegacyWarning) {
        warnings.add('旧备份未包含完整性校验，也不包含长期记忆');
      }
      return false;
    }

    validateBackupEntryNames(archive.files.map((file) => file.name));
    final entries = <String, List<int>>{};
    for (final file in archive.files) {
      if (!file.isFile) {
        throw const FormatException('备份不应包含目录 entry');
      }
      final content = file.content;
      // _decodeArchive 已按预算完整解压并持有这些 bytes；完整性校验只读，
      // 直接复用可避免接近总上限时再复制整包内容导致峰值内存翻倍。
      entries[file.name] = content;
    }
    verifyEntryDigests(entries, manifest['entries']);
    for (final name in [..._v11RowCountKeys.keys, _kSettings]) {
      if (!entries.containsKey(name)) {
        throw FormatException('v11 备份缺少必需 entry：$name');
      }
    }
    return true;
  }

  static void _validateV11ManifestCounts(
    Archive archive,
    Map<String, dynamic> manifest,
    Map<String, int> rowCounts,
  ) {
    final rawCounts = manifest['counts'];
    if (rawCounts is! Map) {
      throw const FormatException('v11 备份缺少 counts 声明');
    }
    final expected = <String, int>{
      for (final entry in _v11RowCountKeys.entries)
        entry.value: rowCounts[entry.key] ?? -1,
      for (final entry in _v11ResourceCountKeys.entries)
        entry.value: archive.files
            .where((file) => file.isFile && file.name.startsWith(entry.key))
            .length,
    };
    if (expected.values.any((count) => count < 0)) {
      throw StateError('v11 实际行数统计不完整');
    }
    final actualKeys = rawCounts.keys.whereType<String>().toSet();
    if (rawCounts.length != expected.length ||
        actualKeys.length != expected.length ||
        !expected.keys.every(actualKeys.contains)) {
      throw const FormatException('v11 备份 counts 字段不完整');
    }
    for (final entry in expected.entries) {
      final declared = rawCounts[entry.key];
      if (declared is! int || declared < 0 || declared != entry.value) {
        throw FormatException(
          'v11 备份数量不一致：${entry.key} '
          '声明 $declared，实际 ${entry.value}',
        );
      }
    }
  }

  static Map<String, dynamic> _readManifest(Archive archive) {
    final manifest = _readJson(archive, _kManifest);
    if (manifest is Map<String, dynamic>) return manifest;
    if (manifest is Map) return manifest.cast<String, dynamic>();
    throw const FormatException('不是有效的备份文件（缺少 manifest.json）');
  }

  static int _validateFormatVersion(
    Map<String, dynamic> manifest,
    Archive archive,
  ) {
    final raw = manifest['formatVersion'];
    if (raw is! int || raw < 1 || raw > formatVersion) {
      throw FormatException('备份 formatVersion 不受支持：$raw');
    }
    if (raw < 11 &&
        (manifest.containsKey('entries') ||
            archive.findFile(_kAssistantMemories) != null)) {
      throw const FormatException('备份版本声明与 v11 完整性结构不一致');
    }
    return raw;
  }

  static bool _isRequiredRowEntry(String name, int version) {
    if (version >= 11) return _v11RowCountKeys.containsKey(name);
    final since = _legacyRequiredRowSince[name];
    return since != null && version >= since;
  }

  static List<Map<String, dynamic>> _readRowsForVersion(
    Archive archive,
    String name,
    int version,
  ) =>
      _readRows(
        archive,
        name,
        strict: _isRequiredRowEntry(name, version),
      );

  static Object? _readSettingsJson(Archive archive, int _) {
    final raw = _readJsonStrict(archive, _kSettings);
    if (raw is! Map) {
      throw const FormatException('settings.json 必须是 JSON object');
    }
    try {
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      throw const FormatException('settings.json 字段格式不合法');
    }
  }

  static AISettings? _parseSettings(Object? settingsJson) {
    if (settingsJson == null) return null;
    if (settingsJson is! Map) {
      throw const FormatException('AI 设置格式不合法');
    }
    try {
      final settings = AISettings.fromJson(
        Map<String, dynamic>.from(settingsJson),
      );
      AISettingsDao.validateSettings(settings);
      return stripImportedMcpAuthorizations(settings);
    } catch (error) {
      throw FormatException('AI 设置格式不合法：$error');
    }
  }

  /// 通过各 DAO 的静态工厂确保四张表存在且 schema 最新（含历史 ALTER）。
  Future<void> _ensureSchema({bool includeSkillCatalog = true}) async {
    await DbMigration.run(storage.db);
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await AssistantDao.create(storage);
    await AssistantMemoryDao.create(storage);
    if (includeSkillCatalog) await SkillCatalogDao.create(storage);
    await FavoriteDao.create(storage);
    await ProjectDao.create(storage);
    await KnowledgeDao.create(storage);
    await StoryPersonaDao.create(storage);
    await StoryRoomDao.create(storage);
    await StoryArtifactDao.create(storage);
    await StoryTemplateDao.create(storage);
    await StoryTemplateTranslationTaskDao.create(storage);
    await AgentWorkspaceDao.create(storage, cid: 0);
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

  static Map<String, dynamic> _normalizeConversationRow(
    Map<String, dynamic> row, {
    required bool hasProjectIdColumn,
  }) {
    final r = Map<String, dynamic>.from(row);
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

  /// 工作区只读取账号库中的正文快照；sourceKey 即使像路径也不会被访问。
  static Future<
          ({List<Map<String, dynamic>> files, List<Map<String, dynamic>> revisions})>
      readWorkspaceRows(HiDBManager storage) async => (
            files: await _tableExists(storage.db, AgentWorkspaceDao.filesTable)
                ? (await storage.db.query(AgentWorkspaceDao.filesTable))
                    .map(Map<String, dynamic>.from)
                    .toList()
                : <Map<String, dynamic>>[],
            revisions:
                await _tableExists(storage.db, AgentWorkspaceDao.revisionsTable)
                    ? (await storage.db.query(AgentWorkspaceDao.revisionsTable))
                        .map(Map<String, dynamic>.from)
                        .toList()
                    : <Map<String, dynamic>>[],
          );

  static ({
    List<Map<String, dynamic>> files,
    List<Map<String, dynamic>> revisions
  }) _readWorkspaceArchiveRows(Archive archive) {
    final hasFiles = archive.findFile(_kWorkspaceFiles) != null;
    final hasRevisions = archive.findFile(_kWorkspaceRevisions) != null;
    if (hasFiles != hasRevisions) {
      throw const FormatException('工作区备份缺少文件或修订条目');
    }
    if (!hasFiles) {
      return (
        files: <Map<String, dynamic>>[],
        revisions: <Map<String, dynamic>>[]
      );
    }
    final files = _readRows(archive, _kWorkspaceFiles, strict: true);
    final revisions = _readRows(archive, _kWorkspaceRevisions, strict: true);
    _validateWorkspaceRows(files, revisions);
    return (files: files, revisions: revisions);
  }

  static void _validateWorkspaceRows(
      List<Map<String, dynamic>> files, List<Map<String, dynamic>> revisions) {
    final ids = <int>{};
    final versions = <String>{};
    for (final row in revisions) {
      final parsed = AgentWorkspaceRevision.fromJson(row);
      if (parsed.fileId <= 0 ||
          parsed.revision <= 0 ||
          !versions.add('${parsed.fileId}:${parsed.revision}')) {
        throw const FormatException('工作区修订 ID 无效或重复');
      }
    }
    for (final row in files) {
      final parsed = AgentWorkspaceFile.fromJson(row);
      if (parsed.id <= 0 ||
          parsed.revision <= 0 ||
          !ids.add(parsed.id) ||
          !versions.contains('${parsed.id}:${parsed.revision}')) {
        throw const FormatException('工作区文件缺少当前修订或 ID 重复');
      }
    }
  }

  /// 与游客迁移共用同一事务内的引用映射，输出及其全部修订均追加保存。
  static Future<Map<int, int>> restoreWorkspaceRows(
    DatabaseExecutor db, {
    required List<Map<String, dynamic>> files,
    required List<Map<String, dynamic>> revisions,
    required Map<int, int> cidMap,
  }) async {
    _validateWorkspaceRows(files, revisions);
    final ids = <int, int>{};
    for (final file in files) {
      final cid = cidMap[_intValue(file['cid'])];
      if (cid == null) continue;
      final oldId = _intValue(file['id'])!;
      ids[oldId] = await db.insert(
          AgentWorkspaceDao.filesTable, _withoutId(file)..['cid'] = cid);
    }
    for (final revision in revisions) {
      final id = ids[_intValue(revision['fileId'])];
      if (id == null) continue;
      await db.insert(
          AgentWorkspaceDao.revisionsTable, {...revision, 'fileId': id});
    }
    return ids;
  }

  /// 只改文件、原文引用的结构化 ID 及清单 JSON，不替换普通正文和引用标记。
  static Map<String, dynamic> remapWorkspaceMessageReferences(
    Map<String, dynamic> message, {
    required List<Map<String, dynamic>> files,
    required Map<int, int> fileIdMap,
    required Map<int, int> cidMap,
  }) {
    final next = Map<String, dynamic>.from(message);
    final raw = message['blocks'];
    if (raw is! String || raw.isEmpty) return next;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return next;
    }
    if (decoded is! List) return next;
    var changed = false;
    final blocks = <Object?>[];
    final oldCid = _intValue(message['cid']);
    for (final original in decoded) {
      if (original is Map &&
          original['type'] == 'citation' &&
          original['localSources'] is List) {
        final block = Map<String, dynamic>.from(original);
        block['localSources'] = [
          for (final rawSource in original['localSources'] as List)
            if (rawSource is Map)
              _remapWorkspaceCitation(
                Map<String, dynamic>.from(rawSource),
                oldMessageCid: oldCid,
                files: files,
                fileIdMap: fileIdMap,
                cidMap: cidMap,
              )
            else
              rawSource,
        ];
        blocks.add(block);
        changed = true;
        continue;
      }
      if (original is! Map ||
          original['type'] != 'file' ||
          original['file'] is! Map) {
        blocks.add(original);
        continue;
      }
      final block = Map<String, dynamic>.from(original);
      final file = Map<String, dynamic>.from(original['file'] as Map);
      final oldId = _intValue(file['workspaceFileId']);
      if (oldId == null) {
        blocks.add(original);
        continue;
      }
      final belongsToConversation = files.any((row) =>
          _intValue(row['id']) == oldId && _intValue(row['cid']) == oldCid);
      var id = belongsToConversation ? fileIdMap[oldId] : null;
      final cid = oldCid == null ? null : cidMap[oldCid];
      final text = file['extractedText'];
      const prefix = '【工作区附件，正文尚未读取】\n';
      if (text is String && text.startsWith(prefix)) {
        final end = text.indexOf('\n', prefix.length);
        if (end >= 0) {
          try {
            final manifest = Map<String, dynamic>.from(
                jsonDecode(text.substring(prefix.length, end)) as Map);
            if (_intValue(manifest['id']) != oldId) id = null;
            if (id != null && cid != null) {
              manifest['id'] = id;
              manifest['cid'] = cid;
              file['extractedText'] =
                  '$prefix${jsonEncode(manifest)}${text.substring(end)}';
            } else {
              manifest.remove('id');
              manifest.remove('cid');
              manifest['available'] = false;
              file['extractedText'] = '$prefix${jsonEncode(manifest)}\n'
                  '此备份未包含可用的工作区正文，请重新附加原文件后阅读。';
            }
          } catch (_) {
            // 非清单文本保留原样，引用仍按数据库映射处理。
          }
        }
      }
      if (id == null || cid == null) {
        file.remove('workspaceFileId');
      } else {
        file['workspaceFileId'] = id;
      }
      block['file'] = file;
      blocks.add(block);
      changed = true;
    }
    if (changed) next['blocks'] = jsonEncode(blocks);
    return next;
  }

  static Map<String, dynamic> _remapWorkspaceCitation(
    Map<String, dynamic> source, {
    required int? oldMessageCid,
    required List<Map<String, dynamic>> files,
    required Map<int, int> fileIdMap,
    required Map<int, int> cidMap,
  }) {
    final next = Map<String, dynamic>.from(source);
    final oldFileId = _intValue(source['fileId']);
    final oldSourceCid = _intValue(source['cid']);
    final owned = oldFileId != null &&
        oldMessageCid != null &&
        oldSourceCid == oldMessageCid &&
        files.any((row) =>
            _intValue(row['id']) == oldFileId &&
            _intValue(row['cid']) == oldMessageCid);
    final mappedFileId = owned ? fileIdMap[oldFileId] : null;
    final mappedCid = owned ? cidMap[oldMessageCid] : null;
    if (mappedFileId == null || mappedCid == null) {
      // 缺正文或跨会话伪造引用不能沿用旧 ID，避免碰巧指向目标库同号文件。
      next['available'] = false;
    } else {
      next['fileId'] = mappedFileId;
      next['cid'] = mappedCid;
    }
    // sourceId 与正文标记保持一致；版本、区间、hash、quote 不随 ID 映射改变。
    return next;
  }

  static void _normalizeStoryMessageBranches(
    List<Map<String, dynamic>> rooms,
    List<Map<String, dynamic>> participants,
    List<Map<String, dynamic>> messages,
    List<String> warnings,
  ) {
    for (final room in rooms) {
      room['promptConfigJson'] = '${room['promptConfigJson'] ?? ''}';
      room['quickRepliesJson'] = '${room['quickRepliesJson'] ?? ''}';
      room['regexScriptsJson'] = '${room['regexScriptsJson'] ?? ''}';
      final rawPreset = room['tavernPresetJson'];
      room['tavernPresetJson'] =
          StoryTavernPresetTransfer.normalizeRoomBundle(rawPreset);
      room['temperature'] =
          StoryTavernPresetTransfer.safeTemperature(room['temperature']);
      room['topP'] = StoryTavernPresetTransfer.safeTopP(room['topP']);
      room['maxOutputTokens'] =
          StoryTavernPresetTransfer.safeMaxTokens(room['maxOutputTokens']);
      if (rawPreset != null &&
          '$rawPreset'.trim().isNotEmpty &&
          room['tavernPresetJson'] == '') {
        warnings.add('酒馆房间包含无效 Tavern 预设，已安全移除。');
      }
      room['personaKey'] = room['personaKey']?.toString();
    }
    final roomById = <int, Map<String, dynamic>>{
      for (final room in rooms)
        if (_intValue(room['id']) != null) _intValue(room['id'])!: room,
    };
    var repaired = 0;
    final participantKeysByRoom = <int, Set<String>>{};
    for (var index = 0; index < participants.length; index++) {
      final participant = participants[index];
      final roomId = _intValue(participant['roomId']);
      if (roomId == null) continue;
      final used = participantKeysByRoom.putIfAbsent(roomId, () => <String>{});
      var key = '${participant['participantKey'] ?? ''}'.trim();
      if (key.isEmpty || used.contains(key)) {
        final suffix = _intValue(participant['id']) ?? index + 1;
        final base = 'backup-participant-$roomId-$suffix';
        key = base;
        var attempt = 1;
        while (used.contains(key)) {
          key = '$base-${++attempt}';
        }
        repaired++;
      }
      participant['participantKey'] = key;
      participant['stateSummary'] = '${participant['stateSummary'] ?? ''}';
      participant['topP'] =
          StoryTavernPresetTransfer.safeTopP(participant['topP']);
      used.add(key);
    }
    final grouped = <int, List<Map<String, dynamic>>>{};
    for (final message in messages) {
      final roomId = _intValue(message['roomId']);
      if (roomId == null) continue;
      grouped.putIfAbsent(roomId, () => []).add(message);
    }
    final usedKeys = <String>{};
    for (final entry in grouped.entries) {
      final roomId = entry.key;
      final rows = entry.value
        ..sort((a, b) {
          final byId =
              (_intValue(a['id']) ?? 0).compareTo(_intValue(b['id']) ?? 0);
          if (byId != 0) return byId;
          return (_intValue(a['createdAt']) ?? 0)
              .compareTo(_intValue(b['createdAt']) ?? 0);
        });
      final hasBranchData = rows.any((row) =>
          '${row['nodeKey'] ?? ''}'.trim().isNotEmpty ||
          row.containsKey('parentNodeKey'));
      final keyMap = <String, String>{};
      final roomKeys = <String>{};
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final original = '${row['nodeKey'] ?? ''}'.trim();
        var key = original;
        if (key.isEmpty || usedKeys.contains(key)) {
          final suffix = _intValue(row['id']) ?? index + 1;
          final base = 'backup-node-$roomId-$suffix';
          key = base;
          var attempt = 1;
          while (usedKeys.contains(key)) {
            key = '$base-${++attempt}';
          }
          repaired++;
        }
        if (original.isNotEmpty) keyMap.putIfAbsent(original, () => key);
        row['nodeKey'] = key;
        row['contextStateAfter'] = '${row['contextStateAfter'] ?? ''}';
        row['roleStatesAfter'] = '${row['roleStatesAfter'] ?? '{}'}';
        usedKeys.add(key);
        roomKeys.add(key);
      }
      String? previous;
      for (final row in rows) {
        final key = row['nodeKey'] as String;
        if (!hasBranchData) {
          row['parentNodeKey'] = previous;
        } else {
          final rawParent = '${row['parentNodeKey'] ?? ''}'.trim();
          final parent = keyMap[rawParent] ?? rawParent;
          if (parent.isEmpty || !roomKeys.contains(parent) || parent == key) {
            if (rawParent.isNotEmpty) repaired++;
            row['parentNodeKey'] = null;
          } else {
            row['parentNodeKey'] = parent;
          }
        }
        final rawGroup = '${row['candidateGroupKey'] ?? ''}'.trim();
        row['candidateGroupKey'] =
            rawGroup.isEmpty ? key : (keyMap[rawGroup] ?? rawGroup);
        previous = key;
      }
      final room = roomById[roomId];
      if (room == null || rows.isEmpty) continue;
      final rawActive = '${room['activeMessageKey'] ?? ''}'.trim();
      final active = keyMap[rawActive] ?? rawActive;
      if (!roomKeys.contains(active)) {
        room['activeMessageKey'] = rows.last['nodeKey'];
        if (rawActive.isNotEmpty || !hasBranchData) repaired++;
      } else {
        room['activeMessageKey'] = active;
      }
      if (!hasBranchData) {
        rows.last['contextStateAfter'] = '${room['worldBookState'] ?? ''}';
      }
    }
    for (final message in messages) {
      // 早期远端/备份没有 Persona 说话人键；显式补空值，保持旧档可恢复。
      message['speakerPersonaKey'] = message['speakerPersonaKey']?.toString();
    }
    if (repaired > 0) {
      warnings.add('$repaired 处旧故事分支关系已自动修复');
    }
  }

  /// Persona 以 [personaKey] 为稳定身份，导入档里的重复项只保留较新的版本。
  static List<Map<String, dynamic>> _dedupeStoryPersonas(
    Iterable<Map<String, dynamic>> rows,
    List<String> warnings,
  ) {
    final byKey = <String, Map<String, dynamic>>{};
    var skipped = 0;
    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw);
      final key = '${row['personaKey'] ?? ''}'.trim();
      if (key.isEmpty) {
        skipped++;
        continue;
      }
      final previous = byKey[key];
      if (previous == null ||
          (_intValue(row['updatedAt']) ?? 0) >=
              (_intValue(previous['updatedAt']) ?? 0)) {
        byKey[key] = row;
      }
    }
    final deduplicated = byKey.values.toList(growable: false);
    final duplicates = rows.length - skipped - deduplicated.length;
    if (skipped > 0) {
      warnings.add('$skipped 个 Persona 缺少 personaKey，已跳过');
    }
    if (duplicates > 0) {
      warnings.add('$duplicates 个重复 Persona 已按 updatedAt 保留较新版本');
    }
    return deduplicated;
  }

  static void _repairStoryPersonaBindings(
    Iterable<Map<String, dynamic>> personas,
    Iterable<Map<String, dynamic>> rooms,
    List<String> warnings, {
    Iterable<String> additionalPersonaKeys = const <String>[],
  }) {
    final validKeys = <String>{
      for (final persona in personas)
        if ('${persona['personaKey'] ?? ''}'.trim().isNotEmpty)
          '${persona['personaKey']}'.trim(),
      ...additionalPersonaKeys
          .map((key) => key.trim())
          .where((key) => key.isNotEmpty),
    };
    var repaired = 0;
    for (final room in rooms) {
      final key = '${room['personaKey'] ?? ''}'.trim();
      if (key.isEmpty || validKeys.contains(key)) continue;
      room['personaKey'] = null;
      repaired++;
    }
    if (repaired > 0) {
      warnings.add('$repaired 个酒馆房间引用的 Persona 不在备份中，已解除绑定');
    }
  }

  static int _remapStoryBranchKeyConflicts(
    List<Map<String, dynamic>> rooms,
    List<Map<String, dynamic>> messages,
    Set<String> localKeys,
  ) {
    final used = <String>{...localKeys};
    final keyMap = <String, String>{};
    var remapped = 0;
    for (final message in messages) {
      final original = '${message['nodeKey'] ?? ''}'.trim();
      if (original.isEmpty) continue;
      var next = original;
      if (used.contains(next)) {
        var attempt = 1;
        do {
          next = '$original-import-${attempt++}';
        } while (used.contains(next));
        keyMap[original] = next;
        remapped++;
      }
      message['nodeKey'] = next;
      used.add(next);
    }
    if (keyMap.isEmpty) return 0;
    for (final message in messages) {
      final parent = '${message['parentNodeKey'] ?? ''}'.trim();
      if (keyMap[parent] case final mapped?) {
        message['parentNodeKey'] = mapped;
      }
      final group = '${message['candidateGroupKey'] ?? ''}'.trim();
      if (keyMap[group] case final mapped?) {
        message['candidateGroupKey'] = mapped;
      }
    }
    for (final room in rooms) {
      final active = '${room['activeMessageKey'] ?? ''}'.trim();
      if (keyMap[active] case final mapped?) {
        room['activeMessageKey'] = mapped;
      }
    }
    return remapped;
  }

  static Map<String, dynamic> _withoutId(Map<String, dynamic> row) {
    final r = Map<String, dynamic>.from(row);
    r.remove('id');
    return r;
  }

  static List<Map<String, dynamic>> _validateAssistantMemories(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> assistants,
  ) {
    final assistantIds = {
      for (final row in assistants)
        if (_intValue(row['id']) != null) _intValue(row['id'])!,
    };
    final memoryIds = <String>{};
    final normalized = <Map<String, dynamic>>[];
    for (final row in rows) {
      final memoryId = '${row['memoryId'] ?? ''}'.trim();
      if (memoryId.isEmpty) {
        throw const FormatException('长期记忆缺少 memoryId');
      }
      if (!memoryIds.add(memoryId)) {
        throw FormatException('长期记忆 memoryId 重复：$memoryId');
      }
      final assistantId = _intValue(row['assistantId']);
      if (assistantId == null || !assistantIds.contains(assistantId)) {
        throw FormatException('长期记忆引用了不存在的助手：$memoryId');
      }
      final status = row['status']?.toString() ?? '';
      if (!AssistantMemoryStatus.values.any((value) => value.name == status)) {
        throw FormatException('长期记忆状态不合法：$memoryId');
      }
      final rawConfirmed = row['confirmedByUser'];
      final bool confirmed;
      if (rawConfirmed is bool) {
        confirmed = rawConfirmed;
      } else if (rawConfirmed is int &&
          (rawConfirmed == 0 || rawConfirmed == 1)) {
        confirmed = rawConfirmed == 1;
      } else {
        throw FormatException(
          '长期记忆 confirmedByUser 只能是 bool/0/1：$memoryId',
        );
      }
      if (status == AssistantMemoryStatus.active.name && !confirmed) {
        throw FormatException('active 长期记忆未经用户确认：$memoryId');
      }
      try {
        final model = AssistantMemoryModel.fromJson(row)
          ..assistantId = assistantId
          ..memoryId = memoryId
          ..confirmedByUser = confirmed;
        if (model.assistantSyncId.trim().isEmpty) {
          model.assistantSyncId = 'legacy:$assistantId';
        }
        normalized.add(model.toJson());
      } catch (error) {
        throw FormatException('长期记忆格式不合法：$memoryId ($error)');
      }
    }
    return normalized;
  }

  static List<Map<String, dynamic>> _readSkillCatalog(
    Archive archive,
    List<Map<String, dynamic>> assistants,
  ) {
    if (archive.findFile(_kSkillCatalog) == null) return [];
    return validateSkillCatalogRows(
      _readRows(archive, _kSkillCatalog, strict: true),
      assistants,
    );
  }

  /// 备份与游客迁移共用的读取入口：只导出仍归属于原助手的有效技能。
  /// 避免助手删除/覆写后遗留的 catalog 随 id 复用进入另一个助手。
  static Future<List<Map<String, dynamic>>> readSkillCatalogRows(
    HiDBManager storage, {
    required List<Map<String, dynamic>> assistants,
  }) async {
    if (!await _tableExists(storage.db, 'tb_skill_catalog')) return [];
    final rows = await storage.db.rawQuery('''
      select c.* from tb_skill_catalog c
      inner join tb_assistant a on a.id = c.assistantId
        and a.createdAt = c.assistantCreatedAt
        and a.prompt = c.body
      order by c.assistantId asc
    ''');
    return validateSkillCatalogRows(rows, assistants);
  }

  /// 校验可选扩展的正文、包内引用和助手归属，返回只包含已知列的写入行。
  /// 在事务修改旧数据前拒绝损坏或跨助手挂载的技能记录。
  static List<Map<String, dynamic>> validateSkillCatalogRows(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> assistants,
  ) {
    final owners = {
      for (final assistant in assistants)
        if (_intValue(assistant['id']) != null)
          _intValue(assistant['id'])!: assistant,
    };
    final used = <int>{};
    final normalized = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = row['assistantId'];
      final createdAt = row['assistantCreatedAt'];
      final body = row['body'];
      final name = row['name'];
      final description = row['description'];
      final rawReferences = row['referencesJson'];
      final owner = id is int ? owners[id] : null;
      if (id is! int ||
          id < 1 ||
          !used.add(id) ||
          createdAt is! int ||
          owner == null ||
          _intValue(owner['createdAt']) != createdAt ||
          body is! String ||
          owner['prompt'] != body ||
          name is! String ||
          name.trim().isEmpty ||
          description is! String ||
          rawReferences is! String) {
        throw const FormatException('Skill 目录格式或助手归属不合法');
      }
      try {
        final decoded = jsonDecode(rawReferences);
        if (decoded is! List ||
            decoded.length > SkillCatalogDao.maxReferences) {
          throw const FormatException('Skill 参考资料格式或数量不合法');
        }
        final references = decoded
            .map((ref) => SkillCatalogReference.fromJson(
                  Map<String, dynamic>.from(ref as Map),
                ))
            .toList();
        SkillCatalogDao.validateContent(body: body, references: references);
        normalized.add({
          'assistantId': id,
          'assistantCreatedAt': createdAt,
          'name': name,
          'description': description,
          'body': body,
          'referencesJson': jsonEncode(
            references.map((ref) => ref.toJson()).toList(),
          ),
        });
      } catch (error) {
        throw FormatException('Skill 目录引用格式不合法：$error');
      }
    }
    return normalized;
  }

  static _AssistantMemoryExportCopy _normalizeAssistantMemoriesForExport(
    List<Map<String, Object?>> rows,
    List<Map<String, Object?>> assistants,
  ) {
    final assistantIds = {
      for (final row in assistants)
        if (_intValue(row['id']) != null) _intValue(row['id'])!,
    };
    final usedMemoryIds = <String>{};
    final normalized = <Map<String, dynamic>>[];
    var orphaned = 0;
    var rekeyed = 0;
    var archivedUnconfirmed = 0;
    var archivedInvalidStatus = 0;

    for (final source in rows) {
      final assistantId = _intValue(source['assistantId']);
      if (assistantId == null || !assistantIds.contains(assistantId)) {
        orphaned++;
        continue;
      }
      final row = Map<String, dynamic>.from(source)
        ..['assistantId'] = assistantId;
      var memoryId = '${row['memoryId'] ?? ''}'.trim();
      if (memoryId.isEmpty || !usedMemoryIds.add(memoryId)) {
        do {
          memoryId = generateUuidV4();
        } while (!usedMemoryIds.add(memoryId));
        rekeyed++;
      }
      row['memoryId'] = memoryId;

      final rawConfirmed = row['confirmedByUser'];
      final confirmed = rawConfirmed == true || rawConfirmed == 1;
      row['confirmedByUser'] = confirmed ? 1 : 0;
      final rawStatus = '${row['status'] ?? ''}'.trim();
      final validStatus = AssistantMemoryStatus.values
          .any((status) => status.name == rawStatus);
      if (!validStatus) {
        row['status'] = AssistantMemoryStatus.archived.name;
        archivedInvalidStatus++;
      } else if (rawStatus == AssistantMemoryStatus.active.name && !confirmed) {
        row['status'] = AssistantMemoryStatus.archived.name;
        archivedUnconfirmed++;
      }
      normalized.add(row);
    }

    final warnings = <String>[
      if (orphaned > 0) '$orphaned 条已失去助手归属的历史孤儿记忆未纳入备份，原数据库未修改',
      if (rekeyed > 0) '$rekeyed 条重复或缺失 ID 的长期记忆已在备份副本中重新编号，原数据库未修改',
      if (archivedUnconfirmed > 0)
        '$archivedUnconfirmed 条未确认的 active 长期记忆已在备份副本中归档',
      if (archivedInvalidStatus > 0)
        '$archivedInvalidStatus 条状态异常的长期记忆已在备份副本中归档',
    ];
    return _AssistantMemoryExportCopy(normalized, warnings);
  }

  /// merge 中的稳定去重键：身份相同且内容、来源、生命周期一致
  /// 时视为同一条；时间戳与 revision 不影响语义去重。
  static String _assistantMemoryStableKey(Map<String, Object?> row) =>
      jsonEncode([
        '${row['content'] ?? ''}'.trim(),
        '${row['source'] ?? ''}'.trim(),
        '${row['sourceType'] ?? ''}'.trim(),
        '${row['sourceConversationId'] ?? ''}'.trim(),
        '${row['sourceMessageId'] ?? ''}'.trim(),
        '${row['status'] ?? ''}'.trim(),
        row['confirmedByUser'] == true || row['confirmedByUser'] == 1,
      ]);

  static int? _intValue(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static List<Map<String, dynamic>> _sanitizeStoryRoomsForExport(
    List<Map<String, Object?>> rows,
  ) =>
      [
        for (final source in rows)
          Map<String, dynamic>.from(source)
            ..['tavernPresetJson'] =
                StoryTavernPresetTransfer.normalizeRoomBundle(
              source['tavernPresetJson'],
            ),
      ];

  static List<Map<String, dynamic>> _sanitizeStoryTemplatesForExport(
    List<Map<String, Object?>> rows,
  ) {
    return [
      for (final source in rows) _sanitizeStoryTemplateForExport(source),
    ];
  }

  /// 翻译执行快照只允许模型定位和推理策略字段。即使数据库行被旧版本或
  /// 外部工具写入了额外 JSON 字段，备份也不会把 API Key 一并带出。
  static List<Map<String, dynamic>> _sanitizeTranslationTasksForExport(
    List<Map<String, Object?>> rows,
  ) =>
      [
        for (final source in rows)
          _normalizeTranslationTaskRunState(source)
            ..['requestProfile'] = _sanitizeTranslationRequestProfile(
              source['requestProfile'],
            ),
      ];

  /// 运行租约只在当前进程内有效，不能跨备份传播。运行中的任务恢复为可重试，
  /// 其他状态也清掉不一致的租约字段，避免幽灵 worker 或未来租约阻塞恢复。
  static List<Map<String, dynamic>> _normalizeTranslationTaskRunStates(
    List<Map<String, dynamic>> rows,
  ) =>
      [for (final row in rows) _normalizeTranslationTaskRunState(row)];

  static Map<String, dynamic> _normalizeTranslationTaskRunState(
    Map<String, Object?> source,
  ) {
    final row = Map<String, dynamic>.from(source);
    if (row['status'] == StoryTemplateTranslationTaskStatus.running) {
      row
        ..['status'] = StoryTemplateTranslationTaskStatus.retryable
        ..['nextRunAt'] = null;
    }
    row
      ..['leaseOwner'] = null
      ..['leaseUntil'] = null;
    return row;
  }

  static String _sanitizeTranslationRequestProfile(Object? raw) {
    try {
      if (raw is! String || raw.trim().isEmpty) return '';
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return '';
      final profile = TranslationRequestProfile.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return jsonEncode(profile.toJson());
    } catch (_) {
      return '';
    }
  }

  static Map<String, dynamic> _sanitizeStoryTemplateForExport(
    Map<String, Object?> source,
  ) {
    final row = Map<String, dynamic>.from(source);
    final rawPayload = source['payload'];
    try {
      if (rawPayload is! String) {
        throw const FormatException('模板 payload 不是字符串');
      }
      final decoded = jsonDecode(rawPayload);
      if (decoded is! Map) {
        throw const FormatException('模板 payload 不是 JSON object');
      }
      final payload = Map<String, dynamic>.from(decoded);
      if (payload.containsKey('tavernPresetJson')) {
        payload['tavernPresetJson'] =
            StoryTavernPresetTransfer.normalizeRoomBundle(
          payload['tavernPresetJson'],
        );
      }
      row['payload'] = jsonEncode(payload);
    } catch (_) {
      // 无法解析时不能证明原 payload 不含凭据；只在导出副本中清空。
      row['payload'] = '{}';
    }
    return row;
  }

  static List<int> _jsonBytes(Object content) =>
      utf8.encode(jsonEncode(content));

  Future<BackupConflictSummary> _previewConflicts({
    required List<Map<String, dynamic>> conversations,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> assistants,
    required List<Map<String, dynamic>> assistantMemories,
    required List<Map<String, dynamic>> favorites,
    required List<Map<String, dynamic>> projects,
    required List<Map<String, dynamic>> knowledgeDocs,
    required List<Map<String, dynamic>> knowledgeChunks,
    required List<Map<String, dynamic>> projectKnowledge,
    required List<Map<String, dynamic>> storyTemplates,
    required List<Map<String, dynamic>> storyTemplateTranslationTasks,
    required List<Map<String, dynamic>> storyPersonas,
    required List<Map<String, dynamic>> storyRooms,
    required List<Map<String, dynamic>> storyParticipants,
    required List<Map<String, dynamic>> storyMessages,
    required List<Map<String, dynamic>> storyArtifacts,
    required List<Map<String, dynamic>> storyArtifactRevisions,
  }) async {
    final specs = [
      _ConflictSpec('tb_conversation_list', 'cid', conversations),
      _ConflictSpec('tb_messages', 'id', messages),
      _ConflictSpec('tb_assistant', 'id', assistants),
      _ConflictSpec(
        'tb_assistant_memory',
        'memoryId',
        assistantMemories,
      ),
      _ConflictSpec('tb_favorite', 'id', favorites),
      _ConflictSpec('tb_project', 'id', projects),
      _ConflictSpec('tb_kb_doc', 'id', knowledgeDocs),
      _ConflictSpec('tb_kb_chunk', 'id', knowledgeChunks),
      _ConflictSpec('tb_project_kb', 'projectId', projectKnowledge,
          secondColumn: 'docId'),
      _ConflictSpec('tb_story_template', 'id', storyTemplates),
      _ConflictSpec(
        'tb_story_template_translation_task',
        'id',
        storyTemplateTranslationTasks,
      ),
      _ConflictSpec('tb_story_persona', 'personaKey', storyPersonas),
      _ConflictSpec('tb_story_room', 'id', storyRooms),
      _ConflictSpec('tb_story_participant', 'id', storyParticipants),
      _ConflictSpec('tb_story_message', 'id', storyMessages),
      _ConflictSpec('tb_story_artifact', 'id', storyArtifacts),
      _ConflictSpec('tb_story_artifact_revision', 'id', storyArtifactRevisions),
    ];

    var localRows = 0;
    var replacingRows = 0;
    var localOnlyRows = 0;
    var backupOnlyRows = 0;
    var changedRows = 0;
    final tableConflicts = <BackupTableConflict>[];
    for (final spec in specs) {
      final currentRows = await _tableExists(storage.db, spec.table)
          ? await storage.db.query(spec.table)
          : const <Map<String, Object?>>[];
      localRows += currentRows.length;
      final backupKeys = _rowKeys(spec.backupRows, spec);
      final localKeys = _rowKeys(currentRows, spec);
      final replacing = localKeys.intersection(backupKeys);
      final localOnly = localKeys.difference(backupKeys);
      final backupOnly = backupKeys.difference(localKeys);
      final changed = _changedRows(currentRows, spec.backupRows, spec);
      replacingRows += replacing.length;
      localOnlyRows += localOnly.length;
      backupOnlyRows += backupOnly.length;
      changedRows += changed;
      tableConflicts.add(BackupTableConflict(
        table: spec.table,
        localRows: currentRows.length,
        backupRows: spec.backupRows.length,
        replacingRows: replacing.length,
        localOnlyRows: localOnly.length,
        backupOnlyRows: backupOnly.length,
        changedRows: changed,
        replacingSamples: replacing.take(3).toList(growable: false),
        localOnlySamples: localOnly.take(3).toList(growable: false),
      ));
    }
    return BackupConflictSummary(
      localRows: localRows,
      replacingRows: replacingRows,
      localOnlyRows: localOnlyRows,
      backupOnlyRows: backupOnlyRows,
      changedRows: changedRows,
      tableConflicts: tableConflicts,
    );
  }

  static int _changedRows(
    Iterable<Map<String, Object?>> localRows,
    Iterable<Map<String, Object?>> backupRows,
    _ConflictSpec spec,
  ) {
    final localByKey = {
      for (final row in localRows)
        if (_rowKey(row, spec) != null) _rowKey(row, spec)!: _stableJson(row),
    };
    var changed = 0;
    for (final row in backupRows) {
      final key = _rowKey(row, spec);
      if (key == null || !localByKey.containsKey(key)) continue;
      if (localByKey[key] != _stableJson(row)) changed++;
    }
    return changed;
  }

  static Set<String> _rowKeys(
      Iterable<Map<String, Object?>> rows, _ConflictSpec spec) {
    return {
      for (final row in rows)
        if (_rowKey(row, spec) != null) _rowKey(row, spec)!,
    };
  }

  static String? _rowKey(Map<String, Object?> row, _ConflictSpec spec) {
    if (row[spec.keyColumn] == null) return null;
    if (spec.secondColumn != null && row[spec.secondColumn] == null) {
      return null;
    }
    return spec.secondColumn == null
        ? '${row[spec.keyColumn]}'
        : '${row[spec.keyColumn]}:${row[spec.secondColumn]}';
  }

  static String _stableJson(Map<String, Object?> row) {
    final sorted = SplayTreeMap<String, Object?>.of(row);
    return jsonEncode(sorted);
  }

  static Future<bool> _tableExists(DatabaseExecutor db, String table) async {
    final rows = await db.query('sqlite_master',
        columns: ['name'],
        where: 'type = ? and name = ?',
        whereArgs: ['table', table],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// 任务断点/语义摘要属于当前本机消息的派生数据，不随备份恢复。
  /// 两个覆盖会话的模式才清理；追加合并保留已有会话的任务状态。
  static Future<void> _clearDerivedConversationState(Transaction txn) async {
    for (final table in [
      'tb_agent_read_interval',
      'tb_agent_verification_report',
      'tb_agent_verification_turn',
      'tb_agent_task_criteria',
      'tb_agent_task_session',
      'tb_chat_semantic_summary',
    ]) {
      if (await _tableExists(txn, table)) await txn.delete(table);
    }
  }

  Future<void> _runResourceTransaction(
    _BackupResourceCoordinator resources,
    Future<void> Function(Transaction txn) action, {
    BackupAccountGuard? accountGuard,
  }) async {
    try {
      await storage.db.transaction((txn) async {
        await action(txn);
        final guard = accountGuard;
        if (guard != null) await guard();
        final injector = debugImportFailureInjector;
        if (injector != null) {
          await injector(BackupImportFailurePoint.beforeResourceSwap);
        }
        await resources.swapDirectories(
          afterFirstSwap: () async {
            final currentInjector = debugImportFailureInjector;
            if (currentInjector != null) {
              await currentInjector(
                BackupImportFailurePoint.afterFirstResourceDirectorySwap,
              );
            }
          },
        );
        final currentInjector = debugImportFailureInjector;
        if (currentInjector != null) {
          await currentInjector(BackupImportFailurePoint.afterResourceSwap);
        }
      });
      await resources.finish();
    } catch (error, stackTrace) {
      try {
        await resources.rollback(
          failureInjector: debugResourceRollbackFailureInjector,
        );
      } catch (rollbackError, rollbackStackTrace) {
        Error.throwWithStackTrace(rollbackError, rollbackStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static Future<Directory> _generatedImageDocumentsDir() =>
      (debugGeneratedImageDirectoryResolver ??
          getApplicationDocumentsDirectory)();

  static Future<Directory> _generatedImageAlbumDir({
    required String accountHash,
  }) async {
    final baseDir = await (debugGeneratedImageDirectoryResolver ??
        getApplicationDocumentsDirectory)();
    return AccountResourceScope.scopedDirectory(
      base: baseDir,
      resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
      accountHash: accountHash,
    );
  }

  static Future<Map<String, List<int>>> _collectGeneratedImageFiles({
    required String accountHash,
  }) async {
    final files = <String, List<int>>{};
    try {
      final baseDir = await _generatedImageDocumentsDir();
      final scopedDir = AccountResourceScope.scopedDirectory(
        base: baseDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: accountHash,
      );
      final legacyDir = AccountResourceScope.legacyRoot(
        base: baseDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
      );
      // 只扫描当前 scoped 与 legacy 顶层，不递归进入 accounts/。
      await _collectGeneratedImageDirectory(scopedDir, files);
      await _collectGeneratedImageDirectory(legacyDir, files);
    } catch (_) {
      // 应用内相册资源缺失不阻塞备份。
    }
    return files;
  }

  static Future<void> _collectGeneratedImageDirectory(
    Directory directory,
    Map<String, List<int>> files,
  ) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!_isImageFileName(name)) continue;
      final archiveName = _uniqueImageAssetName(files.keys, name);
      files[archiveName] = await entity.readAsBytes();
    }
  }

  static String _uniqueImageAssetName(Iterable<String> existing, String name) {
    final used = existing.toSet();
    if (!used.contains(name)) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var index = 1;
    while (used.contains('${stem}_$index$extension')) {
      index++;
    }
    return '${stem}_$index$extension';
  }

  static Future<Directory> _roleCardAssetsRootDir() async {
    final base = await (debugRoleCardAssetsDirectoryResolver ??
        getApplicationDocumentsDirectory)();
    return Directory(
        '${base.path}/${AssistantRoleCardAssetStore.directoryName}');
  }

  static Future<Directory> _roleCardAssetsAccountDir({
    required String accountHash,
  }) async {
    final root = await _roleCardAssetsRootDir();
    return AccountResourceScope.scopedDirectory(
      base: root.parent,
      resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
      accountHash: accountHash,
    );
  }

  static Future<Map<String, List<int>>> _collectRoleCardAssetFiles(
    List<Map<String, Object?>> assistants, {
    required String accountHash,
  }) async {
    final files = <String, List<int>>{};
    final hasReferences = assistants.any((assistant) {
      final manifest = _roleCardAssetManifest(assistant['roleCardAssets']);
      return manifest?.any((entry) =>
              entry is Map &&
              (entry['localPath']?.toString().trim().isNotEmpty ?? false)) ??
          false;
    });
    if (!hasReferences) return files;
    late final Directory root;
    try {
      root = await _roleCardAssetsRootDir();
    } catch (_) {
      // 纯 Dart 测试或平台目录暂不可用时，仍允许导出数据库元数据。
      return files;
    }
    for (final assistant in assistants) {
      final assistantId = _intValue(assistant['id']);
      final manifest = _roleCardAssetManifest(assistant['roleCardAssets']);
      if (assistantId == null || manifest == null) continue;
      for (final entry in manifest.asMap().entries) {
        if (entry.value is! Map) continue;
        final asset = Map<String, dynamic>.from(entry.value as Map);
        final localPath = asset['localPath']?.toString().trim() ?? '';
        final suffix = AssistantRoleCardAssetStore.managedSuffix(
          localPath,
          accountHash: accountHash,
        );
        if (suffix == null ||
            !_isRoleCardAssetSuffixForAssistant(suffix, assistantId)) {
          continue;
        }
        try {
          // 清单的绝对根不可信，只从当前 documents 托管根重定位。
          final file = File('${root.path}/$suffix');
          if (!await file.exists()) continue;
          files[_roleCardAssetArchiveName(assistantId, entry.key, asset)] =
              await file.readAsBytes();
        } catch (_) {
          // 单个角色卡资源缺失不阻塞整包备份。
        }
      }
    }
    return files;
  }

  static Future<void> _restoreRoleCardAssets(
    Archive archive,
    List<Map<String, dynamic>> assistants,
    Map<int, int> assistantIdMap,
    List<String> warnings, {
    required String accountHash,
    required bool replaceExisting,
    required _BackupResourceCoordinator resources,
  }) async {
    final hasReferences = _hasRoleCardAssetReferences(assistants);
    if (!hasReferences && !replaceExisting) return;
    late final Directory root;
    try {
      root = await _roleCardAssetsAccountDir(accountHash: accountHash);
    } catch (_) {
      warnings.add('角色卡资源目录无法重建，已跳过资源恢复');
      return;
    }
    final stageRoot = await resources.stageDirectory(
      root,
      preserveExisting: !replaceExisting,
    );
    if (!hasReferences) return;

    var missing = 0;
    var failed = 0;
    for (final assistant in assistants) {
      final oldId = _intValue(assistant['id']);
      final newId = oldId == null ? null : assistantIdMap[oldId];
      final manifest = _roleCardAssetManifest(assistant['roleCardAssets']);
      if (manifest == null) continue;
      var changed = false;
      for (final entry in manifest.asMap().entries) {
        if (entry.value is! Map) continue;
        final asset = Map<String, dynamic>.from(entry.value as Map);
        final localPath = asset['localPath']?.toString().trim() ?? '';
        if (localPath.isEmpty) continue;
        final archiveFile = oldId == null
            ? null
            : archive.findFile(
                '$_kRoleCardAssetPrefix${_roleCardAssetArchiveName(oldId, entry.key, asset)}',
              );
        if (newId == null || archiveFile == null) {
          asset['localPath'] = '';
          manifest[entry.key] = asset;
          changed = true;
          missing++;
          continue;
        }
        try {
          final dir = Directory('${stageRoot.path}/$newId');
          if (!await dir.exists()) await dir.create(recursive: true);
          final filename = _roleCardAssetFileName(entry.key, asset);
          final stagedTarget = File('${dir.path}/$filename');
          await stagedTarget.writeAsBytes(archiveFile.content as List<int>,
              flush: true);
          asset['localPath'] = '${root.path}/$newId/$filename';
          manifest[entry.key] = asset;
          changed = true;
        } catch (_) {
          asset['localPath'] = '';
          manifest[entry.key] = asset;
          changed = true;
          failed++;
        }
      }
      if (changed) assistant['roleCardAssets'] = jsonEncode(manifest);
    }
    if (missing > 0) {
      warnings.add('$missing 个角色卡资源不在备份中，已保留资源元数据');
    }
    if (failed > 0) {
      warnings.add('$failed 个角色卡资源写入失败，已保留资源元数据');
    }
  }

  static Map<int, int> _identityAssistantIdMap(
    List<Map<String, dynamic>> assistants,
  ) =>
      {
        for (final assistant in assistants)
          if (_intValue(assistant['id']) != null)
            _intValue(assistant['id'])!: _intValue(assistant['id'])!,
      };

  static List<dynamic>? _roleCardAssetManifest(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is List ? List<dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static bool _hasRoleCardAssetReferences(
    List<Map<String, dynamic>> assistants,
  ) =>
      assistants.any((assistant) {
        final manifest = _roleCardAssetManifest(assistant['roleCardAssets']);
        return manifest?.any((entry) =>
                entry is Map &&
                (entry['localPath']?.toString().trim().isNotEmpty ?? false)) ??
            false;
      });

  static bool _isRoleCardAssetSuffixForAssistant(
    String suffix,
    int assistantId,
  ) {
    final segments = suffix.replaceAll('\\', '/').split('/');
    final idIndex =
        segments.first == AccountResourceScope.accountsDirectoryName ? 2 : 0;
    return segments.length > idIndex &&
        int.tryParse(segments[idIndex]) == assistantId;
  }

  static String _roleCardAssetArchiveName(
    int assistantId,
    int index,
    Map<String, dynamic> asset,
  ) =>
      '$assistantId/${_roleCardAssetFileName(index, asset)}';

  static String _roleCardAssetFileName(
    int index,
    Map<String, dynamic> asset,
  ) {
    final extension = asset['ext']?.toString().trim().replaceFirst(
              RegExp(r'^\\.+'),
              '',
            ) ??
        '';
    final safeExtension = RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(extension)
        ? extension.toLowerCase()
        : 'bin';
    return '${index.toString().padLeft(3, '0')}.$safeExtension';
  }

  static Future<Map<String, List<int>>> _collectAvatarFiles(
      Iterable<Map<String, Object?>> avatarOwners) async {
    final files = <String, List<int>>{};
    for (final row in avatarOwners) {
      if (row['avatarType'] != AvatarAssetService.imageType) continue;
      final path = row['avatarValue']?.toString();
      if (!AvatarAssetService.isManagedPath(path)) continue;
      try {
        final file = File(path!);
        if (!await file.exists()) continue;
        files[_basename(path)] = await file.readAsBytes();
      } catch (_) {
        // 头像资源缺失不阻塞备份，导入时会回退默认头像。
      }
    }
    return files;
  }

  static Future<Map<String, List<int>>> _collectAttachmentFiles(
      List<Map<String, Object?>> messages) async {
    final files = <String, List<int>>{};
    for (final row in messages) {
      final blocks = MessageBlock.decodeList(row['blocks']?.toString());
      for (final block in blocks) {
        if (block is! FileBlock) continue;
        final path = block.file.path;
        if (path == null || path.isEmpty) continue;
        try {
          final bytes = await ManagedAttachmentStore.readManagedBytes(path);
          if (bytes == null) continue;
          files[_attachmentAssetName(block.file)] = bytes;
        } catch (_) {
          // 附件原始文件缺失不阻塞备份；FileBlock 元数据仍会随消息保留。
        }
      }
    }
    return files;
  }

  static Future<void> _restoreAvatarAssets(
    Archive archive,
    List<Map<String, dynamic>> conversations,
    List<String> warnings, {
    required String accountHash,
    required _BackupResourceCoordinator resources,
    List<Map<String, dynamic>> storyPersonas = const [],
    List<Map<String, dynamic>> storyMessages = const [],
  }) async {
    final avatarAssets = {
      for (final file in archive.files)
        if (file.isFile && file.name.startsWith(_kAvatarPrefix))
          _basename(file.name): file,
    };
    final archiveHasNoAvatarAssets = avatarAssets.isEmpty;
    var dropped = 0;
    final restoredPaths = <String, String>{};
    Directory? targetDir;
    Directory? stageDir;
    Future<void> restoreRows(
      Iterable<Map<String, dynamic>> rows, {
      required String typeField,
      required String valueField,
      required bool useEmojiFallback,
    }) async {
      for (final row in rows) {
        if (row[typeField] != AvatarAssetService.imageType) continue;
        final oldPath = row[valueField]?.toString() ?? '';
        final asset = avatarAssets[_basename(oldPath)];
        if (asset == null) {
          row[typeField] = useEmojiFallback ? 'emoji' : null;
          row[valueField] = useEmojiFallback ? '🙂' : null;
          dropped++;
          continue;
        }
        var restored = restoredPaths[oldPath];
        if (restored == null) {
          targetDir ??=
              await AvatarAssetService.avatarDir(accountHash: accountHash);
          stageDir ??= await resources.stageDirectory(
            targetDir!,
            preserveExisting: true,
          );
          final filename = _basename(asset.name);
          final stagedTarget = File('${stageDir!.path}/$filename');
          await stagedTarget.writeAsBytes(asset.content as List<int>,
              flush: true);
          restored = '${targetDir!.path}/$filename';
          restoredPaths[oldPath] = restored;
        }
        row[valueField] = restored;
      }
    }

    await restoreRows(
      conversations,
      typeField: 'avatarType',
      valueField: 'avatarValue',
      useEmojiFallback: false,
    );
    await restoreRows(
      storyPersonas,
      typeField: 'avatarType',
      valueField: 'avatarValue',
      useEmojiFallback: true,
    );
    // 消息保存的是当时的 Persona 头像快照；同一旧路径必须与 Persona
    // 一并改写，否则历史消息会在新设备上丢失图片。
    await restoreRows(
      storyMessages,
      typeField: 'speakerAvatarType',
      valueField: 'speakerAvatarValue',
      useEmojiFallback: true,
    );
    if (dropped > 0) {
      warnings.add(archiveHasNoAvatarAssets
          ? '$dropped 个头像资源不在备份中，已恢复默认头像'
          : '$dropped 个头像资源缺失，已恢复默认头像');
    }
  }

  static Future<void> _restoreAttachmentAssets(
    Archive archive,
    List<Map<String, dynamic>> messages,
    List<String> warnings,
    _BackupResourceCoordinator resources,
  ) async {
    final fileAssets = {
      for (final file in archive.files)
        if (file.isFile && file.name.startsWith(_kFilePrefix))
          _basename(file.name): file,
    };

    final dir = await ManagedAttachmentStore.ensureRootDirectory();
    Directory? stageDir;
    var missing = 0;
    for (final row in messages) {
      final blocks = MessageBlock.decodeList(row['blocks'] as String?);
      if (blocks.isEmpty) continue;
      var changed = false;
      final restored = <MessageBlock>[];
      for (final block in blocks) {
        if (block is! FileBlock) {
          restored.add(block);
          continue;
        }
        final assetName = _attachmentAssetName(block.file);
        final asset = fileAssets[assetName];
        if (asset == null ||
            asset.size > ManagedAttachmentStore.maxAttachmentBytes) {
          // 备份中的 FileMetadata.path 来自归档，不得在当前设备继续被解释为
          // 可读本地路径。只有归档实际携带的附件资产才能重建 managed path。
          if (block.file.path != null) {
            missing++;
            restored.add(_fileBlockWithPath(block, null));
            changed = true;
          } else {
            restored.add(block);
          }
          continue;
        }
        stageDir ??= await resources.stageDirectory(
          dir,
          preserveExisting: true,
        );
        // 归档 key 包含旧设备完整路径，可能超过宿主文件系统的单文件名上限。
        // 保留归档 key 的兼容性，只把恢复后的磁盘文件名映射为固定长度。
        final extension = RegExp(r'\.[A-Za-z0-9]{1,10}$')
                .firstMatch(block.file.name)
                ?.group(0)
                ?.toLowerCase() ??
            '';
        final targetName =
            '${sha256.convert(utf8.encode(assetName))}$extension';
        final stagedTarget = File('${stageDir.path}/$targetName');
        await stagedTarget.writeAsBytes(asset.content as List<int>,
            flush: true);
        restored.add(_fileBlockWithPath(block, '${dir.path}/$targetName'));
        changed = true;
      }
      if (changed) row['blocks'] = MessageBlock.encodeList(restored);
    }
    if (missing > 0) {
      warnings.add('$missing 个附件原始文件不在备份中，已移除归档携带的本地路径');
    }
  }

  static FileBlock _fileBlockWithPath(FileBlock block, String? path) =>
      FileBlock(
        id: block.id,
        messageId: block.messageId,
        createdAt: block.createdAt,
        updatedAt: block.updatedAt,
        status: block.status,
        modelId: block.modelId,
        file: FileMetadata(
          name: block.file.name,
          path: path,
          mime: block.file.mime,
          size: block.file.size,
          extractedText: block.file.extractedText,
          workspaceFileId: block.file.workspaceFileId,
        ),
      );

  static Future<int> _restoreGeneratedImageAssets(
    Archive archive,
    _BackupResourceCoordinator resources, {
    required String accountHash,
    required bool replaceExisting,
  }) async {
    final imageAssets = [
      for (final file in archive.files)
        if (file.isFile && file.name.startsWith(_kGeneratedImagePrefix)) file,
    ];
    // overwrite 即使备份中没有图片，也要清空“当前账号” scoped；legacy 与
    // 其它账号目录从未进入 coordinator，因此始终原样保留。
    if (imageAssets.isEmpty && !replaceExisting) return 0;

    final dir = await _generatedImageAlbumDir(accountHash: accountHash);
    final stageDir = await resources.stageDirectory(
      dir,
      preserveExisting: !replaceExisting,
    );

    var restored = 0;
    for (final asset in imageAssets) {
      final name = _safeImageAssetName(_basename(asset.name));
      if (name == null) continue;
      final target = replaceExisting
          ? File('${stageDir.path}/$name')
          : await _uniqueFile(stageDir, name);
      await target.writeAsBytes(asset.content as List<int>, flush: true);
      restored++;
    }
    return restored;
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  static bool _isImageFileName(String name) {
    final lower = name.toLowerCase();
    return _imageExtensions.any(lower.endsWith);
  }

  static String? _safeImageAssetName(String name) {
    final normalized = name.replaceAll(RegExp(r'[/\\]'), '_').trim();
    if (normalized.isEmpty || !_isImageFileName(normalized)) return null;
    return normalized;
  }

  static Future<File> _uniqueFile(Directory dir, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    var candidate = File('${dir.path}/$name');
    var i = 1;
    while (await candidate.exists()) {
      candidate = File('${dir.path}/${stem}_$i$ext');
      i++;
    }
    return candidate;
  }

  static String _attachmentAssetName(FileMetadata file) {
    final name = file.name.trim().isEmpty
        ? _basename(file.path ?? 'attachment')
        : file.name.trim();
    final raw = '${file.path ?? name}::$name';
    final digest = base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
    return '${digest}_$name'.replaceAll(RegExp(r'[/\\]'), '_');
  }

  /// 读 zip 内一个 JSON 文件，缺失/解析失败返回 null。
  static Object? _readJson(Archive archive, String name) {
    final file = archive.findFile(name);
    if (file == null) return null;
    try {
      return jsonDecode(utf8.decode(file.content));
    } catch (e) {
      AILogger.log('backup: parse $name failed: $e');
      return null;
    }
  }

  static Object? _readJsonStrict(Archive archive, String name) {
    final file = archive.findFile(name);
    if (file == null) {
      throw FormatException('备份缺少必需 entry：$name');
    }
    try {
      return jsonDecode(utf8.decode(file.content));
    } catch (_) {
      throw FormatException('备份 entry 不是有效 JSON：$name');
    }
  }

  /// 读一个「行列表」文件；行是 sqflite 的 Map，缺失时返回空列表。
  static List<Map<String, dynamic>> _readRows(
    Archive archive,
    String name, {
    bool strict = false,
  }) {
    final raw =
        strict ? _readJsonStrict(archive, name) : _readJson(archive, name);
    if (raw is! List) {
      if (strict) throw FormatException('备份行 entry 必须是列表：$name');
      return [];
    }
    final rows = <Map<String, dynamic>>[];
    for (var index = 0; index < raw.length; index++) {
      final row = raw[index];
      if (row is! Map) {
        if (strict) {
          throw FormatException('备份行不是 Map：$name#$index');
        }
        continue;
      }
      try {
        rows.add(Map<String, dynamic>.from(row));
      } catch (_) {
        if (strict) {
          throw FormatException('备份行字段格式不合法：$name#$index');
        }
      }
    }
    return rows;
  }
}

class _ConflictSpec {
  final String table;
  final String keyColumn;
  final String? secondColumn;
  final List<Map<String, dynamic>> backupRows;

  const _ConflictSpec(this.table, this.keyColumn, this.backupRows,
      {this.secondColumn});
}

class _AssistantMemoryExportCopy {
  final List<Map<String, dynamic>> rows;
  final List<String> warnings;

  const _AssistantMemoryExportCopy(this.rows, this.warnings);
}

/// 把一个导入涉及的资源目录先构造成同文件系统的完整 staging 快照。
///
/// 正式目录只在 SQLite transaction 回调的最后阶段通过 rename 切换；旧目录
/// 会保留到 transaction 真正提交后。这样 SQLite commit 自身失败时仍可补偿
/// 恢复文件资源，而不是留下“新文件 + 旧数据库”或相反的半套状态。
class _BackupResourceCoordinator {
  final Map<String, _BackupResourceDirectory> _directories = {};

  Future<Directory> stageDirectory(
    Directory target, {
    required bool preserveExisting,
  }) async {
    final normalizedTarget = target.absolute;
    final key = normalizedTarget.path;
    final existing = _directories[key];
    if (existing != null) {
      if (existing.preserveExisting != preserveExisting) {
        throw StateError('同一资源目录不能同时使用覆盖与合并策略：$key');
      }
      return existing.stage;
    }

    final parent = normalizedTarget.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final token = generateUuidV4();
    final stage = Directory('$key.backup-stage-$token');
    final backup = Directory('$key.backup-original-$token');
    await stage.create(recursive: true);
    try {
      final before = await _snapshotTarget(normalizedTarget);
      if (preserveExisting && before.existed) {
        await _copyDirectory(normalizedTarget, stage);
      }
      final after = await _snapshotTarget(normalizedTarget);
      if (before != after) {
        throw StateError('资源目录在 staging 期间发生变化，已取消导入');
      }
      _directories[key] = _BackupResourceDirectory(
        target: normalizedTarget,
        stage: stage,
        backup: backup,
        targetExisted: before.existed,
        targetFingerprint: before.fingerprint,
        preserveExisting: preserveExisting,
      );
      return stage;
    } catch (_) {
      if (await stage.exists()) await stage.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> swapDirectories({
    Future<void> Function()? afterFirstSwap,
  }) async {
    var swapped = 0;
    for (final state in _directories.values) {
      await _assertTargetUnchanged(state);
      final stagedSnapshot = await _snapshotTarget(state.stage);
      if (!stagedSnapshot.existed || stagedSnapshot.fingerprint == null) {
        throw StateError('资源 staging 目录缺失，已取消导入');
      }
      if (state.targetExisted) {
        if (await _entityExists(state.backup.path)) {
          throw StateError('资源补偿目录已存在，已取消导入');
        }
        await state.target.rename(state.backup.path);
        state.originalMoved = true;
        state.backupOwned = true;
        final movedFingerprint = await _directoryFingerprint(state.backup);
        if (movedFingerprint != state.targetFingerprint) {
          throw StateError('资源目录在切换期间发生变化，已取消导入');
        }
      }
      await state.stage.rename(state.target.path);
      // rename 已成功后先记录所有权。后续指纹读取即使失败，
      // rollback 也知道 staging 已经占用正式路径。
      state.stageMoved = true;
      state.swappedTargetFingerprint = stagedSnapshot.fingerprint;
      final swappedSnapshot = await _snapshotTarget(state.target);
      if (!swappedSnapshot.existed ||
          swappedSnapshot.fingerprint != stagedSnapshot.fingerprint) {
        throw StateError('资源 staging 目录在切换期间发生变化，已取消导入');
      }
      swapped++;
      if (swapped == 1 && afterFirstSwap != null) {
        await afterFirstSwap();
      }
    }
  }

  Future<void> rollback({
    BackupResourceRollbackFailureInjector? failureInjector,
  }) async {
    final states = _directories.values.toList(growable: false).reversed;
    final errors = <Object>[];
    var rollbackIndex = 0;
    for (final state in states) {
      Future<void> run(
        BackupResourceRollbackOperation operation,
        Future<void> Function() action,
      ) async {
        try {
          final injector = failureInjector;
          if (injector != null) await injector(rollbackIndex, operation);
          await action();
        } catch (error) {
          errors.add(error);
        }
      }

      if (state.stageMoved) {
        await run(BackupResourceRollbackOperation.removeStagedTarget, () async {
          final current = await _snapshotTarget(state.target);
          if (current.existed) {
            if (current.fingerprint != state.swappedTargetFingerprint) {
              // 正式路径在 swap 后又被其他操作修改/替换。此时宁可
              // 保留 backup 等待人工恢复，也不能递归删掉不再属于
              // 本次导入的外部目录。
              throw StateError('资源正式目录在切换后发生变化');
            }
            await state.target.delete(recursive: true);
          }
          state.stageMoved = false;
        });
      }
      if (state.originalMoved) {
        await run(BackupResourceRollbackOperation.restoreOriginal, () async {
          if (!await state.backup.exists()) {
            throw StateError('资源补偿目录缺失');
          }
          final backupFingerprint = await _directoryFingerprint(state.backup);
          if (backupFingerprint != state.targetFingerprint) {
            throw StateError('资源补偿目录在回滚前发生变化');
          }
          if (await _entityExists(state.target.path)) {
            throw StateError('资源正式目录仍被占用');
          }
          await state.backup.rename(state.target.path);
          state.originalMoved = false;
          state.backupOwned = false;
        });
      }
      await run(BackupResourceRollbackOperation.removeStage, () async {
        if (await state.stage.exists()) {
          await state.stage.delete(recursive: true);
        }
      });
      if (state.backupOwned && !state.originalMoved) {
        await run(BackupResourceRollbackOperation.removeBackup, () async {
          if (await state.backup.exists()) {
            final fingerprint = await _directoryFingerprint(state.backup);
            if (fingerprint != state.targetFingerprint) {
              throw StateError('资源补偿目录在清理前发生变化');
            }
            await state.backup.delete(recursive: true);
          }
          state.backupOwned = false;
        });
      }
      rollbackIndex++;
    }
    if (errors.isNotEmpty) {
      throw StateError('备份资源回滚过程中有 ${errors.length} 个操作未完成');
    }
  }

  Future<void> finish() async {
    // transaction 已提交，清理不再影响导入结果；单个清理失败也不能把已提交的
    // SQLite 状态伪装成导入失败。残留目录不在正式路径下，下次系统清理即可。
    for (final state in _directories.values) {
      try {
        if (state.backupOwned && await state.backup.exists()) {
          final fingerprint = await _directoryFingerprint(state.backup);
          if (fingerprint == state.targetFingerprint) {
            await state.backup.delete(recursive: true);
            state.backupOwned = false;
          }
        }
        if (await state.stage.exists()) {
          await state.stage.delete(recursive: true);
        }
      } catch (_) {
        // best effort cleanup after a successful database commit
      }
    }
  }

  static Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await for (final entity in source.list(followLinks: false)) {
      final name = BackupService._basename(entity.path);
      if (entity is Directory) {
        final child = Directory('${destination.path}/$name');
        await child.create(recursive: true);
        await _copyDirectory(entity, child);
      } else if (entity is File) {
        await entity.copy('${destination.path}/$name');
      }
      // Link 不跟随也不复制，避免备份导入借符号链接越过托管目录。
    }
  }

  static Future<void> _assertTargetUnchanged(
    _BackupResourceDirectory state,
  ) async {
    final current = await _snapshotTarget(state.target);
    if (current.existed != state.targetExisted ||
        current.fingerprint != state.targetFingerprint) {
      throw StateError('资源目录在导入期间发生变化，已取消导入');
    }
  }

  static Future<_BackupTargetSnapshot> _snapshotTarget(
    Directory target,
  ) async {
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const _BackupTargetSnapshot.absent();
    }
    if (type != FileSystemEntityType.directory) {
      throw StateError('资源目标路径不是目录，已取消导入');
    }
    return _BackupTargetSnapshot.present(
      await _directoryFingerprint(target),
    );
  }

  static Future<String> _directoryFingerprint(Directory root) async {
    final records = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(root.path.length);
      if (entity is File) {
        final digest = await sha256.bind(entity.openRead()).first;
        records.add(jsonEncode(['file', relative, '$digest']));
      } else if (entity is Directory) {
        records.add(jsonEncode(['directory', relative]));
      } else if (entity is Link) {
        records.add(jsonEncode(['link', relative, await entity.target()]));
      }
    }
    records.sort();
    return sha256.convert(utf8.encode(jsonEncode(records))).toString();
  }

  static Future<bool> _entityExists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;
}

class _BackupResourceDirectory {
  final Directory target;
  final Directory stage;
  final Directory backup;
  final bool targetExisted;
  final String? targetFingerprint;
  final bool preserveExisting;
  bool originalMoved = false;
  bool stageMoved = false;
  bool backupOwned = false;
  String? swappedTargetFingerprint;

  _BackupResourceDirectory({
    required this.target,
    required this.stage,
    required this.backup,
    required this.targetExisted,
    required this.targetFingerprint,
    required this.preserveExisting,
  });
}

class _BackupTargetSnapshot {
  final bool existed;
  final String? fingerprint;

  const _BackupTargetSnapshot.absent()
      : existed = false,
        fingerprint = null;

  const _BackupTargetSnapshot.present(this.fingerprint) : existed = true;

  @override
  bool operator ==(Object other) =>
      other is _BackupTargetSnapshot &&
      other.existed == existed &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(existed, fingerprint);
}
