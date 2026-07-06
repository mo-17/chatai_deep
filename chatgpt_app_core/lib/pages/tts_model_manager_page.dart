import 'dart:io';

import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class TtsModelManagerPage extends StatefulWidget {
  const TtsModelManagerPage({super.key});

  @override
  State<TtsModelManagerPage> createState() => _TtsModelManagerPageState();
}

class _TtsModelManagerPageState extends State<TtsModelManagerPage> {
  final _store = UserSherpaOnnxTtsModelStore();
  var _models = <UserSherpaOnnxTtsModel>[];
  var _loading = true;
  var _importing = false;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  Widget build(BuildContext context) {
    final importDisabled = Platform.operatingSystem == 'ohos' || _importing;
    return Scaffold(
      appBar: AppBar(title: const Text('离线语音模型')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('导入目录'),
                        onPressed: importDisabled ? null : _importDirectory,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.archive_outlined),
                        label: const Text('导入 ZIP'),
                        onPressed: importDisabled ? null : _importZip,
                      ),
                    ),
                  ],
                ),
                if (Platform.operatingSystem == 'ohos')
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      '鸿蒙版本暂不支持文件选择导入。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 16),
                if (_models.isEmpty)
                  const _EmptyModelHint()
                else
                  for (final model in _models) _modelTile(model),
              ],
            ),
    );
  }

  Widget _modelTile(UserSherpaOnnxTtsModel model) {
    final manifest = model.manifest;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.record_voice_over)),
        title: Text(model.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${manifest.locale} / ${manifest.speaker} / ${manifest.sampleRate}Hz\n${model.rootDir.path}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
      ),
    );
  }

  Future<void> _loadModels() async {
    final models = await _store.listModels();
    if (!mounted) return;
    setState(() {
      _models = models;
      _loading = false;
    });
  }

  Future<void> _importDirectory() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: '选择 sherpa-onnx TTS 模型目录',
      );
      if (path == null || path.trim().isEmpty) return;
      await _runImport(() => _store.installFromDirectory(path));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取目录失败：$e');
    }
  }

  Future<void> _importZip() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      final files = result?.files ?? const <PlatformFile>[];
      final path = files.isEmpty ? null : files.first.path;
      if (path == null || path.trim().isEmpty) return;
      await _runImport(() => _store.installFromZip(path));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取 ZIP 失败：$e');
    }
  }

  Future<void> _runImport(
    Future<UserSherpaOnnxTtsModel> Function() action,
  ) async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final model = await action();
      await _loadModels();
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已导入模型：${model.title}');
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导入模型失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}

class _EmptyModelHint extends StatelessWidget {
  const _EmptyModelHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Text(
          '还没有用户模型。\n请选择包含 manifest.json 的 sherpa-onnx Matcha 模型目录，或直接导入 ZIP。',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600]),
        ),
      ),
    );
  }
}
