import 'dart:async';

import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/data/provider_presets.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/ai_provider/api_key_field.dart';
import 'package:chatgpt_app_core/widget/ai_provider/capability_chip.dart';
import 'package:chatgpt_app_core/widget/ai_provider/provider_avatar.dart';
import 'package:chatgpt_app_core/widget/ai_provider/section_card.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

enum _TestState { idle, running, success, failure }

/// 服务商详情页：迁移自 Cherry 的「服务商设置」。
/// 配 API Key / 地址、测试连接、管理模型、设为当前。改动即时保存。
class AiProviderDetailPage extends StatefulWidget {
  final String providerId;
  const AiProviderDetailPage({super.key, required this.providerId});

  @override
  State<AiProviderDetailPage> createState() => _AiProviderDetailPageState();
}

class _AiProviderDetailPageState extends State<AiProviderDetailPage> {
  late final TextEditingController _keyCtl;
  late final TextEditingController _hostCtl;
  Timer? _debounce;

  _TestState _testState = _TestState.idle;
  String? _testError;
  final Map<String, _TestState> _modelTestStates = {};
  final Map<String, String> _modelTestErrors = {};

  // initState 时缓存，避免 dispose 里再用 context.read。
  late final AISettingsProvider _store = context.read<AISettingsProvider>();
  late final String _accountHashAtOpen = _store.accountHash;

  AiProvider? get _provider {
    final list =
        _store.settings.providers.where((p) => p.id == widget.providerId);
    return list.isEmpty ? null : list.first;
  }

