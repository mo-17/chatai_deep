import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';

/// 成果绑定生成时的版本；历史预览不会被新的同名成果替换。
class AgentTaskOutputPage extends StatefulWidget {
  final int cid;
  final int fileId;
  final int revision;
  final String name;
  final int? currentRevision;
  final String expectedAccountHash;
  final String Function()? accountHash;
  final Listenable? accountChanges;
  final Future<AgentWorkspaceRevision> Function()? loadRevision;

  const AgentTaskOutputPage({
    super.key,
    required this.cid,
    required this.fileId,
    required this.revision,
    required this.name,
    required this.expectedAccountHash,
    this.currentRevision,
    this.accountHash,
    this.accountChanges,
    this.loadRevision,
  });

  @override
  State<AgentTaskOutputPage> createState() => _AgentTaskOutputPageState();
}

class _AgentTaskOutputPageState extends State<AgentTaskOutputPage>
    with WidgetsBindingObserver {
  AgentWorkspaceRevision? _version;
  bool _busy = true;
  bool _accountChanged = false;
  String? _error;
  int _visibleChars = 12000;
  int _loadToken = 0;
  Listenable? _accountChanges;
  Timer? _accountTimer;

  bool get _accountMatches =>
      (widget.accountHash?.call() ?? HiDBManager.getAccountHash()) ==
      widget.expectedAccountHash;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _accountChanges = widget.accountChanges ?? AISettingsProvider.instance;
    _accountChanges?.addListener(_checkAccount);
    // 登出设置保留时 provider 可能不发通知，仍及时隐藏旧账号正文。
    _accountTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _checkAccount());
    unawaited(_load());
  }

  bool _checkAccount() {
    if (!mounted || _accountChanged) return false;
    if (_accountMatches) return true;
    _loadToken++;
    setState(() {
      _accountChanged = true;
      _version = null;
      _busy = false;
      _error = null;
    });
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccount();
  }

  Future<AgentWorkspaceRevision> _readVersion() async {
    if (widget.loadRevision != null) return widget.loadRevision!();
    final manager =
        await HiDBManager.instance(dbName: widget.expectedAccountHash);
    if (!_checkAccount()) throw const FormatException('账号已切换');
    final workspace =
        await AgentWorkspaceService.create(manager, cid: widget.cid);
    if (!_checkAccount()) throw const FormatException('账号已切换');
    final file = await workspace.getFile(widget.fileId);
    if (!_checkAccount()) throw const FormatException('账号已切换');
    if (file == null || file.kind != 'output') {
      throw const FormatException('成果已不存在');
    }
    return workspace.getRevision(widget.fileId, revision: widget.revision);
  }

  Future<void> _load() async {
    if (!_checkAccount()) return;
    final token = ++_loadToken;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final version = await _readVersion();
      if (!mounted || !_checkAccount() || token != _loadToken) return;
      if (version.fileId != widget.fileId ||
          version.revision != widget.revision) {
        throw const FormatException('成果版本不一致');
      }
      setState(() {
        _version = version;
        _busy = false;
      });
    } catch (_) {
      if (!mounted || !_checkAccount() || token != _loadToken) return;
      setState(() {
        _busy = false;
        _error = '这个成果版本暂时不可用，文件可能已删除或未随备份导入。';
      });
    }
  }

  @override
  void dispose() {
    _loadToken++;
    _accountTimer?.cancel();
    _accountChanges?.removeListener(_checkAccount);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changed = _accountChanged || !_accountMatches;
    final version = changed ? null : _version;
    return Scaffold(
      appBar: AppBar(title: Text(changed ? '任务成果' : widget.name)),
      body: changed
          ? const Center(child: Text('账号已切换，请返回当前账号的任务'))
          : _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!)),
                      TextButton(onPressed: _load, child: const Text('重新加载')),
                    ]))
                  : ListView(padding: const EdgeInsets.all(20), children: [
                      Text(
                          '生成时版本 v${widget.revision} · ${version!.content.length} 字符',
                          key: const ValueKey('task_output_version')),
                      if (widget.currentRevision != null &&
                          widget.currentRevision != widget.revision)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                                '当前文件已更新到 v${widget.currentRevision}，这里仍显示本轮生成时的版本。')),
                      const Divider(height: 32),
                      SelectableText(
                          version.content
                              .substring(0, _visibleEnd(version.content)),
                          key: const ValueKey('task_output_content')),
                      if (_visibleChars < version.content.length)
                        TextButton(
                            onPressed: () {
                              if (_checkAccount()) {
                                setState(() => _visibleChars += 12000);
                              }
                            },
                            child: const Text('加载更多正文')),
                    ]),
    );
  }

  int _visibleEnd(String content) {
    var end = _visibleChars.clamp(0, content.length);
    if (end > 0 &&
        end < content.length &&
        content.codeUnitAt(end - 1) >= 0xD800 &&
        content.codeUnitAt(end - 1) <= 0xDBFF &&
        content.codeUnitAt(end) >= 0xDC00 &&
        content.codeUnitAt(end) <= 0xDFFF) {
      end++;
    }
    return end;
  }
}
