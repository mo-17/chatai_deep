import 'package:chatgpt_flutter/dao/chat/chat_service.dart';
import 'package:chatgpt_flutter/model/ai_settings.dart';
import 'package:chatgpt_flutter/provider/ai_settings_provider.dart';
import 'package:chatgpt_flutter/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AISettingsPage extends StatefulWidget {
  const AISettingsPage({super.key});

  @override
  State<AISettingsPage> createState() => _AISettingsPageState();
}

class _AISettingsPageState extends State<AISettingsPage> {
  // editing state
  late AIMode _mode;
  late LocalProvider _localProvider;
  late TextEditingController _openaiKeyCtl;
  late TextEditingController _openaiModelCtl;
  late TextEditingController _openaiUrlCtl;
  late TextEditingController _deepseekKeyCtl;
  late TextEditingController _deepseekModelCtl;
  late TextEditingController _deepseekUrlCtl;
  late String _backendModel;

  bool _obscureOpenai = true;
  bool _obscureDeepseek = true;
  bool _saving = false;
  late bool _streamEnabled;

  @override
  void initState() {
    super.initState();
    final s = context.read<AISettingsProvider>().settings;
    _mode = s.mode;
    _localProvider = s.localProvider;
    _openaiKeyCtl = TextEditingController(text: s.openai.apiKey);
    _openaiModelCtl = TextEditingController(text: s.openai.model);
    _openaiUrlCtl = TextEditingController(text: s.openai.baseUrl);
    _deepseekKeyCtl = TextEditingController(text: s.deepseek.apiKey);
    _deepseekModelCtl = TextEditingController(text: s.deepseek.model);
    _deepseekUrlCtl = TextEditingController(text: s.deepseek.baseUrl);
    _backendModel = s.backendModel;
    _streamEnabled = s.streamEnabled;
  }

  @override
  void dispose() {
    _openaiKeyCtl.dispose();
    _openaiModelCtl.dispose();
    _openaiUrlCtl.dispose();
    _deepseekKeyCtl.dispose();
    _deepseekModelCtl.dispose();
    _deepseekUrlCtl.dispose();
    super.dispose();
  }

