import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
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
  final int favorites;
  final int projects;
  final int knowledgeDocs;
  final int knowledgeChunks;
  final int projectKnowledge;
  final int storyTemplates;
  final int generatedImageAssets;

  /// 备份里的 AI 设置（settings.json 缺失时为 null）。
  final AISettings? settings;

  /// 非致命问题（外键修复、账号不一致等），UI 可提示用户。
  final List<String> warnings;

  const BackupRestoreResult({
    this.conversations = 0,
    this.messages = 0,
    this.assistants = 0,
    this.favorites = 0,
    this.projects = 0,
    this.knowledgeDocs = 0,
    this.knowledgeChunks = 0,
    this.projectKnowledge = 0,
    this.storyTemplates = 0,
    this.generatedImageAssets = 0,
    this.settings,
    this.warnings = const [],
  });
}

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

/// 导入前预览：只解析 zip 与 manifest，不写数据库、不恢复资源。
class BackupPreview {
  final int formatVersion;
  final int exportedAt;
  final String accountHash;
  final bool includeApiKeys;
  final int conversations;
  final int messages;
  final int assistants;
  final int favorites;
  final int projects;
  final int knowledgeDocs;
  final int knowledgeChunks;
  final int projectKnowledge;
  final int storyTemplates;
  final int avatarAssets;
  final int fileAssets;
  final int generatedImageAssets;
  final bool hasSettings;
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
    required this.favorites,
    required this.projects,
    required this.knowledgeDocs,
    required this.knowledgeChunks,
    required this.projectKnowledge,
    this.storyTemplates = 0,
    required this.avatarAssets,
    required this.fileAssets,
    this.generatedImageAssets = 0,
    required this.hasSettings,
    this.conflictSummary = const BackupConflictSummary(),
    this.warnings = const [],
  });

  int get totalRows =>
      conversations +
      messages +
      assistants +
      favorites +
      projects +
      knowledgeDocs +
      knowledgeChunks +
      projectKnowledge +
      storyTemplates;

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
        return sum('仅助手', const ['tb_assistant']);
      case BackupImportMode.knowledgeBaseOnly:
        return sum('仅知识库', const ['tb_kb_doc', 'tb_kb_chunk', 'tb_project_kb']);
      case BackupImportMode.mergeAppend:
        final plan = sum('合并导入', const [
          'tb_project',
          'tb_conversation_list',
          'tb_messages',
          'tb_assistant',
          'tb_favorite',
          'tb_kb_doc',
          'tb_kb_chunk',
          'tb_project_kb',
          'tb_story_template',
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
  static const int formatVersion = 3;

  static const _kManifest = 'manifest.json';
  static const _kConversations = 'conversations.json';
  static const _kMessages = 'messages.json';
  static const _kAssistants = 'assistants.json';
  static const _kFavorites = 'favorites.json';
  static const _kProjects = 'projects.json';
  static const _kSettings = 'settings.json';
  static const _kKnowledgeDocs = 'knowledge_docs.json';
  static const _kKnowledgeChunks = 'knowledge_chunks.json';
  static const _kProjectKnowledge = 'project_knowledge.json';
  static const _kStoryTemplates = 'story_templates.json';
  static const _kAvatarPrefix = 'assets/avatars/';
  static const _kFilePrefix = 'assets/files/';
  static const _kGeneratedImagePrefix = 'assets/generated_images/';
  static const _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.gif'};

  @visibleForTesting
  static Future<Directory> Function()? debugGeneratedImageDirectoryResolver;

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
  }) async {
    // 表是 DAO 懒建的：先确保 schema 就绪（含 assistantId 列 ALTER），
    // 全新账号没建过的表导出为空列表而不是报错。
    await _ensureSchema();
    final conversations = await storage.db.query('tb_conversation_list');
    final messages = await storage.db.query('tb_messages');
    final assistants = await storage.db.query('tb_assistant');
    final favorites = await storage.db.query('tb_favorite');
    final projects = await storage.db.query('tb_project');
    final knowledgeDocs = await storage.db.query('tb_kb_doc');
    final knowledgeChunks = await storage.db.query('tb_kb_chunk');
    final projectKnowledge = await storage.db.query('tb_project_kb');
    final storyTemplates = await storage.db.query('tb_story_template');
    final avatarFiles = await _collectAvatarFiles(conversations);
    final attachmentFiles = await _collectAttachmentFiles(messages);
    final generatedImageFiles = await _collectGeneratedImageFiles();

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

    final manifest = {
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'accountHash': accountHash,
      'includeApiKeys': includeApiKeys,
      'counts': {
        'conversations': conversations.length,
        'messages': messages.length,
        'assistants': assistants.length,
        'favorites': favorites.length,
        'projects': projects.length,
        'knowledgeDocs': knowledgeDocs.length,
        'knowledgeChunks': knowledgeChunks.length,
        'projectKnowledge': projectKnowledge.length,
        'storyTemplates': storyTemplates.length,
        'avatarAssets': avatarFiles.length,
        'fileAssets': attachmentFiles.length,
        'generatedImageAssets': generatedImageFiles.length,
      },
    };

    final archive = Archive()
      ..addFile(_jsonFile(_kManifest, manifest))
      ..addFile(_jsonFile(_kConversations, conversations))
      ..addFile(_jsonFile(_kMessages, messages))
      ..addFile(_jsonFile(_kAssistants, assistants))
      ..addFile(_jsonFile(_kFavorites, favorites))
      ..addFile(_jsonFile(_kProjects, projects))
      ..addFile(_jsonFile(_kKnowledgeDocs, knowledgeDocs))
      ..addFile(_jsonFile(_kKnowledgeChunks, knowledgeChunks))
      ..addFile(_jsonFile(_kProjectKnowledge, projectKnowledge))
      ..addFile(_jsonFile(_kStoryTemplates, storyTemplates))
      ..addFile(_jsonFile(_kSettings, exportedSettings.toJson()));
    for (final entry in avatarFiles.entries) {
      archive.addFile(
          ArchiveFile.bytes('$_kAvatarPrefix${entry.key}', entry.value));
    }
    for (final entry in attachmentFiles.entries) {
      archive
          .addFile(ArchiveFile.bytes('$_kFilePrefix${entry.key}', entry.value));
    }
    for (final entry in generatedImageFiles.entries) {
      archive.addFile(ArchiveFile.bytes(
          '$_kGeneratedImagePrefix${entry.key}', entry.value));
    }
    AILogger.log('backup export: ${manifest['counts']}');
    return ZipEncoder().encodeBytes(archive);
  }

  // ---------------------------------------------------------------- 导入

  /// 导入前预览：读取数量、账号、资源与设置状态，但不修改当前数据库。
  Future<BackupPreview> previewArchive(
    List<int> zipBytes, {
    required String accountHash,
  }) async {
    final archive = _decodeArchive(zipBytes);
    final manifest = _readManifest(archive);
    final version = manifest['formatVersion'] as int? ?? 0;
    if (version > formatVersion) {
      throw FormatException('备份版本过新（v$version），请先升级 App 再导入');
    }

    final warnings = <String>[];
    final backupAccount = manifest['accountHash'] as String? ?? '';
    if (backupAccount.isNotEmpty && backupAccount != accountHash) {
      warnings.add('备份来自其他账号，导入会写入当前账号');
    }

    final counts = (manifest['counts'] as Map?)?.cast<String, dynamic>();
    final conversations = _readRows(archive, _kConversations);
    final messages = _readRows(archive, _kMessages);
    final assistants = _readRows(archive, _kAssistants);
    final favorites = _readRows(archive, _kFavorites);
    final projects = _readRows(archive, _kProjects);
    final knowledgeDocs = _readRows(archive, _kKnowledgeDocs);
    final knowledgeChunks = _readRows(archive, _kKnowledgeChunks);
    final projectKnowledge = _readRows(archive, _kProjectKnowledge);
    final storyTemplates = _readRows(archive, _kStoryTemplates);
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
      }
      return 0;
    }

    final settingsJson = _readJson(archive, _kSettings);
    final conflictSummary = await _previewConflicts(
      conversations: conversations,
      messages: messages,
      assistants: assistants,
      favorites: favorites,
      projects: projects,
      knowledgeDocs: knowledgeDocs,
      knowledgeChunks: knowledgeChunks,
      projectKnowledge: projectKnowledge,
      storyTemplates: storyTemplates,
    );
    return BackupPreview(
      formatVersion: version,
      exportedAt: manifest['exportedAt'] as int? ?? 0,
      accountHash: backupAccount,
      includeApiKeys: manifest['includeApiKeys'] == true,
      conversations: countOf('conversations', _kConversations),
      messages: countOf('messages', _kMessages),
      assistants: countOf('assistants', _kAssistants),
      favorites: countOf('favorites', _kFavorites),
      projects: countOf('projects', _kProjects),
      knowledgeDocs: countOf('knowledgeDocs', _kKnowledgeDocs),
      knowledgeChunks: countOf('knowledgeChunks', _kKnowledgeChunks),
      projectKnowledge: countOf('projectKnowledge', _kProjectKnowledge),
      storyTemplates: countOf('storyTemplates', _kStoryTemplates),
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
      conflictSummary: conflictSummary,
      warnings: warnings,
    );
  }

  /// 校验并恢复一个备份 zip。**覆盖式**：清空四张表后整批写回，
  /// 保留原始 id/cid（assistantId 外键、消息排序都依赖它们）。
  /// 格式不合法 / 版本过新时抛 [FormatException]，不会动现有数据。
  Future<BackupRestoreResult> importArchive(
    List<int> zipBytes, {
    required String accountHash,
    BackupImportMode mode = BackupImportMode.overwriteAll,
  }) async {
    final archive = _decodeArchive(zipBytes);
    final manifest = _readManifest(archive);
    final version = manifest['formatVersion'] as int? ?? 0;
    if (version > formatVersion) {
      throw FormatException('备份版本过新（v$version），请先升级 App 再导入');
    }

    final warnings = <String>[];
    final backupAccount = manifest['accountHash'] as String? ?? '';
    if (backupAccount.isNotEmpty && backupAccount != accountHash) {
      warnings.add('备份来自其他账号，已导入当前账号');
    }

    final conversations = _readRows(archive, _kConversations);
    final messages = _readRows(archive, _kMessages);
    final assistants = _readRows(archive, _kAssistants);
    final favorites = _readRows(archive, _kFavorites);
    final projects = _readRows(archive, _kProjects);
    final knowledgeDocs = _readRows(archive, _kKnowledgeDocs);
    final knowledgeChunks = _readRows(archive, _kKnowledgeChunks);
    final projectKnowledge = _readRows(archive, _kProjectKnowledge);
    final storyTemplates = _readRows(archive, _kStoryTemplates);
    if (mode == BackupImportMode.mergeAppend) {
      return _importMergeAppend(
        archive: archive,
        accountHash: accountHash,
        projects: projects,
        conversations: conversations,
        messages: messages,
        assistants: assistants,
        favorites: favorites,
        knowledgeDocs: knowledgeDocs,
        knowledgeChunks: knowledgeChunks,
        projectKnowledge: projectKnowledge,
        storyTemplates: storyTemplates,
        warnings: warnings,
      );
    }
    if (mode == BackupImportMode.projectConversationsOnly) {
      return _importProjectConversationsOnly(
        archive: archive,
        accountHash: accountHash,
        projects: projects,
        conversations: conversations,
        messages: messages,
        warnings: warnings,
      );
    }
    if (mode == BackupImportMode.assistantsOnly) {
      return _importAssistantsOnly(
        assistants: assistants,
        warnings: warnings,
      );
    }
    if (mode == BackupImportMode.knowledgeBaseOnly) {
      return _importKnowledgeBaseOnly(
        knowledgeDocs: knowledgeDocs,
        knowledgeChunks: knowledgeChunks,
        projectKnowledge: projectKnowledge,
        warnings: warnings,
      );
    }
    await _restoreAttachmentAssets(archive, messages, warnings);
    final generatedImageAssets =
        await _restoreGeneratedImageAssets(archive, replaceExisting: true);

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
    await _restoreAvatarAssets(archive, normalizedConversations, warnings,
        accountHash: accountHash);

    // 单事务覆盖式写入：任何一步失败整体回滚，不会留下半套数据。
    await storage.db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete('tb_project');
      batch.delete('tb_conversation_list');
      batch.delete('tb_messages');
      batch.delete('tb_assistant');
      batch.delete('tb_favorite');
      batch.delete('tb_project_kb');
      batch.delete('tb_story_template');
      batch.delete('tb_kb_chunk');
      batch.delete('tb_kb_doc');
      for (final row in projects) {
        batch.insert('tb_project', row);
      }
      for (final row in assistants) {
        batch.insert('tb_assistant', row);
      }
      for (final row in normalizedConversations) {
        batch.insert('tb_conversation_list', row);
      }
      for (final row in messages) {
        batch.insert('tb_messages', row);
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
      await batch.commit(noResult: true);
    });

    AISettings? settings;
    final settingsJson = _readJson(archive, _kSettings);
    if (settingsJson is Map<String, dynamic>) {
      settings = AISettings.fromJson(settingsJson);
    }

    AILogger.log('backup import: ${conversations.length} conversations'
        ', ${messages.length} messages, ${assistants.length} assistants'
        ', ${favorites.length} favorites, ${projects.length} projects'
        ', ${knowledgeDocs.length} kb docs, ${knowledgeChunks.length} kb chunks'
        ', ${projectKnowledge.length} project kb refs'
        ', ${storyTemplates.length} story templates'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      conversations: conversations.length,
      messages: messages.length,
      assistants: assistants.length,
      favorites: favorites.length,
      projects: projects.length,
      knowledgeDocs: knowledgeDocs.length,
      knowledgeChunks: knowledgeChunks.length,
      projectKnowledge: projectKnowledge.length,
      storyTemplates: storyTemplates.length,
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
    required List<String> warnings,
  }) async {
    await _restoreAttachmentAssets(archive, messages, warnings);
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

    await _restoreAvatarAssets(archive, normalizedConversations, warnings,
        accountHash: accountHash);

    final existingProjectKnowledge =
        await storage.db.query('tb_project_kb', limit: 1);
    if (existingProjectKnowledge.isNotEmpty) {
      warnings.add('项目知识库绑定未随项目/会话模式导入，已清空以避免旧项目引用失效');
    }

    await storage.db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete('tb_project_kb');
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
        batch.insert('tb_messages', row);
      }
      await batch.commit(noResult: true);
    });

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
    required List<Map<String, dynamic>> assistants,
    required List<Map<String, dynamic>> favorites,
    required List<Map<String, dynamic>> knowledgeDocs,
    required List<Map<String, dynamic>> knowledgeChunks,
    required List<Map<String, dynamic>> projectKnowledge,
    required List<Map<String, dynamic>> storyTemplates,
    required List<String> warnings,
  }) async {
    await _restoreAttachmentAssets(archive, messages, warnings);
    final generatedImageAssets =
        await _restoreGeneratedImageAssets(archive, replaceExisting: false);
    await _ensureSchema();
    final hasProjectColumn =
        await _hasColumn(storage.db, 'tb_conversation_list', 'projectId');
    final normalizedConversations = conversations
        .map((c) =>
            _normalizeConversationRow(c, hasProjectIdColumn: hasProjectColumn))
        .toList();
    await _restoreAvatarAssets(archive, normalizedConversations, warnings,
        accountHash: accountHash);

    final assistantIdMap = <int, int>{};
    final projectIdMap = <int, int>{};
    final cidMap = <int, int>{};
    final docIdMap = <int, int>{};
    var skippedMessages = 0;
    var skippedChunks = 0;
    var skippedProjectKnowledge = 0;
    var fixedConversationAssistants = 0;
    var fixedConversationProjects = 0;
    var fixedProjectAssistants = 0;
    var remappedCids = 0;
    var insertedProjectKnowledge = 0;

    await storage.db.transaction((txn) async {
      for (final row in assistants) {
        final oldId = _intValue(row['id']);
        final newId = await txn.insert('tb_assistant', _withoutId(row));
        if (oldId != null) assistantIdMap[oldId] = newId;
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

      final usedCids = {
        for (final row in await txn.query('tb_conversation_list'))
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

      for (final row in messages) {
        final oldCid = _intValue(row['cid']);
        final newCid = oldCid == null ? null : cidMap[oldCid];
        if (newCid == null) {
          skippedMessages++;
          continue;
        }
        await txn.insert(
          'tb_messages',
          _withoutId(row)..['cid'] = newCid,
        );
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
        await txn.insert('tb_story_template', _withoutId(row));
      }
    });

    if (remappedCids > 0) {
      warnings.add('$remappedCids 个会话 cid 与本地冲突，已改用新 cid 合并导入');
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

    AILogger.log('backup import merge append: '
        '${projects.length} projects, ${conversations.length} conversations'
        ', ${messages.length - skippedMessages} messages'
        ', ${assistants.length} assistants, ${favorites.length} favorites'
        ', ${knowledgeDocs.length} kb docs'
        ', ${knowledgeChunks.length - skippedChunks} kb chunks'
        ', $insertedProjectKnowledge project kb refs'
        ', ${storyTemplates.length} story templates'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      conversations: conversations.length,
      messages: messages.length - skippedMessages,
      assistants: assistants.length,
      favorites: favorites.length,
      projects: projects.length,
      knowledgeDocs: knowledgeDocs.length,
      knowledgeChunks: knowledgeChunks.length - skippedChunks,
      projectKnowledge: insertedProjectKnowledge,
      storyTemplates: storyTemplates.length,
      generatedImageAssets: generatedImageAssets,
      warnings: warnings,
    );
  }

  Future<BackupRestoreResult> _importAssistantsOnly({
    required List<Map<String, dynamic>> assistants,
    required List<String> warnings,
  }) async {
    await _ensureSchema();
    final assistantIds = {
      for (final a in assistants)
        if (a['id'] != null) a['id'],
    };

    await storage.db.transaction((txn) async {
      await txn.delete('tb_assistant');
      for (final row in assistants) {
        await txn.insert('tb_assistant', row);
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
    });

    AILogger.log(
        'backup import assistants only: ${assistants.length} assistants'
        ', warnings: $warnings');
    restoreTick.value++;
    return BackupRestoreResult(
      assistants: assistants.length,
      warnings: warnings,
    );
  }

  Future<BackupRestoreResult> _importKnowledgeBaseOnly({
    required List<Map<String, dynamic>> knowledgeDocs,
    required List<Map<String, dynamic>> knowledgeChunks,
    required List<Map<String, dynamic>> projectKnowledge,
    required List<String> warnings,
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

    await storage.db.transaction((txn) async {
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
    });

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

  static Archive _decodeArchive(List<int> zipBytes) {
    try {
      return ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw const FormatException('不是有效的备份文件（zip 解析失败）');
    }
  }

  static Map<String, dynamic> _readManifest(Archive archive) {
    final manifest = _readJson(archive, _kManifest);
    if (manifest is Map<String, dynamic>) return manifest;
    if (manifest is Map) return manifest.cast<String, dynamic>();
    throw const FormatException('不是有效的备份文件（缺少 manifest.json）');
  }

  /// 通过各 DAO 的静态工厂确保四张表存在且 schema 最新（含历史 ALTER）。
  Future<void> _ensureSchema() async {
    await DbMigration.run(storage.db);
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await AssistantDao.create(storage);
    await FavoriteDao.create(storage);
    await ProjectDao.create(storage);
    await KnowledgeDao.create(storage);
    await StoryTemplateDao.create(storage);
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

  static Map<String, dynamic> _withoutId(Map<String, dynamic> row) {
    final r = Map<String, dynamic>.from(row);
    r.remove('id');
    return r;
  }

  static int? _intValue(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static ArchiveFile _jsonFile(String name, Object content) =>
      ArchiveFile.bytes(name, utf8.encode(jsonEncode(content)));

  Future<BackupConflictSummary> _previewConflicts({
    required List<Map<String, dynamic>> conversations,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> assistants,
    required List<Map<String, dynamic>> favorites,
    required List<Map<String, dynamic>> projects,
    required List<Map<String, dynamic>> knowledgeDocs,
    required List<Map<String, dynamic>> knowledgeChunks,
    required List<Map<String, dynamic>> projectKnowledge,
    required List<Map<String, dynamic>> storyTemplates,
  }) async {
    final specs = [
      _ConflictSpec('tb_conversation_list', 'cid', conversations),
      _ConflictSpec('tb_messages', 'id', messages),
      _ConflictSpec('tb_assistant', 'id', assistants),
      _ConflictSpec('tb_favorite', 'id', favorites),
      _ConflictSpec('tb_project', 'id', projects),
      _ConflictSpec('tb_kb_doc', 'id', knowledgeDocs),
      _ConflictSpec('tb_kb_chunk', 'id', knowledgeChunks),
      _ConflictSpec('tb_project_kb', 'projectId', projectKnowledge,
          secondColumn: 'docId'),
      _ConflictSpec('tb_story_template', 'id', storyTemplates),
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

  static Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.query('sqlite_master',
        columns: ['name'],
        where: 'type = ? and name = ?',
        whereArgs: ['table', table],
        limit: 1);
    return rows.isNotEmpty;
  }

  static Future<Directory> _generatedImageAlbumDir() async {
    final baseDir = await (debugGeneratedImageDirectoryResolver ??
        getApplicationDocumentsDirectory)();
    return Directory(
        '${baseDir.path}/${GeneratedImageSaveService.albumDirectoryName}');
  }

  static Future<Map<String, List<int>>> _collectGeneratedImageFiles() async {
    final files = <String, List<int>>{};
    try {
      final dir = await _generatedImageAlbumDir();
      if (!await dir.exists()) return files;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (!_isImageFileName(name)) continue;
        files[name] = await entity.readAsBytes();
      }
    } catch (_) {
      // 应用内相册资源缺失不阻塞备份。
    }
    return files;
  }

  static Future<Map<String, List<int>>> _collectAvatarFiles(
      List<Map<String, Object?>> conversations) async {
    final files = <String, List<int>>{};
    for (final row in conversations) {
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
          final file = File(path);
          if (!await file.exists()) continue;
          files[_attachmentAssetName(block.file)] = await file.readAsBytes();
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
  }) async {
    final avatarAssets = {
      for (final file in archive.files)
        if (file.isFile && file.name.startsWith(_kAvatarPrefix))
          _basename(file.name): file,
    };
    if (avatarAssets.isEmpty) {
      var dropped = 0;
      for (final row in conversations) {
        if (row['avatarType'] == AvatarAssetService.imageType &&
            AvatarAssetService.isManagedPath(row['avatarValue']?.toString())) {
          row['avatarType'] = null;
          row['avatarValue'] = null;
          dropped++;
        }
      }
      if (dropped > 0) {
        warnings.add('$dropped 个会话头像资源不在备份中，已恢复默认头像');
      }
      return;
    }

    final dir = await AvatarAssetService.avatarDir(accountHash: accountHash);
    var dropped = 0;
    for (final row in conversations) {
      if (row['avatarType'] != AvatarAssetService.imageType) continue;
      final oldPath = row['avatarValue']?.toString();
      final asset = avatarAssets[_basename(oldPath ?? '')];
      if (asset == null) {
        row['avatarType'] = null;
        row['avatarValue'] = null;
        dropped++;
        continue;
      }
      final target = File('${dir.path}/${_basename(asset.name)}');
      await target.writeAsBytes(asset.content as List<int>, flush: true);
      row['avatarValue'] = target.path;
    }
    if (dropped > 0) {
      warnings.add('$dropped 个会话头像资源缺失，已恢复默认头像');
    }
  }

  static Future<void> _restoreAttachmentAssets(
    Archive archive,
    List<Map<String, dynamic>> messages,
    List<String> warnings,
  ) async {
    final fileAssets = {
      for (final file in archive.files)
        if (file.isFile && file.name.startsWith(_kFilePrefix))
          _basename(file.name): file,
    };
    if (fileAssets.isEmpty) return;

    final dir = Directory('${Directory.systemTemp.path}/chatai_restored_files');
    if (!dir.existsSync()) await dir.create(recursive: true);
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
        if (asset == null) {
          missing++;
          restored.add(block);
          continue;
        }
        final target = File('${dir.path}/$assetName');
        await target.writeAsBytes(asset.content as List<int>, flush: true);
        restored.add(FileBlock(
          id: block.id,
          messageId: block.messageId,
          createdAt: block.createdAt,
          updatedAt: block.updatedAt,
          status: block.status,
          modelId: block.modelId,
          file: FileMetadata(
            name: block.file.name,
            path: target.path,
            mime: block.file.mime,
            size: block.file.size,
            extractedText: block.file.extractedText,
          ),
        ));
        changed = true;
      }
      if (changed) row['blocks'] = MessageBlock.encodeList(restored);
    }
    if (missing > 0) {
      warnings.add('$missing 个附件原始文件不在备份中，仅保留附件元数据');
    }
  }

  static Future<int> _restoreGeneratedImageAssets(
    Archive archive, {
    required bool replaceExisting,
  }) async {
    final imageAssets = [
      for (final file in archive.files)
        if (file.isFile && file.name.startsWith(_kGeneratedImagePrefix)) file,
    ];
    if (imageAssets.isEmpty) return 0;

    final dir = await _generatedImageAlbumDir();
    if (replaceExisting && await dir.exists()) {
      await dir.delete(recursive: true);
    }
    if (!await dir.exists()) await dir.create(recursive: true);

    var restored = 0;
    for (final asset in imageAssets) {
      final name = _safeImageAssetName(_basename(asset.name));
      if (name == null) continue;
      final target = replaceExisting
          ? File('${dir.path}/$name')
          : await _uniqueFile(dir, name);
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

  /// 读一个「行列表」文件；行是 sqflite 的 Map，缺失时返回空列表。
  static List<Map<String, dynamic>> _readRows(Archive archive, String name) {
    final raw = _readJson(archive, name);
    if (raw is! List) return [];
    return [
      for (final row in raw)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
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
