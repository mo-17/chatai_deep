import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

///备份与恢复页（阶段八）：导出 zip / 导入恢复。
///文件选择走 file_picker（与阶段四附件同一插件），核心逻辑在 [BackupService]。
class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({Key? key}) : super(key: key);

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  ///备份是否包含 API Key（默认脱敏，避免备份文件外流泄露 key）。
  bool _includeApiKeys = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '备份内容：会话、聊天记录（含思考/工具等块数据）、助手、收藏、AI 设置。'
            '按当前登录账号导出/导入。',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('备份包含 API Key'),
            subtitle: const Text('默认不包含，防止备份文件外流时泄露密钥'),
            value: _includeApiKeys,
            onChanged: (v) => setState(() => _includeApiKeys = v),
          ),
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入恢复'),
        content: const Text('导入将覆盖当前账号的全部会话、聊天记录、助手与收藏，'
            '且不可撤销。建议先导出一份当前数据。确定继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('覆盖导入')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await _service();
      final result = await service.importArchive(
        bytes,
        accountHash: HiDBManager.getAccountHash(),
      );
      _applySettings(result);
      if (!mounted) return;
      final warning =
          result.warnings.isEmpty ? '' : '\n${result.warnings.join('\n')}';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Text('已恢复 ${result.conversations} 个会话、'
              '${result.messages} 条消息、${result.assistants} 个助手、'
              '${result.favorites} 条收藏。$warning'),
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
