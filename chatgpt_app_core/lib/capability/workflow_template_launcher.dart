import 'dart:async';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';

class WorkflowTemplateLauncher {
  static Future<void> start(
      BuildContext context, WorkflowTemplate template) async {
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final assistant = await ensureAssistantForTemplate(storage, template);
    final project = await ensureProjectForTemplate(
      storage,
      template,
      assistant: assistant,
    );
    await bindKnowledgeForTemplate(storage, template, project);
    final conversation = conversationForTemplate(
      template,
      assistant,
      projectId: project?.id,
    );
    if (!context.mounted) return;
    NavigatorUtil.push(
      context,
      ConversationPage(
        conversationModel: conversation,
        initialPrompt: initialPromptForTemplate(template),
        conversationUpdate: (model) => _persistConversation(storage, model),
      ),
    ).then((_) => unawaited(_persistConversation(storage, conversation)));
  }

  static Future<AssistantModel?> ensureAssistantForTemplate(
      HiDBManager storage, WorkflowTemplate template) async {
    final name = template.assistantName?.trim();
    if (name == null || name.isEmpty) return null;

    final dao = await AssistantDao.create(storage);
    final prompt = template.systemPrompt.trim();
    final toolIds = template.toolIds;
    final assistants = await dao.getAssistants();
    for (final assistant in assistants) {
      final sameName = assistant.name == name;
      final samePrompt = assistant.prompt.trim() == prompt;
      final sameTools = _sameStringList(assistant.toolIds ?? const [], toolIds);
      if (sameName && samePrompt && sameTools) {
        final enriched = _enrichAssistantFromTemplate(assistant, template);
        if (enriched) await dao.saveAssistant(assistant);
        return assistant;
      }
    }

    final openingMessage = _openingMessageFromTemplate(template);
    final exampleDialogs = _exampleDialogsFromTemplate(template);
    final assistant = AssistantModel(
      name: name,
      emoji: '🧩',
      prompt: prompt,
      openingMessage: openingMessage,
      exampleDialogs: exampleDialogs,
      providerId: template.providerCode ?? '',
      model: template.modelId ?? '',
      useTools: toolIds.isNotEmpty,
      toolIds: toolIds.isEmpty ? null : [...toolIds],
    );
    await dao.saveAssistant(assistant);
    return assistant;
  }

  static ConversationModel conversationForTemplate(
      WorkflowTemplate template, AssistantModel? assistant,
      {int? now, String? icon, int? projectId}) {
    final cid = now ?? DateTime.now().millisecondsSinceEpoch;
    return ConversationModel(
      cid: cid,
      icon: icon ?? AiCatalogDao.avatarUrl(),
      assistantId: assistant?.id,
      projectId: projectId,
      modelProviderId: template.providerCode,
      modelId: template.modelId,
      webSearchEnabled: template.webSearch ? true : null,
      toolIds: template.toolIds.isEmpty ? null : [...template.toolIds],
    );
  }

  static Future<ProjectModel?> ensureProjectForTemplate(
    HiDBManager storage,
    WorkflowTemplate template, {
    AssistantModel? assistant,
  }) async {
    final name = template.projectName?.trim();
    if (name == null || name.isEmpty) return null;
    final dao = await ProjectDao.create(storage);
    final projects = await dao.getProjects();
    ProjectModel? project;
    for (final item in projects) {
      if (item.name.trim() == name) {
        project = item;
        break;
      }
    }
    project ??= ProjectModel(name: name, sortOrder: projects.length);

    var changed = project.id == null;
    if ((project.defaultProviderId == null ||
            project.defaultProviderId!.trim().isEmpty) &&
        template.providerCode != null &&
        template.providerCode!.trim().isNotEmpty) {
      project.defaultProviderId = template.providerCode;
      changed = true;
    }
    if ((project.defaultModelId == null ||
            project.defaultModelId!.trim().isEmpty) &&
        template.modelId != null &&
        template.modelId!.trim().isNotEmpty) {
      project.defaultModelId = template.modelId;
      changed = true;
    }
    if (project.defaultAssistantId == null && assistant?.id != null) {
      project.defaultAssistantId = assistant!.id;
      changed = true;
    }
    if (project.defaultUseWebSearch == null && template.webSearch) {
      project.defaultUseWebSearch = true;
      changed = true;
    }
    if (project.defaultToolIds == null && template.toolIds.isNotEmpty) {
      project.defaultToolIds = [...template.toolIds];
      changed = true;
    }
    if (changed) await dao.saveProject(project);
    return project;
  }

