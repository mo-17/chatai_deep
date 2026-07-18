import 'package:chatgpt_app_core/capability/model_picker_presenter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter/material.dart';

Future<TranslationModelPreference?> showConfiguredAiModelPickerSheet(
  BuildContext context, {
  required AISettings settings,
  required TranslationModelPreference selected,
  bool includeFollowGlobal = true,
  TranslationExecutionMode? onlyMode,
}) =>
    showModalBottomSheet<TranslationModelPreference>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ConfiguredAiModelPickerSheet(
        settings: settings,
        selected: selected,
        includeFollowGlobal: includeFollowGlobal,
        onlyMode: onlyMode,
      ),
    );

class _ConfiguredAiModelPickerSheet extends StatefulWidget {
  final AISettings settings;
  final TranslationModelPreference selected;
  final bool includeFollowGlobal;
  final TranslationExecutionMode? onlyMode;

  const _ConfiguredAiModelPickerSheet({
    required this.settings,
    required this.selected,
    required this.includeFollowGlobal,
    required this.onlyMode,
  });

  @override
  State<_ConfiguredAiModelPickerSheet> createState() =>
      _ConfiguredAiModelPickerSheetState();
}

class _ConfiguredAiModelPickerSheetState
    extends State<_ConfiguredAiModelPickerSheet> {
  final _searchController = TextEditingController();
  var _filter = ConversationModelPickerFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _searchController.text.trim().toLowerCase();
    final providers = _configuredProviders(widget.settings);
    final showLocal = widget.onlyMode != TranslationExecutionMode.backend;
    final showBackend = widget.onlyMode != TranslationExecutionMode.local;
    final backendModel = widget.settings.backendModel.trim();
    final hasVisibleLocal = providers.any(
      (provider) => _visibleModels(provider, query).isNotEmpty,
    );
    final hasBackend = showBackend &&
        backendModel.isNotEmpty &&
        (query.isEmpty || '后端代理 $backendModel'.toLowerCase().contains(query)) &&
        (_filter == ConversationModelPickerFilter.all ||
            _filter == ConversationModelPickerFilter.available);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: ListView(
          key: const ValueKey('configured_ai_model_picker'),
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: TextField(
                key: const ValueKey('configured_model_search'),
                controller: _searchController,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索模型或服务商',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _filterChip('全部', ConversationModelPickerFilter.all),
                  _filterChip('可用', ConversationModelPickerFilter.available),
                  _filterChip('图片', ConversationModelPickerFilter.image),
                  _filterChip('工具', ConversationModelPickerFilter.tool),
                  _filterChip('推理', ConversationModelPickerFilter.reasoning),
                ],
              ),
            ),
            if (widget.includeFollowGlobal)
              ListTile(
                key: const ValueKey('configured_model_follow_global'),
                leading: const Icon(Icons.public),
                title: const Text('跟随全局设置'),
                subtitle: Text(widget.settings.effectiveModel),
                trailing: widget.selected.mode ==
                        TranslationModelPreferenceMode.followGlobal
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  context,
                  const TranslationModelPreference(
                    mode: TranslationModelPreferenceMode.followGlobal,
                    reasoningPolicy: ChatReasoningPolicy.offIfSupported,
                  ),
                ),
              ),
            if (widget.includeFollowGlobal) const Divider(height: 1),
            if (hasBackend)
              ListTile(
                key: ValueKey('configured_model_backend_$backendModel'),
                leading: const Icon(Icons.cloud_outlined),
                title: Text(backendModel),
                subtitle: const Text('后端代理'),
                trailing: _isSelectedBackend(backendModel)
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  context,
                  TranslationModelPreference(
                    mode: TranslationModelPreferenceMode.backend,
                    modelId: backendModel,
                    reasoningPolicy: ChatReasoningPolicy.offIfSupported,
                  ),
                ),
              ),
            if (hasBackend) const Divider(height: 1),
            if (showLocal)
              for (final provider in providers)
                if (_visibleModels(provider, query).isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child:
                        Text(provider.name, style: theme.textTheme.labelLarge),
                  ),
                  for (final model in _visibleModels(provider, query))
                    _modelTile(provider, model),
                ],
            if ((!showLocal || !hasVisibleLocal) && !hasBackend)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '没有匹配的已配置模型',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  FilterChip _filterChip(
    String label,
    ConversationModelPickerFilter value,
  ) =>
      FilterChip(
        label: Text(label),
        selected: _filter == value,
        onSelected: (_) => setState(() => _filter = value),
        visualDensity: VisualDensity.compact,
      );

  List<AiModel> _visibleModels(AiProvider provider, String query) =>
      ConversationModelPickerPresenter.visibleModels(
        provider,
        query: query,
        filter: _filter,
      ).where((model) => model.id.trim().isNotEmpty).toList(growable: false);

  Widget _modelTile(AiProvider provider, AiModel model) {
    final theme = Theme.of(context);
    final caps = ConversationModelPickerPresenter.capabilities(provider, model);
    final failed = model.lastTestStatus == 'failure';
    final available = model.lastTestStatus == 'success';
    return ListTile(
      key: ValueKey('configured_model_${provider.id}_${model.id}'),
      dense: true,
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.id != model.name) Text(model.id),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              if (caps.image) _badge('图片'),
              if (caps.tool) _badge('工具'),
              if (caps.reasoning) _badge('推理'),
              if (caps.pdf) _badge('PDF'),
              if (available) _badge('可用'),
              if (failed) _badge('测试失败', error: true),
            ],
          ),
          if (model.lastUsedAt != null)
            Text(
              '最近使用：${_timeLabel(model.lastUsedAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
        ],
      ),
      trailing: _isSelectedLocal(provider.id, model.id)
          ? const Icon(Icons.check)
          : null,
      onTap: () => Navigator.pop(
        context,
        TranslationModelPreference(
          mode: TranslationModelPreferenceMode.local,
          providerId: provider.id,
          modelId: model.id,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
      ),
    );
  }

  Widget _badge(String label, {bool error = false}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          height: 1,
          color: error ? colors.onErrorContainer : colors.onSecondaryContainer,
        ),
      ),
    );
  }

  bool _isSelectedLocal(String providerId, String modelId) =>
      widget.selected.mode == TranslationModelPreferenceMode.local &&
      widget.selected.providerId == providerId &&
      widget.selected.modelId == modelId;

  bool _isSelectedBackend(String modelId) =>
      widget.selected.mode == TranslationModelPreferenceMode.backend &&
      widget.selected.modelId == modelId;

  static List<AiProvider> _configuredProviders(AISettings settings) => [
        for (final provider in settings.providers)
          if (provider.enabled &&
              provider.apiKey.trim().isNotEmpty &&
              provider.models.any((model) => model.id.trim().isNotEmpty))
            provider,
      ];

  static String _timeLabel(int millis) {
    final value = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
