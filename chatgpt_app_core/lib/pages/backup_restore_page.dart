import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

///备份与恢复页（阶段八）：导出 zip / 导入恢复。
///文件选择走 file_picker（与阶段四附件同一插件），核心逻辑在 [BackupService]。
class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class BackupImportPreviewDialog extends StatefulWidget {
  final BackupPreview preview;

  const BackupImportPreviewDialog({super.key, required this.preview});

  @override
  State<BackupImportPreviewDialog> createState() =>
      _BackupImportPreviewDialogState();
}

class _BackupImportPreviewDialogState extends State<BackupImportPreviewDialog> {
  BackupImportMode _mode = BackupImportMode.overwriteAll;

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final theme = Theme.of(context);
    final warning = widget.preview.warnings.isEmpty
        ? ''
        : '\n\n${widget.preview.warnings.join('\n')}';
    return AlertDialog(
      title: const Text('导入预览'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_previewText(widget.preview)),
            if (warning.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(warning.trim()),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<BackupImportMode>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: '导入方式'),
              items: const [
                DropdownMenuItem(
                  value: BackupImportMode.overwriteAll,
                  child: Text('覆盖全部'),
                ),
                DropdownMenuItem(
                  value: BackupImportMode.projectConversationsOnly,
                  child: Text('仅导入项目和会话'),
                ),
                DropdownMenuItem(
                  value: BackupImportMode.assistantsOnly,
                  child: Text('仅导入助手'),
                ),
                DropdownMenuItem(
                  value: BackupImportMode.knowledgeBaseOnly,
                  child: Text('仅导入知识库'),
                ),
                DropdownMenuItem(
                  value: BackupImportMode.mergeAppend,
                  child: Text('合并导入'),
                ),
              ],
              onChanged: (value) => setState(() => _mode = value ?? _mode),
            ),
            const SizedBox(height: 8),
            Text(
              _modeWarning(_mode),
              style: visual.isAnime
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            Text(_impactText(widget.preview, _mode)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, _mode),
          style: visual.isAnime && _mode != BackupImportMode.mergeAppend
              ? TextButton.styleFrom(foregroundColor: theme.colorScheme.error)
              : null,
          child: Text(_confirmText(_mode)),
        ),
      ],
    );
  }

  static String _confirmText(BackupImportMode mode) {
    switch (mode) {
      case BackupImportMode.overwriteAll:
        return '覆盖导入';
      case BackupImportMode.projectConversationsOnly:
        return '仅导入项目和会话';
      case BackupImportMode.assistantsOnly:
        return '仅导入助手';
      case BackupImportMode.knowledgeBaseOnly:
        return '仅导入知识库';
      case BackupImportMode.mergeAppend:
        return '合并导入';
    }
  }

  static String _modeWarning(BackupImportMode mode) {
    switch (mode) {
      case BackupImportMode.overwriteAll:
        return '覆盖全部不可撤销。建议先导出一份当前数据。';
      case BackupImportMode.projectConversationsOnly:
        return '仅项目和会话导入会替换项目、会话和消息，并保留助手、收藏、知识库和 AI 设置。';
      case BackupImportMode.assistantsOnly:
        return '仅助手导入会替换助手列表，并解除无法匹配新助手集的会话/项目助手引用。';
      case BackupImportMode.knowledgeBaseOnly:
        return '仅知识库导入不会修改会话、消息、助手、收藏、项目和 AI 设置。';
      case BackupImportMode.mergeAppend:
        return '合并导入会追加为新数据；同 ID/cid 会自动重映射，不覆盖本地数据和 AI 设置。';
    }
  }

  static String _impactText(BackupPreview preview, BackupImportMode mode) {
    final plan = preview.planFor(mode);
    final localOnlyLabel = switch (mode) {
      BackupImportMode.overwriteAll => '仅本地数据将删除',
      BackupImportMode.projectConversationsOnly => '仅本地项目/会话/消息将删除',
      BackupImportMode.assistantsOnly => '仅本地助手将删除',
      BackupImportMode.knowledgeBaseOnly => '仅本地知识库数据将删除',
      BackupImportMode.mergeAppend => '仅本地数据将保留',
    };
    if (mode == BackupImportMode.mergeAppend) {
      return '预计影响：${plan.scope}；追加 ${plan.backupOnlyRows} 行，'
          '其中 ${plan.replacingRows} 行同 ID/cid 会重映射，'
          '内容不同 ${plan.changedRows} 行，$localOnlyLabel ${plan.localRows} 行。';
    }
    return '预计影响：${plan.scope}；覆盖 ${plan.replacingRows} 行，'
        '内容不同 ${plan.changedRows} 行，新增 ${plan.backupOnlyRows} 行，'
        '$localOnlyLabel ${plan.localOnlyRows} 行。';
  }

  static String _previewText(BackupPreview preview) {
    String exportedAtText() {
      if (preview.exportedAt <= 0) return '未知';
      final at = DateTime.fromMillisecondsSinceEpoch(preview.exportedAt);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${at.year}-${two(at.month)}-${two(at.day)} '
          '${two(at.hour)}:${two(at.minute)}';
    }

    return [
      '备份版本：v${preview.formatVersion}',
      '导出时间：${exportedAtText()}',
      if (preview.accountHash.isNotEmpty) '来源账号：${preview.accountHash}',
      'AI 设置：${preview.hasSettings ? '包含' : '不包含'}'
          '${preview.includeApiKeys ? '（含 API Key）' : '（不含 API Key）'}',
      '会话：${preview.conversations}',
      '消息：${preview.messages}',
      '助手：${preview.assistants}',
      '收藏：${preview.favorites}',
      '项目：${preview.projects}',
      '知识库文档：${preview.knowledgeDocs}',
      '知识库片段：${preview.knowledgeChunks}',
      '项目知识库绑定：${preview.projectKnowledge}',
      '头像资源：${preview.avatarAssets}',
      '附件原始文件：${preview.fileAssets}',
      '生成图片：${preview.generatedImageAssets}',
      if (preview.conflictSummary.hasLocalData) ...[
        '',
        '当前本地数据：${preview.conflictSummary.localRows} 行',
        '同 ID 覆盖：${preview.conflictSummary.replacingRows} 行',
        '内容不同：${preview.conflictSummary.changedRows} 行',
        '仅本地存在：${preview.conflictSummary.localOnlyRows} 行',
        '仅备份存在：${preview.conflictSummary.backupOnlyRows} 行',
        for (final item in preview.conflictSummary.tableConflicts
            .where((item) => item.hasConflict)
            .take(4))
          '${item.table}：覆盖 ${item.replacingRows}，不同 ${item.changedRows}，'
              '仅本地 ${item.localOnlyRows}',
      ],
    ].join('\n');
  }
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  ///备份是否包含 API Key（默认脱敏，避免备份文件外流泄露 key）。
  bool _includeApiKeys = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final theme = Theme.of(context);
    final description = Text(
      '备份内容：会话、聊天记录（含思考/工具等块数据）、助手、收藏、AI 设置。'
      '按当前登录账号导出/导入。',
      style: visual.isAnime
          ? theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )
          : const TextStyle(color: Colors.grey),
    );
    final apiKeyTile = SwitchListTile(
      contentPadding: visual.isAnime
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 4)
          : EdgeInsets.zero,
      title: const Text('备份包含 API Key'),
      subtitle: const Text('默认不包含，防止备份文件外流时泄露密钥'),
      value: _includeApiKeys,
      onChanged: (v) => setState(() => _includeApiKeys = v),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (visual.isAnime)
            AppVisualSurface(
              animeKey: const ValueKey('backup_intro_surface'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: description),
                ],
              ),
            )
          else
            description,
          const SizedBox(height: 16),
          if (visual.isAnime)
            AppVisualSurface(
              padding: EdgeInsets.zero,
              child: apiKeyTile,
            )
          else
            apiKeyTile,
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.upload_file),
            label: const Text('导出备份'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.restore),
            label: const Text('导入恢复'),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Future<BackupService> _service() async {
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    return BackupService(dbManager);
  }

  String _fileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'chatgpt_backup_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
  }

  ///file_picker 暂未支持鸿蒙（与消息输入框的文件入口同口径）。
  bool get _pickerUnsupported => Platform.operatingSystem == 'ohos';

  void _export() async {
    if (_pickerUnsupported) {
      HiDialog.showSnackBar(context, '鸿蒙版本暂不支持备份文件选择，敬请期待');
      return;
    }
    setState(() => _busy = true);
    try {
      final settings = context.read<AISettingsProvider>().settings;
      final service = await _service();
      final bytes = await service.exportArchive(
        settings: settings,
        accountHash: HiDBManager.getAccountHash(),
        includeApiKeys: _includeApiKeys,
      );
      // 移动端 saveFile 由插件代写 bytes；桌面端只返回路径，需自行写文件。
      final path = await FilePicker.saveFile(
        dialogTitle: '保存备份',
        fileName: _fileName(),
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        bytes: bytes,
      );
      if (path == null) return; // 用户取消
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已导出备份（${_sizeText(bytes.length)}）');
    } catch (e) {
      AILogger.log('backup export failed: $e');
      if (!mounted) return;
      HiDialog.showSnackBar(context, '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _import() async {
    if (_pickerUnsupported) {
      HiDialog.showSnackBar(context, '鸿蒙版本暂不支持备份文件选择，敬请期待');
      return;
    }
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择备份文件',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: true,
    );
    final file = picked?.files.firstOrNull;
    if (file == null || !mounted) return; // 用户取消
    final bytes = file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) {
      if (mounted) HiDialog.showSnackBar(context, '读取备份文件失败');
      return;
    }
    if (!mounted) return;

    final BackupPreview preview;
    try {
      final service = await _service();
      preview = await service.previewArchive(
        bytes,
        accountHash: HiDBManager.getAccountHash(),
      );
    } on FormatException catch (e) {
      if (mounted) HiDialog.showSnackBar(context, e.message);
      return;
    } catch (e) {
      AILogger.log('backup preview failed: $e');
      if (mounted) HiDialog.showSnackBar(context, '读取备份文件失败：$e');
      return;
    }
    if (!mounted) return;

    final mode = await _confirmImport(preview);
    if (mode == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await _service();
      final result = await service.importArchive(
        bytes,
        accountHash: HiDBManager.getAccountHash(),
        mode: mode,
      );
      _applySettings(result);
      if (!mounted) return;
      final warning =
          result.warnings.isEmpty ? '' : '\n${result.warnings.join('\n')}';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Text(_resultText(result, mode, warning)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('好')),
          ],
        ),
      );
    } on FormatException catch (e) {
      if (mounted) HiDialog.showSnackBar(context, e.message);
    } catch (e) {
      AILogger.log('backup import failed: $e');
      if (mounted) HiDialog.showSnackBar(context, '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<BackupImportMode?> _confirmImport(BackupPreview preview) {
    return showDialog<BackupImportMode>(
      context: context,
      builder: (ctx) => BackupImportPreviewDialog(preview: preview),
    );
  }

  String _resultText(
      BackupRestoreResult result, BackupImportMode mode, String warning) {
    switch (mode) {
      case BackupImportMode.overwriteAll:
        return '已恢复 ${result.conversations} 个会话、'
            '${result.messages} 条消息、${result.assistants} 个助手、'
            '${result.favorites} 条收藏。$warning';
      case BackupImportMode.projectConversationsOnly:
        return '已恢复 ${result.projects} 个项目、'
            '${result.conversations} 个会话、${result.messages} 条消息。$warning';
      case BackupImportMode.assistantsOnly:
        return '已恢复 ${result.assistants} 个助手。$warning';
      case BackupImportMode.knowledgeBaseOnly:
        return '已恢复 ${result.knowledgeDocs} 个知识库文档、'
            '${result.knowledgeChunks} 个片段、'
            '${result.projectKnowledge} 条项目知识库绑定。$warning';
      case BackupImportMode.mergeAppend:
        return '已合并 ${result.projects} 个项目、${result.conversations} 个会话、'
            '${result.messages} 条消息、${result.assistants} 个助手、'
            '${result.favorites} 条收藏、${result.knowledgeDocs} 个知识库文档。'
            '$warning';
    }
  }

  ///应用备份里的 AI 设置：备份脱敏导出时 key 为空，保留本地已配置的 key，
  ///避免「导入一份脱敏备份把自己的 key 清掉」。
  void _applySettings(BackupRestoreResult result) {
    final incoming = result.settings;
    if (incoming == null) return;
    final provider = context.read<AISettingsProvider>();
    final local = provider.settings;
    // 按服务商 id 把缺失的 key 用本地已配置的补上。
    for (final p in incoming.providers) {
      if (p.apiKey.isNotEmpty) continue;
      final matches = local.providers.where((e) => e.id == p.id);
      if (matches.isNotEmpty && matches.first.apiKey.isNotEmpty) {
        p.apiKey = matches.first.apiKey;
      }
    }
    if (incoming.tavilyApiKey.isEmpty) {
      incoming.tavilyApiKey = local.tavilyApiKey;
    }
    if (incoming.exaApiKey.isEmpty) incoming.exaApiKey = local.exaApiKey;
    if (incoming.bochaApiKey.isEmpty) incoming.bochaApiKey = local.bochaApiKey;
    if (incoming.zhipuApiKey.isEmpty) incoming.zhipuApiKey = local.zhipuApiKey;
    provider.update(incoming);
  }

  String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
