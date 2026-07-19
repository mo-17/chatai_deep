import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_conversation_factory.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/application/translation_work_estimator.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/skill_script_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_market_page.dart';
import 'package:chatgpt_app_core/pages/assistant_memory_page.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/translation_task_log_dialog.dart';
import 'package:chatgpt_app_core/widget/translation_settings_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

final _roleCardImportCoordinator = _RoleCardImportCoordinator();
final _tavernTranslationCoordinator =
    StoryTemplateTranslationCoordinator.instance;
const _translationWorkEstimator = TranslationWorkEstimator();

Color _mutedTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color _statusColor(BuildContext context, AppStatusKind kind) =>
    AppStatusPalette.of(context, kind).foreground;

Future<StoryTemplateModel> _saveTavernRoomTemplate(
  HiDBManager dbManager,
  List<AssistantRoleCardImportResult> results, {
  required String title,
  required String sourceTitle,
  required bool translated,
  String? initialOpening,
}) async {
  final templateDao = await StoryTemplateDao.create(dbManager);
  final template = StoryRoomTemplatePayload(
    results: results,
    initialOpening: initialOpening?.trim() ?? '',
  ).toTemplate(
    title: title,
    sourceTitle: sourceTitle,
    translated: translated,
  );
  await templateDao.saveTemplate(template);
  return template;
}

///助手管理页（阶段七）：列表 + 新建 / 编辑 / 删除。
///对应源项目 `src/screens/assistant/AssistantScreen.tsx` 的精简版。
class AssistantListPage extends StatefulWidget {
  const AssistantListPage({super.key});

  @override
  State<AssistantListPage> createState() => _AssistantListPageState();
}

