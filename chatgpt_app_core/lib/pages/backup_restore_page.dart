import 'package:login_sdk/platform/app_io.dart';
import 'dart:typed_data';

import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/backup/backup_settings_merge.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/platform/app_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

/// 备份会替换翻译任务表时，旧 runner 必须先完全退出；无论导入成功或失败，
/// 最后都从当前账号数据库重新绑定任务快照，避免旧 lease/旧 UI 继续写入。
Future<T> runBackupImportWithTranslationTaskRebind<T>({
  required StoryTemplateTranslationCoordinator coordinator,
  required HiDBManager storage,
  required String accountHash,
  required Future<T> Function() importAction,
  bool Function()? shouldRebind,
}) async {
  await coordinator.detachForLifecycle();
  try {
    return await importAction();
  } finally {
    if (shouldRebind?.call() ?? true) {
      await coordinator.initialize(storage, accountHash: accountHash);
    }
  }
}

/// FilePicker 关闭 `withData` 后的有界读取边界。服务层仍会重新校验 ZIP
/// 元数据；这里负责在把本地不受信任文件整体搬进内存前拒绝超限输入。
Future<Uint8List?> readBackupImportFile(PlatformFile file) async {
  validateBackupCompressedSize(file.size);
  final inMemory = file.bytes;
  if (inMemory != null) {
    validateBackupCompressedSize(inMemory.length);
    return inMemory;
  }
  final path = file.path;
  if (path == null || path.isEmpty) return null;
  return readFileBytesBounded(
    appFile(path),
    maxBytes: BackupArchiveLimits.standard.maxCompressedBytes,
    label: '备份文件',
  );
}

///备份与恢复页（阶段八）：导出 zip / 导入恢复。
///文件选择走 file_picker（与阶段四附件同一插件），核心逻辑在 [BackupService]。
class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class BackupImportPreviewDialog extends StatefulWidget {
  final BackupPreview preview;
  final String targetAccountHash;

  const BackupImportPreviewDialog({
    super.key,
    required this.preview,
    this.targetAccountHash = '',
  });

  @override
  State<BackupImportPreviewDialog> createState() =>
      _BackupImportPreviewDialogState();
}

class _BackupImportPreviewDialogState extends State<BackupImportPreviewDialog> {
  BackupImportMode _mode = BackupImportMode.overwriteAll;
  bool _crossAccountConfirmed = false;
  bool _secretsConfirmed = false;