  AISettings _buildSettings() => AISettings(
        mode: _mode,
        localProvider: _localProvider,
        openai: ProviderConfig(
          apiKey: _openaiKeyCtl.text,
          baseUrl: _openaiUrlCtl.text,
          model: _openaiModelCtl.text,
        ),
        deepseek: ProviderConfig(
          apiKey: _deepseekKeyCtl.text,
          baseUrl: _deepseekUrlCtl.text,
          model: _deepseekModelCtl.text,
        ),
        backendModel: _backendModel,
        streamEnabled: _streamEnabled,
      );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<AISettingsProvider>().update(_buildSettings());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    final settings = _buildSettings();
    final service = ChatService.from(settings);
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
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 服务设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildModeCard(),
          const SizedBox(height: 16),
          _buildStreamCard(),
          const SizedBox(height: 16),
          if (_mode == AIMode.local) ...[
            _buildProviderCard(),
            const SizedBox(height: 16),
            if (_localProvider == LocalProvider.openai)
              _buildProviderConfigCard(
                title: 'OpenAI 配置',
                keyCtl: _openaiKeyCtl,
                modelCtl: _openaiModelCtl,
                urlCtl: _openaiUrlCtl,
                obscure: _obscureOpenai,
                onToggleObscure: () =>
                    setState(() => _obscureOpenai = !_obscureOpenai),
                modelOptions: ModelCatalog.openai,
              )
            else
              _buildProviderConfigCard(
                title: 'DeepSeek 配置',
                keyCtl: _deepseekKeyCtl,
                modelCtl: _deepseekModelCtl,
                urlCtl: _deepseekUrlCtl,
                obscure: _obscureDeepseek,
                onToggleObscure: () =>
                    setState(() => _obscureDeepseek = !_obscureDeepseek),
                modelOptions: ModelCatalog.deepseek,
              ),
          ] else
            _buildBackendModelCard(),
          const SizedBox(height: 24),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildModeCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('调用模式',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            SegmentedButton<AIMode>(
              segments: const [
                ButtonSegment(
                    value: AIMode.local,
                    label: Text('本地'),
                    tooltip: '使用自己的 key，免费'),
                ButtonSegment(
                    value: AIMode.backend,
                    label: Text('后端'),
                    tooltip: '统一服务，可能收费'),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamCard() {
    return Card(
      child: SwitchListTile(
        title: const Text('流式输出'),
        subtitle: const Text('开启后逐字显示 AI 回复，关闭则等待完整回复一次性展示'),
        value: _streamEnabled,
        onChanged: (v) => setState(() => _streamEnabled = v),
      ),
    );
  }

  Widget _buildProviderCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('服务商',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            SegmentedButton<LocalProvider>(
              segments: const [
                ButtonSegment(
                    value: LocalProvider.deepseek,
                    label: Text('DeepSeek')),
                ButtonSegment(
                    value: LocalProvider.openai, label: Text('OpenAI')),
              ],
              selected: {_localProvider},
              onSelectionChanged: (s) =>
                  setState(() => _localProvider = s.first),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderConfigCard({
    required String title,
    required TextEditingController keyCtl,
    required TextEditingController modelCtl,
    required TextEditingController urlCtl,
    required bool obscure,
    required VoidCallback onToggleObscure,
    required List<ModelOption> modelOptions,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            // API Key
            TextField(
              controller: keyCtl,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'API Key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: onToggleObscure,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Model dropdown
            _buildModelDropdown(modelOptions, modelCtl),
            const SizedBox(height: 12),
            // Base URL (advanced)
            ExpansionTile(
              title: const Text('Base URL（高级，一般不动）',
                  style: TextStyle(fontSize: 14)),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: urlCtl,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'https://...',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackendModelCard() {
    final options = ModelCatalog.backendAll();
    final fromRemote = ModelCatalog.remoteAvailable;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('后端模型',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                if (fromRemote)
                  const Icon(Icons.cloud_done, size: 18, color: Colors.green)
                else
                  const Icon(Icons.cloud_off, size: 18, color: Colors.orange),
              ],
            ),
            const SizedBox(height: 12),
            if (!fromRemote)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('ⓘ 暂未拉取到后端清单，显示本地兜底模型',
                    style: TextStyle(fontSize: 12, color: Colors.orange)),
              ),
            _buildBackendModelDropdown(options),
            const SizedBox(height: 12),
            Text(
              fromRemote
                  ? 'ⓘ 模型清单来自后端 /uapi/ai/catalog，随管理后台实时更新'
                  : 'ⓘ 后端按 model 前缀路由到上游：deepseek-* → DeepSeek，gpt-* / o1-* → OpenAI',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            const Text(
              'ⓘ 将记录用量供未来计费',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // Uses DropdownButtonFormField + allows tracking current model string
  String _selectedDropdownValue(
      List<ModelOption> options, TextEditingController ctl) {
    final v = ctl.text;
    for (final o in options) {
      if (o.id == v) return o.id;
    }
    // custom value — will show as extra item
    return v.isEmpty ? options.first.id : v;
  }

  Widget _buildModelDropdown(
      List<ModelOption> options, TextEditingController ctl) {
    final current = _selectedDropdownValue(options, ctl);
    final inList = options.any((o) => o.id == ctl.text);

    final items = <DropdownMenuItem<String>>[
      for (final o in options)
        DropdownMenuItem(
          value: o.id,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(o.id, style: const TextStyle(fontWeight: FontWeight.w500)),
              if (o.hint != null)
                Text(o.hint!, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      if (!inList && ctl.text.isNotEmpty)
        DropdownMenuItem(
          value: ctl.text,
          child: Text(ctl.text),
        ),
      const DropdownMenuItem(
        value: '__custom__',
        child: Text('自定义...', style: TextStyle(fontStyle: FontStyle.italic)),
      ),
    ];

    final selectedValue =
        items.any((i) => i.value == current) ? current : '__custom__';

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '模型',
        border: OutlineInputBorder(),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selectedValue,
          isDense: true,
          isExpanded: true,
          items: items,
          onChanged: (v) {
            if (v == '__custom__') {
              _showCustomModelDialog(ctl);
            } else if (v != null) {
              setState(() => ctl.text = v);
            }
          },
        ),
      ),
    );
  }

  Widget _buildBackendModelDropdown(List<ModelOption> options) {
    // For backend we just use a simple string dropdown
    final items = <DropdownMenuItem<String>>[
      // Group headers are not natively supported in DropdownMenuItem,
      // so we'll just show all items with their prefix labels
      for (final o in options)
        DropdownMenuItem(
          value: o.id,
          child: Text(o.displayLabel ?? o.id,
              style: const TextStyle(fontSize: 14)),
        ),
      const DropdownMenuItem(
        value: '__custom__',
        child: Text('自定义...', style: TextStyle(fontStyle: FontStyle.italic)),
      ),
    ];

    // ensure current value is selectable
    final hasValue = items.any((i) => i.value == _backendModel);

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '模型',
        border: OutlineInputBorder(),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: hasValue ? _backendModel : '__custom__',
          isDense: true,
          isExpanded: true,
          items: items,
          onChanged: (v) {
            if (v == '__custom__') {
              _showCustomBackendModelDialog();
            } else if (v != null) {
              setState(() => _backendModel = v);
            }
          },
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _testConnection,
            child: const Text('测试连接'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ),
      ],
    );
  }

  void _showCustomModelDialog(TextEditingController ctl) {
    final c = TextEditingController(text: ctl.text);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('自定义模型'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入模型 ID',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() => ctl.text = c.text);
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showCustomBackendModelDialog() {
    final c = TextEditingController(text: _backendModel);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('自定义模型'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入模型 ID',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _backendModel = c.text);
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