class _AssistantListPageState extends State<AssistantListPage> {
  AssistantDao? _dao;
  List<AssistantModel> _assistants = [];
  int _lastImportCompletedTick = 0;
  final Set<int> _observedCompletedTavernTaskIds = <int>{};
  bool _loading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _roleCardImportCoordinator.addListener(_handleRoleCardImportChanged);
    _tavernTranslationCoordinator.addListener(_handleTavernImportChanged);
    _doInit();
  }

  @override
  void dispose() {
    _roleCardImportCoordinator.removeListener(_handleRoleCardImportChanged);
    _tavernTranslationCoordinator.removeListener(_handleTavernImportChanged);
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
  }

  void _doInit() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      _dao = await AssistantDao.create(dbManager);
      await _tavernTranslationCoordinator.initialize(
        dbManager,
        accountHash: HiDBManager.getAccountHash(),
      );
      if (!mounted) return;
      await _loadData();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadData() async {
    final list = await _dao!.getAssistants();
    setState(() => _assistants = list);
  }

  void _handleRoleCardImportChanged() {
    if (!mounted) return;
    setState(() {});
    final completedTick = _roleCardImportCoordinator.completedTick;
    if (completedTick != _lastImportCompletedTick && _dao != null) {
      _lastImportCompletedTick = completedTick;
      unawaited(_loadData());
    }
  }

  void _handleTavernImportChanged() {
    if (!mounted) return;
    setState(() {});
    final newCompleted = _tavernTranslationCoordinator.tasks
        .where((task) =>
            task.taskKind ==
                StoryTemplateTranslationTaskKind.tavernRoomImport &&
            (task.status == StoryTemplateTranslationTaskStatus.completed ||
                task.status ==
                    StoryTemplateTranslationTaskStatus.completedWithWarnings) &&
            task.id != null)
        .map((task) => task.id!)
        .where(_observedCompletedTavernTaskIds.add)
        .isNotEmpty;
    if (newCompleted) {
      HiDialog.showSnackBar(context, '酒馆房间翻译导入已完成');
    }
  }

  List<StoryTemplateTranslationTaskModel> get _tavernTranslationTasks =>
      _tavernTranslationCoordinator.tasks
          .where((task) =>
              task.taskKind ==
              StoryTemplateTranslationTaskKind.tavernRoomImport)
          .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('助手管理'),
        centerTitle: true,
        actions: [
          // file_picker 暂无鸿蒙实现，OHOS 隐藏文件导入入口。
          if (Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: '导入角色卡（.json/.png/.zip）',
              onPressed: _loading ? null : _importRoleCardFile,
            ),
          if (Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: '导入技能（.zip，含 SKILL.md）',
              onPressed: _loading ? null : _importSkillZip,
            ),
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            tooltip: '助手市场',
            onPressed: _loading ? null : _openMarket,
          ),
        ],
      ),
      body: _body,
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : () => _edit(null),
        tooltip: '新建助手',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _body {
    if (_loading &&
        _roleCardImportCoordinator.jobs.isEmpty &&
        _tavernTranslationTasks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null &&
        _roleCardImportCoordinator.jobs.isEmpty &&
        _tavernTranslationTasks.isEmpty) {
      return AppVisualEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '助手列表加载失败',
        message: _loadError.toString(),
        action: FilledButton.icon(
          onPressed: _doInit,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    return _assistants.isEmpty &&
            _roleCardImportCoordinator.jobs.isEmpty &&
            _tavernTranslationTasks.isEmpty
        ? _emptyView
        : _listView;
  }

  Widget get _emptyView => AppVisualEmptyState(
        icon: Icons.smart_toy_outlined,
        title: '还没有助手',
        message: '点右下角新建，或从右上角「助手市场」挑一个。',
        classic: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🤖', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text('还没有助手，点右下角新建，或从右上角「助手市场」挑一个',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget get _listView => ListView.builder(
        padding: AppVisualTheme.of(context).isAnime
            ? const EdgeInsets.fromLTRB(12, 12, 12, 24)
            : EdgeInsets.zero,
        itemCount: _tavernTranslationTasks.length +
            _roleCardImportCoordinator.jobs.length +
            _assistants.length,
        itemBuilder: (context, index) {
          final tavernTasks = _tavernTranslationTasks;
          if (index < tavernTasks.length) {
            final task = tavernTasks[index];
            return _TavernTranslationTaskTile(
              task: task,
              onShowLog: () => _showTavernTranslationLog(task),
              onRetry: task.canRetry
                  ? () => _showTavernTranslationRecovery(task)
                  : null,
              onCancel: _canCancelTavernTranslationTask(task)
                  ? () => _tavernTranslationCoordinator.cancel(task)
                  : null,
              onDismiss: task.isTerminal
                  ? () => _tavernTranslationCoordinator.dismiss(task)
                  : null,
            );
          }
          index -= tavernTasks.length;
          final importJobs = _roleCardImportCoordinator.jobs;
          if (index < importJobs.length) {
            return _RoleCardImportJobTile(
              job: importJobs[index],
              onShowLog: () => _showRoleCardImportFailureLog(
                importJobs[index],
              ),
              onDismiss: () =>
                  _roleCardImportCoordinator.dismiss(importJobs[index]),
            );
          }
          final assistantIndex = index - importJobs.length;
          final a = _assistants[assistantIndex];
          final tile = ListTile(
            leading: _assistantAvatar(a),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              _subtitleOf(a),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) {
                switch (value) {
                  case 'start_chat':
                    _startConversationWithAssistant(a);
                    break;
                  case 'profile':
                    _openProfilePage(a);
                    break;
                  case 'preview':
                    _previewRoleCard(a);
                    break;
                  case 'memory':
                    _openMemoryPage(a);
                    break;
                  case 'world_book':
                    _openWorldBookPage(a);
                    break;
                  case 'export':
                    _exportRoleCard(a);
                    break;
                  case 'copy_json':
                    _copyRoleCardJson(a);
                    break;
                  case 'export_tavern':
                    _exportTavernRoleCard(a);
                    break;
                  case 'copy_tavern_json':
                    _copyTavernRoleCardJson(a);
                    break;
                  case 'export_tavern_png':
                    _exportTavernRoleCardPng(a);
                    break;
                  case 'export_charx':
                    _exportCharxRoleCard(a);
                    break;
                  case 'delete':
                    _delete(a);
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'start_chat',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.chat_bubble_outline),
                    title: Text('开始对话'),
                  ),
                ),
                PopupMenuItem(
                  value: 'preview',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.badge_outlined),
                    title: Text('查看角色卡'),
                  ),
                ),
                PopupMenuItem(
                  value: 'profile',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.person_search_outlined),
                    title: Text('角色资料'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.ios_share_outlined),
                    title: Text(AssistantRoleCardService.fullExportLabel),
                    subtitle:
                        Text(AssistantRoleCardService.fullExportDescription),
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_json',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.content_copy_outlined),
                    title: Text('复制完整 JSON'),
                    subtitle: Text('复制到剪贴板，不走 iOS 分享面板'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export_tavern',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.swap_horiz_outlined),
                    title: Text(AssistantRoleCardService.tavernExportLabel),
                    subtitle:
                        Text(AssistantRoleCardService.tavernExportDescription),
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_tavern_json',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.copy_all_outlined),
                    title: Text('复制 Tavern V2 JSON'),
                    subtitle: Text('复制角色卡文本，适合粘贴到工具或调试'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export_tavern_png',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.image_outlined),
                    title: Text(AssistantRoleCardService.tavernPngExportLabel),
                    subtitle: Text(
                        AssistantRoleCardService.tavernPngExportDescription),
                  ),
                ),
                PopupMenuItem(
                  value: 'export_charx',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.inventory_2_outlined),
                    title: Text(AssistantRoleCardService.charxExportLabel),
                    subtitle:
                        Text(AssistantRoleCardService.charxExportDescription),
                  ),
                ),
                PopupMenuItem(
                  value: 'world_book',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.menu_book_outlined),
                    title: Text('世界书'),
                  ),
                ),
                PopupMenuItem(
                  value: 'memory',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.psychology_alt_outlined),
                    title: Text('长期记忆'),
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
            onTap: () => _edit(a),
          );
          return AppVisualSurface(
            padding: EdgeInsets.zero,
            margin: AppVisualTheme.of(context).isAnime
                ? const EdgeInsets.only(bottom: 8)
                : EdgeInsets.zero,
            child: tile,
          );
        },
      );

  String _subtitleOf(AssistantModel a) {
    final parts = <String>[
      if (a.model.trim().isNotEmpty) a.model,
      if (!a.useTools) '工具已关',
      if (a.description.trim().isNotEmpty) a.description.trim(),
      if (a.memoryBook.trim().isNotEmpty) '已配置关键词记忆',
      if (a.description.trim().isEmpty && a.prompt.trim().isNotEmpty)
        a.prompt.trim(),
    ];
    return parts.isEmpty ? '无系统提示词' : parts.join(' · ');
  }

  void _edit(AssistantModel? assistant) async {
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => AssistantEditPage(assistant: assistant)));
    if (changed == true) _loadData();
  }

  Future<_RoleCardImportOptions?> _showRoleCardPreview(
    AssistantModel assistant, {
    bool importMode = false,
    String? targetName,
    AssistantModel? conflictingAssistant,
    AssistantMemoryBookMergePreview? mergePreview,
  }) {
    final summary = AssistantRoleCardService.summarize(assistant);
    return showDialog<_RoleCardImportOptions>(
      context: context,
      builder: (ctx) => _RoleCardPreviewDialog(
        assistant: assistant,
        summary: summary,
        importMode: importMode,
        targetName: targetName,
        conflictingAssistant: conflictingAssistant,
        mergePreview: mergePreview,
      ),
    );
  }

  Future<_RoleCardImportOptions?> _showRoleCardBatchPreview(
      List<_RoleCardImportPlan> plans,
      {List<AssistantRoleCardSkippedImport> skipped = const []}) {
    var keepTools = false;
    var keepModelOverride = false;
    var keepDefaultVoice = false;
    var translateToSimplifiedChinese = false;
    var conflictMode = _RoleCardImportConflictMode.rename;
    final conflictCount = plans.where((plan) => plan.hasConflict).length;
    final hasConflicts = conflictCount > 0;
    final highImpact = plans.any((plan) {
      final summary = AssistantRoleCardService.summarize(plan.result.assistant);
      return summary.toolCount > 0 ||
          !plan.result.assistant.useTools ||
          summary.hasModelOverride ||
          summary.hasDefaultVoice;
    });
    return showDialog<_RoleCardImportOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('导入 ${plans.length} 张角色卡'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasConflicts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '$conflictCount 张与现有助手重名，重名处理策略会应用到这些角色卡。',
                      style: TextStyle(
                        color: _statusColor(context, AppStatusKind.info),
                        fontSize: 12,
                      ),
                    ),
                  ),
                for (final plan in plans.take(8))
                  _RoleCardBatchPreviewTile(
                    plan: plan,
                    conflictMode: conflictMode,
                  ),
                if (plans.length > 8)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '还有 ${plans.length - 8} 张会一并导入',
                      style: TextStyle(
                          color: _mutedTextColor(context), fontSize: 12),
                    ),
                  ),
                if (hasConflicts) ...[
                  const SizedBox(height: 12),
                  Text(
                    '重名处理',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: _statusColor(context, AppStatusKind.info),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 2),
                    child: Text(
                      '覆盖时默认保留本地工具、模型和语音设置；下方安全选项勾选后才使用外部卡配置。',
                      style: TextStyle(
                          fontSize: 12, color: _mutedTextColor(context)),
                    ),
                  ),
                  RadioGroup<_RoleCardImportConflictMode>(
                    groupValue: conflictMode,
                    onChanged: (value) => setDialogState(
                      () => conflictMode =
                          value ?? _RoleCardImportConflictMode.rename,
                    ),
                    child: const Column(
                      children: [
                        RadioListTile<_RoleCardImportConflictMode>(
                          contentPadding: EdgeInsets.zero,
                          value: _RoleCardImportConflictMode.rename,
                          title: Text('另存为新角色'),
                          subtitle: Text('自动追加编号，不影响已有助手'),
                        ),
                        RadioListTile<_RoleCardImportConflictMode>(
                          contentPadding: EdgeInsets.zero,
                          value: _RoleCardImportConflictMode.overwrite,
                          title: Text('覆盖同名角色'),
                          subtitle: Text('更新已有助手内容，保留原助手名称和会话绑定'),
                        ),
                        RadioListTile<_RoleCardImportConflictMode>(
                          contentPadding: EdgeInsets.zero,
                          value: _RoleCardImportConflictMode.mergeMemoryBook,
                          title: Text('覆盖并合并世界书'),
                          subtitle: Text('更新角色内容，但旧世界书未重复条目会保留'),
                        ),
                      ],
                    ),
                  ),
                ],
                if (skipped.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${skipped.length} 个文件无法作为角色卡导入',
                          style: TextStyle(
                              color:
                                  _statusColor(context, AppStatusKind.warning),
                              fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        for (final item in skipped.take(3))
                          Text(
                            '${item.name}：${item.reason}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: _mutedTextColor(context), fontSize: 12),
                          ),
                        if (skipped.length > 3)
                          Text(
                            '还有 ${skipped.length - 3} 个文件未展示',
                            style: TextStyle(
                                color: _mutedTextColor(context), fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  '语言转换',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: _statusColor(context, AppStatusKind.info),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: translateToSimplifiedChinese,
                  onChanged: (v) => setDialogState(
                    () => translateToSimplifiedChinese = v ?? false,
                  ),
                  title: const Text('使用当前 AI 配置翻译为简体中文'),
                  subtitle: const Text('会逐张调用 AI，可能更慢并产生用量成本；只翻译角色文本内容'),
                ),
                if (highImpact) ...[
                  const SizedBox(height: 12),
                  Text(
                    '导入安全选项',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: _statusColor(context, AppStatusKind.warning),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: keepTools,
                    onChanged: (v) =>
                        setDialogState(() => keepTools = v ?? false),
                    title: const Text('使用外部卡工具绑定 / 工具开关'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: keepModelOverride,
                    onChanged: (v) =>
                        setDialogState(() => keepModelOverride = v ?? false),
                    title: const Text('使用外部卡模型覆盖'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: keepDefaultVoice,
                    onChanged: (v) =>
                        setDialogState(() => keepDefaultVoice = v ?? false),
                    title: const Text('使用外部卡默认语音'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _RoleCardImportOptions(
                  keepTools: keepTools,
                  keepModelOverride: keepModelOverride,
                  keepDefaultVoice: keepDefaultVoice,
                  translateToSimplifiedChinese: translateToSimplifiedChinese,
                  conflictMode: conflictMode,
                ),
              ),
              child: const Text('导入全部'),
            ),
          ],
        ),
      ),
    );
  }

  void _previewRoleCard(AssistantModel assistant) {
    _showRoleCardPreview(assistant);
  }

  void _openProfilePage(AssistantModel assistant) async {
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final memoryDao = await AssistantMemoryDao.create(dbManager);
    final memories = await memoryDao.getMemories(assistant.id ?? 0, limit: 8);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantProfilePage(
          assistant: assistant,
          memories: memories,
          onStartConversation: () {
            Navigator.of(context).pop();
            _startConversationWithAssistant(assistant);
          },
        ),
      ),
    );
    _loadData();
  }

  void _openMemoryPage(AssistantModel assistant) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AssistantMemoryPage(assistant: assistant)),
    );
  }

  void _openWorldBookPage(AssistantModel assistant) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AssistantWorldBookPage(assistant: assistant)),
    );
    _loadData();
  }

  void _importRoleCardFile() async {
    String? path;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'png', 'zip'],
      );
      path = result?.files.single.path;
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取文件失败：$e');
      return;
    }
    if (path == null) return;

    AssistantRoleCardImportBatchResult importBatch;
    try {
      final pickedBytes = await File(path).readAsBytes();
      importBatch = AssistantRoleCardService.importPackageBatchBytes(
        pickedBytes,
        filename: path,
      );
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(
          context, e is FormatException ? e.message : '解析角色卡失败：$e');
      return;
    }

    if (!mounted) return;
    final importResults = importBatch.results;
    if (importResults.isEmpty) return;
    if (importResults.length == 1 &&
        StoryRoomRoleCardImporter.shouldSuggestTavernRoom(
          importResults.single.assistant,
        )) {
      final choice = await _showRoleCardImportTarget(importResults.single);
      if (choice == null) return;
      if (choice.target == _RoleCardImportTarget.tavernRoom) {
        if (choice.translateToSimplifiedChinese) {
          final initialOpening =
              await _chooseTavernInitialOpening(importResults.single);
          if (initialOpening == null || !mounted) return;
          final selected = await _selectTranslationProfile(
            estimatedRunes: _translationWorkEstimator.totalRunesForAssistant(
                  importResults.single.assistant,
                ) +
                initialOpening.runes.length,
            title: '翻译并创建酒馆房间',
          );
          if (selected == null || !mounted) return;
          await _startPersistentTavernImport(
            [importResults.single],
            sourceTitle: importResults.single.sourceName ??
                importResults.single.assistant.name,
            initialOpening: initialOpening,
            preference: selected.preference,
            accountHash: selected.accountHash,
          );
          return;
        }
        await _importRoleCardAsTavernRoom(
          importResults.single,
          translateToSimplifiedChinese: choice.translateToSimplifiedChinese,
        );
        return;
      }
    }
    if (importResults.length > 1) {
      final choice = await _showRoleCardBatchImportTarget(
        importResults,
        skipped: importBatch.skipped,
      );
      if (choice == null) return;
      if (choice.target == _RoleCardImportTarget.tavernRoom) {
        if (choice.translateToSimplifiedChinese) {
          final initialOpening =
              await _chooseTavernBatchInitialOpening(importResults);
          if (initialOpening == null || !mounted) return;
          final selected = await _selectTranslationProfile(
            estimatedRunes: _translationWorkEstimator.totalRunesForResults(
              importResults,
              initialOpening: initialOpening,
            ),
            title: '翻译并创建酒馆房间',
          );
          if (selected == null || !mounted) return;
          await _startPersistentTavernImport(
            importResults,
            sourceTitle: _stripExtension(_basename(path)),
            initialOpening: initialOpening,
            preference: selected.preference,
            accountHash: selected.accountHash,
          );
          return;
        }
        await _importRoleCardBatchAsTavernRoom(
          importResults,
          sourcePath: path,
          translateToSimplifiedChinese: choice.translateToSimplifiedChinese,
        );
        return;
      }
    }
    final importPlans = _planRoleCardImports(importResults);
    _SelectedTranslationProfile? selectedTranslation;
    var options = importPlans.length == 1
        ? await _showRoleCardPreview(
            importPlans.single.result.assistant,
            importMode: true,
            targetName: importPlans.single.renameTargetName,
            conflictingAssistant: importPlans.single.conflictingAssistant,
            mergePreview: importPlans.single.mergePreview,
          )
        : await _showRoleCardBatchPreview(
            importPlans,
            skipped: importBatch.skipped,
          );
    if (options == null) return;
    if (!mounted) return;
    if (options.translateToSimplifiedChinese) {
      selectedTranslation = await _selectTranslationProfile(
        estimatedRunes: _translationWorkEstimator.totalRunesForResults(
          importPlans.map((plan) => plan.result),
        ),
        title: '翻译角色卡',
      );
      if (selectedTranslation == null || !mounted) return;
      options = options.withTranslationProfile(selectedTranslation.profile);
    }
    final accountHash = LoginDao.getAccountHash();
    if (accountHash == null || accountHash.trim().isEmpty) {
      HiDialog.showSnackBar(context, '账号状态已变化，请重新进入助手页面后导入');
      return;
    }

    _roleCardImportCoordinator.start(
      plans: importPlans,
      options: options,
      settings: context.read<AISettingsProvider>().settings.clone(),
      accountHash: accountHash,
    );
    if (selectedTranslation != null) {
      unawaited(_saveTranslationPreferenceAfterStart(
        selectedTranslation.preference,
        selectedTranslation.accountHash,
      ));
    }
  }

  Future<void> _startPersistentTavernImport(
    List<AssistantRoleCardImportResult> results, {
    required String sourceTitle,
    required String initialOpening,
    required TranslationModelPreference preference,
    required String accountHash,
  }) async {
    final settings = context.read<AISettingsProvider>().settings.clone();
    final environment = TranslationEligibilityEnvironment.current();
    final boundary = TranslationExecutionBoundary(
      settings: settings,
      environment: environment,
    );
    try {
      final profile = boundary.snapshot(preference);
      await _tavernTranslationCoordinator.startTavernRoomImport(
        results,
        sourceTitle: sourceTitle,
        initialOpening: initialOpening,
        requestProfile: profile,
        checkEligibility: boundary.checkEligibility,
        resolveExecutor: _translationExecutorResolver(boundary.settings),
      );
      if (!mounted) return;
      try {
        await TranslationModelPreferenceStore().save(
          preference,
          expectedAccountHash: accountHash,
        );
      } catch (_) {
        if (mounted) {
          HiDialog.showSnackBar(context, '任务已创建，但翻译模型偏好未能保存');
        }
        return;
      }
      if (mounted) HiDialog.showSnackBar(context, '已加入后台任务，可断点续传');
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '创建翻译任务失败：$error');
    }
  }

  Future<_SelectedTranslationProfile?> _selectTranslationProfile({
    required int estimatedRunes,
    required String title,
    TranslationModelPreference? initialValue,
  }) async {
    final settings = context.read<AISettingsProvider>().settings.clone();
    final accountHash =
        LoginDao.getAccountHash() ?? HiDBManager.getAccountHash();
    final store = TranslationModelPreferenceStore();
    final preference = await showTranslationSettingsDialog(
      context,
      settings: settings,
      initialValue: initialValue ?? store.read(accountHash),
      estimatedRunes: estimatedRunes,
      title: title,
    );
    if (preference == null || !mounted) return null;
    try {
      return _SelectedTranslationProfile(
        preference: preference,
        profile: TranslationModelResolver.snapshot(settings, preference),
        accountHash: accountHash,
      );
    } catch (error) {
      HiDialog.showSnackBar(context, '翻译模型不可用：$error');
      return null;
    }
  }

  Future<void> _saveTranslationPreferenceAfterStart(
    TranslationModelPreference preference,
    String accountHash,
  ) async {
    try {
      await TranslationModelPreferenceStore().save(
        preference,
        expectedAccountHash: accountHash,
      );
    } catch (_) {
      if (mounted) HiDialog.showSnackBar(context, '导入已开始，但翻译模型偏好未能保存');
    }
  }

  TranslationExecutorResolver _translationExecutorResolver(
    AISettings settings,
  ) =>
      (profile) => TranslationStreamExecutor(
            service: ChatService.from(
              TranslationModelResolver.apply(settings, profile),
            ),
            profile: profile,
          );

  Future<_TavernRoomImportOptions?> _showRoleCardBatchImportTarget(
    List<AssistantRoleCardImportResult> results, {
    List<AssistantRoleCardSkippedImport> skipped = const [],
  }) {
    var translateToSimplifiedChinese = false;
    final participantCount = results.fold<int>(0, (sum, result) {
      final parsed = StoryRoomRoleCardImporter.parseMemoryBookParticipants(
        result.assistant.memoryBook,
        roomId: 0,
      );
      return sum + (parsed.length >= 2 ? parsed.length : 1);
    });
    final worldBookCount = results.fold<int>(0, (sum, result) {
      return sum +
          AssistantRoleCardService.summarize(result.assistant).memoryCount;
    });
    final openingCount =
        results.expand((result) => _tavernOpeningOptions(result)).length;
    return showDialog<_TavernRoomImportOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择批量导入方式'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('已解析 ${results.length} 张角色卡，可作为普通助手批量导入，也可以合并成一个酒馆房间。'),
                const SizedBox(height: 10),
                Text(
                  [
                    '可加入角色 $participantCount 个',
                    if (worldBookCount > 0) '世界书 $worldBookCount 条',
                    if (openingCount > 0) '开场 $openingCount 条',
                    if (skipped.isNotEmpty) '跳过 ${skipped.length} 个文件',
                  ].join(' · '),
                  style: TextStyle(
                    color: _statusColor(ctx, AppStatusKind.info),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '合并成酒馆房间会把每张卡作为房间角色，并把各卡世界书汇总为共享上下文；普通助手导入则保持现有批量导入和重名处理流程。',
                  style: TextStyle(fontSize: 12, color: _mutedTextColor(ctx)),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: translateToSimplifiedChinese,
                  onChanged: (v) => setDialogState(
                    () => translateToSimplifiedChinese = v ?? false,
                  ),
                  title: const Text('创建酒馆房间前翻译为简体中文'),
                  subtitle: const Text('使用当前 AI 配置逐张翻译；会产生用量成本'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(
                const _TavernRoomImportOptions(
                  target: _RoleCardImportTarget.assistant,
                ),
              ),
              child: const Text('批量助手'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                _TavernRoomImportOptions(
                  target: _RoleCardImportTarget.tavernRoom,
                  translateToSimplifiedChinese: translateToSimplifiedChinese,
                ),
              ),
              child: const Text('酒馆房间'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_TavernRoomImportOptions?> _showRoleCardImportTarget(
    AssistantRoleCardImportResult result,
  ) {
    final assistant = result.assistant;
    final summary = AssistantRoleCardService.summarize(assistant);
    final participants = StoryRoomRoleCardImporter.parseMemoryBookParticipants(
      assistant.memoryBook,
      roomId: 0,
    );
    var translateToSimplifiedChinese = false;
    return showDialog<_TavernRoomImportOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择导入方式'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '「${assistant.name}」包含较多世界书/多角色信息，更适合导入为酒馆房间。',
                ),
                const SizedBox(height: 10),
                Text(
                  [
                    if (summary.memoryCount > 0) '世界书 ${summary.memoryCount} 条',
                    if (participants.isNotEmpty)
                      '可识别角色 ${participants.length} 个',
                    if (summary.alternateGreetingCount > 0)
                      '备选开场 ${summary.alternateGreetingCount} 条',
                  ].join(' · '),
                  style: TextStyle(
                    color: _statusColor(ctx, AppStatusKind.info),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '创建酒馆房间会把主卡内容作为公共上下文，把可识别的世界书角色加入房间参与者；也可以继续按普通助手导入。',
                  style: TextStyle(fontSize: 12, color: _mutedTextColor(ctx)),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: translateToSimplifiedChinese,
                  onChanged: (v) => setDialogState(
                    () => translateToSimplifiedChinese = v ?? false,
                  ),
                  title: const Text('创建酒馆房间前翻译为简体中文'),
                  subtitle: const Text('使用当前 AI 配置翻译角色文本；会产生用量成本'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(
                const _TavernRoomImportOptions(
                  target: _RoleCardImportTarget.assistant,
                ),
              ),
              child: const Text('普通助手'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                _TavernRoomImportOptions(
                  target: _RoleCardImportTarget.tavernRoom,
                  translateToSimplifiedChinese: translateToSimplifiedChinese,
                ),
              ),
              child: const Text('酒馆房间'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importRoleCardAsTavernRoom(
    AssistantRoleCardImportResult result, {
    required bool translateToSimplifiedChinese,
  }) async {
    final prepared = [result];
    final translatedResult = prepared.single;
    final initialOpening = await _chooseTavernInitialOpening(translatedResult);
    if (initialOpening == null) return;
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final dao = await StoryRoomDao.create(dbManager);
      final existingTitles = (await dao.getRooms()).map((room) => room.title);
      final title = AssistantRoleCardService.uniqueImportName(
        translatedResult.assistant.name,
        existingTitles,
      );
      final importer = StoryRoomRoleCardImportService(dao);
      final template = await _saveTavernRoomTemplate(
        dbManager,
        [translatedResult],
        title: title,
        sourceTitle: result.sourceName ?? translatedResult.assistant.name,
        translated: translateToSimplifiedChinese,
        initialOpening: initialOpening,
      );
      final roomId = await importer.createRoomFromTemplate(template);
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已创建酒馆房间「$title」');
      final room = await dao.getRoom(roomId);
      if (!mounted || room == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => StoryRoomPage(room: room)),
      );
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '创建酒馆房间失败：$e');
    }
  }

  Future<void> _importRoleCardBatchAsTavernRoom(
    List<AssistantRoleCardImportResult> results, {
    required String sourcePath,
    required bool translateToSimplifiedChinese,
  }) async {
    final prepared = results;
    final initialOpening = await _chooseTavernBatchInitialOpening(prepared);
    if (initialOpening == null) return;
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final dao = await StoryRoomDao.create(dbManager);
      final existingTitles = (await dao.getRooms()).map((room) => room.title);
      final baseTitle = _roleCardBatchRoomTitle(prepared, sourcePath);
      final title = AssistantRoleCardService.uniqueImportName(
        baseTitle,
        existingTitles,
      );
      final importer = StoryRoomRoleCardImportService(dao);
      final template = await _saveTavernRoomTemplate(
        dbManager,
        prepared,
        title: title,
        sourceTitle: sourcePath,
        translated: translateToSimplifiedChinese,
        initialOpening: initialOpening,
      );
      final roomId = await importer.createRoomFromTemplate(template);
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已创建酒馆房间「$title」');
      final room = await dao.getRoom(roomId);
      if (!mounted || room == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => StoryRoomPage(room: room)),
      );
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '创建酒馆房间失败：$e');
    }
  }

  Future<String?> _chooseTavernBatchInitialOpening(
    List<AssistantRoleCardImportResult> results,
  ) async {
    final options = <_TavernOpeningOption>[
      for (final result in results)
        for (final option in _tavernOpeningOptions(result))
          _TavernOpeningOption(
            label: '${result.assistant.name} · ${option.label}',
            text: option.text,
          ),
    ];
    if (options.isEmpty) return '';
    if (options.length == 1) return options.first.text;
    var selected = 0;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择房间开场'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: RadioGroup<int>(
                groupValue: selected,
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() => selected = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < options.length; i++)
                      RadioListTile<int>(
                        value: i,
                        contentPadding: EdgeInsets.zero,
                        title: Text(options[i].label),
                        subtitle: Text(
                          options[i].text,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(options[selected].text),
              child: const Text('创建房间'),
            ),
          ],
        ),
      ),
    );
  }

  String _roleCardBatchRoomTitle(
    List<AssistantRoleCardImportResult> results,
    String sourcePath,
  ) {
    final sourceName = _basename(sourcePath);
    if (sourceName.isNotEmpty) return _stripExtension(sourceName);
    final firstName = results.first.assistant.name.trim();
    if (firstName.isEmpty) return '酒馆房间';
    return results.length == 1 ? firstName : '$firstName 等 ${results.length} 人';
  }

  Future<String?> _chooseTavernInitialOpening(
    AssistantRoleCardImportResult result,
  ) async {
    final options = _tavernOpeningOptions(result);
    if (options.length <= 1) {
      return options.isEmpty ? '' : options.first.text;
    }
    var selected = 0;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择房间开场'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: RadioGroup<int>(
                groupValue: selected,
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() => selected = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < options.length; i++)
                      RadioListTile<int>(
                        value: i,
                        contentPadding: EdgeInsets.zero,
                        title: Text(options[i].label),
                        subtitle: Text(
                          options[i].text,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(options[selected].text),
              child: const Text('创建房间'),
            ),
          ],
        ),
      ),
    );
  }

  List<_TavernOpeningOption> _tavernOpeningOptions(
    AssistantRoleCardImportResult result,
  ) {
    final options = <_TavernOpeningOption>[];
    final seen = <String>{};
    void add(String label, String text) {
      final normalized = text.trim();
      if (normalized.isEmpty) return;
      if (!seen.add(normalized.replaceAll(RegExp(r'\s+'), ''))) return;
      options.add(_TavernOpeningOption(label: label, text: normalized));
    }

    add('默认开场', result.assistant.openingMessage);
    final metaGreetings = result.tavernMeta?.alternateGreetings ?? const [];
    for (var i = 0; i < metaGreetings.length; i++) {
      add('备选开场 ${i + 1}', metaGreetings[i]);
    }
    final embeddedGreetings = AssistantRoleCardService.alternateGreetings(
        result.assistant.exampleDialogs);
    for (var i = 0; i < embeddedGreetings.length; i++) {
      add('备选开场 ${metaGreetings.length + i + 1}', embeddedGreetings[i]);
    }
    return options;
  }

  String _basename(String path) {
    final parts =
        path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path.trim() : parts.last;
  }

  String _stripExtension(String filename) {
    final index = filename.lastIndexOf('.');
    if (index <= 0) return filename;
    return filename.substring(0, index);
  }

  Future<void> _showRoleCardImportFailureLog(
    _RoleCardImportJob job,
  ) {
    return showDialog<void>(
      context: context,
      builder: (context) => TranslationTaskLogDialog(
        title: '导入任务日志',
        log: job.log,
        error: job.error,
      ),
    );
  }

  Future<void> _showTavernTranslationLog(
    StoryTemplateTranslationTaskModel task,
  ) =>
      showDialog<void>(
        context: context,
        builder: (context) => TranslationTaskLogDialog(
          title: '酒馆翻译任务日志',
          log: task.log,
          error: task.error,
        ),
      );

  Future<void> _showTavernTranslationRecovery(
    StoryTemplateTranslationTaskModel task,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('继续使用原模型'),
              onTap: () => Navigator.pop(sheetContext, 'retry'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('更换模型后继续'),
              onTap: () => Navigator.pop(sheetContext, 'replace'),
            ),
            if (task.chunkPayload.trim().isNotEmpty)
              ListTile(
                leading: const Icon(Icons.rule_folder_outlined),
                title: const Text('保留失败块原文并完成'),
                onTap: () => Navigator.pop(sheetContext, 'retain'),
              ),
            ListTile(
              leading: const Icon(Icons.cancel_outlined),
              title: const Text('取消任务'),
              onTap: () => Navigator.pop(sheetContext, 'cancel'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'cancel') {
      await _tavernTranslationCoordinator.cancel(task);
      return;
    }
    if (action == 'retain') {
      await _tavernTranslationCoordinator.completeKeepingOriginalChunks(task);
      if (!mounted) return;
      final settings = context.read<AISettingsProvider>().settings.clone();
      final environment = TranslationEligibilityEnvironment.current();
      const evaluator = TranslationModelEligibilityEvaluator();
      TranslationEligibilityResult checkEligibility(
        TranslationRequestProfile profile,
      ) =>
          evaluator.evaluateProfile(
            settings: settings,
            profile: profile,
            environment: environment,
          );
      await _tavernTranslationCoordinator.resumeRecoverable(
        checkEligibility: checkEligibility,
        resolveExecutor: _translationExecutorResolver(settings),
      );
      return;
    }
    if (action == 'retry') {
      final settings = context.read<AISettingsProvider>().settings.clone();
      final environment = TranslationEligibilityEnvironment.current();
      const evaluator = TranslationModelEligibilityEvaluator();
      TranslationEligibilityResult checkEligibility(
        TranslationRequestProfile profile,
      ) =>
          evaluator.evaluateProfile(
            settings: settings,
            profile: profile,
            environment: environment,
          );
      await _tavernTranslationCoordinator.retry(
        task,
        checkEligibility: checkEligibility,
        resolveExecutor: _translationExecutorResolver(settings),
      );
      return;
    }
    final selected = await _selectTranslationProfile(
      estimatedRunes: _translationWorkEstimator
              .tryTotalRunesForTaskSource(task.sourcePayload) ??
          0,
      title: '更换翻译模型',
      initialValue: _preferenceFromTask(task),
    );
    if (selected == null || !mounted) return;
    final settings = context.read<AISettingsProvider>().settings.clone();
    final environment = TranslationEligibilityEnvironment.current();
    final boundary = TranslationExecutionBoundary(
      settings: settings,
      environment: environment,
    );
    await boundary.runGuarded(
      action: () async {
        final profile = boundary.snapshot(selected.preference);
        await _tavernTranslationCoordinator.retry(
          task,
          replacementProfile: profile,
          checkEligibility: boundary.checkEligibility,
          resolveExecutor: _translationExecutorResolver(boundary.settings),
        );
        await _saveTranslationPreferenceAfterStart(
          selected.preference,
          selected.accountHash,
        );
      },
      onUnavailable: (error) {
        if (mounted) {
          HiDialog.showSnackBar(context, '更换翻译模型失败：${error.message}');
        }
      },
    );
  }

  TranslationModelPreference? _preferenceFromTask(
    StoryTemplateTranslationTaskModel task,
  ) {
    try {
      final decoded = jsonDecode(task.requestProfile);
      if (decoded is! Map) return null;
      final profile = TranslationRequestProfile.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return TranslationModelPreference(
        mode: profile.mode == TranslationExecutionMode.local
            ? TranslationModelPreferenceMode.local
            : TranslationModelPreferenceMode.backend,
        providerId: profile.providerId,
        modelId: profile.modelId,
        reasoningPolicy: profile.reasoningPolicy,
      );
    } catch (_) {
      return null;
    }
  }

  bool _canCancelTavernTranslationTask(
    StoryTemplateTranslationTaskModel task,
  ) =>
      task.status != StoryTemplateTranslationTaskStatus.completed &&
      task.status != StoryTemplateTranslationTaskStatus.completedWithWarnings &&
      task.status != StoryTemplateTranslationTaskStatus.cancelled;

  List<_RoleCardImportPlan> _planRoleCardImports(
    List<AssistantRoleCardImportResult> results,
  ) {
    final usedNames = {
      ..._assistants.map((assistant) => assistant.name),
      ..._roleCardImportCoordinator.jobs
          .where((job) => !job.failed)
          .map((job) => job.displayName),
    };
    final plans = <_RoleCardImportPlan>[];
    for (final result in results) {
      final targetName = AssistantRoleCardService.uniqueImportName(
        result.assistant.name,
        usedNames,
      );
      final conflictingAssistant = _findRoleCardImportConflict(
        result.assistant.name,
      );
      final mergePreview = conflictingAssistant == null
          ? null
          : AssistantRoleCardService.mergeMemoryBookPreview(
              conflictingAssistant.memoryBook,
              result.assistant.memoryBook,
            );
      plans.add(_RoleCardImportPlan(
        result: result,
        renameTargetName: targetName,
        conflictingAssistant: conflictingAssistant,
        mergePreview: mergePreview,
      ));
      usedNames.add(targetName);
    }
    return plans;
  }

  AssistantModel? _findRoleCardImportConflict(String name) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) return null;
    for (final assistant in _assistants) {
      final unique = AssistantRoleCardService.uniqueImportName(
        normalizedName,
        [assistant.name],
      );
      if (unique != normalizedName) return assistant;
    }
    return null;
  }

  void _startConversationWithAssistant(AssistantModel assistant) async {
    final opening = await _chooseAssistantOpening(assistant);
    if (opening == null || !mounted) return;
    final model = AssistantConversationFactory.create(
      cid: DateTime.now().millisecondsSinceEpoch,
      icon: AiCatalogDao.avatarUrl(),
      assistant: assistant,
    );
    NavigatorUtil.push(
      context,
      ConversationPage(
        conversationModel: model,
        initialAssistantOpening: opening,
        conversationUpdate: (updated) {
          unawaited(_saveStartedConversation(updated));
        },
      ),
    );
  }

  Future<String?> _chooseAssistantOpening(AssistantModel assistant) async {
    final candidates =
        AssistantConversationFactory.openingMessageCandidates(assistant);
    if (candidates.length <= 1) {
      return candidates.isEmpty ? '' : candidates.first;
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择开场白'),
        children: [
          for (var i = 0; i < candidates.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, candidates[i]),
              child: Text(
                candidates[i],
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('不使用开场白'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveStartedConversation(ConversationModel updated) async {
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await ConversationListDao.create(dbManager);
    await dao.saveConversation(updated);
    AppEvents.notifyConversationsChanged();
  }

  Widget _assistantAvatar(AssistantModel assistant) {
    return AssistantAvatar(assistant: assistant);
  }

  void _exportRoleCard(AssistantModel assistant) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/${AssistantRoleCardService.filenameFor(assistant)}');
      await file.writeAsString(AssistantRoleCardService.exportJson(assistant));
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
      ));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导出失败：$e');
    }
  }

  void _copyRoleCardJson(AssistantModel assistant) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: AssistantRoleCardService.exportJson(assistant)),
      );
      if (mounted) HiDialog.showSnackBar(context, '已复制完整角色卡 JSON');
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '复制失败：$e');
    }
  }

  void _exportTavernRoleCard(AssistantModel assistant) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/${AssistantRoleCardService.tavernFilenameFor(assistant)}');
      await file.writeAsString(
        AssistantRoleCardService.exportTavernV2Json(assistant),
      );
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
      ));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导出 Tavern 角色卡失败：$e');
    }
  }

  void _copyTavernRoleCardJson(AssistantModel assistant) async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: AssistantRoleCardService.exportTavernV2Json(assistant),
        ),
      );
      if (mounted) HiDialog.showSnackBar(context, '已复制 Tavern V2 JSON');
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '复制 Tavern JSON 失败：$e');
    }
  }

  void _exportTavernRoleCardPng(AssistantModel assistant) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/${AssistantRoleCardService.tavernPngFilenameFor(assistant)}');
      final bytes = AssistantRoleCardService.exportTavernV2Png(
        assistant,
        basePngBytes: await _readAssistantAvatarBytes(assistant),
      );
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
      ));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导出 Tavern PNG 失败：$e');
    }
  }

  void _exportCharxRoleCard(AssistantModel assistant) async {
    try {
      final resources =
          await AssistantRoleCardAssetStore.load(assistant.roleCardAssets);
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/${AssistantRoleCardService.charxFilenameFor(assistant)}',
      );
      final bytes = AssistantRoleCardService.exportCharx(
        assistant,
        resources: resources,
        avatarPngBytes: await _readAssistantAvatarBytes(assistant),
      );
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导出 CHARX 失败：$e');
    }
  }

  Future<List<int>?> _readAssistantAvatarBytes(AssistantModel assistant) async {
    final avatarType = assistant.avatarType;
    final avatarValue = assistant.avatarValue?.trim() ?? '';
    if (avatarType != AvatarAssetService.imageType || avatarValue.isEmpty) {
      return null;
    }
    final file = File(avatarValue);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 导入技能 zip（Agent Skill：SKILL.md + references/）：解析成
  /// 「助手（正文→系统提示词）+ 知识库文档（references→RAG）」并落库。
  /// 仅适用纯指令型 skill；带脚本/需沙箱的 skill 在移动端无法执行。
  void _importSkillZip() async {
    // 选 zip 文件。
    String? path;
    String? pickedName;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      path = result?.files.single.path;
      pickedName = result?.files.single.name;
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取文件失败：$e');
      return;
    }
    if (path == null) return;

    // 解析。
    SkillPackage pkg;
    try {
      final bytes = await File(path).readAsBytes();
      final fallback = (pickedName != null && pickedName.contains('.'))
          ? pickedName.substring(0, pickedName.lastIndexOf('.'))
          : pickedName;
      pkg = SkillImportService.parseArchive(bytes, fallbackName: fallback);
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(
          context, e is FormatException ? e.message : '解析失败：$e');
      return;
    }

    // 预览确认。
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${pkg.emoji} 导入技能「${pkg.name}」'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pkg.description.isNotEmpty) ...[
                Text(pkg.description,
                    style:
                        TextStyle(color: _mutedTextColor(ctx), fontSize: 13)),
                const SizedBox(height: 12),
              ],
              Text('将新建助手：${pkg.name}'),
              Text('系统提示词：约 ${pkg.systemPrompt.length} 字'),
              Text(pkg.references.isEmpty
                  ? '参考资料：无'
                  : '参考资料：${pkg.references.length} 篇 → 导入知识库，'
                      '并自动绑定「知识库检索」工具\n'
                      '· ${pkg.references.map((r) => r.title).join('\n· ')}'),
              if (pkg.scripts.isNotEmpty)
                Text(
                  '脚本：${pkg.scripts.length} 个 → 绑定「运行脚本」工具，'
                  '运行前在沙箱执行并需你确认（仅 Android/iOS 等支持，鸿蒙不可执行）\n'
                  '· ${pkg.scripts.map((s) => s.name).join('\n· ')}',
                  style: TextStyle(
                    color: _statusColor(ctx, AppStatusKind.warning),
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;

    // 落库。
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final kbDao = await KnowledgeDao.create(dbManager);
      final scriptDao = await SkillScriptDao.create(dbManager);
      // 导入时 AI 安全审计的实时 LLM 调用（auditCall）暂留待接入聊天路径；
      // 现以 pending 入库，执行时由 run_script 工具展示代码预览 + 用户确认兜底。
      final result = await SkillImportService.import(
        pkg,
        assistantDao: _dao!,
        knowledgeDao: kbDao,
        scriptDao: scriptDao,
      );
      if (!mounted) return;
      final parts = <String>[
        if (result.docCount > 0) '${result.docCount} 篇资料进知识库',
        if (result.scriptCount > 0) '${result.scriptCount} 个脚本',
      ];
      final extra = parts.isEmpty ? '' : '，${parts.join('、')}';
      HiDialog.showSnackBar(context, '已导入技能「${result.name}」$extra');
      await _loadData();
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导入失败：$e');
    }
  }

  ///助手市场（遗留项 9）：浏览内置模板并添加。关闭后刷新列表（可能已添加几个）。
  void _openMarket() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const AssistantMarketPage()));
    _loadData();
  }

  void _delete(AssistantModel a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除助手'),
        content: Text('确定删除「${a.name}」吗？已绑定的会话将回落为无助手。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || a.id == null) return;
    final accountHash = LoginDao.getAccountHash();
    if (accountHash == null || accountHash.trim().isEmpty) {
      if (mounted) HiDialog.showSnackBar(context, '账号状态已变化，请重新进入助手页面后删除');
      return;
    }
    try {
      await LoginDao.runWithStableAccount(
        expectedAccountHash: accountHash,
        action: () async {
          final dbManager = await HiDBManager.instance(dbName: accountHash);
          final dao = await AssistantDao.create(dbManager);
          await dao.deleteAssistant(a.id!);
          await AssistantRoleCardAssetStore.delete(
            assistantId: a.id!,
            accountHash: accountHash,
          );
        },
      );
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '删除失败：$e');
      return;
    }
    if (!mounted) return;
    HiDialog.showSnackBar(context, '已删除「${a.name}」');
    _loadData();
  }
}

