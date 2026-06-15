import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

///助手新建 / 编辑页（阶段七）：名称、emoji、系统提示词、可选模型覆盖、工具开关。
///对应源项目 `src/screens/assistant/AssistantDetailScreen.tsx` 的精简版。
class AssistantEditPage extends StatefulWidget {
  ///null = 新建。
  final AssistantModel? assistant;

  const AssistantEditPage({Key? key, this.assistant}) : super(key: key);

  @override
  State<AssistantEditPage> createState() => _AssistantEditPageState();
}

class _AssistantEditPageState extends State<AssistantEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _emojiCtl;
  late final TextEditingController _promptCtl;

  ///模型覆盖（'' = 跟随全局设置）。
  String _model = '';
  bool _useTools = true;

  /// 助手绑定的工具 id 集合（L1）。旧助手 toolIds 为 null 时按空集处理，
  /// 保存后变为显式列表（语义不变：未勾选 = 不绑定）。
  late final Set<String> _toolIds;
  bool _saving = false;

  /// 「新建」以是否已有持久化 id 判定：从助手市场预填的模板 id 为 null，
  /// 同样视为新建（保存即插入），标题/按钮显示「新建/创建」（遗留项 9）。
  bool get _isNew => widget.assistant?.id == null;

  @override
  void initState() {
    super.initState();
    final a = widget.assistant;
    _nameCtl = TextEditingController(text: a?.name ?? '');
    _emojiCtl = TextEditingController(text: a?.emoji ?? '🤖');
    _promptCtl = TextEditingController(text: a?.prompt ?? '');
    _model = a?.model ?? '';
    _useTools = a?.useTools ?? true;
    _toolIds = {...?a?.toolIds};
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _emojiCtl.dispose();
    _promptCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建助手' : '编辑助手'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _emojiCtl,
                    textAlign: TextAlign.center,
                    maxLength: 2,
                    decoration: const InputDecoration(
                      labelText: '头像',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _nameCtl,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      hintText: '如：翻译官 / 代码审查员',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _promptCtl,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: '系统提示词',
                hintText: '定义助手的人设与行为，发请求时作为 system 消息注入',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            _buildModelDropdown(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许工具调用'),
              subtitle: const Text('总开关；关闭后一律不调用工具，联网回落意图编排'),
              value: _useTools,
              onChanged: (v) => setState(() => _useTools = v),
            ),
            if (_useTools) _buildToolsSection(),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_isNew ? '创建' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具绑定多选（L1）：列出 [ToolRegistry.catalog]，勾选即写入助手 toolIds。
  /// 依赖搜索 key 的工具在未配置时置灰并提示；只有支持工具的模型 + 流式才会真正生效。
  Widget _buildToolsSection() {
    final settings = context.watch<AISettingsProvider>().settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 4),
          child: Text('可用工具（绑定后该助手始终向模型暴露）',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        for (final d in ToolRegistry.catalog)
          _buildToolTile(d, ToolRegistry.isAvailable(settings, d.id)),
      ],
    );
  }

  Widget _buildToolTile(ToolDescriptor d, bool available) {
    final selected = _toolIds.contains(d.id);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Text(d.label),
      subtitle: Text(
          available ? d.description : '${d.description}（需先在 AI 设置里配置搜索 key）'),
      // 未满足依赖时禁用勾选。
      onChanged: available
          ? (v) => setState(() {
                if (v == true) {
                  _toolIds.add(d.id);
                } else {
                  _toolIds.remove(d.id);
                }
              })
          : null,
    );
  }

  ///模型覆盖下拉：选项按当前全局设置的生效路径给（后端模式 -> 后端清单，
  ///本地模式 -> 当前服务商清单），保证覆盖的模型与服务商兼容。
  Widget _buildModelDropdown() {
    final settings = context.watch<AISettingsProvider>().settings;
    final options = settings.mode == AIMode.backend
        ? ModelCatalog.backendAll()
        : settings.activeProvider.models
            .map((m) => ModelOption(m.id, m.description, displayLabel: m.name))
            .toList();

    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: '',
        child: Text('跟随全局设置', style: TextStyle(fontWeight: FontWeight.w500)),
      ),
      for (final o in options)
        DropdownMenuItem(
          value: o.id,
          child: Text(o.displayLabel ?? o.id,
              style: const TextStyle(fontSize: 14)),
        ),
      if (_model.isNotEmpty && !options.any((o) => o.id == _model))
        DropdownMenuItem(value: _model, child: Text(_model)),
      const DropdownMenuItem(
        value: '__custom__',
        child: Text('自定义...', style: TextStyle(fontStyle: FontStyle.italic)),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '模型覆盖（可选）',
          border: OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: items.any((i) => i.value == _model) ? _model : '__custom__',
            isDense: true,
            isExpanded: true,
            items: items,
            onChanged: (v) {
              if (v == '__custom__') {
                _showCustomModelDialog();
              } else if (v != null) {
                setState(() => _model = v);
              }
            },
          ),
        ),
      ),
    );
  }

  void _showCustomModelDialog() async {
    final ctl = TextEditingController(text: _model);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义模型'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入 modelId'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null) setState(() => _model = result);
  }

  void _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      HiDialog.showSnackBar(context, '请输入助手名称');
      return;
    }
    setState(() => _saving = true);
    final model = widget.assistant ?? AssistantModel(name: name);
    model
      ..name = name
      ..emoji = _emojiCtl.text.trim().isEmpty ? '🤖' : _emojiCtl.text.trim()
      ..prompt = _promptCtl.text.trim()
      ..model = _model.trim()
      ..useTools = _useTools
      ..toolIds = _toolIds.toList();
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await AssistantDao.create(dbManager);
    await dao.saveAssistant(model);
    if (!mounted) return;
    Navigator.pop(context, true);
  }
}
