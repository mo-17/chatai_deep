import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务商健康检查'),
        actions: [
          IconButton(
            tooltip: '复制诊断',
            onPressed: () => _copyDiagnostics(store.settings),
            icon: const Icon(Icons.copy_all_outlined),
          ),
          TextButton(
            onPressed: _testingAll
                ? () => setState(() => _cancelRequested = true)
                : () => _testAll(store, providers),
            child: Text(_testingAll ? '停止' : '全部测试'),
          ),
        ],
      ),
      body: providers.isEmpty
          ? const Center(child: Text('暂无已启用的服务商'))
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
    return ListTile(
      dense: true,
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.id != model.name) Text(model.id),
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
    final key = _key(provider.id, model.id);
    setState(() {
      _states[key] = _HealthState.running;
      _errors.remove(key);
    });
    final settings = store.settings.clone()
      ..mode = AIMode.local
      ..activeProviderId = provider.id;
    final p = settings.providers.firstWhere((e) => e.id == provider.id);
    p.selectedModelId = model.id;
    try {
      await ChatService.from(settings).chat(prompt: 'ping', history: []);
      model.markTestResult(success: true);
      final caps = ModelCapabilities.heuristic(model.id,
          providerCode: provider.providerCode);
      model.applyCapabilityHints(
        vision: caps.image,
        tool: caps.tool,
        reasoning: caps.reasoning,
      );
      await store.updateProvider(provider);
      if (!mounted) return;
      setState(() => _states[key] = _HealthState.success);
    } catch (e) {
      final error = '$e';
      model.markTestResult(success: false, error: error);
      await store.updateProvider(provider);
      if (!mounted) return;
      setState(() {
        _states[key] = _HealthState.failure;
        _errors[key] = error;
      });
    }
  }

  Future<void> _deepProbe(
      AISettingsProvider store, AiProvider provider, AiModel model) async {
    final key = _key(provider.id, model.id);
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
    try {
      await service.chat(prompt: 'ping', history: []);
      model.markTestResult(success: true);
      final heuristic = ModelCapabilities.heuristic(model.id,
          providerCode: provider.providerCode);
      model.applyCapabilityHints(
        vision: heuristic.image,
        tool: heuristic.tool,
        reasoning: heuristic.reasoning,
      );
      try {
        final toolOk = await _probeTool(service);
        if (toolOk) {
          model.applyCapabilityHints(tool: true);
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
        model.applyCapabilityHints(vision: true);
        notes.add('vision=confirmed');
      } catch (e) {
        notes.add('vision=failed:$e');
      }
    } catch (e) {
      ok = false;
      model.markTestResult(success: false, error: '$e');
      notes.add('base=failed:$e');
    }
    await store.updateProvider(provider);
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