enum _RoleCardImportConflictMode { rename, overwrite, mergeMemoryBook }

enum _RoleCardImportTarget { assistant, tavernRoom }

class _TavernRoomImportOptions {
  final _RoleCardImportTarget target;
  final bool translateToSimplifiedChinese;
  final TranslationRequestProfile? translationProfile;

  const _TavernRoomImportOptions({
    required this.target,
    this.translateToSimplifiedChinese = false,
    this.translationProfile,
  });

  _TavernRoomImportOptions withTranslationProfile(
    TranslationRequestProfile profile,
  ) =>
      _TavernRoomImportOptions(
        target: target,
        translateToSimplifiedChinese: true,
        translationProfile: profile,
      );
}

class _SelectedTranslationProfile {
  final TranslationModelPreference preference;
  final TranslationRequestProfile profile;
  final String accountHash;

  const _SelectedTranslationProfile({
    required this.preference,
    required this.profile,
    required this.accountHash,
  });
}

class _TavernOpeningOption {
  final String label;
  final String text;

  const _TavernOpeningOption({
    required this.label,
    required this.text,
  });
}

class _RoleCardImportCoordinator extends ChangeNotifier {
  final List<_RoleCardImportJob> _jobs = [];
  int _completedTick = 0;

  List<_RoleCardImportJob> get jobs => List.unmodifiable(_jobs);
  int get completedTick => _completedTick;

