import 'package:flutter/material.dart';
import '../dao/ai_catalog_dao.dart';
import '../storage/ohos_storage_service.dart';

class StorageManagementPage extends StatefulWidget {
  final OhosStorageService? service;
  const StorageManagementPage({super.key, this.service});
  @override
  State<StorageManagementPage> createState() => _StorageManagementState();
}

class _StorageManagementState extends State<StorageManagementPage> {
  late final _service = widget.service ?? OhosStorageService.shared;
  late final _identity = AiCatalogIdentity.capture();
  OhosStorageInventory? _inventory;
  String? _message;
  bool _busy = true;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  bool get _current => mounted && _identity.current;
  Future<void> _refresh() async {
    try {
      final inventory = await _service.inspect();
      if (_current) setState(() => _inventory = inventory);
    } catch (_) {
      if (_current) setState(() => _message ??= '无法读取存储统计，请在附件操作结束后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clean() async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result =
          await _service.clean(manual: true, isCurrent: () => _current);
      if (_current) {
        setState(() => _message =
            '已释放 ${_size(result.bytes)}，清理 ${result.removed} 份副本；其余资料已保留');
      }
    } catch (_) {
      if (_current) setState(() => _message = '存储核对或清理未完成，未处理的文件已保留，请稍后重试');
    } finally {
      if (_current) {
        await _refresh();
      } else if (mounted) {
        setState(() {
          _busy = false;
          _message = '账号已变化，请重新打开存储管理';
        });
      }
    }
  }

  static String _size(int value) => value >= 1024 * 1024
      ? '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB'
      : '${(value / 1024).toStringAsFixed(1)} KiB';
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('存储管理')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('文件与图片副本',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_inventory != null) ...[
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('文件选择缓存'),
                trailing: Text(_size(_inventory!.fileBytes))),
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('图片副本'),
                trailing: Text(_size(_inventory!.imageBytes))),
          ],
          const Text(
              '清理前会检查全部本地账号的消息、头像、设置与草稿。正在使用、可恢复或仍有引用的附件会保留。图片仅回收超过 7 天的无引用副本。'),
          const SizedBox(height: 12),
          const Text(
              '文件缓存累计上限为 512 MiB。自动整理只回收超过 24 小时的无引用文件；此处可提前清理闲置文件副本。未保存输入受保护，部分副本需下次应用启动后才能回收。'),
          const SizedBox(height: 12),
          const Text('不删除会话、原始文档、头像或草稿。无法完整核对时会跳过清理。'),
          const SizedBox(height: 24),
          if (_busy) const Center(child: CircularProgressIndicator()),
          FilledButton.icon(
              onPressed: _busy || !_identity.current ? null : _clean,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理无引用副本')),
          TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _busy = true;
                        _message = null;
                      });
                      _refresh();
                    },
              child: const Text('刷新统计')),
          if (_message != null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_message!)),
        ]),
      );
}
