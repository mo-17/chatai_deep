import 'package:chatgpt_app_core/chat/application/story_regex_executor.dart';
import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/widget/story_visual_widgets.dart';
import 'package:flutter/material.dart';

typedef StoryRegexScriptsSave = Future<void> Function(StoryRoomModel room);

class StoryRegexScriptsPage extends StatefulWidget {
  final StoryRoomModel room;
  final StoryRegexScriptsSave onSave;

  const StoryRegexScriptsPage({
    super.key,
    required this.room,
    required this.onSave,
  });

  @override
  State<StoryRegexScriptsPage> createState() => _StoryRegexScriptsPageState();
}

class _StoryRegexScriptsPageState extends State<StoryRegexScriptsPage> {
  late List<StoryRegexScript> _rules;
  late final TextEditingController _previewController;
  StoryRegexStage _previewStage = StoryRegexStage.assistantDisplay;
  StoryRegexExecutionResult? _previewResult;
  Duration? _previewElapsed;
  bool _previewing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _rules = [
      ...StoryRegexScriptsCodec.decode(widget.room.regexScriptsJson)
          .orderedRules,
    ];
    _previewController = TextEditingController();
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabledCount = _rules.where((rule) => rule.enabled).length;
    return Scaffold(
      key: const ValueKey('story_regex_scripts_page'),
      appBar: AppBar(
        title: const Text('Regex Scripts'),
        actions: [
          IconButton(
            key: const ValueKey('story_regex_scripts_save'),
            tooltip: '保存 Regex Scripts',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: [
          Text(
            '受控文本替换 · ${_rules.length}/$maxRulesLabel 条 · 已启用 $enabledCount',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '规则只在选定阶段执行；脚本不会执行代码。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _buildPreview(context),
          const SizedBox(height: 12),
          const Divider(height: 1),
          for (final stage in StoryRegexStage.values) ...[
            const SizedBox(height: 4),
            _buildStage(context, stage),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('story_regex_scripts_add'),
        tooltip: '新增规则',
        onPressed: _addRule,
        child: const Icon(Icons.add),
      ),
    );
  }

  String get maxRulesLabel => '${StoryRegexScriptLimits.maxRules}';

  Widget _buildPreview(BuildContext context) {
    final result = _previewResult;
    final textTheme = Theme.of(context).textTheme;
    return StoryAdaptiveSurface(
      animeKey: const ValueKey('anime_story_regex_preview'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: storyUsesAnimeStyle(context)
              ? Colors.transparent
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(
            storyUsesAnimeStyle(context) ? 20 : 8,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('内置预览', style: textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButtonFormField<StoryRegexStage>(
                key: const ValueKey('story_regex_preview_stage'),
                initialValue: _previewStage,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '执行阶段',
                  border: storyInputBorder(context),
                ),
                items: [
                  for (final stage in StoryRegexStage.values)
                    DropdownMenuItem(
                      value: stage,
                      child: Text(_stageLabel(stage)),
                    ),
                ],
                onChanged: _previewing
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _previewStage = value);
                        }
                      },
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('story_regex_preview_input'),
                controller: _previewController,
                minLines: 3,
                maxLines: 6,
                maxLength: StoryRegexScriptLimits.maxTextLength,
                decoration: InputDecoration(
                  labelText: '样本文本',
                  alignLabelWithHint: true,
                  border: storyInputBorder(context),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const ValueKey('story_regex_preview_run'),
                  onPressed: _previewing ? null : _runPreview,
                  icon: _previewing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('运行预览'),
                ),
              ),
              if (result != null) ...[
                const Divider(height: 24),
                Text('处理后文本', style: textTheme.labelLarge),
                const SizedBox(height: 6),
                _previewText(result.output),
                const SizedBox(height: 8),
                _previewSummary(result),
                if (result.inputTruncated || result.outputTruncated) ...[
                  const SizedBox(height: 4),
                  Text(
                    '文本已按 ${StoryRegexScriptLimits.maxTextLength} 字符上限截断。',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                for (final ruleResult in result.rules)
                  _previewRuleResult(ruleResult),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewText(String value) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(
          storyUsesAnimeStyle(context) ? 14 : 6,
        ),
      ),
      child: SingleChildScrollView(
        child: SelectableText(value.isEmpty ? '（空）' : value),
      ),
    );
  }

  Widget _previewSummary(StoryRegexExecutionResult result) {
    final counts = <StoryRegexRuleStatus, int>{};
    for (final item in result.rules) {
      counts[item.status] = (counts[item.status] ?? 0) + 1;
    }
    final elapsed = _previewElapsed?.inMicroseconds ?? 0;
    final elapsedText = elapsed < 1000
        ? '$elapsed μs'
        : '${(elapsed / 1000).toStringAsFixed(1)} ms';
    return Text(
      '命中 ${counts[StoryRegexRuleStatus.applied] ?? 0} · '
      '失败 ${counts[StoryRegexRuleStatus.failed] ?? 0} · '
      '超时 ${counts[StoryRegexRuleStatus.timedOut] ?? 0} · '
      '跳过 ${counts[StoryRegexRuleStatus.skipped] ?? 0} · 耗时 $elapsedText',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _previewRuleResult(StoryRegexRuleResult result) {
    final rule = _rules.cast<StoryRegexScript?>().firstWhere(
          (item) => item?.key == result.key,
          orElse: () => null,
        );
    final elapsed = result.elapsed.inMicroseconds < 1000
        ? '${result.elapsed.inMicroseconds} μs'
        : '${(result.elapsed.inMicroseconds / 1000).toStringAsFixed(1)} ms';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_statusIcon(result.status), size: 17),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${rule?.name ?? result.key} · ${_statusLabel(result.status)} · $elapsed'
              '${result.error == null ? '' : ' · ${result.error}'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStage(BuildContext context, StoryRegexStage stage) {
    final rules = _rulesForStage(stage);
    return StoryAdaptiveListItem(
      animeMargin: const EdgeInsets.symmetric(vertical: 5),
      child: ExpansionTile(
        key: PageStorageKey<String>('story_regex_stage_${stage.value}'),
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
        title: Text(_stageLabel(stage)),
        subtitle: Text(
            '${rules.length} 条 · ${rules.where((r) => r.enabled).length} 条启用'),
        children: [
          if (rules.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
                child: Text('这个阶段还没有规则'),
              ),
            ),
          for (var index = 0; index < rules.length; index++)
            _buildRule(context, rules[index], index, rules.length),
        ],
      ),
    );
  }

  Widget _buildRule(
    BuildContext context,
    StoryRegexScript rule,
    int index,
    int count,
  ) {
    final replacement = rule.replace.isEmpty ? '（删除匹配内容）' : rule.replace;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  rule.name,
                  key: ValueKey('story_regex_rule_name_${rule.key}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Switch(
                key: ValueKey('story_regex_rule_enabled_${rule.key}'),
                value: rule.enabled,
                onChanged: (value) => _setEnabled(rule, value),
              ),
            ],
          ),
          Text(
            '查找：${rule.find}\n替换：$replacement',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 0,
            runSpacing: 0,
            children: [
              _actionButton(
                key: ValueKey('story_regex_rule_up_${rule.key}'),
                tooltip: '规则上移',
                icon: Icons.keyboard_arrow_up,
                onPressed: index == 0 ? null : () => _moveRule(rule, -1),
              ),
              _actionButton(
                key: ValueKey('story_regex_rule_down_${rule.key}'),
                tooltip: '规则下移',
                icon: Icons.keyboard_arrow_down,
                onPressed: index == count - 1 ? null : () => _moveRule(rule, 1),
              ),
              _actionButton(
                key: ValueKey('story_regex_rule_edit_${rule.key}'),
                tooltip: '编辑规则',
                icon: Icons.edit_outlined,
                onPressed: () => _editRule(rule),
              ),
              _actionButton(
                key: ValueKey('story_regex_rule_delete_${rule.key}'),
                tooltip: '删除规则',
                icon: Icons.delete_outline,
                onPressed: () => _deleteRule(rule),
              ),
            ],
          ),
          if (index < count - 1) const Divider(height: 16),
        ],
      ),
    );
  }