  void start({
    required List<_RoleCardImportPlan> plans,
    required _RoleCardImportOptions options,
    required AISettings settings,
    required String accountHash,
  }) {
    if (plans.isEmpty) return;
    final jobs = [
      for (var i = 0; i < plans.length; i++)
        _RoleCardImportJob.fromPlan(
          plan: plans[i],
          total: plans.length,
          index: i + 1,
          translate: options.translateToSimplifiedChinese,
        ),
    ];
    _jobs.insertAll(0, jobs);
    notifyListeners();
    unawaited(
      _run(
        jobs: jobs,
        plans: plans,
        options: options,
        settings: settings,
        accountHash: accountHash,
      ),
    );
  }

  void dismiss(_RoleCardImportJob job) {
    if (!_jobs.remove(job)) return;
    notifyListeners();
  }

  Future<void> _run({
    required List<_RoleCardImportJob> jobs,
    required List<_RoleCardImportPlan> plans,
    required _RoleCardImportOptions options,
    required AISettings settings,
    required String accountHash,
  }) async {
    for (var i = 0; i < plans.length; i++) {
      final job = jobs[i];
      final plan = plans[i];
      try {
        _update(
          job,
          status: _RoleCardImportJobStatus.running,
          stage: options.translateToSimplifiedChinese ? '等待 AI 翻译返回' : '正在导入',
          progress: options.translateToSimplifiedChinese ? 0.18 : 0.35,
        );
        final assistant = await _prepareImportedRoleCard(
          plan,
          options,
          settings,
          onProgress: (value) => _update(
            job,
            stage: value.stage,
            detail: _translationDetail(value),
            progress: 0.18 + (0.52 * _translationProgressRatio(value)),
          ),
        );
        _update(
          job,
          stage: '正在保存',
          displayName: assistant.name,
          detail: '',
          progress: 0.78,
        );
        await LoginDao.runWithStableAccount(
          expectedAccountHash: accountHash,
          action: () async {
            final dbManager = await HiDBManager.instance(dbName: accountHash);
            final dao = await AssistantDao.create(dbManager);
            await dao.saveAssistant(assistant);
            final assistantId = assistant.id;
            if (assistantId != null && plan.result.resources.isNotEmpty) {
              assistant.roleCardAssets = await AssistantRoleCardAssetStore.save(
                assistantId: assistantId,
                resources: plan.result.resources,
                accountHash: accountHash,
              );
              await dao.saveAssistant(assistant);
            }
          },
        );
        _update(
          job,
          status: _RoleCardImportJobStatus.completed,
          stage: '已保存',
          displayName: assistant.name,
          detail: '',
          progress: 1,
        );
        _jobs.remove(job);
        _completedTick += 1;
        notifyListeners();
      } catch (e, stackTrace) {
        _failJob(job, options, e, stackTrace);
      }
    }
  }

