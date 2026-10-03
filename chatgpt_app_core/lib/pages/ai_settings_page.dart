import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_health_check_page.dart';
import 'package:chatgpt_app_core/pages/ai_provider_list_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
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
  late final String _accountHashAtOpen = _store.accountHash;

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
    unawaited(_flushSearch(notify: false, showError: false));
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
    unawaited(_persistSettings(s));
  }

  Future<bool> _persistSettings(
    AISettings settings, {
    bool notify = true,
    bool showError = true,
  }) async {
    try {
      await _store.update(
        settings,
        notify: notify,
        expectedAccountHash: _accountHashAtOpen,
      );
      return true;
    } catch (error) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置未保存，请稍后重试：$error')),
        );
      }
      return false;
    }
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
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flushSearch()),
    );
  }

  /// 一次性把搜索区三类文本框（结果数 / 长度 / 当前服务商 Key）全部读出落盘，
  /// 避免「单字段防抖」在并发编辑不同字段时互相覆盖丢失。
  Future<bool> _flushSearch({
    bool notify = true,
    bool showError = true,
  }) async {
    final s = _store.settings.clone();
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
    return _persistSettings(
      s,
      notify: notify,
      showError: showError,
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AISettingsProvider>();
    final s = _store.settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 设置'),
        actions: [
          IconButton(
            tooltip: '服务商健康检查',
            icon: const Icon(Icons.health_and_safety_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiHealthCheckPage()),
            ),
          ),
        ],
      ),
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
                    HiDialog.showSnackBar(context, '游客模式仅支持本地直连，登录后可使用后端代理');
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
      subtitle:
          Text(active.name, style: tt.bodySmall?.copyWith(color: cs.primary)),
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
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
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
      builder: (dialogContext) => AlertDialog(
        title: const Text('自定义模型'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '输入模型 id',
            border: AppVisualTheme.of(dialogContext).isAnime
                ? null
                : const OutlineInputBorder(),
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
        ListTile(
          key: const ValueKey('context_input_budget_setting'),
          title: const Text('应用输入预算'),
          subtitle: Text(
              '${s.effectiveContextInputBudgetTokens} Token\n控制本轮问题、附件和历史的输入总量',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: _editInputBudget,
        ),
        ListTile(
          key: const ValueKey('attachment_text_chars_setting'),
          title: const Text('单个附件文字上限'),
          subtitle: Text(
              '${s.attachmentProcessingLimits.maxTextChars} 字符\n文本文件、PDF 抽文本均适用',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: () => _editAttachmentLimit(fileSize: false),
        ),
        ListTile(
          key: const ValueKey('attachment_text_file_size_setting'),
          title: const Text('文本文件大小上限'),
          subtitle: Text(
              '${_formatAttachmentMiB(s.attachmentProcessingLimits.maxTextFileBytes)} MiB\n读取文本文件前检查文件大小',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: () => _editAttachmentLimit(fileSize: true),
        ),
        ListTile(
          title: const Text('采样温度'),
          subtitle: Text(
              s.temperature == null
                  ? '默认（不发送）'
                  : 'temperature ${s.temperature!.toStringAsFixed(1)}',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: _editTemperature,
        ),
        ListTile(
          title: const Text('核采样 Top P'),
          subtitle: Text(
              s.topP == null
                  ? '默认（不发送）'
                  : 'top_p ${s.topP!.toStringAsFixed(2)}',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: _editTopP,
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

  Future<void> _editInputBudget() async {
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _ContextInputBudgetDialog(
          initialValue: _store.settings.effectiveContextInputBudgetTokens),
    );
    if (value == null || !mounted) return;
    final next = _store.settings.clone()..contextInputBudgetTokens = value;
    await _persistSettings(next);
  }

  Future<void> _editAttachmentLimit({required bool fileSize}) async {
    final limits = _store.settings.attachmentProcessingLimits;
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _AttachmentLimitDialog(
        fileSize: fileSize,
        initialValue: fileSize ? limits.maxTextFileBytes : limits.maxTextChars,
      ),
    );
    if (value == null || !mounted) return;
    final next = _store.settings.clone();
    if (fileSize) {
      next.attachmentTextMaxFileBytes = value;
    } else {
      next.attachmentTextMaxChars = value;
    }
    await _persistSettings(next);
  }

  Future<void> _editMaxTokens() async {
    final ctl = TextEditingController(
        text: _store.settings.maxOutputTokens > 0
            ? _store.settings.maxOutputTokens.toString()
            : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('最大输出长度'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'max_tokens',
            hintText: '留空不限制（推荐）',
            helperText: 'ⓘ 设太小会截断回复；推理模型的思考也计入',
            border: AppVisualTheme.of(dialogContext).isAnime
                ? null
                : const OutlineInputBorder(),
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

  /// 采样温度编辑：开关 + 0.0~2.0 滑块。关闭则置 null（请求不带 temperature）。
  Future<void> _editTemperature() async {
    final current = _store.settings.temperature;
    bool enabled = current != null;
    double value = current ?? 1.0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final cs = Theme.of(ctx).colorScheme;
          final tt = Theme.of(ctx).textTheme;
          return AlertDialog(
            title: const Text('采样温度'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用温度调节'),
                  subtitle: const Text('关闭则不发送 temperature，用模型默认'),
                  value: enabled,
                  onChanged: (v) => setLocal(() => enabled = v),
                ),
                Opacity(
                  opacity: enabled ? 1 : 0.4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('temperature', style: tt.bodyMedium),
                          Text(value.toStringAsFixed(1),
                              style:
                                  tt.titleMedium?.copyWith(color: cs.primary)),
                        ],
                      ),
                      Slider(
                        value: value,
                        min: 0.0,
                        max: 2.0,
                        divisions: 20,
                        label: value.toStringAsFixed(1),
                        onChanged:
                            enabled ? (v) => setLocal(() => value = v) : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text('低（如 0.2）更确定、稳定；高（如 1.0+）更发散、有创意。',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确定')),
            ],
          );
        },
      ),
    );
    if (ok == true) {
      _patch((s) => s.temperature = enabled ? value : null);
    }
  }

  Future<void> _editTopP() async {
    final current = _store.settings.topP;
    var enabled = current != null;
    var value = current ?? 1.0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('核采样 Top P'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 Top P'),
                subtitle: const Text('关闭则不发送 top_p，用模型默认'),
                value: enabled,
                onChanged: (next) => setLocal(() => enabled = next),
              ),
              Opacity(
                opacity: enabled ? 1 : 0.4,
                child: Slider(
                  value: value,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: value.toStringAsFixed(2),
                  onChanged:
                      enabled ? (next) => setLocal(() => value = next) : null,
                ),
              ),
              Text('当前值：${value.toStringAsFixed(2)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      _patch((settings) => settings.topP = enabled ? value : null);
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
    final isAnime = AppVisualTheme.of(context).isAnime;
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
                decoration: InputDecoration(
                  labelText: '搜索服务商',
                  border: isAnime ? null : const OutlineInputBorder(),
                  isDense: isAnime ? false : true,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: active.$1,
                    isDense: isAnime ? false : true,
                    isExpanded: true,
                    items: [
                      for (final p in _searchProviders)
                        DropdownMenuItem(value: p.$1, child: Text(p.$2)),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      // 先把当前服务商的 Key/参数落盘，再切换，避免丢失。
                      if (!await _flushSearch(notify: false)) return;
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
                  border: isAnime ? null : const OutlineInputBorder(),
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
              LayoutBuilder(
                builder: (context, constraints) {
                  final fieldWidth = constraints.maxWidth < 420
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: fieldWidth,
                        child: TextField(
                          controller: _searchCountCtl,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => _scheduleSearchSave(),
                          decoration: InputDecoration(
                            labelText: '结果个数',
                            hintText: '5',
                            border: isAnime ? null : const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: fieldWidth,
                        child: TextField(
                          controller: _searchLimitCtl,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => _scheduleSearchSave(),
                          decoration: InputDecoration(
                            labelText: '内容长度限制',
                            hintText: '留空不限',
                            border: isAnime ? null : const OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
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
              onPressed: () => Navigator.pop(context), child: const Text('确定')),
        ],
      ),
    );
  }
}

class _ContextInputBudgetDialog extends StatefulWidget {
  final int initialValue;

  const _ContextInputBudgetDialog({required this.initialValue});

  @override
  State<_ContextInputBudgetDialog> createState() =>
      _ContextInputBudgetDialogState();
}

class _ContextInputBudgetDialogState extends State<_ContextInputBudgetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue.toString());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('应用输入预算'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const ValueKey('context_input_budget_field'),
                  controller: _controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  decoration: InputDecoration(
                    labelText: '输入预算（Token）',
                    helperText: '范围：1024～1048576',
                    border: AppVisualTheme.of(context).isAnime
                        ? null
                        : const OutlineInputBorder(),
                  ),
                  validator: (text) {
                    final value = int.tryParse(text?.trim() ?? '');
                    if (value == null ||
                        value < AISettings.minContextInputBudgetTokens ||
                        value > AISettings.maxContextInputBudgetTokens) {
                      return '请输入 1024～1048576 之间的整数';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                const Text('超出预算时压缩较早对话，原始记录保留。输出长度单独设置；请根据模型实际容量调整。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _controller.text =
                  AISettings.defaultContextInputBudgetTokens.toString();
              _formKey.currentState?.validate();
            },
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (_formKey.currentState?.validate() != true) return;
              Navigator.pop(context, int.parse(_controller.text.trim()));
            },
            child: const Text('保存'),
          ),
        ],
      );
}

String _formatAttachmentMiB(int bytes) =>
    (bytes / (1024 * 1024)).toString().replaceFirst(RegExp(r'\.0$'), '');

class _AttachmentLimitDialog extends StatefulWidget {
  final bool fileSize;
  final int initialValue;

  const _AttachmentLimitDialog({
    required this.fileSize,
    required this.initialValue,
  });

  @override
  State<_AttachmentLimitDialog> createState() => _AttachmentLimitDialogState();
}

class _AttachmentLimitDialogState extends State<_AttachmentLimitDialog> {
  static const _minMiB =
      AttachmentProcessingLimits.minTextFileBytes ~/ (1024 * 1024);
  static const _maxMiB =
      AttachmentProcessingLimits.maximumTextFileBytes ~/ (1024 * 1024);
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.fileSize
        ? _formatAttachmentMiB(widget.initialValue)
        : widget.initialValue.toString(),
  );

  int? _parseValue(String? text) {
    final trimmed = text?.trim() ?? '';
    if (!widget.fileSize) {
      final value = int.tryParse(trimmed);
      return value != null &&
              value >= AttachmentProcessingLimits.minTextChars &&
              value <= AttachmentProcessingLimits.maximumTextChars
          ? value
          : null;
    }
    final value = double.tryParse(trimmed);
    if (value == null || !value.isFinite || value < _minMiB || value > _maxMiB) {
      return null;
    }
    return (value * 1024 * 1024).round();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.fileSize ? '文本文件大小上限' : '单个附件文字上限'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: ValueKey(widget.fileSize
                      ? 'attachment_text_file_size_field'
                      : 'attachment_text_chars_field'),
                  controller: _controller,
                  autofocus: true,
                  keyboardType:
                      TextInputType.numberWithOptions(decimal: widget.fileSize),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  decoration: InputDecoration(
                    labelText: widget.fileSize ? '文件大小（MiB）' : '文字上限（字符）',
                    helperText: widget.fileSize
                        ? '范围：$_minMiB～$_maxMiB MiB，可输入小数'
                        : '范围：1024～1048576 字符',
                    border: AppVisualTheme.of(context).isAnime
                        ? null
                        : const OutlineInputBorder(),
                  ),
                  validator: (text) => _parseValue(text) != null
                      ? null
                      : widget.fileSize
                          ? '请输入 $_minMiB～$_maxMiB 之间的大小（MiB）'
                          : '请输入 1024～1048576 之间的整数',
                ),
                const SizedBox(height: 12),
                Text(widget.fileSize
                    ? '适用于 TXT、Markdown 等文本文件。图片和原生 PDF 上传仍按模型限制处理。'
                    : '适用于文本文件和 PDF 抽取的文字。超出时截取前面的内容，并显示截断提示。'),
                const SizedBox(height: 8),
                const Text('本轮问题、附件和历史合计仍受「应用输入预算」限制。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _controller.text = widget.fileSize
                  ? _formatAttachmentMiB(
                      AttachmentProcessingLimits.defaultMaxTextFileBytes)
                  : AttachmentProcessingLimits.defaultMaxTextChars.toString();
              _formKey.currentState?.validate();
            },
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (_formKey.currentState?.validate() != true) return;
              Navigator.pop(context, _parseValue(_controller.text));
            },
            child: const Text('保存'),
          ),
        ],
      );
}
