import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/configured_ai_model_picker_sheet.dart';
import 'package:flutter/material.dart';

Future<TranslationModelPreference?> showTranslationSettingsDialog(
  BuildContext context, {
  required AISettings settings,
  required TranslationModelPreference initialValue,
  required int estimatedRunes,
  String title = '翻译设置',
}) =>
    showDialog<TranslationModelPreference>(
      context: context,
      builder: (_) => _TranslationSettingsDialog(
        settings: settings,
        initialValue: initialValue,
        estimatedRunes: estimatedRunes,
        title: title,
      ),
    );

class _TranslationSettingsDialog extends StatefulWidget {
  final AISettings settings;
  final TranslationModelPreference initialValue;
  final int estimatedRunes;
  final String title;

  const _TranslationSettingsDialog({
    required this.settings,
    required this.initialValue,
    required this.estimatedRunes,
    required this.title,
  });

  @override
  State<_TranslationSettingsDialog> createState() =>
      _TranslationSettingsDialogState();
}

class _TranslationSettingsDialogState
    extends State<_TranslationSettingsDialog> {
  late TranslationModelPreference _selected;
  late bool _disableThinking;

  @override
  void initState() {
    super.initState();
    _selected = _isAvailable(widget.settings, widget.initialValue)
        ? widget.initialValue
        : const TranslationModelPreference(
            mode: TranslationModelPreferenceMode.followGlobal,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          );
    // 每次任务默认优先快速翻译；模型选择会被记住，但是否关闭 Thinking
    // 由本次任务显式确认，不继承旧任务可能采用的 provider default。
    _disableThinking = true;
  }

  @override
  Widget build(BuildContext context) {
    final decision = _reasoningDecision(widget.settings, _selected);
    final supportsThinkingControl = decision.supported;
    final effectiveSwitch = supportsThinkingControl && _disableThinking;
    return AlertDialog(
      key: const ValueKey('translation_settings_dialog'),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('预计翻译 ${_formatRunes(widget.estimatedRunes)} 字'),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('translation_model_button'),
              icon: const Icon(Icons.smart_toy_outlined),
              label: Text(_selectionLabel(widget.settings, _selected)),
              onPressed: _pickModel,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('translation_disable_thinking'),
              contentPadding: EdgeInsets.zero,
              title: const Text('关闭深度思考（推荐）'),
              subtitle: Text(
                supportsThinkingControl
                    ? '翻译任务会显式请求快速输出，减少首字等待。'
                    : '该接口不会发送 Thinking 参数',
              ),
              value: effectiveSwitch,
              onChanged: supportsThinkingControl
                  ? (value) => setState(() => _disableThinking = value)
                  : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('translation_settings_cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('translation_settings_confirm'),
          onPressed: () => Navigator.pop(
            context,
            _copyWithReasoning(
              _selected,
              supportsThinkingControl && _disableThinking
                  ? ChatReasoningPolicy.offIfSupported
                  : ChatReasoningPolicy.providerDefault,
            ),
          ),
          child: const Text('开始翻译'),
        ),
      ],
    );
  }

  Future<void> _pickModel() async {
    final picked = await showConfiguredAiModelPickerSheet(
      context,
      settings: widget.settings,
      selected: _selected,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _selected = picked;
      _disableThinking = true;
    });
  }

  static TranslationModelPreference _copyWithReasoning(
    TranslationModelPreference value,
    ChatReasoningPolicy reasoningPolicy,
  ) =>
      TranslationModelPreference(
        mode: value.mode,
        providerId: value.providerId,
        modelId: value.modelId,
        reasoningPolicy: reasoningPolicy,
      );

  static bool _isAvailable(
    AISettings settings,
    TranslationModelPreference value,
  ) {
    switch (value.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        return true;
      case TranslationModelPreferenceMode.backend:
        return value.modelId != null &&
            value.modelId == settings.backendModel.trim() &&
            value.modelId!.isNotEmpty;
      case TranslationModelPreferenceMode.local:
        final provider = _provider(settings, value.providerId);
        return provider != null &&
            provider.enabled &&
            provider.apiKey.trim().isNotEmpty &&
            provider.models.any((model) => model.id == value.modelId);
    }
  }

  static ReasoningControlDecision _reasoningDecision(
    AISettings settings,
    TranslationModelPreference value,
  ) {
    switch (value.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        if (settings.mode == AIMode.backend) {
          return ReasoningControlAdapter.resolve(
            providerId: null,
            providerCode: null,
            modelId: settings.backendModel,
            policy: ChatReasoningPolicy.offIfSupported,
          );
        }
        final provider = settings.activeProvider;
        return ReasoningControlAdapter.resolve(
          providerId: provider.id,
          providerCode: provider.providerCode,
          modelId: provider.effectiveModelId,
          policy: ChatReasoningPolicy.offIfSupported,
        );
      case TranslationModelPreferenceMode.local:
        final provider = _provider(settings, value.providerId);
        return ReasoningControlAdapter.resolve(
          providerId: provider?.id,
          providerCode: provider?.providerCode,
          modelId: value.modelId ?? '',
          policy: ChatReasoningPolicy.offIfSupported,
        );
      case TranslationModelPreferenceMode.backend:
        return ReasoningControlAdapter.resolve(
          providerId: null,
          providerCode: null,
          modelId: value.modelId ?? '',
          policy: ChatReasoningPolicy.offIfSupported,
        );
    }
  }

  static AiProvider? _provider(AISettings settings, String? providerId) {
    for (final provider in settings.providers) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }

  static String _selectionLabel(
    AISettings settings,
    TranslationModelPreference value,
  ) {
    switch (value.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        return '跟随全局：${settings.effectiveModel}';
      case TranslationModelPreferenceMode.backend:
        return '后端代理：${value.modelId}';
      case TranslationModelPreferenceMode.local:
        final provider = _provider(settings, value.providerId);
        return '${provider?.name ?? value.providerId} / ${value.modelId}';
    }
  }

  static String _formatRunes(int value) {
    final digits = value < 0 ? 0 : value;
    final text = '$digits';
    final buffer = StringBuffer();
    for (var index = 0; index < text.length; index += 1) {
      if (index > 0 && (text.length - index) % 3 == 0) buffer.write(',');
      buffer.write(text[index]);
    }
    return buffer.toString();
  }
}