  void _update(
    _RoleCardImportJob job, {
    _RoleCardImportJobStatus? status,
    String? stage,
    String? displayName,
    String? detail,
    double? progress,
  }) {
    if (!_jobs.contains(job)) return;
    if (status != null) job.status = status;
    if (stage != null) job.stage = stage;
    if (displayName != null) job.displayName = displayName;
    if (detail != null) job.detail = detail;
    if (progress != null) job.progress = progress.clamp(0, 1).toDouble();
    _appendLog(
      job,
      stage: stage,
      detail: detail,
      displayName: displayName,
      progress: progress,
      status: status,
    );
    notifyListeners();
  }

  void _appendLog(
    _RoleCardImportJob job, {
    _RoleCardImportJobStatus? status,
    String? stage,
    String? detail,
    String? displayName,
    double? progress,
  }) {
    final parts = <String>[
      _logTime(),
      if (status != null) _statusLabel(status),
      if (stage != null && stage.trim().isNotEmpty) stage.trim(),
      if (detail != null && detail.trim().isNotEmpty) detail.trim(),
      if (displayName != null && displayName.trim().isNotEmpty)
        '对象：${displayName.trim()}',
      if (progress != null) '进度：${(progress.clamp(0, 1) * 100).round()}%',
    ];
    if (parts.length <= 1) return;
    final line = parts.join(' · ');
    final lines = job.log.split('\n');
    if (lines.isNotEmpty && lines.last == line) return;
    job.log = job.log.trim().isEmpty ? line : '${job.log}\n$line';
    _trimLog(job);
  }

