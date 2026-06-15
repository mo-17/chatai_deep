import 'dart:async';

import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_provider_list_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/widget/ai_provider/provider_avatar.dart';
import 'package:chatgpt_app_core/widget/ai_provider/section_card.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';

/// AI 设置首页（重做）：服务商入口 + 连接模式 + 通用 + 联网搜索，改动即时保存。
/// 各服务商的 Key/地址/模型已移到「服务商管理」二级页（[AiProviderListPage]）。
class AISettingsPage extends StatefulWidget {
  const AISettingsPage({super.key});

  @override
  State<AISettingsPage> createState() => _AISettingsPageState();
}

class _AISettingsPageState extends State<AISettingsPage> {
  late final TextEditingController _searchCountCtl;
  late final TextEditingController _searchLimitCtl;
  // 4 个联网搜索服务商各自一个 key 控制器，按当前选择显示其中之一。
  late final TextEditingController _tavilyKeyCtl;
  late final TextEditingController _exaKeyCtl;
  late final TextEditingController _bochaKeyCtl;
  late final TextEditingController _zhipuKeyCtl;
  Timer? _debounce;

  bool _obscureSearchKey = true;

  // initState 时缓存，避免 dispose 里再用 context.read。
  late final AISettingsProvider _store = context.read<AISettingsProvider>();

  @override
  void initState() {
    super.initState();
    final s = _store.settings;
    _searchCountCtl =
        TextEditingController(text: s.searchMaxResults.toString());
    _searchLimitCtl = TextEditingController(
        text: s.searchContentLimit > 0 ? s.searchContentLimit.toString() : '');
    _tavilyKeyCtl = TextEditingController(text: s.tavilyApiKey);
    _exaKeyCtl = TextEditingController(text: s.exaApiKey);
    _bochaKeyCtl = TextEditingController(text: s.bochaApiKey);
    _zhipuKeyCtl = TextEditingController(text: s.zhipuApiKey);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 落盘未触发的防抖编辑（结果数/长度/搜索 Key），静默保存避免丢失。
    _flushSearch(notify: false);
    _searchCountCtl.dispose();
    _searchLimitCtl.dispose();
    _tavilyKeyCtl.dispose();
    _exaKeyCtl.dispose();
    _bochaKeyCtl.dispose();
    _zhipuKeyCtl.dispose();
    super.dispose();
  }

  int _parseInt(String t, {int fallback = 0}) =>
      int.tryParse(t.trim()) ?? fallback;

  /// 立即保存：克隆当前设置，应用变更，落盘。
  void _patch(void Function(AISettings) mutate) {
    final s = _store.settings.clone();
    mutate(s);
    _store.update(s);
  }

  TextEditingController _searchKeyCtl(String providerId) {
    switch (providerId) {
      case 'exa':
        return _exaKeyCtl;
      case 'bocha':
        return _bochaKeyCtl;
      case 'zhipu':
        return _zhipuKeyCtl;
      default:
        return _tavilyKeyCtl;
    }
  }

