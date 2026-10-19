import 'dart:io';
import 'package:chatgpt_app_core/chat/application/downloadable_tts_models.dart';
import 'package:hi_download/hi_download.dart';

import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
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
  DownloadCancellationToken? _downloadToken;
  double? _progress;
  bool _downloading = false;
  var _loading = true;
  var _importing = false;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  Widget build(BuildContext context) {
    final importDisabled =
        Platform.operatingSystem == 'ohos' || _importing || _downloading;
    return Scaffold(
      appBar: AppBar(title: const Text('离线语音模型')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                FilledButton.icon(
                  onPressed: (_downloading ||
                          _importing ||
                          Platform.operatingSystem == 'ohos')
                      ? null
                      : _downloadOfficial,
                  icon: const Icon(Icons.download),
                  label: const Text('下载中文女声 Baker（按需）'),
                ),
                if (_downloadToken != null) ...[
                  LinearProgressIndicator(value: _progress),
                  TextButton(
                      onPressed: () => _downloadToken?.cancel(),
                      child: const Text('暂停，下次继续')),
                ],
                _importActions(importDisabled),
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

  Widget _importActions(bool importDisabled) {
    final directory = OutlinedButton.icon(
      icon: const Icon(Icons.folder_open_outlined),
      label: const Text('导入目录'),
      onPressed: importDisabled ? null : _importDirectory,
    );
    final archive = FilledButton.icon(
      icon: const Icon(Icons.archive_outlined),
      label: const Text('导入 ZIP'),
      onPressed: importDisabled ? null : _importZip,
    );
    if (AppVisualTheme.of(context).isAnime) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < 420
              ? constraints.maxWidth
              : (constraints.maxWidth - 12) / 2;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(width: width, child: directory),
              SizedBox(width: width, child: archive),
            ],
          );
        },
      );
    }
    return Row(
      children: [
        Expanded(child: directory),
        const SizedBox(width: 12),
        Expanded(child: archive),
      ],
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

  Future<void> _downloadOfficial() async {
    if (_downloading || _importing) return;
    setState(() => _downloading = true);
    try {
      final store = DownloadableTtsModelStore();
      final catalog = await store.catalog();
      if (!mounted || catalog.isEmpty) return;
      final model = catalog.first;
      final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('下载离线语音'),
                content: Text(
                    '中文女声 Baker，约 ${(model.bytes / 1024 / 1024).ceil()} MB。建议连接 Wi-Fi，下载后无需联网即可朗读。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('下载'))
                ],
              ));
      if (accepted != true || !mounted) return;
      final token = DownloadCancellationToken();
      setState(() {
        _downloadToken = token;
        _progress = null;
      });
      await store.install(model, token: token,
          listener: (total, received, done) {
        if (mounted) {
          setState(() => _progress = total > 0 ? received / total : null);
        }
      });
      await _loadModels();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('中文女声已安装，可离线朗读')));
      }
    } on DownloadCancelled {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已暂停，再次下载将继续')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('模型下载或安装失败，请重试')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadToken = null;
          _downloading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _downloadToken?.cancel();
    super.dispose();
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
        withData: false,
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
    final classic = Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Text(
          '还没有用户模型。\n请选择包含 manifest.json 的 sherpa-onnx Matcha 模型目录，或直接导入 ZIP。',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600]),
        ),
      ),
    );
    return AppVisualEmptyState(
      animeKey: const ValueKey('tts_empty_state'),
      icon: Icons.graphic_eq_rounded,
      title: '还没有离线语音模型',
      message: '请选择包含 manifest.json 的 sherpa-onnx Matcha 模型目录，或直接导入 ZIP。',
      classic: classic,
    );
  }
}