  static Future<List<int>> bindKnowledgeForTemplate(
    HiDBManager storage,
    WorkflowTemplate template,
    ProjectModel? project,
  ) async {
    if (project?.id == null || template.knowledgeDocTitles.isEmpty) {
      return const [];
    }
    final wanted = template.knowledgeDocTitles
        .map((title) => title.trim())
        .where((title) => title.isNotEmpty)
        .toSet();
    if (wanted.isEmpty) return const [];

    final dao = await KnowledgeDao.create(storage);
    final docs = await dao.getDocuments();
    final matched = [
      for (final doc in docs)
        if (doc.id != null && wanted.contains(doc.title.trim())) doc.id!,
    ];
    if (matched.isEmpty) return const [];

    final existing = await dao.getProjectDocIds(project!.id!);
    final next = {...existing, ...matched}.toList();
    await dao.setProjectDocIds(project.id!, next);
    return next;
  }

  static String initialPromptForTemplate(WorkflowTemplate template) {
    final sections = <String>[];
    final prompt = template.firstUserPrompt.trim();
    if (prompt.isNotEmpty) sections.add(prompt);

    final hints = <String>[];
    final projectName = template.projectName?.trim();
    if (projectName != null && projectName.isNotEmpty) {
      hints.add('项目：$projectName');
    }
    if (template.knowledgeDocTitles.isNotEmpty) {
      hints.add('优先检索知识库：${template.knowledgeDocTitles.join('、')}');
    }
    if (template.webSearch) {
      hints.add('需要时请结合联网搜索核对最新信息。');
    }
    if (template.toolIds.isNotEmpty) {
      hints.add('可用工具：${template.toolIds.join('、')}');
    }
    if (hints.isNotEmpty) {
      sections.add('模板上下文：\n${hints.map((hint) => '- $hint').join('\n')}');
    }
    return sections.join('\n\n');
  }

  static Future<void> _persistConversation(
      HiDBManager storage, ConversationModel model) async {
    if (model.title == null) return;
    final messageDao = await MessageDao.create(storage, cid: model.cid);
    model.messageCount = await messageDao.getMessageCount();
    final conversationDao = await ConversationListDao.create(storage);
    await conversationDao.saveConversation(model);
    AppEvents.notifyConversationsChanged();
  }

  static bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _enrichAssistantFromTemplate(
    AssistantModel assistant,
    WorkflowTemplate template,
  ) {
    var changed = false;
    final openingMessage = _openingMessageFromTemplate(template);
    if (assistant.openingMessage.trim().isEmpty &&
        openingMessage.trim().isNotEmpty) {
      assistant.openingMessage = openingMessage;
      changed = true;
    }
    final exampleDialogs = _exampleDialogsFromTemplate(template);
    if (assistant.exampleDialogs.trim().isEmpty &&
        exampleDialogs.trim().isNotEmpty) {
      assistant.exampleDialogs = exampleDialogs;
      changed = true;
    }
    return changed;
  }

  static String _openingMessageFromTemplate(WorkflowTemplate template) {
    final lines = template.firstUserPrompt.replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('角色开场白：')) continue;
      final inline = line.substring('角色开场白：'.length).trim();
      if (inline.isNotEmpty) return inline;
      final collected = <String>[];
      for (final next in lines.skip(i + 1)) {
        final text = next.trim();
        if (text.isEmpty || text == '可选备选开场白：') break;
        collected.add(text);
      }
      return collected.join('\n').trim();
    }
    return '';
  }

  static String _exampleDialogsFromTemplate(WorkflowTemplate template) {
    final greetings = _alternateGreetingsFromTemplate(template);
    if (greetings.isEmpty) return '';
    return ['[备选开场白]', ...greetings].join('\n');
  }

  static List<String> _alternateGreetingsFromTemplate(
      WorkflowTemplate template) {
    final lines = template.firstUserPrompt.replaceAll('\r\n', '\n').split('\n');
    final greetings = <String>[];
    var collecting = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line == '可选备选开场白：') {
        collecting = true;
        continue;
      }
      if (!collecting) continue;
      if (line.isEmpty) break;
      greetings.add(line.replaceFirst(RegExp(r'^[-*]\s*'), '').trim());
    }
    return greetings.where((item) => item.isNotEmpty).toList(growable: false);
  }
}