  /// 防抖：搜索区文本变化后延迟落盘。
  void _scheduleSearchSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _flushSearch);
  }

  /// 一次性把搜索区三类文本框（结果数 / 长度 / 当前服务商 Key）全部读出落盘，
  /// 避免「单字段防抖」在并发编辑不同字段时互相覆盖丢失。
  void _flushSearch({bool notify = true}) {
    final s = notify ? _store.settings.clone() : _store.settings;
    s.searchMaxResults =
        _parseInt(_searchCountCtl.text, fallback: 5).clamp(1, 20);
    s.searchContentLimit = _parseInt(_searchLimitCtl.text);
    final key = _searchKeyCtl(s.webSearchProviderId).text.trim();
    switch (s.webSearchProviderId) {
      case 'exa':
        s.exaApiKey = key;
        break;
      case 'bocha':
        s.bochaApiKey = key;
        break;
      case 'zhipu':
        s.zhipuApiKey = key;
        break;
      default:
        s.tavilyApiKey = key;
    }
    if (notify) {
      _store.update(s);
    } else {
      _store.saveQuietly();
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AISettingsProvider>();
    final s = _store.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const SectionLabel('连接模式'),
          _buildModeCard(s),
          const SizedBox(height: 16),
          const SectionLabel('通用'),
          _buildGeneralCard(s),
          const SizedBox(height: 16),
          const SectionLabel('联网搜索'),
          _buildWebSearchCard(s),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.network_check_rounded),
              label: const Text('测试当前配置'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48)),
              onPressed: _testConnection,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildModeCard(AISettings s) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('请求方式', style: tt.bodyMedium),
              const SizedBox(height: 10),
              SegmentedButton<AIMode>(
                segments: const [
                  ButtonSegment(
                      value: AIMode.local,
                      label: Text('本地直连'),
                      icon: Icon(Icons.phone_iphone_rounded)),
                  ButtonSegment(
                      value: AIMode.backend,
                      label: Text('后端代理'),
                      icon: Icon(Icons.cloud_outlined)),
                ],
                selected: {s.mode},
                onSelectionChanged: (sel) {
                  if (sel.first == AIMode.backend && LoginDao.isGuest()) {
                    HiDialog.showSnackBar(
                        context, '游客模式仅支持本地直连，登录后可使用后端代理');
                    return;
                  }
                  _patch((x) => x.mode = sel.first);
                },
              ),
              if (LoginDao.isGuest()) ...[
                const SizedBox(height: 8),
                Text('游客模式：请在「服务商」里填入自己的 API Key',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        if (s.mode == AIMode.local)
          _buildProviderEntry(s)
        else
          _buildBackendModelTile(s),
      ],
    );
  }

  /// 本地模式：服务商入口（头像 + 当前名称 + 已启用数 + 箭头）。
  Widget _buildProviderEntry(AISettings s) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final active = s.activeProvider;
    final enabledCount = s.enabledProviders.length;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Hero(
        tag: 'active-provider-avatar',
        child:
            ProviderAvatar(providerId: active.id, name: active.name, size: 40),
      ),
      title: const Text('AI 服务商'),
      subtitle: Text(active.name,
          style: tt.bodySmall?.copyWith(color: cs.primary)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$enabledCount 已启用',
                style:
                    tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded,
              size: 20, color: cs.onSurfaceVariant),
        ],
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AiProviderListPage()),
      ),
    );
  }

  /// 后端模式：后端模型选择。
  Widget _buildBackendModelTile(AISettings s) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: const Text('后端模型'),
      subtitle: Text(
        ModelCatalog.remoteAvailable ? '清单来自后端，实时更新' : '本地兜底清单',
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text(s.backendModel,
              style: tt.bodyMedium?.copyWith(color: cs.primary),
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 4),
        Icon(Icons.chevron_right_rounded, size: 20, color: cs.onSurfaceVariant),
      ]),
      onTap: _pickBackendModel,
    );
  }

  Future<void> _pickBackendModel() async {
    final options = ModelCatalog.backendAll();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in options)
              ListTile(
                title: Text(o.displayLabel ?? o.id),
                trailing: o.id == _store.settings.backendModel
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(ctx, o.id),
              ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('自定义模型 id...'),
              onTap: () => Navigator.pop(ctx, '__custom__'),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == '__custom__') {
      await _customBackendModel();
    } else {
      _patch((s) => s.backendModel = picked);
    }
  }

  Future<void> _customBackendModel() async {
    final ctl = TextEditingController(text: _store.settings.backendModel);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('自定义模型'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: '输入模型 id', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      _patch((s) => s.backendModel = ctl.text.trim());
    }
  }

  Widget _buildGeneralCard(AISettings s) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SectionCard(
      children: [
        SwitchListTile(
          value: s.streamEnabled,
          onChanged: (v) => _patch((x) => x.streamEnabled = v),
          title: const Text('流式输出'),
          subtitle: Text('逐字显示 AI 回复',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        ListTile(
          title: const Text('最大输出长度'),
          subtitle: Text(
              s.maxOutputTokens > 0 ? '${s.maxOutputTokens} tokens' : '不限制（推荐）',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: _editMaxTokens,
        ),
        SwitchListTile(
          value: s.resetOnLogout,
          onChanged: (v) => _patch((x) => x.resetOnLogout = v),
          title: const Text('退出登录时重置'),
          subtitle: Text('清空 API Key 等设置',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
      ],
    );
  }

  Future<void> _editMaxTokens() async {
    final ctl = TextEditingController(
        text: _store.settings.maxOutputTokens > 0
            ? _store.settings.maxOutputTokens.toString()
            : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('最大输出长度'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'max_tokens',
            hintText: '留空不限制（推荐）',
            helperText: 'ⓘ 设太小会截断回复；推理模型的思考也计入',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) {
      _patch((s) => s.maxOutputTokens = _parseInt(ctl.text));
    }
  }

  static const _searchProviders = <(String, String, String)>[
    ('tavily', 'Tavily', '在 tavily.com 免费申请'),
    ('exa', 'Exa', '在 dashboard.exa.ai 申请'),
    ('bocha', '博查', '在 open.bochaai.com 申请'),
    ('zhipu', '智谱', '在 open.bigmodel.cn 申请'),
  ];

  Widget _buildWebSearchCard(AISettings s) {
    final cs = Theme.of(context).colorScheme;
    final active = _searchProviders.firstWhere(
        (p) => p.$1 == s.webSearchProviderId,
        orElse: () => _searchProviders.first);
    return SectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '搜索服务商',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: active.$1,
                    isDense: true,
                    isExpanded: true,
                    items: [
                      for (final p in _searchProviders)
                        DropdownMenuItem(value: p.$1, child: Text(p.$2)),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      // 先把当前服务商的 Key/参数落盘，再切换，避免丢失。
                      _flushSearch(notify: false);
                      _patch((x) => x.webSearchProviderId = v);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('search_key_${active.$1}'),
                controller: _searchKeyCtl(active.$1),
                obscureText: _obscureSearchKey,
                onChanged: (_) => _scheduleSearchSave(),
                decoration: InputDecoration(
                  labelText: '${active.$2} API Key',
                  helperText: 'ⓘ ${active.$3}；配置后会话页出现联网开关',
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  suffixIcon: IconButton(
                    icon: Icon(_obscureSearchKey
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded),
                    onPressed: () =>
                        setState(() => _obscureSearchKey = !_obscureSearchKey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCountCtl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _scheduleSearchSave(),
                      decoration: const InputDecoration(
                        labelText: '结果个数',
                        hintText: '5',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _searchLimitCtl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _scheduleSearchSave(),
                      decoration: const InputDecoration(
                        labelText: '内容长度限制',
                        hintText: '留空不限',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('搜索词附带当前日期'),
                subtitle: const Text('提升「最新 / 今天」类问题质量'),
                value: s.searchWithTime,
                onChanged: (v) => _patch((x) => x.searchWithTime = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _testConnection() async {
    final service = ChatService.from(_store.settings);
    String result;
    try {
      final reply = await service.chat(prompt: 'ping', history: []);
      result = reply != null ? '连接成功: $reply' : '连接成功（空回复）';
    } catch (e) {
      result = '连接失败: $e';
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('测试结果'),
        content: Text(result),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定')),
        ],
      ),
    );
  }
}
