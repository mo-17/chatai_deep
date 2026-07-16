import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

enum _HealthState { idle, running, success, failure }

/// 服务商健康检查：批量测试已启用服务商的模型连通性，并写回 AiModel 测试状态。
class AiHealthCheckPage extends StatefulWidget {
  const AiHealthCheckPage({super.key});

  @override
  State<AiHealthCheckPage> createState() => _AiHealthCheckPageState();
}

class _AiHealthCheckPageState extends State<AiHealthCheckPage> {
  final _states = <String, _HealthState>{};
  final _errors = <String, String>{};
  bool _testingAll = false;
  bool _cancelRequested = false;

  String _key(String providerId, String modelId) => '$providerId::$modelId';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AISettingsProvider>();
    final providers = store.settings.enabledProviders;
    final isAnime = AppVisualTheme.of(context).isAnime;
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务商健康检查'),
        actions: [
          IconButton(
            tooltip: '复制诊断',
            onPressed: () => _copyDiagnostics(store.settings),
            icon: const Icon(Icons.copy_all_outlined),
          ),
          if (isAnime)
            IconButton(
              tooltip: _testingAll ? '停止全部测试' : '测试全部模型',
              onPressed: _testingAll
                  ? () => setState(() => _cancelRequested = true)
                  : () => _testAll(store, providers),
              icon: Icon(_testingAll
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline_rounded),
            )
          else
            TextButton(
              onPressed: _testingAll
                  ? () => setState(() => _cancelRequested = true)
                  : () => _testAll(store, providers),
              child: Text(_testingAll ? '停止' : '全部测试'),
            ),
        ],
      ),
      body: providers.isEmpty
          ? const AppVisualEmptyState(
              animeKey: ValueKey('health_check_empty_state'),
              icon: Icons.health_and_safety_outlined,
              title: '暂无已启用的服务商',
              message: '先在 AI 服务设置中启用服务商，再回来批量检查模型。',
              classic: Center(child: Text('暂无已启用的服务商')),
            )
          : isAnime
              ? ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: providers.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, index) =>
                      _providerSurface(store, providers[index]),
                )
              : ListView(
                  children: [
                    for (final provider in providers) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
                        child: Text(provider.name,
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      for (final model in provider.models)
                        _modelTile(store, provider, model),
                    ],
                  ],
                ),
    );
  }

  Widget _providerSurface(AISettingsProvider store, AiProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    return AppVisualSurface(
      animeKey: ValueKey('health_provider_${provider.id}'),
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.dns_outlined,
                      color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(provider.name,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(
                  '${provider.models.length} 个模型',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Divider(),
          for (var index = 0; index < provider.models.length; index++) ...[
            _modelTile(store, provider, provider.models[index]),
            if (index != provider.models.length - 1) const Divider(indent: 68),
          ],
        ],
      ),
    );
  }

  Widget _modelTile(
      AISettingsProvider store, AiProvider provider, AiModel model) {
    final cs = Theme.of(context).colorScheme;
    final state = _states[_key(provider.id, model.id)] ??
        switch (model.lastTestStatus) {
          'success' => _HealthState.success,
          'failure' => _HealthState.failure,
          _ => _HealthState.idle,
        };
    final error = _errors[_key(provider.id, model.id)] ?? model.lastTestError;
    final status = switch (state) {
      _HealthState.running => '测试中',
      _HealthState.success => '可用',
      _HealthState.failure => '不可用',
      _ => '未测试',
    };
    final color = switch (state) {
      _HealthState.success => cs.primary,
      _HealthState.failure => cs.error,
      _ => cs.onSurfaceVariant,
    };
    final isAnime = AppVisualTheme.of(context).isAnime;
    final statusKind = switch (state) {
      _HealthState.success => AppStatusKind.success,
      _HealthState.failure => AppStatusKind.error,
      _HealthState.running => AppStatusKind.info,
      _ => AppStatusKind.neutral,
    };
    final statusPalette = AppStatusPalette.of(context, statusKind);
    return ListTile(
      dense: isAnime ? false : true,
      leading: isAnime
          ? CircleAvatar(
              backgroundColor: statusPalette.container,
              foregroundColor: statusPalette.foreground,
              child: Icon(switch (state) {
                _HealthState.success => Icons.check_rounded,
                _HealthState.failure => Icons.error_outline_rounded,
                _HealthState.running => Icons.sync_rounded,
                _ => Icons.pending_outlined,
              }),
            )
          : null,
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.id != model.name) Text(model.id),
          if (isAnime)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppStatusBadge(label: status, kind: statusKind),
              ),
            )
          else
            Text(status, style: TextStyle(color: color)),
          if (error != null)
            Text(error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: state == _HealthState.failure
                        ? cs.error
                        : cs.onSurfaceVariant)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '深度探测',
            icon: const Icon(Icons.science_outlined),
            onPressed: state == _HealthState.running
                ? null
                : () => _deepProbe(store, provider, model),
          ),
          IconButton(
            tooltip: '测试模型',
            icon: state == _HealthState.running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check_rounded),
            onPressed: state == _HealthState.running
                ? null
                : () => _testOne(store, provider, model),
          ),
        ],
      ),
    );
  }

  Future<void> _testAll(
      AISettingsProvider store, List<AiProvider> providers) async {
    setState(() {
      _testingAll = true;
      _cancelRequested = false;
    });
    try {
      for (final provider in providers) {
        for (final model in provider.models) {
          if (!mounted || _cancelRequested) return;
          await _testOne(store, provider, model);
        }
      }
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  Future<void> _testOne(
      AISettingsProvider store, AiProvider provider, AiModel model) async {
    final accountHash = store.accountHash;
    final key = _key(provider.id, model.id);
    final currentProviders =
        store.settings.providers.where((item) => item.id == provider.id);
    if (currentProviders.isEmpty) return;
    final currentProvider = currentProviders.first;
    final expectedConfiguration =
        AIProviderHealthConfiguration.capture(currentProvider);
    setState(() {
      _states[key] = _HealthState.running;
      _errors.remove(key);
    });
    final settings = store.settings.clone()
      ..mode = AIMode.local
      ..activeProviderId = provider.id;
    final p = settings.providers.firstWhere((e) => e.id == provider.id);
    p.selectedModelId = model.id;
    Object? requestError;
    try {
      await ChatService.from(settings).chat(prompt: 'ping', history: []);
    } catch (error) {
      requestError = error;
    }

    try {
      final recorded = await store.recordModelTestResult(
        providerId: provider.id,
        modelId: model.id,
        expectedConfiguration: expectedConfiguration,
        success: requestError == null,
        error: requestError?.toString(),
        expectedAccountHash: accountHash,
      );
      if (!mounted) return;
      final error = recorded
          ? requestError?.toString()
          : '配置已变化，请重新测试';
      setState(() {
        _states[key] = recorded && requestError == null
            ? _HealthState.success
            : _HealthState.failure;
        if (error != null) _errors[key] = error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _states[key] = _HealthState.failure;
        _errors[key] = '测试结果未保存：$error';
      });
    }
  }

  Future<void> _deepProbe(
      AISettingsProvider store, AiProvider provider, AiModel model) async {
    final accountHash = store.accountHash;
    final key = _key(provider.id, model.id);
    final currentProviders =
        store.settings.providers.where((item) => item.id == provider.id);
    if (currentProviders.isEmpty) return;
    final currentProvider = currentProviders.first;
    final expectedConfiguration =
        AIProviderHealthConfiguration.capture(currentProvider);
    setState(() {
      _states[key] = _HealthState.running;
      _errors.remove(key);
    });
    final settings = store.settings.clone()
      ..mode = AIMode.local
      ..activeProviderId = provider.id;
    final p = settings.providers.firstWhere((e) => e.id == provider.id);
    p.selectedModelId = model.id;
    final service = ChatService.from(settings);
    final notes = <String>[];
    var ok = true;
    var toolConfirmed = false;
    var visionConfirmed = false;
    try {
      await service.chat(prompt: 'ping', history: []);
      try {
        final toolOk = await _probeTool(service);
        if (toolOk) {
          toolConfirmed = true;
          notes.add('tool=confirmed');
        } else {
          notes.add('tool=not-called');
        }
      } catch (e) {
        notes.add('tool=failed:$e');
      }
      try {
        await service.chat(
          prompt: '请用一个短词描述图片。',
          history: const [],
          attachments: const ChatAttachments(images: [_probeImageDataUri]),
        );
        visionConfirmed = true;
        notes.add('vision=confirmed');
      } catch (e) {
        notes.add('vision=failed:$e');
      }
    } catch (e) {
      ok = false;
      notes.add('base=failed:$e');
    }
    try {
      final recorded = await store.recordModelTestResult(
        providerId: provider.id,
        modelId: model.id,
        expectedConfiguration: expectedConfiguration,
        success: ok,
        error: ok ? null : notes.last,
        tool: toolConfirmed,
        vision: visionConfirmed,
        expectedAccountHash: accountHash,
      );
      if (!recorded) {
        ok = false;
        notes.add('配置已变化，请重新测试');
      }
    } catch (error) {
      ok = false;
      notes.add('测试结果未保存：$error');
    }
    if (!mounted) return;
    setState(() {
      _states[key] = ok ? _HealthState.success : _HealthState.failure;
      if (notes.isNotEmpty) _errors[key] = notes.join('\n');
    });
  }

  Future<bool> _probeTool(ChatService service) async {
    var called = false;
    final stream = service.chatStreamEvents(
      prompt: '请调用 report_probe 工具，参数 ok=true。',
      history: const [],
      tools: const [
        {
          'type': 'function',
          'function': {
            'name': 'report_probe',
            'description': 'Report capability probe result.',
            'parameters': {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'}
              },
              'required': ['ok']
            }
          }
        }
      ],
    ).timeout(const Duration(seconds: 20));
    await for (final event in stream) {
      if (event.type == StreamEventType.toolCall) called = true;
    }
    return called;
  }

  static const _probeImageDataUri =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';

  Future<void> _copyDiagnostics(AISettings settings) async {
    final lines = <String>[
      'ChatAI Deep 服务商健康检查',
      'mode=${settings.mode.name}',
      'activeProvider=${settings.activeProviderId}',
      'generatedAt=${DateTime.now().toIso8601String()}',
      '',
    ];
    for (final provider in settings.enabledProviders) {
      lines.add('[${provider.name}] id=${provider.id}');
      lines.add('baseUrl=${provider.apiHost}');
      lines.add('apiKey=${provider.apiKey.isEmpty ? 'missing' : 'configured'}');
      for (final model in provider.models) {
        final key = _key(provider.id, model.id);
        final state = _states[key] ??
            switch (model.lastTestStatus) {
              'success' => _HealthState.success,
              'failure' => _HealthState.failure,
              _ => _HealthState.idle,
            };
        final status = switch (state) {
          _HealthState.running => 'running',
          _HealthState.success => 'success',
          _HealthState.failure => 'failure',
          _ => 'unknown',
        };
        final error = _errors[key] ?? model.lastTestError;
        lines.add('- ${model.id}: $status');
        if (error != null && error.isNotEmpty) {
          lines.add('  error=$error');
        }
      }
      lines.add('');
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
  }
}