  void _failJob(
    _RoleCardImportJob job,
    _RoleCardImportOptions options,
    Object error,
    StackTrace stackTrace, {
    String stage = '导入失败',
  }) {
    if (!_jobs.contains(job)) return;
    job.status = _RoleCardImportJobStatus.failed;
    job.stage = stage;
    job.progress = 1;
    job.error = error is FormatException ? error.message : error.toString();
    final failure = [
      '角色卡导入失败',
      '名称：${job.displayName}',
      '阶段：${job.stage}',
      '翻译：${options.translateToSimplifiedChinese ? '是' : '否'}',
      '错误：$error',
      '',
      stackTrace.toString(),
    ].join('\n');
    job.log = job.log.trim().isEmpty ? failure : '${job.log}\n\n$failure';
    _trimLog(job);
    notifyListeners();
  }

  static void _trimLog(_RoleCardImportJob job) {
    const maxLines = 500;
    final lines = job.log.split('\n');
    if (lines.length <= maxLines) return;
    job.log = [
      '日志较长，已隐藏前 ${lines.length - maxLines} 行',
      ...lines.skip(lines.length - maxLines),
    ].join('\n');
  }

  static String _logTime() {
    final now = DateTime.now();
    return [
      now.hour.toString().padLeft(2, '0'),
      now.minute.toString().padLeft(2, '0'),
      now.second.toString().padLeft(2, '0'),
    ].join(':');
  }

  static String _statusLabel(_RoleCardImportJobStatus status) {
    switch (status) {
      case _RoleCardImportJobStatus.queued:
        return '排队中';
      case _RoleCardImportJobStatus.running:
        return '运行中';
      case _RoleCardImportJobStatus.completed:
        return '已完成';
      case _RoleCardImportJobStatus.failed:
        return '失败';
    }
  }

  Future<AssistantModel> _prepareImportedRoleCard(
    _RoleCardImportPlan plan,
    _RoleCardImportOptions options,
    AISettings settings, {
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    var incoming = plan.result.assistant;
    if (options.translateToSimplifiedChinese) {
      final profile = options.translationProfile;
      if (profile == null) {
        throw const FormatException('翻译角色卡缺少模型快照');
      }
      incoming = await _translateImportedRoleCard(
        incoming,
        settings,
        profile: profile,
        onProgress: onProgress,
      );
    }
    final assistant = AssistantRoleCardService.sanitizeForImport(
      incoming,
      keepTools: options.keepTools,
      keepModelOverride: options.keepModelOverride,
      keepDefaultVoice: options.keepDefaultVoice,
    );
    final overwriteTarget = options.conflictMode ==
                _RoleCardImportConflictMode.overwrite ||
            options.conflictMode == _RoleCardImportConflictMode.mergeMemoryBook
        ? plan.conflictingAssistant
        : null;
    if (overwriteTarget != null) {
      assistant.id = overwriteTarget.id;
      assistant.createdAt = overwriteTarget.createdAt;
      assistant.name = overwriteTarget.name;
      assistant.roleCardAssets = overwriteTarget.roleCardAssets;
      AssistantRoleCardService.preserveLocalOverwriteSettings(
        assistant,
        overwriteTarget,
        keepIncomingTools: options.keepTools,
        keepIncomingModelOverride: options.keepModelOverride,
        keepIncomingDefaultVoice: options.keepDefaultVoice,
      );
      if (options.conflictMode == _RoleCardImportConflictMode.mergeMemoryBook) {
        assistant.memoryBook = plan.mergePreview?.mergedText ??
            AssistantRoleCardService.mergeMemoryBooks(
              overwriteTarget.memoryBook,
              assistant.memoryBook,
            );
      }
    } else {
      assistant.name = plan.renameTargetName;
    }
    final avatarBytes = plan.result.avatarPngBytes;
    if (avatarBytes != null) {
      try {
        assistant.avatarType = AvatarAssetService.imageType;
        assistant.avatarValue =
            await AvatarAssetService.saveAssistantAvatarBytes(
          bytes: avatarBytes,
          assistantName: assistant.name,
          extension: plan.result.avatarExtension ?? '.png',
        );
      } catch (_) {
        assistant.avatarType = null;
        assistant.avatarValue = null;
      }
    } else if (overwriteTarget != null) {
      assistant.avatarType = overwriteTarget.avatarType;
      assistant.avatarValue = overwriteTarget.avatarValue;
    }
    return assistant;
  }

  Future<AssistantModel> _translateImportedRoleCard(
    AssistantModel assistant,
    AISettings settings, {
    required TranslationRequestProfile profile,
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    final executor = TranslationStreamExecutor(
      service:
          ChatService.from(TranslationModelResolver.apply(settings, profile)),
      profile: profile,
    );
    final cancellation = TranslationCancellationController();
    try {
      return await AssistantRoleCardTranslationService
          .translateToSimplifiedChinese(
        assistant,
        complete: (prompt) => executor.complete(
          prompt,
          cancellation: cancellation,
        ),
        onProgress: onProgress,
      );
    } on FormatException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('翻译角色卡失败：$e');
    }
  }

  static String _translationDetail(RoleCardTranslationProgress value) {
    final parts = <String>[
      if (value.fieldLabel.isNotEmpty) value.fieldLabel,
      if (value.total > 1) '${value.current}/${value.total}',
      if (value.detail.trim().isNotEmpty) value.detail.trim(),
      if (value.completedRunes != null &&
          value.totalRunes != null &&
          value.totalRunes! > 0)
        formatRuneProgress(value.completedRunes!, value.totalRunes!),
    ];
    return parts.join(' · ');
  }

  static double _translationProgressRatio(RoleCardTranslationProgress value) {
    if (value.completedRunes != null &&
        value.totalRunes != null &&
        value.totalRunes! > 0) {
      return (value.completedRunes! / value.totalRunes!).clamp(0, 1).toDouble();
    }
    return _legacyFieldProgressRatio(value);
  }

  static double _legacyFieldProgressRatio(
    RoleCardTranslationProgress value,
  ) {
    if (value.total <= 0) return 0;
    final fieldBase = (value.current - 1).clamp(0, value.total) / value.total;
    final inField = value.fieldProgress.clamp(0, 1).toDouble() / value.total;
    return (fieldBase + inField).clamp(0, 1).toDouble();
  }
}

class _TavernTranslationTaskTile extends StatelessWidget {
  final StoryTemplateTranslationTaskModel task;
  final VoidCallback onShowLog;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onDismiss;

