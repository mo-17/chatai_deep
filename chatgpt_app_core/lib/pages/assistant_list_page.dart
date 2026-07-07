import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_conversation_factory.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
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
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_market_page.dart';
import 'package:chatgpt_app_core/pages/assistant_memory_page.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

final _roleCardImportCoordinator = _RoleCardImportCoordinator();

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

  @override
  void initState() {
    super.initState();
    _roleCardImportCoordinator.addListener(_handleRoleCardImportChanged);
    _doInit();
  }

  @override
  void dispose() {
    _roleCardImportCoordinator.removeListener(_handleRoleCardImportChanged);
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
  }

  void _doInit() async {
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    _dao = await AssistantDao.create(dbManager);
    await _loadData();
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
              onPressed: _importRoleCardFile,
            ),
          if (Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: '导入技能（.zip，含 SKILL.md）',
              onPressed: _importSkillZip,
            ),
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            tooltip: '助手市场',
            onPressed: _openMarket,
          ),
        ],
      ),
      body: _assistants.isEmpty && _roleCardImportCoordinator.jobs.isEmpty
          ? _emptyView
          : _listView,
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        tooltip: '新建助手',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _emptyView => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🤖', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('还没有助手，点右下角新建，或从右上角「助手市场」挑一个',
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center),
          ],
        ),
      );

  Widget get _listView => ListView.builder(
        itemCount: _roleCardImportCoordinator.jobs.length + _assistants.length,
        itemBuilder: (context, index) {
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
          return ListTile(
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
                      style:
                          TextStyle(color: Colors.blueGrey[700], fontSize: 12),
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
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ),
                if (hasConflicts) ...[
                  const SizedBox(height: 12),
                  Text(
                    '重名处理',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Colors.blueGrey[700],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 2),
                    child: Text(
                      '覆盖时默认保留本地工具、模型和语音设置；下方安全选项勾选后才使用外部卡配置。',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
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
                          dense: true,
                          value: _RoleCardImportConflictMode.rename,
                          title: Text('另存为新角色'),
                          subtitle: Text('自动追加编号，不影响已有助手'),
                        ),
                        RadioListTile<_RoleCardImportConflictMode>(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: _RoleCardImportConflictMode.overwrite,
                          title: Text('覆盖同名角色'),
                          subtitle: Text('更新已有助手内容，保留原助手名称和会话绑定'),
                        ),
                        RadioListTile<_RoleCardImportConflictMode>(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
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
                              color: Colors.orange[800], fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        for (final item in skipped.take(3))
                          Text(
                            '${item.name}：${item.reason}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 12),
                          ),
                        if (skipped.length > 3)
                          Text(
                            '还有 ${skipped.length - 3} 个文件未展示',
                            style: const TextStyle(
                                color: Colors.black45, fontSize: 12),
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
                    color: Colors.blueGrey[700],
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
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
                      color: Colors.orange[800],
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: keepTools,
                    onChanged: (v) =>
                        setDialogState(() => keepTools = v ?? false),
                    title: const Text('使用外部卡工具绑定 / 工具开关'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: keepModelOverride,
                    onChanged: (v) =>
                        setDialogState(() => keepModelOverride = v ?? false),
                    title: const Text('使用外部卡模型覆盖'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
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
          if (!mounted) return;
          _roleCardImportCoordinator.startTavernRoom(
            results: [importResults.single],
            sourceTitle: '',
            translateToSimplifiedChinese: true,
            settings: context.read<AISettingsProvider>().settings.clone(),
          );
          HiDialog.showSnackBar(context, '已开始后台创建酒馆房间');
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
          if (!mounted) return;
          _roleCardImportCoordinator.startTavernRoom(
            results: importResults,
            sourceTitle: _stripExtension(_basename(path)),
            translateToSimplifiedChinese: true,
            settings: context.read<AISettingsProvider>().settings.clone(),
          );
          HiDialog.showSnackBar(context, '已开始后台创建酒馆房间');
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
    final options = importPlans.length == 1
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

    _roleCardImportCoordinator.start(
      plans: importPlans,
      options: options,
      settings: context.read<AISettingsProvider>().settings.clone(),
    );
  }

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
                  style: TextStyle(color: Colors.blueGrey[700], fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text(
                  '合并成酒馆房间会把每张卡作为房间角色，并把各卡世界书汇总为共享上下文；普通助手导入则保持现有批量导入和重名处理流程。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
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
                  style: TextStyle(color: Colors.blueGrey[700], fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text(
                  '创建酒馆房间会把主卡内容作为公共上下文，把可识别的世界书角色加入房间参与者；也可以继续按普通助手导入。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
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
    final prepared = await _prepareTavernRoleCardResults(
      [result],
      translateToSimplifiedChinese: translateToSimplifiedChinese,
    );
    if (prepared == null || prepared.isEmpty) return;
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
    final prepared = await _prepareTavernRoleCardResults(
      results,
      translateToSimplifiedChinese: translateToSimplifiedChinese,
    );
    if (prepared == null || prepared.isEmpty) return;
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

  Future<List<AssistantRoleCardImportResult>?> _prepareTavernRoleCardResults(
    List<AssistantRoleCardImportResult> results, {
    required bool translateToSimplifiedChinese,
  }) async {
    if (!translateToSimplifiedChinese) return results;
    final progress = ValueNotifier<_TavernTranslationProgress>(
      _TavernTranslationProgress(
        current: 0,
        total: results.length,
        name: results.first.assistant.name,
        stage: '准备翻译',
      ),
    );
    if (!mounted) return null;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _TavernTranslationProgressDialog(progress: progress),
    ));
    try {
      final settings = context.read<AISettingsProvider>().settings.clone();
      final chatService = ChatService.from(settings);
      return await TavernRoomImportPreparer.prepare(
        results,
        translateToSimplifiedChinese: true,
        complete: (prompt) => chatService.chat(
          prompt: prompt,
          history: const [],
          timeout: const Duration(minutes: 2),
        ),
        onProgress: (value) {
          progress.value = _TavernTranslationProgress(
            current: value.current,
            total: value.total,
            name: value.name,
            stage: value.stage,
          );
        },
      );
    } on FormatException catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '翻译失败：${e.message}');
      return null;
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '翻译失败：$e');
      return null;
    } finally {
      if (mounted) {
        await Navigator.of(context, rootNavigator: true).maybePop();
      }
      progress.dispose();
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
      builder: (context) => AlertDialog(
        title: const Text('导入失败日志'),
        content: SingleChildScrollView(
          child: SelectableText(
            job.log.trim().isEmpty ? job.error : job.log,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

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
                    style: TextStyle(color: Colors.grey[700], fontSize: 13)),
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
                  style: TextStyle(color: Colors.orange[800], fontSize: 13),
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
    await _dao!.deleteAssistant(a.id!);
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

  const _TavernRoomImportOptions({
    required this.target,
    this.translateToSimplifiedChinese = false,
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

class _TavernTranslationProgress {
  final int current;
  final int total;
  final String name;
  final String stage;

  const _TavernTranslationProgress({
    required this.current,
    required this.total,
    required this.name,
    required this.stage,
  });

  double get value {
    if (total <= 0) return nullSafeProgress;
    final base = (current - 1).clamp(0, total) / total;
    return base.clamp(0, 1).toDouble();
  }

  static const nullSafeProgress = 0.0;
}

class _TavernTranslationProgressDialog extends StatelessWidget {
  final ValueListenable<_TavernTranslationProgress> progress;

  const _TavernTranslationProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在翻译角色卡'),
      content: ValueListenableBuilder<_TavernTranslationProgress>(
        valueListenable: progress,
        builder: (context, value, _) {
          final ratio = value.total <= 0
              ? 0.0
              : (value.current / value.total).clamp(0, 1).toDouble();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value.name.trim().isEmpty ? '未命名角色' : value.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '${value.stage} · ${value.current}/${value.total}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: ratio),
            ],
          );
        },
      ),
    );
  }
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
        _run(jobs: jobs, plans: plans, options: options, settings: settings));
  }

  void startTavernRoom({
    required List<AssistantRoleCardImportResult> results,
    required String sourceTitle,
    required bool translateToSimplifiedChinese,
    required AISettings settings,
  }) {
    if (results.isEmpty) return;
    final job = _RoleCardImportJob.tavernRoom(
      title: sourceTitle.trim().isEmpty
          ? _fallbackTavernRoomTitle(results)
          : sourceTitle.trim(),
      translate: translateToSimplifiedChinese,
    );
    _jobs.insert(0, job);
    notifyListeners();
    unawaited(_runTavernRoom(
      job: job,
      results: results,
      sourceTitle: sourceTitle,
      translateToSimplifiedChinese: translateToSimplifiedChinese,
      settings: settings,
    ));
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
  }) async {
    AssistantDao? dao;
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      dao = await AssistantDao.create(dbManager);
    } catch (e, stackTrace) {
      for (final job in jobs) {
        _failJob(job, options, e, stackTrace, stage: '初始化数据库失败');
      }
      return;
    }

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
        );
        _update(
          job,
          stage: '正在保存',
          displayName: assistant.name,
          progress: 0.78,
        );
        await dao.saveAssistant(assistant);
        _update(
          job,
          status: _RoleCardImportJobStatus.completed,
          stage: '已保存',
          displayName: assistant.name,
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

  Future<void> _runTavernRoom({
    required _RoleCardImportJob job,
    required List<AssistantRoleCardImportResult> results,
    required String sourceTitle,
    required bool translateToSimplifiedChinese,
    required AISettings settings,
  }) async {
    try {
      _update(
        job,
        status: _RoleCardImportJobStatus.running,
        stage: translateToSimplifiedChinese ? '等待 AI 翻译返回' : '正在创建房间',
        progress: translateToSimplifiedChinese ? 0.12 : 0.45,
      );
      final chatService = ChatService.from(settings);
      final prepared = await TavernRoomImportPreparer.prepare(
        results,
        translateToSimplifiedChinese: translateToSimplifiedChinese,
        complete: (prompt) => chatService.chat(
          prompt: prompt,
          history: const [],
          timeout: const Duration(minutes: 2),
        ),
        onProgress: (value) {
          _update(
            job,
            stage: value.stage,
            displayName: value.name,
            progress: 0.12 + (0.58 * value.current / value.total),
          );
        },
      );
      _update(job, stage: '正在保存模板', progress: 0.76);
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final dao = await StoryRoomDao.create(dbManager);
      final existingTitles = (await dao.getRooms()).map((room) => room.title);
      final title = AssistantRoleCardService.uniqueImportName(
        _tavernRoomTitle(prepared, sourceTitle),
        existingTitles,
      );
      final importer = StoryRoomRoleCardImportService(dao);
      final template = await _saveTavernRoomTemplate(
        dbManager,
        prepared,
        title: title,
        sourceTitle: sourceTitle,
        translated: translateToSimplifiedChinese,
      );
      _update(job, stage: '正在创建房间', progress: 0.84);
      final roomId = await importer.createRoomFromTemplate(template);
      _update(
        job,
        status: _RoleCardImportJobStatus.completed,
        stage: '已创建房间 #$roomId',
        displayName: title,
        progress: 1,
      );
      _completedTick += 1;
      notifyListeners();
    } catch (e, stackTrace) {
      _failJob(
        job,
        _RoleCardImportOptions(
          keepTools: false,
          keepModelOverride: false,
          keepDefaultVoice: false,
          translateToSimplifiedChinese: translateToSimplifiedChinese,
        ),
        e,
        stackTrace,
        stage: '创建酒馆房间失败',
      );
    }
  }

  void _update(
    _RoleCardImportJob job, {
    _RoleCardImportJobStatus? status,
    String? stage,
    String? displayName,
    double? progress,
  }) {
    if (!_jobs.contains(job)) return;
    if (status != null) job.status = status;
    if (stage != null) job.stage = stage;
    if (displayName != null) job.displayName = displayName;
    if (progress != null) job.progress = progress.clamp(0, 1).toDouble();
    notifyListeners();
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
    final targetLabel = job.tavernRoom ? '酒馆房间导入' : '角色卡导入';
    job.log = [
      '$targetLabel失败',
      '名称：${job.displayName}',
      '阶段：${job.stage}',
      '翻译：${options.translateToSimplifiedChinese ? '是' : '否'}',
      '错误：$error',
      '',
      stackTrace.toString(),
    ].join('\n');
    notifyListeners();
  }

  Future<AssistantModel> _prepareImportedRoleCard(
    _RoleCardImportPlan plan,
    _RoleCardImportOptions options,
    AISettings settings,
  ) async {
    var incoming = plan.result.assistant;
    if (options.translateToSimplifiedChinese) {
      incoming = await _translateImportedRoleCard(incoming, settings);
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
          extension: '.png',
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

  static String _tavernRoomTitle(
    List<AssistantRoleCardImportResult> results,
    String sourceTitle,
  ) {
    final source = sourceTitle.trim();
    if (source.isNotEmpty) return source;
    return _fallbackTavernRoomTitle(results);
  }

  static String _fallbackTavernRoomTitle(
    List<AssistantRoleCardImportResult> results,
  ) {
    if (results.isEmpty) return '酒馆房间';
    final first = results.first.assistant.name.trim();
    if (first.isEmpty) return '酒馆房间';
    return results.length == 1 ? first : '$first 等 ${results.length} 人';
  }

  Future<AssistantModel> _translateImportedRoleCard(
    AssistantModel assistant,
    AISettings settings,
  ) async {
    final chatService = ChatService.from(settings);
    try {
      return await AssistantRoleCardTranslationService
          .translateToSimplifiedChinese(
        assistant,
        complete: (prompt) => chatService.chat(
          prompt: prompt,
          history: const [],
          timeout: const Duration(minutes: 2),
        ),
      );
    } on FormatException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('翻译角色卡失败：$e');
    }
  }
}

enum _RoleCardImportJobStatus { queued, running, completed, failed }

enum _RoleCardImportJobKind { assistant, tavernRoom }

class _RoleCardImportJob {
  final int total;
  final int index;
  final bool translate;
  final _RoleCardImportJobKind kind;
  String displayName;
  String stage;
  double progress = 0;
  String error = '';
  String log = '';
  _RoleCardImportJobStatus status = _RoleCardImportJobStatus.queued;

  _RoleCardImportJob({
    required this.total,
    required this.index,
    required this.translate,
    this.kind = _RoleCardImportJobKind.assistant,
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
      kind: _RoleCardImportJobKind.assistant,
      displayName: targetName.trim().isEmpty
          ? plan.result.assistant.name
          : targetName.trim(),
      stage: translate ? '等待翻译' : '等待导入',
    );
  }

  factory _RoleCardImportJob.tavernRoom({
    required String title,
    required bool translate,
  }) {
    return _RoleCardImportJob(
      total: 1,
      index: 1,
      translate: translate,
      kind: _RoleCardImportJobKind.tavernRoom,
      displayName: title.trim().isEmpty ? '酒馆房间' : title.trim(),
      stage: translate ? '等待翻译' : '等待创建房间',
    );
  }

  String get counter => total <= 1 ? '' : '$index / $total';
  bool get failed => status == _RoleCardImportJobStatus.failed;
  bool get running => status == _RoleCardImportJobStatus.running;
  bool get completed => status == _RoleCardImportJobStatus.completed;
  bool get tavernRoom => kind == _RoleCardImportJobKind.tavernRoom;
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
    final color = failed
        ? Colors.red[700]
        : completed
            ? Colors.green[700]
            : Colors.blueGrey[700];
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: failed
            ? Colors.red[50]
            : completed
                ? Colors.green[50]
                : Colors.blueGrey[50],
        child: Icon(
          failed
              ? Icons.error_outline
              : completed
                  ? (job.tavernRoom ? Icons.meeting_room_outlined : Icons.check)
                  : Icons.sync,
          color: color,
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
          Text(
            [
              job.stage,
              if (job.counter.isNotEmpty) job.counter,
              if (job.translate) 'AI 翻译',
              if (job.tavernRoom) '酒馆房间',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: failed ? 1 : job.progress.clamp(0, 1).toDouble(),
            minHeight: 3,
            backgroundColor: Colors.black12,
            color: failed ? Colors.red[300] : Colors.blueGrey[400],
          ),
          if (failed && job.error.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              job.error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ],
      ),
      trailing: failed
          ? PopupMenuButton<String>(
              tooltip: '失败记录',
              onSelected: (value) {
                if (value == 'log') onShowLog();
                if (value == 'dismiss') onDismiss();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'log',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.article_outlined),
                    title: Text('查看日志'),
                  ),
                ),
                PopupMenuItem(
                  value: 'dismiss',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.close),
                    title: Text('移除记录'),
                  ),
                ),
              ],
            )
          : completed
              ? IconButton(
                  tooltip: '移除记录',
                  icon: const Icon(Icons.close),
                  onPressed: onDismiss,
                )
              : const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
    );
  }
}

