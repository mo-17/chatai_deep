import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

/// 集中式数据库 schema 迁移入口。
///
/// DAO 仍保留 guarded ALTER 作为自愈兜底；这里负责把跨模块、跨版本的
/// schema 演进收敛到一个可审计位置，避免长期只散落在各 DAO 构造函数里。
class DbMigration {
  static Future<void> run(Database db) async {
    await _ensureMessages(db);
    await _ensureConversations(db);
    await _ensureProjects(db);
    await _ensureKnowledge(db);
    await _ensureAssistants(db);
    await _ensureFavorites(db);
    await _ensureUsage(db);
    await _ensureToolAudit(db);
    // 不提前创建故事表；已有业务表打开时也可重复补齐独立后端列。
    final storyTables = await db.rawQuery(
      "select name from sqlite_master where type='table' and name in (?, ?)",
      ['tb_story_room', 'tb_story_participant'],
    );
    for (final row in storyTables) {
      await SchemaGuard.ensureColumns(
        db,
        table: row['name'] as String,
        columns: const {'backendSelection': 'text'},
      );
    }
  }

  static Future<void> migrateLegacyMessageTables(Database db) async {
    final tables = await db.rawQuery(
        "select name from sqlite_master where type='table' and name like 'tb\\_%' escape '\\'");
    final knownTables = {
      'tb_conversation_list',
      'tb_favorite',
      'tb_messages',
      'tb_assistant',
      'tb_project',
      'tb_kb_doc',
      'tb_kb_chunk',
      'tb_project_kb',
      'tb_tool_audit',
    };
    await _ensureMessages(db);
    for (final row in tables) {
      final name = row['name'] as String;
      if (knownTables.contains(name)) continue;
      final cid = int.tryParse(name.substring(3));
      if (cid == null) continue;
      try {
        await db.rawInsert(
            'insert into tb_messages (cid, content, createdAt, ownerName, ownerType, avatar) '
            'select $cid, content, createdAt, ownerName, ownerType, avatar from "$name"');
        await db.execute('drop table if exists "$name"');
        debugPrint('migrated table $name -> tb_messages');
      } catch (e) {
        debugPrint('migrate $name failed: $e');
      }
    }
  }