  const _TavernTranslationTaskTile({
    required this.task,
    required this.onShowLog,
    this.onRetry,
    this.onCancel,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final completed =
        task.status == StoryTemplateTranslationTaskStatus.completed;
    final warning =
        task.status == StoryTemplateTranslationTaskStatus.completedWithWarnings;
    final failed = task.status == StoryTemplateTranslationTaskStatus.failed ||
        task.status == StoryTemplateTranslationTaskStatus.needsConfiguration ||
        task.status == StoryTemplateTranslationTaskStatus.retryable;
    final statusKind = completed
        ? AppStatusKind.success
        : warning
            ? AppStatusKind.warning
            : failed
                ? AppStatusKind.error
                : AppStatusKind.info;
    final palette = AppStatusPalette.of(context, statusKind);
    final progress = task.progress.clamp(0, 1).toDouble();
    return AppVisualSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: palette.container,
          child: Icon(
            completed
                ? Icons.meeting_room_outlined
                : failed
                    ? Icons.error_outline
                    : Icons.translate,
            color: palette.foreground,
          ),
        ),
        title: Text(
          task.outputTitle.trim().isEmpty ? task.sourceTitle : task.outputTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                StoryTemplateTranslationTaskStatus.labelOf(task.status),
                if (task.stage.trim().isNotEmpty) task.stage.trim(),
                if (task.detail.trim().isNotEmpty) task.detail.trim(),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.foreground),
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: palette.foreground,
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '任务操作',
          onSelected: (value) {
            if (value == 'log') onShowLog();
            if (value == 'retry') onRetry?.call();
            if (value == 'cancel') onCancel?.call();
            if (value == 'dismiss') onDismiss?.call();
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'log', child: Text('查看日志')),
            if (onRetry != null)
              const PopupMenuItem(value: 'retry', child: Text('恢复任务')),
            if (onCancel != null)
              const PopupMenuItem(value: 'cancel', child: Text('取消任务')),
            if (onDismiss != null)
              const PopupMenuItem(value: 'dismiss', child: Text('移除记录')),
          ],
        ),
      ),
    );
  }
}

enum _RoleCardImportJobStatus { queued, running, completed, failed }

class _RoleCardImportJob {
  final int total;
  final int index;
  final bool translate;
  String displayName;
  String stage;
  String detail = '';
  double progress = 0;
  String error = '';
  String log = '';
  _RoleCardImportJobStatus status = _RoleCardImportJobStatus.queued;

  _RoleCardImportJob({
    required this.total,
    required this.index,
    required this.translate,
    required this.displayName,
    required this.stage,
  });

  factory _RoleCardImportJob.fromPlan({
    required _RoleCardImportPlan plan,
    required int total,
    required int index,
    required bool translate,
  }) {
    final targetName = plan.hasConflict
        ? plan.conflictingAssistant!.name
        : plan.renameTargetName;
    return _RoleCardImportJob(
      total: total,
      index: index,
      translate: translate,
      displayName: targetName.trim().isEmpty
          ? plan.result.assistant.name
          : targetName.trim(),
      stage: translate ? '等待翻译' : '等待导入',
    );
  }

  String get counter => total <= 1 ? '' : '$index / $total';
  bool get failed => status == _RoleCardImportJobStatus.failed;
  bool get running => status == _RoleCardImportJobStatus.running;
  bool get completed => status == _RoleCardImportJobStatus.completed;
}

class _RoleCardImportJobTile extends StatelessWidget {
  final _RoleCardImportJob job;
  final VoidCallback onShowLog;
  final VoidCallback onDismiss;

  const _RoleCardImportJobTile({
    required this.job,
    required this.onShowLog,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final failed = job.failed;
    final completed = job.completed;
    final statusKind = failed
        ? AppStatusKind.error
        : completed
            ? AppStatusKind.success
            : AppStatusKind.info;
    final palette = AppStatusPalette.of(context, statusKind);
    final colorScheme = Theme.of(context).colorScheme;
    final progress = job.progress.clamp(0, 1).toDouble();
    final detailLine = [
      job.stage,
      if (job.detail.trim().isNotEmpty) job.detail.trim(),
    ].join(' · ');
    final metaItems = [
      if (job.counter.isNotEmpty) job.counter,
      if (job.translate) 'AI 翻译',
    ];
    final tile = ListTile(
      leading: CircleAvatar(
        backgroundColor: palette.container,
        child: Icon(
          failed
              ? Icons.error_outline
              : completed
                  ? Icons.check
                  : Icons.sync,
          color: palette.foreground,
        ),
      ),
      title: Text(
        job.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  detailLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.foreground),
                ),
              ),
              if (!failed && !completed) ...[
                const SizedBox(width: 8),
                Text(
                  '${(progress * 100).round()}%',
                  style: TextStyle(
                    color: palette.foreground,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: failed ? 1 : progress,
            minHeight: 3,
            backgroundColor: colorScheme.surfaceContainerHighest,
            color: palette.foreground,
          ),
          if (metaItems.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final item in metaItems) _ImportJobMetaPill(label: item),
              ],
            ),
          ],
          if (failed && job.error.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              job.error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '任务操作',
        onSelected: (value) {
          if (value == 'log') onShowLog();
          if (value == 'dismiss') onDismiss();
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'log',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.article_outlined),
              title: Text('查看日志'),
            ),
          ),
          if (failed || completed)
            const PopupMenuItem(
              value: 'dismiss',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.close),
                title: Text('移除记录'),
              ),
            ),
        ],
      ),
    );
    return AppVisualSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.only(bottom: 8),
      child: tile,
    );
  }
}

class _ImportJobMetaPill extends StatelessWidget {
  final String label;

  const _ImportJobMetaPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          height: 1.1,
        ),
      ),
    );
  }
}

class _RoleCardImportOptions {
  final bool keepTools;
  final bool keepModelOverride;
  final bool keepDefaultVoice;
  final bool translateToSimplifiedChinese;
  final TranslationRequestProfile? translationProfile;
  final _RoleCardImportConflictMode conflictMode;

  const _RoleCardImportOptions({
    required this.keepTools,
    required this.keepModelOverride,
    required this.keepDefaultVoice,
    this.translateToSimplifiedChinese = false,
    this.translationProfile,
    this.conflictMode = _RoleCardImportConflictMode.rename,
  });

  _RoleCardImportOptions withTranslationProfile(
    TranslationRequestProfile profile,
  ) =>
      _RoleCardImportOptions(
        keepTools: keepTools,
        keepModelOverride: keepModelOverride,
        keepDefaultVoice: keepDefaultVoice,
        translateToSimplifiedChinese: true,
        translationProfile: profile,
        conflictMode: conflictMode,
      );
}

class _RoleCardImportPlan {
  final AssistantRoleCardImportResult result;
  final String renameTargetName;
  final AssistantModel? conflictingAssistant;
  final AssistantMemoryBookMergePreview? mergePreview;

  const _RoleCardImportPlan({
    required this.result,
    required this.renameTargetName,
    this.conflictingAssistant,
    this.mergePreview,
  });

  String get originalName => result.assistant.name.trim();
  bool get hasConflict => conflictingAssistant != null;
  bool get renamed =>
      originalName.isNotEmpty && originalName != renameTargetName;
}

class _RoleCardPreviewDialog extends StatefulWidget {
  final AssistantModel assistant;
  final AssistantRoleCardSummary summary;
  final bool importMode;
  final String? targetName;
  final AssistantModel? conflictingAssistant;
  final AssistantMemoryBookMergePreview? mergePreview;

  const _RoleCardPreviewDialog({
    required this.assistant,
    required this.summary,
    required this.importMode,
    this.targetName,
    this.conflictingAssistant,
    this.mergePreview,
  });

  @override
  State<_RoleCardPreviewDialog> createState() => _RoleCardPreviewDialogState();
}

class _RoleCardPreviewDialogState extends State<_RoleCardPreviewDialog> {
  bool _keepTools = false;
  bool _keepModelOverride = false;
  bool _keepDefaultVoice = false;
  bool _translateToSimplifiedChinese = false;
  _RoleCardImportConflictMode _conflictMode =
      _RoleCardImportConflictMode.rename;

  String _memorySummaryText(AssistantRoleCardSummary summary) {
    if (summary.memoryCount == 0) return '无';
    final parts = <String>[
      '常驻 ${summary.alwaysOnMemoryCount}',
      '关键词 ${summary.keywordMemoryCount}',
      if (summary.disabledMemoryCount > 0) '禁用 ${summary.disabledMemoryCount}',
    ];
    return '${summary.memoryCount} 条（${parts.join(' / ')}）';
  }

