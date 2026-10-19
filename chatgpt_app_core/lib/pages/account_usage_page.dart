import 'package:flutter/material.dart';
import 'package:chatgpt_app_core/account/account_api.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:login_sdk/dao/login_dao.dart';

class AccountUsagePage extends StatefulWidget {
  final AccountApi? api;
  const AccountUsagePage({super.key, this.api});
  @override
  State<AccountUsagePage> createState() => _AccountUsagePageState();
}

class _AccountUsagePageState extends State<AccountUsagePage> {
  late final AccountApi _api = widget.api ?? AccountApi();
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  String _prompt = '';
  static const _examples = {
    '写作润色': '帮我润色下面这段文字，让它更清晰自然：\n',
    '学习解释': '请用一个生活中的例子解释：',
    '计划清单': '帮我制定一个可执行的计划，目标是：',
  };
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _api.request('/uapi/account/usage');
      if (mounted) setState(() => _data = data);
    } catch (_) {
      if (mounted) setState(() => _error = '读取用量失败，请确认已登录后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startTrial() async {
    final account = LoginDao.getAccountHash();
    final origin = BackendConst.buildUri('/').origin;
    if (_busy || account == null) return;
    setState(() => _busy = true);
    try {
      // 点击时重新读取政策，不能拿页面旧快照启动。
      final data = await _api.request('/uapi/account/usage');
      if (!mounted ||
          data['trialEnabled'] != true ||
          data['trialEligible'] != true ||
          data['remainingTokens'] is! int ||
          data['remainingTokens'] <= 0 ||
          data['remainingRequests'] is! int ||
          data['remainingRequests'] <= 0) {
        throw StateError('试用暂不可用');
      }
      final provider = AISettingsProvider.instance;
      if (provider == null ||
          account != LoginDao.getAccountHash() ||
          origin != BackendConst.buildUri('/').origin) {
        throw StateError('账号已切换');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('使用官方文字试用'),
          content: const Text(
              '将当前 AI 模式切换为官方后端服务。你自己的服务商配置和 Key 会保留，可在 AI 服务设置中切回。示例只会填入输入框，需要你点击发送后才消耗额度。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      _api.verifyCurrent();
      final pair = BackendSelection.pair(
          providerCode: data['trialProviderCode'],
          modelId: data['trialModel'],
          accountHash: account,
          origin: origin);
      final next = provider.settings.clone()
        ..mode = AIMode.backend
        ..backendSelection = pair;
      await provider.update(next, expectedAccountHash: account);
      _api.verifyCurrent();
      if (!mounted || account != LoginDao.getAccountHash()) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ConversationPage(
                  conversationModel: ConversationModel(
                      cid: DateTime.now().microsecondsSinceEpoch,
                      icon: '✨',
                      backendSelection: pair),
                  initialPrompt: _prompt,
                  expectedAccountHash: account)));
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('试用尚未就绪、额度不足或账号已切换，请刷新后重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
        appBar: AppBar(title: const Text('官方试用与用量')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (LoginDao.isGuest()) ...[
            const Text('无需准备 API Key。登录并通过邮箱验证后，可以使用官方文字试用。'),
            OutlinedButton(
                onPressed: () => LoginDao.logOut(), child: const Text('前往登录')),
          ],
          if (data != null) ...[
            Text(data['trialEnabled'] == true
                ? '官方模型：${data['trialModel']}'
                : '官方试用暂未开放'),
            const SizedBox(height: 16),
            Text(data['limitsEnabled'] == true
                ? '今日剩余 ${data['remainingTokens']} / ${data['dailyTokens']} Token'
                : '当前未设置每日额度'),
            Text(
                '今日请求 ${data['usedRequests']} 次 · 最多同时 ${data['maxConcurrent']} 个请求'),
            const SizedBox(height: 8),
            Text('${data['countingRule']}'),
            const SizedBox(height: 16),
            if (data['trialEnabled'] == true) ...[
              const Text('启用后使用官方后端服务，无需填写 Key；后续可在 AI 服务设置切回自己的服务。试用支持文字聊天。'),
              const SizedBox(height: 12),
              if (data['trialEligible'] != true)
                const Text('请先使用邮箱验证码登录，或在账号中绑定并验证邮箱。仅填写邮箱或密码登录不会自动完成邮箱验证。'),
              if (data['remainingTokens'] == 0 ||
                  data['remainingRequests'] == 0)
                const Text('今日额度已用完，将在下一个 UTC 0 点（北京时间 08:00）重置。'),
              const SizedBox(height: 12),
              const Text('不知道从哪里开始？选择一个示例，进入后补充内容再发送：'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final entry in _examples.entries)
                  ChoiceChip(
                      label: Text(entry.key),
                      selected: _prompt == entry.value,
                      onSelected: _busy
                          ? null
                          : (selected) => setState(
                              () => _prompt = selected ? entry.value : '')),
              ]),
              FilledButton(
                  onPressed: _busy ||
                          data['trialEligible'] != true ||
                          data['remainingTokens'] is! int ||
                          data['remainingTokens'] <= 0 ||
                          data['remainingRequests'] is! int ||
                          data['remainingRequests'] <= 0
                      ? null
                      : _startTrial,
                  child: const Text('开始官方试用')),
            ],
            const Divider(),
            const Text('今日模型用量（服务商返回的实际 Token）'),
            for (final model in data['models'] as List? ?? [])
              ListTile(
                  title: Text('${model['model']}'),
                  subtitle: Text(
                      '${model['requests']} 次 · ${model['totalTokens']} Token')),
          ],
          OutlinedButton(
              onPressed: _busy ? null : _load, child: const Text('刷新用量')),
        ]));
  }
}
