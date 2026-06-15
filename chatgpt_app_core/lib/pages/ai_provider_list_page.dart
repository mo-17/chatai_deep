import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/pages/ai_provider_detail_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/widget/ai_provider/provider_avatar.dart';
import 'package:chatgpt_app_core/widget/ai_provider/section_card.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 服务商管理页：迁移自 Cherry Studio 的「服务商列表」。
/// 上方搜索 + 「已启用 / 可用服务商」两段分组；每行可开关启用、点进详情配置。
class AiProviderListPage extends StatefulWidget {
  const AiProviderListPage({super.key});

  @override
  State<AiProviderListPage> createState() => _AiProviderListPageState();
}

class _AiProviderListPageState extends State<AiProviderListPage> {
  String _query = '';

  bool _match(AiProvider p) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return p.name.toLowerCase().contains(q) || p.id.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final aiProvider = context.watch<AISettingsProvider>();
    final settings = aiProvider.settings;
    final activeId = settings.activeProviderId;

    final enabled =
        settings.providers.where((p) => p.enabled && _match(p)).toList();
    final available =
        settings.providers.where((p) => !p.enabled && _match(p)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('服务商管理'),
        actions: [
          IconButton(
            tooltip: '添加自定义服务商',
            icon: const Icon(Icons.add_rounded),
            onPressed: _showAddSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SearchBar(
              hintText: '搜索服务商...',
              leading: const Icon(Icons.search_rounded),
              elevation: const WidgetStatePropertyAll(0),
              backgroundColor:
                  WidgetStatePropertyAll(cs.surfaceContainerHighest),
              padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 16)),
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
          Expanded(
            child: (enabled.isEmpty && available.isEmpty)
                ? _buildEmpty(cs)
                : ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      if (enabled.isNotEmpty) ...[
                        const SectionLabel('已启用',
                            padding: EdgeInsets.fromLTRB(16, 8, 16, 8)),
                        SectionCard(
                          children: [
                            for (final p in enabled)
                              _ProviderTile(
                                  provider: p,
                                  active: p.id == activeId && p.enabled),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (available.isNotEmpty) ...[
                        const SectionLabel('可用服务商',
                            padding: EdgeInsets.fromLTRB(16, 8, 16, 8)),
                        SectionCard(
                          children: [
                            for (final p in available)
                              _ProviderTile(
                                  provider: p,
                                  active: p.id == activeId && p.enabled),
                          ],
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 64, color: cs.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('未找到服务商', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('点击右上角 + 添加自定义服务商',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  )),
        ],
      ),
    );
  }

  Future<void> _showAddSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const _AddProviderSheet(),
    );
  }
}

/// 列表行：头像 + 名称 + 副标题（模型数 / 未启用 + 当前标记）+ 启用开关 + 箭头。
class _ProviderTile extends StatelessWidget {
  final AiProvider provider;
  final bool active;

  const _ProviderTile({required this.provider, required this.active});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => AiProviderDetailPage(providerId: provider.id)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Hero(
              tag: 'provider-avatar-${provider.id}',
              child: ProviderAvatar(
                  providerId: provider.id, name: provider.name, size: 40),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(provider.name,
                            style: tt.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (active) ...[
                        const SizedBox(width: 8),
                        _CurrentBadge(cs: cs, tt: tt),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    provider.enabled ? '${provider.models.length} 个模型' : '未启用',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 吸收 Switch 的点击，避免冒泡触发整行的导航。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: Switch(
                value: provider.enabled,
                onChanged: (v) => context
                    .read<AISettingsProvider>()
                    .toggleProvider(provider.id, v),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _CurrentBadge extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme tt;
  const _CurrentBadge({required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('当前',
          style: tt.labelSmall
              ?.copyWith(color: cs.onPrimaryContainer, height: 1)),
    );
  }
}

/// 添加自定义服务商：名称 + 协议类型 + API 地址 +（可选）首个模型 id。
class _AddProviderSheet extends StatefulWidget {
  const _AddProviderSheet();

  @override
  State<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<_AddProviderSheet> {
  final _nameCtl = TextEditingController();
  final _hostCtl = TextEditingController();
  final _modelCtl = TextEditingController();
  String _type = 'openai';

  static const _types = ['openai', 'anthropic', 'gemini', 'azure-openai'];

  @override
  void dispose() {
    _nameCtl.dispose();
    _hostCtl.dispose();
    _modelCtl.dispose();
    super.dispose();
  }

  bool get _valid =>
      _nameCtl.text.trim().isNotEmpty && _hostCtl.text.trim().isNotEmpty;

  void _submit() {
    final name = _nameCtl.text.trim();
    final host = _hostCtl.text.trim();
    final modelId = _modelCtl.text.trim();
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final provider = AiProvider(
      id: id,
      type: _type,
      name: name,
      apiHost: host,
      enabled: true,
      models: modelId.isEmpty ? [] : [AiModel(id: modelId)],
      selectedModelId: modelId,
    );
    context.read<AISettingsProvider>().addProvider(provider);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('添加自定义服务商', style: tt.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtl,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '名称 *',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(
              labelText: '协议类型',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in _types)
                DropdownMenuItem(value: t, child: Text(t)),
            ],
            onChanged: (v) => setState(() => _type = v ?? 'openai'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostCtl,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'API 地址 *',
              hintText: 'https://api.example.com/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtl,
            decoration: const InputDecoration(
              labelText: '首个模型 id（可选）',
              hintText: 'gpt-4o',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _valid ? _submit : null,
              child: const Text('添加'),
            ),
          ),
        ],
      ),
    );
  }
}