  @override
  Widget build(BuildContext context) {
    final assistant = widget.assistant;
    final summary = widget.summary;
    final extensionSafety =
        AssistantRoleCardService.extensionSafetyReport(assistant);
    final targetName = widget.targetName?.trim() ?? '';
    final hasConflict = widget.conflictingAssistant != null;
    final renamed = widget.importMode &&
        targetName.isNotEmpty &&
        targetName != assistant.name.trim();
    final visibleName =
        hasConflict && _conflictMode != _RoleCardImportConflictMode.rename
            ? widget.conflictingAssistant!.name
            : renamed
                ? targetName
                : assistant.name;
    final exampleSnippets = AssistantRoleCardService.examplePreviewSnippets(
      assistant.exampleDialogs,
    );
    final muted = _mutedTextColor(context);
    final info = AppStatusPalette.of(context, AppStatusKind.info);
    final warning = AppStatusPalette.of(context, AppStatusKind.warning);
    return AlertDialog(
      title: Text('${assistant.emoji} $visibleName'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.importMode && hasConflict) ...[
              _RoleCardPreviewLine('原名称', assistant.name.trim()),
              _RoleCardPreviewLine(
                _conflictMode != _RoleCardImportConflictMode.rename
                    ? '覆盖目标'
                    : '导入后名称',
                visibleName,
              ),
              const SizedBox(height: 8),
            ] else if (renamed) ...[
              _RoleCardPreviewLine('原名称', assistant.name.trim()),
              _RoleCardPreviewLine('导入后名称', targetName),
              const SizedBox(height: 8),
            ],
            if (widget.importMode && hasConflict) ...[
              Text(
                '重名处理',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: info.foreground,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  '覆盖时默认保留本地工具、模型和语音设置；下方安全选项勾选后才使用外部卡配置。',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
              RadioGroup<_RoleCardImportConflictMode>(
                groupValue: _conflictMode,
                onChanged: (value) => setState(
                  () => _conflictMode =
                      value ?? _RoleCardImportConflictMode.rename,
                ),
                child: Column(
                  children: [
                    RadioListTile<_RoleCardImportConflictMode>(
                      contentPadding: EdgeInsets.zero,
                      value: _RoleCardImportConflictMode.rename,
                      title: const Text('另存为新角色'),
                      subtitle:
                          Text(targetName.isEmpty ? '自动追加编号' : targetName),
                    ),
                    RadioListTile<_RoleCardImportConflictMode>(
                      contentPadding: EdgeInsets.zero,
                      value: _RoleCardImportConflictMode.overwrite,
                      title: const Text('覆盖同名角色'),
                      subtitle: Text(
                        '更新「${widget.conflictingAssistant!.name}」，保留会话绑定',
                      ),
                    ),
                    RadioListTile<_RoleCardImportConflictMode>(
                      contentPadding: EdgeInsets.zero,
                      value: _RoleCardImportConflictMode.mergeMemoryBook,
                      title: const Text('覆盖并合并世界书'),
                      subtitle: Text(widget.mergePreview?.compactSummary ??
                          '更新角色内容，但旧世界书未重复条目会保留'),
                    ),
                  ],
                ),
              ),
              if (_conflictMode == _RoleCardImportConflictMode.mergeMemoryBook)
                _RoleCardMergeMemoryPreview(preview: widget.mergePreview),
              const SizedBox(height: 8),
            ],
            if (assistant.description.trim().isNotEmpty) ...[
              Text(
                assistant.description.trim(),
                style: TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 12),
            ],
            _RoleCardPreviewLine('系统提示词', '${summary.promptChars} 字'),
            _RoleCardPreviewLine('开场白',
                summary.openingChars == 0 ? '无' : '${summary.openingChars} 字'),
            _RoleCardPreviewLine(
                '示例对话',
                summary.exampleDialogLines == 0
                    ? '无'
                    : '${summary.exampleDialogLines} 行'),
            if (summary.alternateGreetingCount > 0)
              _RoleCardPreviewLine(
                  '备选开场', '${summary.alternateGreetingCount} 条'),
            if (exampleSnippets.isNotEmpty) ...[
              const SizedBox(height: 2),
              for (final snippet in exampleSnippets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    snippet,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
            ],
            _RoleCardPreviewLine(
              '关键词记忆',
              _memorySummaryText(summary),
            ),
            _RoleCardPreviewLine(
                '默认语音',
                summary.hasDefaultVoice
                    ? assistant.defaultVoiceStyle.trim()
                    : '跟随会话'),
            _RoleCardPreviewLine(
                '模型覆盖',
                summary.hasModelOverride
                    ? [
                        if (assistant.providerId.trim().isNotEmpty)
                          assistant.providerId.trim(),
                        if (assistant.model.trim().isNotEmpty)
                          assistant.model.trim(),
                      ].join(' / ')
                    : '跟随全局'),
            _RoleCardPreviewLine(
                '工具', assistant.useTools ? '${summary.toolCount} 个绑定' : '已关闭'),
            if (extensionSafety.hasBlockedExtensions) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: warning.container,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: warning.foreground.withValues(alpha: 0.18),
                  ),
                ),
                child: Text(
                  extensionSafety.warningText,
                  style: TextStyle(fontSize: 12, color: warning.onContainer),
                ),
              ),
            ],
            if (widget.importMode) ...[
              const SizedBox(height: 12),
              Text(
                '语言转换',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: info.foreground,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _translateToSimplifiedChinese,
                onChanged: (v) => setState(
                  () => _translateToSimplifiedChinese = v ?? false,
                ),
                title: const Text('使用当前 AI 配置翻译为简体中文'),
                subtitle: const Text('会调用当前 AI 服务商并产生用量成本；只翻译角色文本内容'),
              ),
            ],
            if (widget.importMode &&
                (summary.toolCount > 0 ||
                    !assistant.useTools ||
                    summary.hasModelOverride ||
                    summary.hasDefaultVoice)) ...[
              const SizedBox(height: 12),
              Text(
                '导入安全选项',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: warning.foreground,
                ),
              ),
              const SizedBox(height: 4),
              if (summary.toolCount > 0 || !assistant.useTools)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _keepTools,
                  onChanged: (v) => setState(() => _keepTools = v ?? false),
                  title: const Text('使用外部卡工具绑定 / 工具开关'),
                  subtitle: const Text('默认保留本地工具配置，避免外部角色卡改变工具暴露范围'),
                ),
              if (summary.hasModelOverride)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _keepModelOverride,
                  onChanged: (v) =>
                      setState(() => _keepModelOverride = v ?? false),
                  title: const Text('使用外部卡模型覆盖'),
                  subtitle: const Text('默认保留本地模型配置，避免导入后切到不可用服务商'),
                ),
              if (summary.hasDefaultVoice)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _keepDefaultVoice,
                  onChanged: (v) =>
                      setState(() => _keepDefaultVoice = v ?? false),
                  title: const Text('使用外部卡默认语音'),
                  subtitle: const Text('默认保留本地语音配置，避免引用本机不存在的自定义音色'),
                ),
            ],
            if (summary.memoryEntries.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('世界书预览',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              for (final entry in summary.memoryEntries.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${entry.label}：${entry.content}',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              if (summary.memoryEntries.length > 5)
                Text('还有 ${summary.memoryEntries.length - 5} 条未展示',
                    style: TextStyle(fontSize: 12, color: muted)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.importMode ? '取消' : '关闭')),
        if (widget.importMode)
          FilledButton(
              onPressed: () => Navigator.pop(
                    context,
                    _RoleCardImportOptions(
                      keepTools: _keepTools,
                      keepModelOverride: _keepModelOverride,
                      keepDefaultVoice: _keepDefaultVoice,
                      translateToSimplifiedChinese:
                          _translateToSimplifiedChinese,
                      conflictMode: _conflictMode,
                    ),
                  ),
              child: const Text('导入')),
      ],
    );
  }
}

class _RoleCardBatchPreviewTile extends StatelessWidget {
  final _RoleCardImportPlan plan;
  final _RoleCardImportConflictMode conflictMode;

  const _RoleCardBatchPreviewTile({
    required this.plan,
    required this.conflictMode,
  });

  @override
  Widget build(BuildContext context) {
    final result = plan.result;
    final assistant = result.assistant;
    final sourceName = _basename(result.sourceName);
    final overwrite = conflictMode != _RoleCardImportConflictMode.rename &&
        plan.conflictingAssistant != null;
    final targetName =
        overwrite ? plan.conflictingAssistant!.name : plan.renameTargetName;
    final summaryText = AssistantRoleCardService.importPreviewSummaryText(
      assistant,
      hasAvatar: result.avatarPngBytes != null,
    );
    final extensionSafety =
        AssistantRoleCardService.extensionSafetyReport(assistant);
    final detail = [
      if (sourceName.isNotEmpty) sourceName,
      if (overwrite &&
          conflictMode == _RoleCardImportConflictMode.mergeMemoryBook)
        '合并世界书：${plan.mergePreview?.compactSummary ?? '无可预览'}',
      if (overwrite && conflictMode == _RoleCardImportConflictMode.overwrite)
        '将覆盖 ${plan.conflictingAssistant!.name}',
      if (!overwrite && plan.renamed) '原名 ${plan.originalName}',
      summaryText,
      if (extensionSafety.hasBlockedExtensions) '含未执行的第三方扩展',
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AssistantAvatar(assistant: assistant),
      title: Text(targetName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  String _basename(String? path) {
    if (path == null || path.trim().isEmpty) return '';
    final parts =
        path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path.trim() : parts.last;
  }
}

class _RoleCardMergeMemoryPreview extends StatelessWidget {
  final AssistantMemoryBookMergePreview? preview;

  const _RoleCardMergeMemoryPreview({required this.preview});

  @override
  Widget build(BuildContext context) {
    final data = preview;
    if (data == null) return const SizedBox.shrink();
    final appended = data.appendedPreviewLines();
    final muted = _mutedTextColor(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            data.compactSummary,
            style: TextStyle(fontSize: 12, color: muted),
          ),
          if (appended.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '将追加：',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            for (final line in appended)
              Text(
                '- $line',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: muted),
              ),
            if (data.appendedCount > appended.length)
              Text(
                '还有 ${data.appendedCount - appended.length} 条未展示',
                style: TextStyle(
                  fontSize: 12,
                  color: muted.withValues(alpha: 0.72),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RoleCardPreviewLine extends StatelessWidget {
  final String label;
  final String value;

  const _RoleCardPreviewLine(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text('$label：$value', style: const TextStyle(fontSize: 13)),
    );
  }
}
