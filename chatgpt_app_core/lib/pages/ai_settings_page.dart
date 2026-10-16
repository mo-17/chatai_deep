import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_health_check_page.dart';
import 'package:chatgpt_app_core/pages/ai_provider_list_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/widget/ai_provider/provider_avatar.dart';
import 'package:chatgpt_app_core/widget/ai_provider/backend_model_selection_tile.dart';
import 'package:chatgpt_app_core/widget/ai_provider/section_card.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';
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
  AiCatalogIdentity? _lastCatalogIdentity;
  late AIMode _lastMode;

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
    _lastMode = s.mode;
    _store.addListener(_settingsChanged);
    ModelCatalog.displayChanges.addListener(_catalogChanged);
    AiCatalogIdentity.changes.addListener(_identityChanged);
    BackendConfig.changes.addListener(_identityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _store.settings.mode == AIMode.backend) {
        unawaited(_refreshCatalog());
      }
    });
  }

  void _catalogChanged() {
    if (mounted) setState(() {});
  }

  void _settingsChanged() {
    final mode = _store.settings.mode;
    final entering = mode == AIMode.backend && _lastMode != AIMode.backend;
    _lastMode = mode;
    if (entering) unawaited(_refreshCatalog());
  }

  void _identityChanged() {
    _catalogChanged();
    if (_store.settings.mode == AIMode.backend) unawaited(_refreshCatalog());
  }

  Future<void> _refreshCatalog() async {
    if (!mounted ||
        _store.accountHash != _accountHashAtOpen ||
        (LoginDao.getAccountHash() ?? 'guest') != _accountHashAtOpen) {
      return;
    }
    final identity = AiCatalogIdentity.capture();
    _lastCatalogIdentity = identity;
    await ModelCatalog.refreshFromBackend(joinOngoing: true);
    if (mounted &&
        identical(_lastCatalogIdentity, identity) &&
        identity.current) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _store.removeListener(_settingsChanged);
    ModelCatalog.displayChanges.removeListener(_catalogChanged);
    AiCatalogIdentity.changes.removeListener(_identityChanged);
    BackendConfig.changes.removeListener(_identityChanged);
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
    final catalog = ModelCatalog.displaySnapshot;
    return BackendModelSelectionTile(
      selectionLabel: _backendSelectionLabel(s),
      catalogMessage: _backendCatalogMessage(),
      loading: catalog.loading,
      onSelect: _pickBackendModel,
      onRefresh: () => unawaited(_refreshCatalog()),
    );
  }

  String _backendCatalogMessage() {
    final snapshot = ModelCatalog.displaySnapshot;
    if (!snapshot.hasSnapshot) {
      return switch (snapshot.status) {
        CatalogDisplayStatus.notAuthenticated => '请登录后选择后端服务商与模型',
        CatalogDisplayStatus.forbidden => '服务器未开放模型目录，请联系管理员或明确填写服务商与模型',
        CatalogDisplayStatus.timeout => '获取模型目录超时，请刷新重试或明确填写服务商与模型',
        CatalogDisplayStatus.failed => '获取模型目录失败，请刷新重试或明确填写服务商与模型',
        CatalogDisplayStatus.invalid => '模型目录格式无效，请刷新或明确填写服务商与模型',
        CatalogDisplayStatus.loading => '正在加载服务商与模型清单…',
        _ => '模型清单未能确认，请刷新重试或明确填写服务商与模型',
      };
    }
    if (snapshot.options.isNotEmpty && _backendOptions().isEmpty) {
      return '上次清单缺少完整服务商信息，请刷新或明确填写';
    }
    return snapshot.message;
  }

  String _backendSelectionLabel(AISettings settings) {
    final selection = settings.backendSelection;
    if (selection == null) return '待确认服务商 · ${settings.backendModel}';
    if (!selection.isPair) return '原选择无法识别，请重新选择';
    final identity = AiCatalogIdentity.capture();
    final matches = ModelCatalog.displaySnapshot.options
        .where((o) =>
            o.providerCode == selection.providerCode &&
            o.id == selection.modelId)
        .toList();
    final label = matches.length == 1
        ? matches.single.backendLabel
        : '${selection.providerCode} · ${selection.modelId}';
    if (!selection.matchesScope(
        accountHash: identity.account ?? '',
        origin: identity.endpoint.origin)) {
      return '$label（其它账号或地址）';
    }
    if (!ModelCatalog.backendProfileAvailable(selection.modelId!,
        account: identity.account ?? '',
        providerCode: selection.providerCode)) {
      return '$label（已删除或停用，请重新选择）';
    }
    return label;
  }

  List<ModelOption> _backendOptions() {
    final snapshot = ModelCatalog.displaySnapshot;
    if (!snapshot.hasSnapshot) return const [];
    final seen = <String>{};
    for (final o in snapshot.options) {
      if (o.providerCode == null ||
          o.providerCode!.trim().isEmpty ||
          o.id.trim().isEmpty ||
          !seen.add(o.pairKey)) {
        return const [];
      }
    }
    return snapshot.options;
  }

  Future<void> _pickBackendModel() async {
    final identity = AiCatalogIdentity.capture();
    if (ModelCatalog.displaySnapshot.status == CatalogDisplayStatus.initial) {
      unawaited(_refreshCatalog());
    }
    final picked = await showModalBottomSheet<_BackendModelChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => AnimatedBuilder(
          animation: Listenable.merge([
            ModelCatalog.displayChanges,
            AiCatalogIdentity.changes,
            BackendConfig.changes,
          ]),
          builder: (ctx, _) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(title: Text(_backendCatalogMessage())),
                    ListTile(
                        title: Text(
                            '当前选择：${_backendSelectionLabel(_store.settings)}')),
                    for (final o in identity.current
                        ? _backendOptions()
                        : const <ModelOption>[])
                      ListTile(
                        key: ValueKey(o.pairKey),
                        title: Text(o.backendLabel),
                        trailing: o.providerCode ==
                                    _store.settings.backendSelection
                                        ?.providerCode &&
                                o.id ==
                                    _store.settings.backendSelection?.modelId
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: identity.authenticated
                            ? () => Navigator.pop(ctx, _BackendPairChoice(o))
                            : null,
                      ),
                    ListTile(
                      leading: const Icon(Icons.edit_rounded),
                      title: const Text('自定义服务商与模型...'),
                      onTap: identity.authenticated
                          ? () =>
                              Navigator.pop(ctx, const _BackendCustomChoice())
                          : null,
                    ),
                  ],
                ),
              )),
    );
    if (picked == null || !mounted || !identity.current) return;
    if (picked is _BackendPairChoice) {
      await _saveBackendPair(
          identity, picked.option.providerCode!, picked.option.id);
    } else if (picked is _BackendCustomChoice) {
      final value = await showDialog<_BackendCustomPair>(
          context: context,
          builder: (_) => _BackendPairDialog(
              providerCode:
                  _store.settings.backendSelection?.providerCode ?? '',
              modelId: _store.settings.backendSelection?.modelId ??
                  _store.settings.backendModel));
      if (value != null) {
        await _saveBackendPair(identity, value.providerCode, value.modelId);
      }
    }
  }

  Future<void> _saveBackendPair(
      AiCatalogIdentity identity, String providerCode, String modelId) async {
    if (!mounted ||
        !identity.current ||
        !identity.authenticated ||
        _store.accountHash != identity.account ||
        _store.settings.mode != AIMode.backend) {
      return;
    }
    final next = _store.settings.clone()
      ..backendSelection = BackendSelection.pair(
          providerCode: providerCode,
          modelId: modelId,
          accountHash: identity.account!,
          origin: identity.endpoint.origin);
    final saved = await _persistSettings(next, showError: false);
    if (!saved && mounted && identity.current) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('后端选择未保存，请稍后重试')));
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
        SwitchListTile(
          key: const ValueKey('composer_predictions_setting'),
          value: s.composerPredictionsEnabled,
          onChanged: (v) => _patch((x) => x.composerPredictionsEnabled = v),
          title: const Text('下一条消息建议'),
          subtitle: Text(
            '回复完成后，用当前模型和近期已发送对话预测下一条消息，会额外消耗模型用量。不发送未提交草稿；采纳仅填入输入框，由你确认发送。',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
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
              '${s.attachmentProcessingLimits.maxTextChars} 字符\n文本、Word、Excel、PDF 抽文本均适用',
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
              '${_formatAttachmentMiB(s.attachmentProcessingLimits.maxTextFileBytes)} MiB\n读取文本、Word、Excel 文件前检查大小',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: () => _editAttachmentLimit(fileSize: true),
        ),
        ListTile(
          key: const ValueKey('attachment_total_file_size_setting'),
          title: const Text('每轮附件总大小上限'),
          subtitle: Text(
              '${_formatAttachmentMiB(s.attachmentProcessingLimits.maxTotalFileBytes)} MiB\n数量不限；图片和文件合计按大小检查',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: () => _editAttachmentLimit(fileSize: true, total: true),
        ),
        ListTile(
          key: const ValueKey('attachment_total_chars_setting'),
          title: const Text('每轮附件总字数上限'),
          subtitle: Text(
              '${s.attachmentProcessingLimits.maxTotalTextChars} 字符\n正文与附件标记合计；任务模式按本轮导入原文计',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          trailing:
              Icon(Icons.edit_rounded, size: 18, color: cs.onSurfaceVariant),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          onTap: () => _editAttachmentLimit(fileSize: false, total: true),
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

  Future<void> _editAttachmentLimit(
      {required bool fileSize, bool total = false}) async {
    final limits = _store.settings.attachmentProcessingLimits;
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _AttachmentLimitDialog(
        fileSize: fileSize,
        total: total,
        initialValue: total
            ? (fileSize ? limits.maxTotalFileBytes : limits.maxTotalTextChars)
            : (fileSize ? limits.maxTextFileBytes : limits.maxTextChars),
      ),
    );
    if (value == null || !mounted) return;
    final next = _store.settings.clone();
    if (total && fileSize) {
      next.attachmentTotalMaxFileBytes = value;
    } else if (total) {
      next.attachmentTotalMaxChars = value;
    } else if (fileSize) {
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
        SwitchListTile(
          key: const ValueKey('default_web_search_setting'),
          title: const Text('默认开启联网搜索'),
          subtitle: const Text(
            '适用于跟随全局默认的新旧会话和创作／酒馆房间。'
            '会话、房间的独立选择及项目指定的默认值不受影响；'
            '仍需配置下方搜索服务商。',
          ),
          value: s.webSearchEnabled,
          onChanged: (value) => _patch((x) => x.webSearchEnabled = value),
        ),
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
  final bool total;
  final int initialValue;

  const _AttachmentLimitDialog({
    required this.fileSize,
    this.total = false,
    required this.initialValue,
  });

  @override
  State<_AttachmentLimitDialog> createState() => _AttachmentLimitDialogState();
}

class _AttachmentLimitDialogState extends State<_AttachmentLimitDialog> {
  int get _minMiB =>
      (widget.total
          ? AttachmentProcessingLimits.minTotalFileBytes
          : AttachmentProcessingLimits.minTextFileBytes) ~/
      (1024 * 1024);
  int get _maxMiB =>
      (widget.total
          ? AttachmentProcessingLimits.maximumTotalFileBytes
          : AttachmentProcessingLimits.maximumTextFileBytes) ~/
      (1024 * 1024);
  int get _minChars => widget.total
      ? AttachmentProcessingLimits.minTotalTextChars
      : AttachmentProcessingLimits.minTextChars;
  int get _maxChars => widget.total
      ? AttachmentProcessingLimits.maximumTotalTextChars
      : AttachmentProcessingLimits.maximumTextChars;
  int get _defaultValue => widget.total
      ? (widget.fileSize
          ? AttachmentProcessingLimits.defaultMaxTotalFileBytes
          : AttachmentProcessingLimits.defaultMaxTotalTextChars)
      : (widget.fileSize
          ? AttachmentProcessingLimits.defaultMaxTextFileBytes
          : AttachmentProcessingLimits.defaultMaxTextChars);
  String get _title => widget.total
      ? (widget.fileSize ? '每轮附件总大小上限' : '每轮附件总字数上限')
      : (widget.fileSize ? '文本文件大小上限' : '单个附件文字上限');
  String get _fieldKey => widget.total
      ? (widget.fileSize
          ? 'attachment_total_file_size_field'
          : 'attachment_total_chars_field')
      : (widget.fileSize
          ? 'attachment_text_file_size_field'
          : 'attachment_text_chars_field');
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
      return value != null && value >= _minChars && value <= _maxChars
          ? value
          : null;
    }
    final value = double.tryParse(trimmed);
    if (value == null ||
        !value.isFinite ||
        value < _minMiB ||
        value > _maxMiB) {
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
        title: Text(_title),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: ValueKey(_fieldKey),
                  controller: _controller,
                  autofocus: true,
                  keyboardType:
                      TextInputType.numberWithOptions(decimal: widget.fileSize),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  decoration: InputDecoration(
                    labelText: widget.fileSize ? '文件大小（MiB）' : '文字上限（字符）',
                    helperText: widget.fileSize
                        ? '范围：$_minMiB～$_maxMiB MiB，可输入小数'
                        : '范围：$_minChars～$_maxChars 字符',
                    border: AppVisualTheme.of(context).isAnime
                        ? null
                        : const OutlineInputBorder(),
                  ),
                  validator: (text) => _parseValue(text) != null
                      ? null
                      : widget.fileSize
                          ? '请输入 $_minMiB～$_maxMiB 之间的大小（MiB）'
                          : '请输入 $_minChars～$_maxChars 之间的整数',
                ),
                const SizedBox(height: 12),
                if (widget.total) ...[
                  Text(widget.fileSize
                      ? '附件数量不限。每轮图片和文件的原始大小合计不得超过此上限。'
                      : '附件数量不限。每轮抽取正文及附件标记合计按字符检查；任务模式按本轮导入原文计。'),
                  const SizedBox(height: 8),
                  const Text('图片和原生 PDF 不计入字数，仍受每轮总大小、模型能力和「应用输入预算」限制。'),
                ] else
                  Text(widget.fileSize
                      ? '适用于文本、Word、Excel 文件。图片和原生 PDF 上传仍按模型限制处理。'
                      : '适用于文本、Word、Excel 和 PDF 抽取的文字。超出时截取前面的内容，并显示截断提示。'),
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
                  ? _formatAttachmentMiB(_defaultValue)
                  : _defaultValue.toString();
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

sealed class _BackendModelChoice {
  const _BackendModelChoice();
}

final class _BackendPairChoice extends _BackendModelChoice {
  final ModelOption option;
  const _BackendPairChoice(this.option);
}

final class _BackendCustomChoice extends _BackendModelChoice {
  const _BackendCustomChoice();
}

final class _BackendCustomPair {
  final String providerCode, modelId;
  const _BackendCustomPair(this.providerCode, this.modelId);
}

class _BackendPairDialog extends StatefulWidget {
  final String providerCode, modelId;
  const _BackendPairDialog({required this.providerCode, required this.modelId});
  @override
  State<_BackendPairDialog> createState() => _BackendPairDialogState();
}

class _BackendPairDialogState extends State<_BackendPairDialog> {
  late final _provider = TextEditingController(text: widget.providerCode);
  late final _model = TextEditingController(text: widget.modelId);
  bool _invalid = false;
  @override
  void dispose() {
    _provider.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('自定义服务商与模型'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const ValueKey('backend_provider_code'),
              controller: _provider,
              decoration: InputDecoration(
                  labelText: '服务商 code',
                  errorText: _invalid && _provider.text.trim().isEmpty
                      ? '请输入服务商 code'
                      : null)),
          TextField(
              key: const ValueKey('backend_model_id'),
              controller: _model,
              decoration: InputDecoration(
                  labelText: '模型 id',
                  errorText: _invalid && _model.text.trim().isEmpty
                      ? '请输入模型 id'
                      : null)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
              onPressed: () {
                if (_provider.text.trim().isEmpty ||
                    _model.text.trim().isEmpty) {
                  setState(() => _invalid = true);
                  return;
                }
                Navigator.pop(
                    context, _BackendCustomPair(_provider.text, _model.text));
              },
              child: const Text('确定')),
        ],
      );
}
