import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:chatgpt_app_core/account/account_api.dart';
import 'package:login_sdk/dao/login_dao.dart';

class FeedbackPage extends StatefulWidget {
  final AccountApi? api;
  const FeedbackPage({super.key, this.api});
  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  late final AccountApi _api = widget.api ?? AccountApi();
  final _content = TextEditingController();
  String _category = 'bug';
  String _requestId = _uuid();
  String? _attemptedContent;
  int _loadGeneration = 0;
  bool _diagnostics = false, _busy = false;
  String? _notice;
  List _items = [];
  int _page = 1, _total = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (LoginDao.isGuest()) return;
    final generation = ++_loadGeneration;
    try {
      final data = await _api.request('/uapi/feedback?page=$_page');
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _items = data['list'] as List;
          _total = data['total'] as int;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _notice = '反馈读取失败，请重试');
    }
  }

  Future<void> _submit() async {
    if (_busy || LoginDao.isGuest()) return;
    final content = _content.text.trim();
    if (content.length < 5) {
      setState(() => _notice = '请至少输入 5 个字');
      return;
    }
    final contentKey = '$_category:$content';
    if (_attemptedContent != null && _attemptedContent != contentKey) {
      _requestId = _uuid();
    }
    _attemptedContent = contentKey;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _api.verifyCurrent();
      final diagnostic = <String, String>{};
      if (_diagnostics) {
        try {
          final info = await PackageInfo.fromPlatform();
          diagnostic['appVersion'] = '${info.version}+${info.buildNumber}';
        } catch (_) {
          // 可选版本信息不可用不阻断反馈，仍尊重用户关闭诊断的选择。
        }
        diagnostic['platform'] = Platform.operatingSystem;
        if (!mounted) return;
        diagnostic['locale'] = Localizations.localeOf(context).toLanguageTag();
      }
      await _api.request('/uapi/feedback', body: {
        'requestId': _requestId,
        'content': content,
        'category': _category,
        'diagnostics': diagnostic
      });
      if (!mounted) return;
      _content.clear();
      setState(() {
        _requestId = _uuid();
        _notice = '已提交，可在此查看处理进展和回复';
        _page = 1;
      });
      await _load();
    } catch (_) {
      if (mounted) setState(() => _notice = '提交结果未确认，保留内容；重试相同反馈不会重复创建');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('意见反馈')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (LoginDao.isGuest()) const Text('请登录后提交反馈和查看回复。'),
        DropdownButtonFormField<String>(
            initialValue: _category,
            items: const [
              DropdownMenuItem(value: 'bug', child: Text('问题反馈')),
              DropdownMenuItem(value: 'suggestion', child: Text('功能建议')),
              DropdownMenuItem(value: 'account', child: Text('账号问题')),
              DropdownMenuItem(value: 'other', child: Text('其它'))
            ],
            onChanged: _busy ? null : (v) => setState(() => _category = v!)),
        TextField(
            controller: _content,
            enabled: !_busy,
            minLines: 4,
            maxLines: 8,
            maxLength: 4000,
            decoration: const InputDecoration(
                labelText: '请描述问题和复现步骤',
                helperText: '请勿填写密码、验证码、API Key 或私密聊天内容')),
        CheckboxListTile(
            value: _diagnostics,
            onChanged: _busy ? null : (v) => setState(() => _diagnostics = v!),
            title: const Text('附带版本、平台和语言信息'),
            subtitle: const Text('不读取或上传聊天记录、Key、日志、设备标识')),
        FilledButton(
            onPressed: _busy || LoginDao.isGuest() ? null : _submit,
            child: Text(_busy ? '提交中…' : '提交反馈')),
        if (_notice != null) Text(_notice!),
        const Divider(),
        const Text('我的反馈与回复'),
        for (final item in _items)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('#${item['id']} · ${_status(item['status'])}'),
                        Text('${item['content']}'),
                        if ((item['reply'] as String? ?? '').isNotEmpty)
                          Text('回复：${item['reply']}'),
                      ]))),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          TextButton(
              onPressed: _busy || _page <= 1
                  ? null
                  : () {
                      setState(() => _page--);
                      _load();
                    },
              child: const Text('上一页')),
          Text('第 $_page 页'),
          TextButton(
              onPressed: _busy || _page * 20 >= _total
                  ? null
                  : () {
                      setState(() => _page++);
                      _load();
                    },
              child: const Text('下一页'))
        ]),
        TextButton(
            onPressed: _busy ? null : _load, child: const Text('刷新处理进展')),
      ]));
  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }
}

String _status(Object? value) => switch (value) {
      'in_progress' => '处理中',
      'resolved' => '已解决',
      'closed' => '已关闭',
      _ => '待处理'
    };
String _uuid() {
  final random = Random.secure();
  final b = List.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final s = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}