  @override
  void initState() {
    super.initState();
    final p = _provider;
    _keyCtl = TextEditingController(text: p?.apiKey ?? '');
    _hostCtl = TextEditingController(text: p?.apiHost ?? '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 落盘未触发的防抖编辑（如粘贴 Key 后立刻返回），静默保存避免丢失。
    unawaited(_flush(notify: false, showError: false));
    _keyCtl.dispose();
    _hostCtl.dispose();
    super.dispose();
  }

  /// 文本框防抖保存（500ms），避免每个字符都落盘。
  void _debouncedSave() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flush()),
    );
  }

  Future<bool> _flush({
    bool notify = true,
    bool showError = true,
  }) async {
    final p = _provider?.copy();
    if (p == null) return true;
    final nextKey = _keyCtl.text.trim();
    final nextHost = _hostCtl.text.trim();
    final configChanged = p.apiKey != nextKey || p.apiHost != nextHost;
    p.apiKey = nextKey;
    p.apiHost = nextHost;
    if (configChanged) {
      for (final model in p.models) {
        model.clearTestResult();
      }
    }
    return _persistProvider(
      p,
      notify: notify,
      showError: showError,
    );
  }

  Future<bool> _persistProvider(
    AiProvider provider, {
    bool notify = true,
    bool showError = true,
  }) async {
    try {
      await _store.updateProvider(
        provider,
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

  String get _defaultHost =>
      ProviderPresets.byId(widget.providerId)?.apiHost ?? '';

  String get _apiKeyUrl =>
      ProviderPresets.apiKeyUrls[widget.providerId] ??
      ProviderPresets.officialUrls[widget.providerId] ??
      '';

  Future<void> _openApiKeyUrl() async {
    final url = _apiKeyUrl;
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _runTest() async {
    if (!await _flush()) return;
    setState(() {
      _testState = _TestState.running;
      _testError = null;
    });
    // 用「本地模式 + 当前服务商」克隆一份设置来测，复用聊天链路。
    final s = _store.settings.clone()
      ..mode = AIMode.local
      ..activeProviderId = widget.providerId;
    try {
      // 空回复也算连通（拿到了合法响应）。
      await ChatService.from(s).chat(prompt: 'ping', history: []);
      if (!mounted) return;
      setState(() => _testState = _TestState.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testState = _TestState.failure;
        _testError = '$e';
      });
    }
  }

  Future<void> _runModelTest(String modelId) async {
    if (!await _flush()) return;
    final currentProvider = _provider?.copy();
    if (currentProvider == null) return;
    final expectedConfiguration =
        AIProviderHealthConfiguration.capture(currentProvider);
    setState(() {
      _modelTestStates[modelId] = _TestState.running;
      _modelTestErrors.remove(modelId);
    });
    final s = _store.settings.clone()
      ..mode = AIMode.local
      ..activeProviderId = widget.providerId;
    final p = s.providers.firstWhere((e) => e.id == widget.providerId);
    p.selectedModelId = modelId;
    if (!p.models.any((m) => m.id == modelId)) {
      p.models.insert(0, AiModel(id: modelId));
    }
    Object? requestError;
    try {
      await ChatService.from(s).chat(prompt: 'ping', history: []);
    } catch (e) {
      requestError = e;
    }
    if (!mounted) return;

    try {
      final recorded = await _store.recordModelTestResult(
        providerId: widget.providerId,
        modelId: modelId,
        expectedConfiguration: expectedConfiguration,
        success: requestError == null,
        error: requestError?.toString(),
        expectedAccountHash: _accountHashAtOpen,
      );
      if (!mounted) return;
      if (!recorded) {
        setState(() {
          _modelTestStates[modelId] = _TestState.failure;
          _modelTestErrors[modelId] = '配置已变化，请重新测试';
        });
        return;
      }
      setState(() {
        _modelTestStates[modelId] =
            requestError == null ? _TestState.success : _TestState.failure;
        if (requestError != null) {
          _modelTestErrors[modelId] = '$requestError';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _modelTestStates[modelId] = _TestState.failure;
        _modelTestErrors[modelId] = '测试结果未保存：$error';
      });
    }
  }

  String _testTimeLabel(int? millis) {
    if (millis == null || millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  void _setActive() {
    unawaited(_persistAction(
      () => _store.setActiveProvider(
        widget.providerId,
        expectedAccountHash: _accountHashAtOpen,
      ),
    ));
  }

  void _selectModel(String modelId) {
    final p = _provider?.copy();
    if (p == null) return;
    p.selectedModelId = modelId;
    final models = p.models.where((m) => m.id == modelId);
    if (models.isNotEmpty) models.first.markUsed();
    unawaited(_persistProvider(p));
  }

  void _removeModel(String modelId) {
    final p = _provider?.copy();
    if (p == null) return;
    p.models.removeWhere((m) => m.id == modelId);
    _modelTestStates.remove(modelId);
    _modelTestErrors.remove(modelId);
    if (p.selectedModelId == modelId) {
      p.selectedModelId = p.models.isNotEmpty ? p.models.first.id : '';
    }
    unawaited(_persistProvider(p));
  }

  Future<bool> _persistAction(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置未保存，请稍后重试：$error')),
        );
      }
      return false;
    }
  }

  Future<void> _showAddModelSheet() async {
    final idCtl = TextEditingController();
    final nameCtl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.viewInsetsOf(ctx).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加模型', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 16),
            TextField(
              controller: idCtl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '模型 id *',
                hintText: 'gpt-4o',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: '显示名（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final id = idCtl.text.trim();
                  if (id.isEmpty) return;
                  final p = _provider?.copy();
                  if (p != null && !p.models.any((m) => m.id == id)) {
                    p.models.add(AiModel(
                        id: id,
                        name: nameCtl.text.trim().isEmpty
                            ? id
                            : nameCtl.text.trim()));
                    p.selectedModelId = id;
                    unawaited(_persistProvider(p));
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('添加'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除服务商'),
        content: Text('确定删除「${_provider?.name ?? ''}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      final saved = await _persistAction(
        () => _store.removeProvider(
          widget.providerId,
          expectedAccountHash: _accountHashAtOpen,
        ),
      );
      if (saved && mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    // watch：启用/激活/模型变化时重建。
    context.watch<AISettingsProvider>();
    final p = _provider;
    if (p == null) {
      return const Scaffold(body: Center(child: Text('服务商不存在')));
    }
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final visual = AppVisualTheme.of(context);
    final isActive = _store.settings.activeProviderId == p.id;

    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          if (!p.isSystem)
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _buildHeader(p, cs, tt, isActive),
          const SizedBox(height: 20),

          // 基本配置
          const SectionLabel('基本配置'),
          SectionCard(
            children: [
              SwitchListTile(
                value: p.enabled,
                onChanged: (v) => unawaited(_persistAction(
                  () => _store.toggleProvider(
                    p.id,
                    v,
                    expectedAccountHash: _accountHashAtOpen,
                  ),
                )),
                title: const Text('启用'),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
              ListTile(
                title: const Text('协议类型'),
                trailing: Text(p.type,
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // API Key
          const SectionLabel('API Key'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ApiKeyField(
              controller: _keyCtl,
              onChanged: (_) => _debouncedSave(),
            ),
          ),
          if (_apiKeyUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: InkWell(
                onTap: _openApiKeyUrl,
                borderRadius: visual.isAnime ? BorderRadius.circular(14) : null,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: visual.isAnime ? 44 : 0,
                  ),
                  child: Padding(
                    padding: visual.isAnime
                        ? const EdgeInsets.symmetric(horizontal: 8)
                        : EdgeInsets.zero,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.open_in_new_rounded,
                            size: 14, color: cs.primary),
                        const SizedBox(width: 4),
                        Text('去申请 API Key',
                            style: tt.labelMedium?.copyWith(color: cs.primary)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 20),

          // API Host
          const SectionLabel('API 地址'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _hostCtl,
              onChanged: (_) => _debouncedSave(),
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: _defaultHost,
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                helperText: _defaultHost.isNotEmpty
                    ? 'ⓘ 留空用默认地址；自动补全 /chat/completions'
                    : 'ⓘ 需填写完整 API 地址（裸主机会自动补全 /v1/chat/completions）',
                border: visual.isAnime
                    ? null
                    : OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                suffixIcon: _defaultHost.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '恢复默认',
                        icon: const Icon(Icons.restart_alt_rounded),
                        onPressed: () {
                          _hostCtl.text = _defaultHost;
                          unawaited(_flush());
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 测试连接
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildTestButton(cs, tt),
          ),
          const SizedBox(height: 24),

          // 模型
          Row(
            children: [
              const SectionLabel('模型',
                  padding: EdgeInsets.fromLTRB(16, 0, 8, 8)),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: TextButton.icon(
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('添加模型'),
                  onPressed: _showAddModelSheet,
                ),
              ),
            ],
          ),
          SectionCard(
            children: [
              if (p.models.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('暂无模型，点「添加模型」')),
                )
              else
                for (final m in p.models) _buildModelTile(p, m, cs, tt),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildHeader(
      AiProvider p, ColorScheme cs, TextTheme tt, bool isActive) {
    final visual = AppVisualTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Hero(
            tag: 'provider-avatar-${p.id}',
            child: ProviderAvatar(providerId: p.id, name: p.name, size: 56),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: tt.headlineSmall),
                const SizedBox(height: 6),
                if (isActive && p.enabled)
                  _statusPill(
                      '✓ 当前服务商', cs.primaryContainer, cs.onPrimaryContainer, tt)
                else if (p.enabled)
                  TextButton(
                    onPressed: _setActive,
                    style: visual.isAnime
                        ? null
                        : TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 0),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                    child: const Text('设为当前服务商'),
                  )
                else
                  _statusPill('未启用', cs.surfaceContainerHighest,
                      cs.onSurfaceVariant, tt),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String text, Color bg, Color fg, TextTheme tt) {
    final visual = AppVisualTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: visual.isAnime
          ? ShapeDecoration(
              color: bg,
              shape: StadiumBorder(
                side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
            )
          : BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: tt.labelMedium?.copyWith(color: fg)),
    );
  }

  Widget _buildTestButton(ColorScheme cs, TextTheme tt) {
    final visual = AppVisualTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: _testState == _TestState.running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check_rounded),
            label: Text(_testState == _TestState.running ? '检测中...' : '测试连接'),
            onPressed: _testState == _TestState.running ? null : _runTest,
            style: visual.isAnime
                ? null
                : OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: switch (_testState) {
            _TestState.success => Padding(
                key: const ValueKey('ok'),
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: visual.isAnime
                        ? AppStatusPalette.of(context, AppStatusKind.success)
                            .foreground
                        : Colors.green,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text('连接成功', style: tt.bodySmall),
                ]),
              ),
            _TestState.failure => Padding(
                key: const ValueKey('err'),
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Icon(Icons.cancel_rounded, color: cs.error, size: 18),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(_testError ?? '连接失败',
                        style: tt.bodySmall?.copyWith(color: cs.error),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }

  Widget _buildModelTile(
      AiProvider p, AiModel m, ColorScheme cs, TextTheme tt) {
    final visual = AppVisualTheme.of(context);
    final selected = p.selectedModelId == m.id ||
        (p.selectedModelId.isEmpty && p.models.first.id == m.id);
    final persistedState = switch (m.lastTestStatus) {
      'success' => _TestState.success,
      'failure' => _TestState.failure,
      _ => _TestState.idle,
    };
    final testState = _modelTestStates[m.id] ?? persistedState;
    final testError = _modelTestErrors[m.id] ?? m.lastTestError;
    final testTime = _testTimeLabel(m.lastTestAt);
    final chips = <Widget>[
      if (m.vision)
        const CapabilityChip(label: '视觉', icon: Icons.image_outlined),
      if (m.tool) const CapabilityChip(label: '工具', icon: Icons.build_outlined),
      if (m.reasoning)
        const CapabilityChip(label: '推理', icon: Icons.lightbulb_outline),
      if (m.web)
        const CapabilityChip(label: '联网', icon: Icons.travel_explore_outlined),
    ];
    final statusChips = <Widget>[
      ...chips,
      if (testState == _TestState.success)
        const CapabilityChip(label: '可用', icon: Icons.check_circle_outline),
      if (testState == _TestState.failure)
        CapabilityChip(
            label: '不可用',
            icon: Icons.error_outline,
            color: cs.errorContainer,
            textColor: cs.onErrorContainer),
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        color: selected ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Text(m.name, style: tt.bodyMedium),
      subtitle: statusChips.isEmpty && testError == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (statusChips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child:
                        Wrap(spacing: 4, runSpacing: 4, children: statusChips),
                  ),
                if (testError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(testError,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(color: cs.error)),
                  ),
                if (testTime.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('上次测试：$testTime',
                        style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontSize: visual.isAnime ? null : 11)),
                  ),
              ],
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: testState == _TestState.running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check_rounded),
            tooltip: '测试模型',
            onPressed: testState == _TestState.running
                ? null
                : () => _runModelTest(m.id),
          ),
          IconButton(
            icon: Icon(Icons.remove_circle_outline_rounded, color: cs.error),
            tooltip: '移除',
            onPressed: () => _removeModel(m.id),
          ),
        ],
      ),
      onTap: () => _selectModel(m.id),
    );
  }
}
