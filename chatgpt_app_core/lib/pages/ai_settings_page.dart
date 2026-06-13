import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
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
  late TextEditingController _tavilyKeyCtl;
  late TextEditingController _exaKeyCtl;
  late TextEditingController _bochaKeyCtl;
  late TextEditingController _zhipuKeyCtl;

  // 联网搜索：当前服务商 + 三项通用配置（对照源项目 WebSearchState）
  late String _searchProviderId;
  late bool _searchWithTime;
  late TextEditingController _searchCountCtl;
  late TextEditingController _searchLimitCtl;

  // 最大输出 token（空 = 不限制）
  late TextEditingController _maxTokensCtl;

  bool _obscureOpenai = true;
  bool _obscureDeepseek = true;
  bool _obscureSearchKey = true;
  bool _saving = false;
  late bool _streamEnabled;
  late bool _resetOnLogout;

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
    _tavilyKeyCtl = TextEditingController(text: s.tavilyApiKey);
    _exaKeyCtl = TextEditingController(text: s.exaApiKey);
    _bochaKeyCtl = TextEditingController(text: s.bochaApiKey);
    _zhipuKeyCtl = TextEditingController(text: s.zhipuApiKey);
    _searchProviderId = s.webSearchProviderId;
    _searchWithTime = s.searchWithTime;
    _searchCountCtl =
        TextEditingController(text: s.searchMaxResults.toString());
    _searchLimitCtl = TextEditingController(
        text: s.searchContentLimit > 0 ? s.searchContentLimit.toString() : '');
    _maxTokensCtl = TextEditingController(
        text: s.maxOutputTokens > 0 ? s.maxOutputTokens.toString() : '');
    _streamEnabled = s.streamEnabled;
    _resetOnLogout = s.resetOnLogout;
  }

  @override
  void dispose() {
    _openaiKeyCtl.dispose();
    _openaiModelCtl.dispose();
    _openaiUrlCtl.dispose();
    _deepseekKeyCtl.dispose();
    _deepseekModelCtl.dispose();
    _deepseekUrlCtl.dispose();
    _tavilyKeyCtl.dispose();
    _exaKeyCtl.dispose();
    _bochaKeyCtl.dispose();
    _zhipuKeyCtl.dispose();
    _searchCountCtl.dispose();
    _searchLimitCtl.dispose();
    _maxTokensCtl.dispose();
    super.dispose();
  }

  ///解析数字输入；空/非法返回 [fallback]。
  int _parseInt(String text, {int fallback = 0}) =>
      int.tryParse(text.trim()) ?? fallback;

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
        resetOnLogout: _resetOnLogout,
        tavilyApiKey: _tavilyKeyCtl.text.trim(),
        // 联网开关在会话页切换，这里保留当前值不动。
        webSearchEnabled:
            context.read<AISettingsProvider>().settings.webSearchEnabled,
        webSearchProviderId: _searchProviderId,
        exaApiKey: _exaKeyCtl.text.trim(),
        bochaApiKey: _bochaKeyCtl.text.trim(),
        zhipuApiKey: _zhipuKeyCtl.text.trim(),
        searchWithTime: _searchWithTime,
        searchMaxResults:
            _parseInt(_searchCountCtl.text, fallback: 5).clamp(1, 20),
        searchContentLimit: _parseInt(_searchLimitCtl.text),
        maxOutputTokens: _parseInt(_maxTokensCtl.text),
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
          _buildMaxTokensCard(),
          const SizedBox(height: 16),
          _buildResetOnLogoutCard(),
          const SizedBox(height: 16),
          _buildWebSearchCard(),
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
              onSelectionChanged: (s) {
                // 游客模式没有后端凭证（哨兵 token 会被拒），只能本地直连。
                if (s.first == AIMode.backend && LoginDao.isGuest()) {
                  HiDialog.showSnackBar(
                      context, '游客模式仅支持本地直连，登录后可使用后端代理');
                  return;
                }
                setState(() => _mode = s.first);
              },
            ),
            if (LoginDao.isGuest()) ...[
              const SizedBox(height: 8),
              Text('游客模式：请在下方填入自己的 OpenAI / DeepSeek API Key',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
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

  Widget _buildResetOnLogoutCard() {
    return Card(
      child: SwitchListTile(
        title: const Text('退出登录时重置 AI 配置'),
        subtitle: const Text('开启后退出登录会清空 API Key 等设置，关闭则保留'),
        value: _resetOnLogout,
        onChanged: (v) => setState(() => _resetOnLogout = v),
      ),
    );
  }

  /// 联网搜索服务商清单（与源项目 WebSearchProviderFactory 实际启用的一致）。
  static const _searchProviders = <(String, String, String)>[
    ('tavily', 'Tavily', '在 tavily.com 免费申请'),
    ('exa', 'Exa', '在 dashboard.exa.ai 申请'),
    ('bocha', '博查', '在 open.bochaai.com 申请'),
    ('zhipu', '智谱', '在 open.bigmodel.cn 申请'),
  ];

  TextEditingController get _activeSearchKeyCtl {
    switch (_searchProviderId) {
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

  /// 联网搜索（阶段五 + 本次扩展）：服务商选择 + 各自 API Key +
  /// 三项通用配置（结果条数 / 内容长度限制 / 附带日期，对照源项目）。
  Widget _buildWebSearchCard() {
    final active =
        _searchProviders.firstWhere((p) => p.$1 == _searchProviderId,
            orElse: () => _searchProviders.first);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('联网搜索',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '搜索服务商',
                border: OutlineInputBorder(),
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
                    if (v != null) setState(() => _searchProviderId = v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              // key 跟随服务商切换，避免复用旧输入框状态
              key: ValueKey('search_key_${active.$1}'),
              controller: _activeSearchKeyCtl,
              obscureText: _obscureSearchKey,
              decoration: InputDecoration(
                labelText: '${active.$2} API Key',
                helperText: 'ⓘ ${active.$3}；配置后会话页输入栏出现联网开关',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureSearchKey
                      ? Icons.visibility
                      : Icons.visibility_off),
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
                    decoration: const InputDecoration(
                      labelText: '搜索结果个数',
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
                    decoration: const InputDecoration(
                      labelText: '内容长度限制',
                      hintText: '留空不限制',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('搜索词附带当前日期'),
              subtitle: const Text('提升「最新 / 今天」类问题的搜索质量'),
              value: _searchWithTime,
              onChanged: (v) => setState(() => _searchWithTime = v),
            ),
          ],
        ),
      ),
    );
  }

  /// 最大输出长度（方案2）：默认不限制（不发 max_tokens，用上游默认），
  /// 需要控费时再设上限。修复此前写死 1000 token 导致长回复被截断的问题。
  Widget _buildMaxTokensCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('最大输出长度',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _maxTokensCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'max_tokens',
                hintText: '留空不限制（推荐）',
                helperText: 'ⓘ 设置过小会导致回复被截断；推理模型的思考过程也计入',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
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
