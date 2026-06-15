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
              subtitle: const Text('关闭后联网搜索回落意图编排路径'),
              value: _useTools,
              onChanged: (v) => setState(() => _useTools = v),
            ),
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
      ..useTools = _useTools;
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await AssistantDao.create(dbManager);
    await dao.saveAssistant(model);
    if (!mounted) return;
    Navigator.pop(context, true);
  }
}