  Widget _actionButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(
        minWidth: kStoryMinTouchTarget,
        minHeight: kStoryMinTouchTarget,
      ),
      padding: EdgeInsets.zero,
    );
  }

  List<StoryRegexScript> _rulesForStage(StoryRegexStage stage) => [
        ..._rules.where((rule) => rule.stage == stage),
      ]..sort(_compareRules);

  static int _compareRules(StoryRegexScript a, StoryRegexScript b) {
    final order = a.sortOrder.compareTo(b.sortOrder);
    return order == 0 ? a.key.compareTo(b.key) : order;
  }

  Future<void> _addRule() async {
    if (_rules.length >= StoryRegexScriptLimits.maxRules) {
      _showMessage('最多创建 ${StoryRegexScriptLimits.maxRules} 条规则');
      return;
    }
    final rule = await _showEditor();
    if (!mounted || rule == null) return;
    setState(() {
      _rules.add(rule.copyWith(sortOrder: _nextSortOrder(rule.stage)));
      _normalizeStageOrders(rule.stage);
    });
  }

  Future<void> _editRule(StoryRegexScript rule) async {
    final edited = await _showEditor(initial: rule);
    if (!mounted || edited == null) return;
    final index = _rules.indexOf(rule);
    if (index < 0) return;
    setState(() {
      _rules[index] = edited.copyWith(key: rule.key, sortOrder: rule.sortOrder);
      if (edited.stage != rule.stage) {
        _normalizeStageOrders(rule.stage);
        _normalizeStageOrders(edited.stage);
      }
    });
  }

  Future<void> _deleteRule(StoryRegexScript rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: storyUsesAnimeStyle(context)
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _rules.remove(rule);
      _normalizeStageOrders(rule.stage);
    });
  }

  void _moveRule(StoryRegexScript rule, int delta) {
    final stageRules = _rulesForStage(rule.stage);
    final from = stageRules.indexOf(rule);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= stageRules.length) return;
    final moved = stageRules.removeAt(from);
    stageRules.insert(to, moved);
    setState(() {
      _normalizeStageOrders(rule.stage, ordered: stageRules);
    });
  }

  void _setEnabled(StoryRegexScript rule, bool enabled) {
    final index = _rules.indexOf(rule);
    if (index < 0) return;
    setState(() => _rules[index] = rule.copyWith(enabled: enabled));
  }

  int _nextSortOrder(StoryRegexStage stage) {
    final rules = _rulesForStage(stage);
    return rules.isEmpty ? 10 : rules.last.sortOrder + 10;
  }

  void _normalizeStageOrders(
    StoryRegexStage stage, {
    List<StoryRegexScript>? ordered,
  }) {
    final stageRules = ordered ?? _rulesForStage(stage);
    for (var index = 0; index < stageRules.length; index++) {
      final rule = stageRules[index];
      final actualIndex = _rules.indexOf(rule);
      if (actualIndex >= 0) {
        _rules[actualIndex] = rule.copyWith(sortOrder: (index + 1) * 10);
      }
    }
  }

  Future<StoryRegexScript?> _showEditor({StoryRegexScript? initial}) {
    final key = initial?.key ??
        'regex-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    return showModalBottomSheet<StoryRegexScript>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _StoryRegexScriptEditor(
        keyValue: key,
        initial: initial,
      ),
    );
  }

  Future<void> _runPreview() async {
    if (_previewing) return;
    setState(() {
      _previewing = true;
      _previewResult = null;
      _previewElapsed = null;
    });
    final clock = Stopwatch()..start();
    try {
      final result = await StoryRegexExecutor.execute(
        scripts: StoryRegexScripts(rules: List.unmodifiable(_rules)),
        stage: _previewStage,
        input: _previewController.text,
      );
      clock.stop();
      if (!mounted) return;
      setState(() {
        _previewResult = result;
        _previewElapsed = clock.elapsed;
      });
    } catch (error) {
      clock.stop();
      if (mounted) _showMessage('预览失败：$error');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    _normalizeAllOrders();
    widget.room.regexScriptsJson = StoryRegexScriptsCodec.encode(
      StoryRegexScripts(rules: List.unmodifiable(_rules)),
    );
    try {
      await widget.onSave(widget.room);
      if (mounted) _showMessage('Regex Scripts 已保存');
    } catch (error) {
      if (mounted) _showMessage('保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _normalizeAllOrders() {
    for (final stage in StoryRegexStage.values) {
      _normalizeStageOrders(stage);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  static String _stageLabel(StoryRegexStage stage) {
    switch (stage) {
      case StoryRegexStage.userInput:
        return '用户输入';
      case StoryRegexStage.assistantOutput:
        return '助手输出';
      case StoryRegexStage.assistantDisplay:
        return '助手展示';
    }
  }

  static String _statusLabel(StoryRegexRuleStatus status) {
    switch (status) {
      case StoryRegexRuleStatus.applied:
        return '命中';
      case StoryRegexRuleStatus.failed:
        return '失败';
      case StoryRegexRuleStatus.timedOut:
        return '超时';
      case StoryRegexRuleStatus.skipped:
        return '跳过';
    }
  }

  static IconData _statusIcon(StoryRegexRuleStatus status) {
    switch (status) {
      case StoryRegexRuleStatus.applied:
        return Icons.check_circle_outline;
      case StoryRegexRuleStatus.failed:
        return Icons.error_outline;
      case StoryRegexRuleStatus.timedOut:
        return Icons.timer_off_outlined;
      case StoryRegexRuleStatus.skipped:
        return Icons.remove_circle_outline;
    }
  }
}

class _StoryRegexScriptEditor extends StatefulWidget {
  final String keyValue;
  final StoryRegexScript? initial;

  const _StoryRegexScriptEditor({
    required this.keyValue,
    required this.initial,
  });

  @override
  State<_StoryRegexScriptEditor> createState() =>
      _StoryRegexScriptEditorState();
}

class _StoryRegexScriptEditorState extends State<_StoryRegexScriptEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _findController;
  late final TextEditingController _replaceController;
  late final TextEditingController _trimController;
  late StoryRegexStage _stage;
  late bool _caseSensitive;
  late bool _multiLine;
  late bool _dotAll;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _findController = TextEditingController(text: initial?.find ?? '');
    _replaceController = TextEditingController(text: initial?.replace ?? '');
    _trimController = TextEditingController(
      text: initial?.trimStrings.join('\n') ?? '',
    );
    _stage = initial?.stage ?? StoryRegexStage.assistantDisplay;
    _caseSensitive = initial?.caseSensitive ?? true;
    _multiLine = initial?.multiLine ?? false;
    _dotAll = initial?.dotAll ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    _trimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.initial == null ? '新增 Regex 规则' : '编辑 Regex 规则',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('story_regex_script_name'),
                controller: _nameController,
                maxLength: StoryRegexScriptLimits.maxNameLength,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: '名称',
                  border: storyInputBorder(context),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('story_regex_script_find'),
                controller: _findController,
                maxLength: StoryRegexScriptLimits.maxPatternLength,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'find 正则',
                  alignLabelWithHint: true,
                  border: storyInputBorder(context),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('story_regex_script_replace'),
                controller: _replaceController,
                maxLength: StoryRegexScriptLimits.maxReplacementLength,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'replace 替换文本',
                  alignLabelWithHint: true,
                  border: storyInputBorder(context),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<StoryRegexStage>(
                key: const ValueKey('story_regex_script_stage'),
                initialValue: _stage,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '执行阶段',
                  border: storyInputBorder(context),
                ),
                items: [
                  for (final stage in StoryRegexStage.values)
                    DropdownMenuItem(
                      value: stage,
                      child:
                          Text(_StoryRegexScriptsPageState._stageLabel(stage)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _stage = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('story_regex_script_trim_strings'),
                controller: _trimController,
                maxLength: StoryRegexScriptLimits.maxTrimStrings *
                    StoryRegexScriptLimits.maxTrimStringLength,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'trimStrings（每行一项）',
                  helperText: '从处理结果两端反复移除这些字符串',
                  alignLabelWithHint: true,
                  border: storyInputBorder(context),
                ),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey('story_regex_script_case_sensitive'),
                contentPadding: EdgeInsets.zero,
                title: const Text('区分大小写'),
                value: _caseSensitive,
                onChanged: (value) => setState(() => _caseSensitive = value),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey('story_regex_script_multi_line'),
                contentPadding: EdgeInsets.zero,
                title: const Text('多行模式（multiLine）'),
                value: _multiLine,
                onChanged: (value) => setState(() => _multiLine = value),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey('story_regex_script_dot_all'),
                contentPadding: EdgeInsets.zero,
                title: const Text('点号匹配换行（dotAll）'),
                value: _dotAll,
                onChanged: (value) => setState(() => _dotAll = value),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('story_regex_script_editor_save'),
                    onPressed: _submit,
                    child: const Text('保存规则'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    final find = _findController.text;
    final replace = _replaceController.text;
    if (name.isEmpty) {
      setState(() => _error = '名称不能为空');
      return;
    }
    if (find.isEmpty) {
      setState(() => _error = 'find 正则不能为空');
      return;
    }
    if (_containsUnsafeControl(name) ||
        _containsUnsafeControl(find) ||
        _containsUnsafeControl(replace)) {
      setState(() => _error = '文本不能包含控制字符');
      return;
    }
    final trimStrings = _trimController.text
        .split('\n')
        .where((value) => value.isNotEmpty)
        .toList();
    if (trimStrings.length > StoryRegexScriptLimits.maxTrimStrings) {
      setState(() =>
          _error = 'trimStrings 最多 ${StoryRegexScriptLimits.maxTrimStrings} 项');
      return;
    }
    if (trimStrings.any((value) =>
        value.length > StoryRegexScriptLimits.maxTrimStringLength ||
        _containsUnsafeControl(value))) {
      setState(() => _error = 'trimStrings 单项过长或包含控制字符');
      return;
    }
    Navigator.pop(
      context,
      StoryRegexScript(
        key: widget.keyValue,
        name: name,
        stage: _stage,
        find: find,
        replace: replace,
        trimStrings: List.unmodifiable(trimStrings),
        caseSensitive: _caseSensitive,
        multiLine: _multiLine,
        dotAll: _dotAll,
        enabled: widget.initial?.enabled ?? true,
        sortOrder: widget.initial?.sortOrder ?? 0,
      ),
    );
  }

  static bool _containsUnsafeControl(String value) =>
      value.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'));
}
