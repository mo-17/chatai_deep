import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/foundation.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
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
    this.settings,
    this.warnings = const [],
  });
}

/// 备份/恢复服务（阶段八）。对应源项目 `src/services/BackupService.ts`：
/// 把「会话 + 消息（含 blocks）+ 助手 + 收藏 + AI 设置」打成 zip 导出，
/// 导入时校验 manifest 后**覆盖式恢复**（先清表再写入，保留原始 id）。
///
/// 纯 Dart（archive 包无平台通道），文件读写与分享交给 UI 层，
/// 因此可以用 sqflite_common_ffi 内存库做 round-trip 单测。
class BackupService {
  /// 备份格式版本。导入时大于本值则拒绝（新版本备份导入旧 app）。
  static const int formatVersion = 2;

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
  static const _kAvatarPrefix = 'assets/avatars/';

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
    final avatarFiles = await _collectAvatarFiles(conversations);

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
        'avatarAssets': avatarFiles.length,
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
      ..addFile(_jsonFile(_kSettings, exportedSettings.toJson()));
    for (final entry in avatarFiles.entries) {
      archive.addFile(
          ArchiveFile.bytes('$_kAvatarPrefix${entry.key}', entry.value));
    }
    AILogger.log('backup export: ${manifest['counts']}');
    return ZipEncoder().encodeBytes(archive);
  }

  // ---------------------------------------------------------------- 导入

  /// 校验并恢复一个备份 zip。**覆盖式**：清空四张表后整批写回，
  /// 保留原始 id/cid（assistantId 外键、消息排序都依赖它们）。
  /// 格式不合法 / 版本过新时抛 [FormatException]，不会动现有数据。
  Future<BackupRestoreResult> importArchive(
    List<int> zipBytes, {
    required String accountHash,
  }) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw const FormatException('不是有效的备份文件（zip 解析失败）');
    }

    final manifest = _readJson(archive, _kManifest) as Map<String, dynamic>?;
    if (manifest == null) {
      throw const FormatException('不是有效的备份文件（缺少 manifest.json）');
    }
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
      settings: settings,
      warnings: warnings,
    );
  }

  // ---------------------------------------------------------------- 内部

  /// 通过各 DAO 的静态工厂确保四张表存在且 schema 最新（含历史 ALTER）。
  Future<void> _ensureSchema() async {
    await DbMigration.run(storage.db);
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await AssistantDao.create(storage);
    await FavoriteDao.create(storage);
    await ProjectDao.create(storage);
    await KnowledgeDao.create(storage);
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

  static ArchiveFile _jsonFile(String name, Object content) =>
      ArchiveFile.bytes(name, utf8.encode(jsonEncode(content)));

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

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
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