class _RoleCardImportOptions {
  final bool keepTools;
  final bool keepModelOverride;
  final bool keepDefaultVoice;
  final bool translateToSimplifiedChinese;
  final _RoleCardImportConflictMode conflictMode;

  const _RoleCardImportOptions({
    required this.keepTools,
    required this.keepModelOverride,
    required this.keepDefaultVoice,
    this.translateToSimplifiedChinese = false,
    this.conflictMode = _RoleCardImportConflictMode.rename,
  });
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
                  color: Colors.blueGrey[700],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  '覆盖时默认保留本地工具、模型和语音设置；下方安全选项勾选后才使用外部卡配置。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
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
                      dense: true,
                      value: _RoleCardImportConflictMode.rename,
                      title: const Text('另存为新角色'),
                      subtitle:
                          Text(targetName.isEmpty ? '自动追加编号' : targetName),
                    ),
                    RadioListTile<_RoleCardImportConflictMode>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _RoleCardImportConflictMode.overwrite,
                      title: const Text('覆盖同名角色'),
                      subtitle: Text(
                        '更新「${widget.conflictingAssistant!.name}」，保留会话绑定',
                      ),
                    ),
                    RadioListTile<_RoleCardImportConflictMode>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
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
                style: TextStyle(color: Colors.grey[700], fontSize: 13),
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
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
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
            if (widget.importMode) ...[
              const SizedBox(height: 12),
              Text(
                '语言转换',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Colors.blueGrey[700],
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
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
                  color: Colors.orange[800],
                ),
              ),
              const SizedBox(height: 4),
              if (summary.toolCount > 0 || !assistant.useTools)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _keepTools,
                  onChanged: (v) => setState(() => _keepTools = v ?? false),
                  title: const Text('使用外部卡工具绑定 / 工具开关'),
                  subtitle: const Text('默认保留本地工具配置，避免外部角色卡改变工具暴露范围'),
                ),
              if (summary.hasModelOverride)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _keepModelOverride,
                  onChanged: (v) =>
                      setState(() => _keepModelOverride = v ?? false),
                  title: const Text('使用外部卡模型覆盖'),
                  subtitle: const Text('默认保留本地模型配置，避免导入后切到不可用服务商'),
                ),
              if (summary.hasDefaultVoice)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
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
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              if (summary.memoryEntries.length > 5)
                Text('还有 ${summary.memoryEntries.length - 5} 条未展示',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
    final detail = [
      if (sourceName.isNotEmpty) sourceName,
      if (overwrite &&
          conflictMode == _RoleCardImportConflictMode.mergeMemoryBook)
        '合并世界书：${plan.mergePreview?.compactSummary ?? '无可预览'}',
      if (overwrite && conflictMode == _RoleCardImportConflictMode.overwrite)
        '将覆盖 ${plan.conflictingAssistant!.name}',
      if (!overwrite && plan.renamed) '原名 ${plan.originalName}',
      summaryText,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
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
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            data.compactSummary,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          if (appended.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text(
              '将追加：',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            for (final line in appended)
              Text(
                '- $line',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black45),
              ),
            if (data.appendedCount > appended.length)
              Text(
                '还有 ${data.appendedCount - appended.length} 条未展示',
                style: const TextStyle(fontSize: 12, color: Colors.black38),
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