  bool get _isCrossAccount =>
      widget.preview.accountHash.isNotEmpty &&
      widget.targetAccountHash.isNotEmpty &&
      widget.preview.accountHash != widget.targetAccountHash;

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
            if (_isCrossAccount) ...[
              const SizedBox(height: 12),
              Text(
                '跨账号恢复：${_maskedAccount(widget.preview.accountHash)} → '
                '${_maskedAccount(widget.targetAccountHash)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _crossAccountConfirmed,
                onChanged: (value) => setState(
                  () => _crossAccountConfirmed = value == true,
                ),
                title: const Text('我确认将此备份导入当前账号'),
                subtitle: const Text('备份中的数据不会写回来源账号'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
            if (widget.preview.includeApiKeys) ...[
              const SizedBox(height: 12),
              Text(
                '此 ZIP 未加密，包含 API Key 或 MCP 鉴权信息。'
                '完整性校验不能证明来源可信。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _secretsConfirmed,
                onChanged: (value) => setState(
                  () => _secretsConfirmed = value == true,
                ),
                title: const Text('我确认备份来自可信来源，并接受凭据泄露风险'),
                subtitle: const Text('导入后其中的凭据可能替换当前 AI/MCP 配置'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
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
          onPressed: (_isCrossAccount && !_crossAccountConfirmed) ||
                  (widget.preview.includeApiKeys && !_secretsConfirmed)
              ? null
              : () => Navigator.pop(context, _mode),
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
      preview.integrityVerified ? '内容与清单一致（不代表来源可信）' : '旧备份未包含完整性校验',
      '导出时间：${exportedAtText()}',
      if (preview.accountHash.isNotEmpty)
        '来源账号：${_maskedAccount(preview.accountHash)}',
      'AI 设置：${preview.hasSettings ? '包含' : '不包含'}'
          '${preview.includeApiKeys ? '（含 API Key）' : '（不含 API Key）'}',
      '会话：${preview.conversations}',
      '消息：${preview.messages}',
      '助手：${preview.assistants}',
      '助手记忆：${preview.assistantMemories}',
      '个人记忆：${preview.personalMemories}（恢复后开关关闭）',
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

  static String _maskedAccount(String value) {
    final normalized = value.trim();
    if (normalized.length <= 4) {
      return List.filled(normalized.length, '•').join();
    }
    return '${normalized.substring(0, 2)}…'
        '${normalized.substring(normalized.length - 2)}';
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
      '备份内容：会话、聊天记录（含思考/工具等块数据）、助手及长期记忆、'
      '收藏、AI 设置。'
      '按当前登录账号导出/导入。ZIP 未加密，长期记忆等内容为明文。',
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
      subtitle: const Text('开启后 ZIP 将以明文包含 API Key 和 MCP 鉴权请求头'),
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

  Future<HiDBManager> _storage({String? accountHash}) => HiDBManager.instance(
        dbName: accountHash ?? HiDBManager.getAccountHash(),
      );

  Future<BackupService> _service({String? accountHash}) async =>
      BackupService(await _storage(accountHash: accountHash));

  String _fileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'chatgpt_backup_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
  }

  void _export() async {
    if (_includeApiKeys) {
      final confirmed = await _confirmSecretExport();
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final expectedAccountHash = _captureStableAccount();
      final includeApiKeys = _includeApiKeys;
      // 只把实际读取账号数据的阶段放进 lease；系统保存文件对话框可能等待很久，
      // 不能因此阻塞用户退出或切换账号。
      final export = await LoginDao.runWithStableAccount(
        expectedAccountHash: expectedAccountHash,
        action: () async {
          _assertStableAccount(expectedAccountHash);
          final provider = context.read<AISettingsProvider>();
          final settingsSnapshot = provider.settings.clone();
          final service = await _service(accountHash: expectedAccountHash);
          _assertStableAccount(expectedAccountHash);
          return service.exportArchiveWithReport(
            settings: settingsSnapshot,
            accountHash: expectedAccountHash,
            includeApiKeys: includeApiKeys,
          );
        },
      );
      final bytes = export.bytes;
      // file_picker 11 及本地鸿蒙适配均消费 bytes；返回值只作保存反馈。
      final path = await FilePicker.saveFile(
        dialogTitle: '保存备份',
        fileName: _fileName(),
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        bytes: bytes,
      );
      if (path == null) return; // 用户取消
      if (!mounted) return;
      HiDialog.showSnackBar(context,
          '${kIsWeb ? '已发起备份下载' : '已导出备份'}（${_sizeText(bytes.length)}）');
      if (export.warnings.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('备份已导出，但有数据规范化提示'),
            content: Text(export.warnings.join('\n')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      AILogger.log('backup export failed: $e');
      if (!mounted) return;
      HiDialog.showSnackBar(context, '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmSecretExport() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认导出明文凭据'),
        content: const Text(
          '此 ZIP 不加密，将包含 API Key 与 MCP 鉴权请求头。'
          '请只保存到可信位置，不要发送给他人；文件哈希只能检查内容是否变化，'
          '不能证明备份来源可信。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('仍要导出'),
          ),
        ],
      ),
    );
  }

  void _import() async {
    final FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: '选择备份文件',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: false,
      );
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '选取备份文件失败：$error');
      return;
    }
    final file = picked?.files.firstOrNull;
    if (file == null || !mounted) return; // 用户取消
    Uint8List? bytes;
    try {
      bytes = await readBackupImportFile(file);
    } catch (error) {
      if (mounted) {
        HiDialog.showSnackBar(
          context,
          error is FormatException ? error.message : '读取备份文件失败：$error',
        );
      }
      return;
    }
    if (bytes == null) {
      if (mounted) HiDialog.showSnackBar(context, '读取备份文件失败');
      return;
    }
    final archiveBytes = bytes;
    if (!mounted) return;
    final String accountHash;
    try {
      accountHash = _captureStableAccount();
    } on LoginAccountChangedException {
      HiDialog.showSnackBar(context, '账号状态不一致，请重新进入备份页面');
      return;
    }

    final BackupPreview preview;
    try {
      preview = await LoginDao.runWithStableAccount(
        expectedAccountHash: accountHash,
        action: () async {
          _assertStableAccount(accountHash);
          final service = await _service(accountHash: accountHash);
          final result = await service.previewArchive(
            archiveBytes,
            accountHash: accountHash,
          );
          _assertStableAccount(accountHash);
          return result;
        },
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

    if (!_accountStillMatches(accountHash)) {
      HiDialog.showSnackBar(context, '账号已切换，已取消旧账号的导入操作');
      return;
    }
    final mode = await _confirmImport(preview, accountHash);
    if (mode == null || !mounted) return;
    if (!_accountStillMatches(accountHash)) {
      HiDialog.showSnackBar(context, '账号已切换，已取消旧账号的导入操作');
      return;
    }

    setState(() => _busy = true);
    try {
      final outcome = await LoginDao.runWithStableAccount(
        expectedAccountHash: accountHash,
        action: () async {
          _assertStableAccount(accountHash);
          final provider = context.read<AISettingsProvider>();
          final localSettingsSnapshot = provider.settings.clone();
          final storage = await _storage(accountHash: accountHash);
          final service = BackupService(storage);
          Future<void> accountGuard() async =>
              _assertStableAccount(accountHash);
          Future<BackupRestoreResult> restoreArchive() => service.importArchive(
                archiveBytes,
                accountHash: accountHash,
                mode: mode,
                accountGuard: accountGuard,
              );
          // 覆盖恢复会替换会话与任务快照。先结束旧运行，并在整个恢复期
          // 拒绝同账号新任务，避免恢复后旧 runner 写回同 cid 的数据。
          Future<BackupRestoreResult> importAction() =>
              mode == BackupImportMode.overwriteAll
                  ? AgentTaskExecutor.instance.runWithTasksPaused(
                      accountHash, '正在恢复备份，任务已暂停', restoreArchive)
                  : restoreArchive();
          final affectsTranslationTasks =
              mode == BackupImportMode.overwriteAll ||
                  mode == BackupImportMode.mergeAppend;
          final result = affectsTranslationTasks
              ? await runBackupImportWithTranslationTaskRebind(
                  coordinator: StoryTemplateTranslationCoordinator.instance,
                  storage: storage,
                  accountHash: accountHash,
                  importAction: importAction,
                  shouldRebind: () => _accountStillMatches(accountHash),
                )
              : await importAction();
          Object? settingsError;
          try {
            await _applySettings(
              result,
              incomingIncludesSecrets: preview.includeApiKeys,
              expectedAccountHash: accountHash,
              localSettingsSnapshot: localSettingsSnapshot,
            );
          } catch (error) {
            settingsError = error;
          }
          _assertStableAccount(accountHash);
          return (result: result, settingsError: settingsError);
        },
      );
      final result = outcome.result;
      final settingsError = outcome.settingsError;
      if (settingsError != null) {
        AILogger.log(
          'backup settings restore failed after db commit: '
          '${settingsError.runtimeType}',
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('数据已导入，AI 设置未恢复'),
            content: Text(
              '会话等本地数据已经成功恢复，但安全存储暂时无法保存 AI 设置。'
              '原有 AI 设置未被覆盖，请稍后重新导入。\n\n$settingsError',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
        return;
      }
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

  String _captureStableAccount() {
    final accountHash = LoginDao.getAccountHash();
    if (accountHash == null) throw const LoginAccountChangedException();
    _assertStableAccount(accountHash);
    return accountHash;
  }

  void _assertStableAccount(String expectedAccountHash) {
    if (!mounted ||
        LoginDao.getAccountHash() != expectedAccountHash ||
        HiDBManager.getAccountHash() != expectedAccountHash ||
        context.read<AISettingsProvider>().accountHash != expectedAccountHash) {
      throw const LoginAccountChangedException();
    }
  }

  bool _accountStillMatches(String accountHash) {
    try {
      _assertStableAccount(accountHash);
      return true;
    } on LoginAccountChangedException {
      return false;
    }
  }

  Future<BackupImportMode?> _confirmImport(
    BackupPreview preview,
    String targetAccountHash,
  ) {
    return showDialog<BackupImportMode>(
      context: context,
      builder: (ctx) => BackupImportPreviewDialog(
        preview: preview,
        targetAccountHash: targetAccountHash,
      ),
    );
  }

  String _resultText(
      BackupRestoreResult result, BackupImportMode mode, String warning) {
    switch (mode) {
      case BackupImportMode.overwriteAll:
        return '已恢复 ${result.conversations} 个会话、'
            '${result.messages} 条消息、${result.assistants} 个助手、'
            '${result.assistantMemories} 条助手记忆、${result.personalMemories} 条个人记忆、'
            '${result.favorites} 条收藏。$warning';
      case BackupImportMode.projectConversationsOnly:
        return '已恢复 ${result.projects} 个项目、'
            '${result.conversations} 个会话、${result.messages} 条消息。$warning';
      case BackupImportMode.assistantsOnly:
        return '已恢复 ${result.assistants} 个助手、'
            '${result.assistantMemories} 条助手记忆。$warning';
      case BackupImportMode.knowledgeBaseOnly:
        return '已恢复 ${result.knowledgeDocs} 个知识库文档、'
            '${result.knowledgeChunks} 个片段、'
            '${result.projectKnowledge} 条项目知识库绑定。$warning';
      case BackupImportMode.mergeAppend:
        return '已合并 ${result.projects} 个项目、${result.conversations} 个会话、'
            '${result.messages} 条消息、${result.assistants} 个助手、'
            '${result.assistantMemories} 条助手记忆、${result.personalMemories} 条个人记忆、'
            '${result.favorites} 条收藏、${result.knowledgeDocs} 个知识库文档。'
            '$warning';
    }
  }

  /// 应用备份里的 AI 设置。脱敏/旧备份保留本地凭据；
  /// manifest 显式包含凭据时，则完整恢复备份中的凭据状态。
  Future<void> _applySettings(
    BackupRestoreResult result, {
    required bool incomingIncludesSecrets,
    required String expectedAccountHash,
    required AISettings localSettingsSnapshot,
  }) async {
    final incoming = result.settings;
    if (incoming == null) return;
    final provider = context.read<AISettingsProvider>();
    final merged = mergeImportedSettingsSecrets(
      incoming,
      localSettingsSnapshot,
      incomingIncludesSecrets: incomingIncludesSecrets,
    );
    await provider.update(
      merged,
      expectedAccountHash: expectedAccountHash,
    );
  }

  String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