  static Future<void> _ensureMessages(Database db) async {
    await db.execute(
        'create table if not exists tb_messages (id integer primary key autoincrement'
        ', cid integer not null, content text, createdAt integer'
        ', ownerName text, ownerType text, avatar text, images text, blocks text)');
    await SchemaGuard.ensureColumns(
      db,
      table: 'tb_messages',
      columns: const {
        'images': 'text',
        'blocks': 'text',
      },
    );
    await db.execute(
        'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
  }

  static Future<void> _ensureConversations(Database db) async {
    await db.execute(
        'create table if not exists tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer'
        ', assistantId integer, projectId integer'
        ', avatarType text, avatarValue text'
        ', modelProviderId text, modelId text, backendSelection text, webSearchEnabled integer'
        ', toolIds text, speechInputEnabled integer, readAloudEnabled integer'
        ', voiceLocale text, voiceRate real, voiceStyle text'
        ', readAloudTriggerMode text'
        ', roleScene text, roleRelationship text, roleToneNote text);');
    await SchemaGuard.ensureColumns(
      db,
      table: 'tb_conversation_list',
      columns: const {
        'assistantId': 'integer',
        'projectId': 'integer',
        'avatarType': 'text',
        'avatarValue': 'text',
        'modelProviderId': 'text',
        'modelId': 'text',
        'backendSelection': 'text',
        'webSearchEnabled': 'integer',
        'toolIds': 'text',
        'speechInputEnabled': 'integer',
        'readAloudEnabled': 'integer',
        'voiceLocale': 'text',
        'voiceRate': 'real',
        'voiceStyle': 'text',
        'readAloudTriggerMode': 'text',
        'roleScene': 'text',
        'roleRelationship': 'text',
        'roleToneNote': 'text',
      },
    );
    await db.execute(
        'create unique index if not exists tb_conversation_list_cid_idx on tb_conversation_list (cid);');
    await db.execute(
        'create index if not exists tb_conversation_list_stick_update_idx on tb_conversation_list(stickTime, updateAt desc);');
    await db.execute(
        'create index if not exists tb_conversation_list_project_update_idx on tb_conversation_list(projectId, updateAt desc);');
  }

  static Future<void> _ensureProjects(Database db) async {
    await db.execute(
        'create table if not exists tb_project (id integer primary key autoincrement'
        ', name text not null, icon text, color integer, sortOrder integer'
        ', defaultProviderId text, defaultModelId text, backendSelection text, defaultAssistantId integer'
        ', defaultUseWebSearch integer, defaultToolIds text'
        ', createdAt integer, updatedAt integer);');
    await SchemaGuard.ensureColumns(
      db,
      table: 'tb_project',
      columns: const {
        'icon': 'text',
        'defaultProviderId': 'text',
        'defaultModelId': 'text',
        'backendSelection': 'text',
        'defaultAssistantId': 'integer',
        'defaultUseWebSearch': 'integer',
        'defaultToolIds': 'text',
      },
    );
    await db.execute(
        'create index if not exists tb_project_sort_idx on tb_project(sortOrder, updatedAt desc);');
  }

  static Future<void> _ensureKnowledge(Database db) async {
    await db.execute(
        'create table if not exists tb_kb_doc (id integer primary key autoincrement'
        ', title text, chunkCount integer, createdAt integer);');
    await db.execute(
        'create table if not exists tb_kb_chunk (id integer primary key autoincrement'
        ', docId integer, seq integer, content text);');
    await db.execute(
        'create index if not exists tb_kb_chunk_doc_idx on tb_kb_chunk(docId);');
    await db.execute(
        'create table if not exists tb_project_kb (projectId integer not null'
        ', docId integer not null, primary key(projectId, docId));');
    await db.execute(
        'create index if not exists tb_project_kb_doc_idx on tb_project_kb(docId);');
  }

  static Future<void> _ensureAssistants(Database db) async {
    await db.execute(
        'create table if not exists tb_assistant (id integer primary key autoincrement'
        ', name text, emoji text, prompt text, providerId text, model text, backendSelection text, useTools integer'
        ', tools text, createdAt integer, updatedAt integer);');
    await SchemaGuard.ensureColumns(
      db,
      table: 'tb_assistant',
      columns: const {
        'tools': 'text',
        'providerId': 'text',
        'backendSelection': 'text',
      },
    );
  }

  static Future<void> _ensureFavorites(Database db) async {
    await db.execute(
        'create table if not exists tb_favorite (id integer primary key autoincrement'
        ', ownerName text, content text, createdAt integer);');
  }

  static Future<void> _ensureUsage(Database db) async {
    await db.execute(
        'create table if not exists tb_usage (id integer primary key autoincrement'
        ', modelId text not null, providerId text, projectId integer, cid integer'
        ', promptTokens integer not null, completionTokens integer not null'
        ', cost real not null, estimated integer not null, createdAt integer not null);');
    await SchemaGuard.ensureColumns(
      db,
      table: 'tb_usage',
      columns: const {
        'providerId': 'text',
        'projectId': 'integer',
        'estimated': 'integer',
      },
    );
    await db.execute(
        'create index if not exists tb_usage_model_idx on tb_usage(modelId)');
    await db.execute(
        'create index if not exists tb_usage_cid_idx on tb_usage(cid)');
    await db.execute(
        'create index if not exists tb_usage_project_idx on tb_usage(projectId)');
    await db.execute(
        'create index if not exists tb_usage_created_idx on tb_usage(createdAt)');
  }

  static Future<void> _ensureToolAudit(Database db) async {
    await db.execute(
        'create table if not exists tb_tool_audit (id integer primary key autoincrement'
        ', toolName text not null, sourceType text, sourceId text, sourceName text'
        ', trusted integer not null, readOnly integer not null'
        ', approved integer not null, success integer not null, argCount integer not null'
        ', argsPreview text, resultPreview text, error text, createdAt integer not null);');
    await db.execute(
        'create index if not exists tb_tool_audit_created_idx on tb_tool_audit(createdAt desc);');
    await db.execute(
        'create index if not exists tb_tool_audit_tool_idx on tb_tool_audit(toolName);');
  }
}
