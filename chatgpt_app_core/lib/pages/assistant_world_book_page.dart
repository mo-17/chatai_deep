import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef AssistantWorldBookSaver = Future<void> Function(
    AssistantModel assistant);

class AssistantWorldBookPage extends StatefulWidget {
  final AssistantModel assistant;
  final AssistantWorldBookSaver? onSave;

  const AssistantWorldBookPage({
    super.key,
    required this.assistant,
    this.onSave,
  });

  @override
  State<AssistantWorldBookPage> createState() => _AssistantWorldBookPageState();
}

class _AssistantWorldBookPageState extends State<AssistantWorldBookPage> {
  late List<String> _lines;
  late List<_WorldBookEntry> _entries;
  late final TextEditingController _searchCtl;
  late final TextEditingController _probeCtl;
  AssistantWorldBookSaver? _save;
  List<AssistantMemoryEntryPreview> _probeHits = const [];
  int _probeRequest = 0;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _searchCtl = TextEditingController()..addListener(_onSearchChanged);
    _probeCtl = TextEditingController()..addListener(_onProbeChanged);
    _lines = widget.assistant.memoryBook.split('\n');
    _reparse();
    _doInit();
  }

  @override
  void dispose() {
    _searchCtl
      ..removeListener(_onSearchChanged)
      ..dispose();
    _probeCtl
      ..removeListener(_onProbeChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _doInit() async {
    if (widget.onSave != null) {
      _save = widget.onSave;
      return;
    }
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await AssistantDao.create(dbManager);
    _save = dao.saveAssistant;
  }

  void _reparse() {
    _entries = [
      for (var i = 0; i < _lines.length; i++)
        if (_WorldBookEntry.tryParse(_lines[i], i) case final entry?) entry,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.assistant.name.trim().isEmpty
        ? '世界书'
        : '${widget.assistant.name} · 世界书';
    return Scaffold(
      appBar: AppBar(title: Text(title), centerTitle: true),
      body: _entries.isEmpty ? _emptyView : _contentView,
      floatingActionButton: FloatingActionButton(
        tooltip: '新增设定',
        onPressed: () => _editEntry(null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _emptyView => AppVisualEmptyState(
        icon: Icons.auto_stories_outlined,
        title: '还没有世界书设定',
        message: '点右下角新增；关键词为空时会作为常驻设定。',
        classic: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '还没有世界书设定。点右下角新增；关键词为空时会作为常驻设定。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );

  Widget get _contentView {
    final filtered = _filteredEntries;
    return Column(
      children: [
        _summaryHeader,
        Expanded(
          child: filtered.isEmpty ? _noSearchResultView : _listView(filtered),
        ),
      ],
    );
  }

  Widget get _summaryHeader {
    final disabledCount = _entries.where((entry) => !entry.enabled).length;
    final alwaysOnCount = _entries.where((entry) => entry.alwaysOn).length;
    final keywordCount = _entries.length - alwaysOnCount;
    final colorScheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '共 ${_entries.length} 条 · 常驻 $alwaysOnCount · 关键词 $keywordCount · 禁用 $disabledCount',
            style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchCtl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(Icons.clear),
                      onPressed: _searchCtl.clear,
                    ),
              hintText: '搜索关键词或设定内容',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _probeCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.bolt_outlined),
              suffixIcon: _probeCtl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空试触发',
                      icon: const Icon(Icons.clear),
                      onPressed: _probeCtl.clear,
                    ),
              hintText: '输入一句话试触发世界书',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_probeCtl.text.trim().isNotEmpty) _probePreview,
        ],
      ),
    );
    return AppVisualSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: content,
    );
  }

  Widget get _probePreview {
    final hits = _probeHits;
    final hasHits = hits.isNotEmpty;
    final palette = AppStatusPalette.of(
      context,
      hasHits ? AppStatusKind.info : AppStatusKind.neutral,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.container,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: palette.foreground.withValues(alpha: 0.18),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _probing
                          ? '正在匹配世界书…'
                          : hasHits
                              ? AssistantRoleCardService.memoryHitSummary(hits)
                              : '本句不会注入世界书',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.onContainer,
                      ),
                    ),
                  ),
                  if (hasHits)
                    IconButton(
                      tooltip: '复制命中世界书',
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      onPressed: () => _copyProbeHits(hits),
                    ),
                ],
              ),
              if (hasHits) ...[
                const SizedBox(height: 6),
                for (final hit in hits.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      AssistantRoleCardService.memoryHitPreviewLine(hit),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.onContainer,
                      ),
                    ),
                  ),
                if (hits.length > 4)
                  Text(
                    '还有 ${hits.length - 4} 条未展示',
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.onContainer.withValues(alpha: 0.72),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget get _noSearchResultView => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有匹配的世界书设定',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );

  List<_WorldBookEntry> get _filteredEntries {
    final query = _searchCtl.text.trim().toLowerCase();
    if (query.isEmpty) return _entries;
    return _entries.where((entry) {
      return entry.content.toLowerCase().contains(query) ||
          entry.keywords
              .any((keyword) => keyword.toLowerCase().contains(query));
    }).toList();
  }

  Widget _listView(List<_WorldBookEntry> entries) => ListView.separated(
        padding: AppVisualTheme.of(context).isAnime
            ? const EdgeInsets.fromLTRB(12, 6, 12, 20)
            : const EdgeInsets.symmetric(vertical: 8),
        itemCount: entries.length,
        separatorBuilder: (_, __) => AppVisualTheme.of(context).isAnime
            ? const SizedBox(height: 8)
            : const Divider(height: 1),
        itemBuilder: (context, index) {
          final entry = entries[index];
          final tile = ListTile(
            leading: Icon(
              entry.enabled
                  ? (entry.alwaysOn
                      ? Icons.push_pin_outlined
                      : Icons.key_outlined)
                  : Icons.visibility_off_outlined,
            ),
            title: Text(entry.content,
                maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text(entry.subtitle),
            onTap: () => _editEntry(entry),
            trailing: SizedBox(
              width: 96,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '复制设定',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () => _copyEntry(entry),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteEntry(entry),
                  ),
                ],
              ),
            ),
          );
          return AppVisualSurface(
            padding: EdgeInsets.zero,
            child: tile,
          );
        },
      );

  void _onSearchChanged() => setState(() {});

  Future<void> _onProbeChanged() async {
    final request = ++_probeRequest;
    final input = _probeCtl.text;
    setState(() {
      _probeHits = const [];
      _probing = input.trim().isNotEmpty;
    });
    if (!_probing) return;
    final hits = await AssistantRoleCardService.matchMemoryEntriesSafely(
      widget.assistant.memoryBook,
      input,
      structuredJson: widget.assistant.worldBookJson,
      characterName: widget.assistant.name,
      characterDescription: widget.assistant.prompt,
      creatorNotes: widget.assistant.description,
    );
    if (!mounted || request != _probeRequest) return;
    setState(() {
      _probeHits = hits;
      _probing = false;
    });
  }

  Future<void> _copyProbeHits(List<AssistantMemoryEntryPreview> hits) async {
    final text = AssistantRoleCardService.memoryHitCopyText(hits);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '命中世界书已复制');
  }

  Future<void> _editEntry(_WorldBookEntry? entry) async {
    final result = await showDialog<_WorldBookEditResult>(
      context: context,
      builder: (_) => _WorldBookEditDialog(entry: entry),
    );
    if (result == null || result.content.trim().isEmpty) return;
    if (_hasDuplicateContent(result.content,
        exceptLineIndex: entry?.lineIndex)) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '这条世界书设定已存在');
      return;
    }

    final line = result.toLine();
    setState(() {
      if (entry == null) {
        _lines.add(line);
      } else {
        _lines[entry.lineIndex] = line;
      }
      _reparse();
      widget.assistant.memoryBook = _normalizedMemoryBook();
      _syncStructuredWorldBook();
    });
    _onProbeChanged();
    await _saveAssistant(entry == null ? '已新增世界书设定' : '已更新世界书设定');
  }

  Future<void> _deleteEntry(_WorldBookEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除世界书设定'),
        content: Text(entry.content),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _lines.removeAt(entry.lineIndex);
      _reparse();
      widget.assistant.memoryBook = _normalizedMemoryBook();
      _syncStructuredWorldBook();
    });
    _onProbeChanged();
    await _saveAssistant('已删除世界书设定');
  }

  Future<void> _copyEntry(_WorldBookEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.toLine()));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '世界书设定已复制');
  }

  bool _hasDuplicateContent(String content, {int? exceptLineIndex}) {
    final normalized = _normalizeContent(content);
    if (normalized.isEmpty) return false;
    return _entries
        .where((entry) => entry.lineIndex != exceptLineIndex)
        .map((entry) => _normalizeContent(entry.content))
        .any((item) => item == normalized);
  }

  static String _normalizeContent(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), '');

  String _normalizedMemoryBook() => _lines
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');

  Future<void> _saveAssistant(String message) async {
    final save = _save;
    if (save == null) return;
    try {
      await save(widget.assistant);
      if (!mounted) return;
      HiDialog.showSnackBar(context, message);
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '保存失败：$e');
    }
  }

  void _syncStructuredWorldBook() {
    widget.assistant.worldBookJson = WorldBookCodec.encode(
      WorldBookCodec.decode(legacyText: widget.assistant.memoryBook),
    );
  }
}

class _WorldBookEntry {
  final int lineIndex;
  final WorldBookEntry value;

  const _WorldBookEntry({
    required this.lineIndex,
    required this.value,
  });

  List<String> get keywords => value.keywords;
  String get content => value.content;
  bool get enabled => value.enabled;
  int get priority => value.priority;
  List<String> get excludeKeywords => value.excludeKeywords;
  List<String> get secondaryKeywords => value.secondaryKeywords;
  bool get regex => value.regex;
  bool get caseSensitive => value.caseSensitive;
  bool get wholeWords => value.wholeWords;
  String get position => value.position;
  int? get depth => value.depth;
  int? get probability => value.probability;
  bool get probabilityEnabled => value.probabilityEnabled;
  bool get excludeFromRecursion => value.excludeFromRecursion;
  String get group => value.group;
  int get groupWeight => value.groupWeight;
  bool get groupOverride => value.groupOverride;
  bool get useGroupScoring => value.useGroupScoring;
  WorldBookSelectiveLogic get selectiveLogic => value.selectiveLogic;
  int get sticky => value.sticky;
  int get cooldown => value.cooldown;
  int get delay => value.delay;
  List<String> get characterFilterNames => value.characterFilterNames;
  bool get characterFilterExclude => value.characterFilterExclude;
  bool get matchPersonaDescription => value.matchPersonaDescription;
  bool get matchCharacterDescription => value.matchCharacterDescription;
  bool get matchCharacterPersonality => value.matchCharacterPersonality;
  bool get matchCharacterDepthPrompt => value.matchCharacterDepthPrompt;
  bool get matchScenario => value.matchScenario;
  bool get matchCreatorNotes => value.matchCreatorNotes;
  bool get alwaysOn => keywords.isEmpty;

  String get subtitle {
    final parts = <String>[
      enabled ? '启用' : '已禁用',
      alwaysOn ? '常驻设定' : keywords.join(' / '),
      if (secondaryKeywords.isNotEmpty) '二级 ${secondaryKeywords.join(' / ')}',
      if (priority != 0) '优先级 $priority',
      if (excludeKeywords.isNotEmpty) '排除 ${excludeKeywords.join(' / ')}',
      if (regex) '正则',
      if (caseSensitive) '区分大小写',
      if (wholeWords) '整词',
      if (position.isNotEmpty) '位置 $position',
      if (depth != null) '深度 $depth',
      if (probability != null) '概率 $probability%',
      if (!probabilityEnabled) '概率关闭',
      if (excludeFromRecursion) '不递归',
      if (group.isNotEmpty) '组 $group',
      if (groupWeight != 0) '组权重 $groupWeight',
      if (groupOverride) '组优先',
      if (useGroupScoring) '组评分',
      if (selectiveLogic != WorldBookSelectiveLogic.andAny)
        '二级逻辑 ${_selectiveLogicLabel(selectiveLogic)}',
      if (sticky > 0) '粘滞 $sticky 轮',
      if (cooldown > 0) '冷却 $cooldown 轮',
      if (delay > 0) '延迟 $delay 轮',
      if (characterFilterNames.isNotEmpty)
        '${characterFilterExclude ? '排除' : '限定'}角色 ${characterFilterNames.join(' / ')}',
    ];
    return parts.join(' · ');
  }

  String toLine() => value.toLine(preserveSource: false);

  static _WorldBookEntry? tryParse(String raw, int lineIndex) {
    final value = WorldBookEntry.tryParse(raw, id: 'legacy-$lineIndex');
    if (value == null) return null;
    return _WorldBookEntry(lineIndex: lineIndex, value: value);
  }
}

String _selectiveLogicLabel(WorldBookSelectiveLogic value) => switch (value) {
      WorldBookSelectiveLogic.andAny => '任一匹配',
      WorldBookSelectiveLogic.notAll => '不全部匹配',
      WorldBookSelectiveLogic.notAny => '均不匹配',
      WorldBookSelectiveLogic.andAll => '全部匹配',
    };

class _WorldBookEditResult {
  final String keywords;
  final String content;
  final bool enabled;
  final int priority;
  final String excludeKeywords;
  final List<String> secondaryKeywords;
  final bool regex;
  final bool caseSensitive;
  final bool wholeWords;
  final String position;
  final int? depth;
  final int? probability;
  final bool excludeFromRecursion;
  final String group;
  final int groupWeight;
  final bool probabilityEnabled;
  final bool groupOverride;
  final bool useGroupScoring;
  final WorldBookSelectiveLogic selectiveLogic;
  final int sticky;
  final int cooldown;
  final int delay;
  final List<String> characterFilterNames;
  final bool characterFilterExclude;
  final bool matchPersonaDescription;
  final bool matchCharacterDescription;
  final bool matchCharacterPersonality;
  final bool matchCharacterDepthPrompt;
  final bool matchScenario;
  final bool matchCreatorNotes;

  const _WorldBookEditResult({
    required this.keywords,
    required this.content,
    this.enabled = true,
    this.priority = 0,
    this.excludeKeywords = '',
    this.secondaryKeywords = const [],
    this.regex = false,
    this.caseSensitive = false,
    this.wholeWords = false,
    this.position = '',
    this.depth,
    this.probability,
    this.excludeFromRecursion = false,
    this.group = '',
    this.groupWeight = 0,
    this.probabilityEnabled = true,
    this.groupOverride = false,
    this.useGroupScoring = false,
    this.selectiveLogic = WorldBookSelectiveLogic.andAny,
    this.sticky = 0,
    this.cooldown = 0,
    this.delay = 0,
    this.characterFilterNames = const [],
    this.characterFilterExclude = false,
    this.matchPersonaDescription = false,
    this.matchCharacterDescription = false,
    this.matchCharacterPersonality = false,
    this.matchCharacterDepthPrompt = false,
    this.matchScenario = false,
    this.matchCreatorNotes = false,
  });

  String toLine() {
    return WorldBookEntry(
      keywords: _splitList(keywords, regex: regex),
      content: content.trim(),
      enabled: enabled,
      priority: priority,
      excludeKeywords: _splitList(excludeKeywords),
      secondaryKeywords: secondaryKeywords,
      regex: regex,
      caseSensitive: caseSensitive,
      wholeWords: wholeWords,
      position: position.trim(),
      depth: depth,
      probability: probability,
      probabilityEnabled: probabilityEnabled,
      excludeFromRecursion: excludeFromRecursion,
      group: group.trim(),
      groupWeight: groupWeight,
      groupOverride: groupOverride,
      useGroupScoring: useGroupScoring,
      selectiveLogic: selectiveLogic,
      sticky: sticky,
      cooldown: cooldown,
      delay: delay,
      characterFilterNames: characterFilterNames,
      characterFilterExclude: characterFilterExclude,
      matchPersonaDescription: matchPersonaDescription,
      matchCharacterDescription: matchCharacterDescription,
      matchCharacterPersonality: matchCharacterPersonality,
      matchCharacterDepthPrompt: matchCharacterDepthPrompt,
      matchScenario: matchScenario,
      matchCreatorNotes: matchCreatorNotes,
    ).toLine(preserveSource: false);
  }

  List<String> _splitList(String raw, {bool regex = false}) {
    return raw
        .split(regex ? RegExp(r'\s*\|\|\s*|[,，、/]+') : RegExp(r'[,，、|/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
}

class _WorldBookEditDialog extends StatefulWidget {
  final _WorldBookEntry? entry;

  const _WorldBookEditDialog({required this.entry});

  @override
  State<_WorldBookEditDialog> createState() => _WorldBookEditDialogState();
}

class _WorldBookEditDialogState extends State<_WorldBookEditDialog> {
  late final TextEditingController _keywordsCtl;
  late final TextEditingController _excludeCtl;
  late final TextEditingController _contentCtl;
  late final TextEditingController _priorityCtl;
  late final TextEditingController _depthCtl;
  late final TextEditingController _probabilityCtl;
  late final TextEditingController _secondaryCtl;
  late final TextEditingController _groupCtl;
  late final TextEditingController _groupWeightCtl;
  late final TextEditingController _stickyCtl;
  late final TextEditingController _cooldownCtl;
  late final TextEditingController _delayCtl;
  late final TextEditingController _charactersCtl;
  late bool _enabled;
  late bool _regex;
  late bool _caseSensitive;
  late bool _wholeWords;
  late bool _probabilityEnabled;
  late bool _excludeFromRecursion;
  late bool _groupOverride;
  late bool _useGroupScoring;
  late bool _characterFilterExclude;
  late bool _matchPersonaDescription;
  late bool _matchCharacterDescription;
  late bool _matchCharacterPersonality;
  late bool _matchCharacterDepthPrompt;
  late bool _matchScenario;
  late bool _matchCreatorNotes;
  late WorldBookSelectiveLogic _selectiveLogic;
  late String _position;
  String? _contentError;

  @override
  void initState() {
    super.initState();
    _keywordsCtl =
        TextEditingController(text: widget.entry?.keywords.join(', ') ?? '');
    _excludeCtl = TextEditingController(
        text: widget.entry?.excludeKeywords.join(', ') ?? '');
    _contentCtl = TextEditingController(text: widget.entry?.content ?? '');
    _priorityCtl =
        TextEditingController(text: '${widget.entry?.priority ?? 0}');
    _depthCtl = TextEditingController(text: '${widget.entry?.depth ?? ''}');
    _probabilityCtl =
        TextEditingController(text: '${widget.entry?.probability ?? ''}');
    _secondaryCtl = TextEditingController(
        text: widget.entry?.secondaryKeywords.join(', ') ?? '');
    _groupCtl = TextEditingController(text: widget.entry?.group ?? '');
    _groupWeightCtl =
        TextEditingController(text: '${widget.entry?.groupWeight ?? 0}');
    _stickyCtl = TextEditingController(text: '${widget.entry?.sticky ?? 0}');
    _cooldownCtl =
        TextEditingController(text: '${widget.entry?.cooldown ?? 0}');
    _delayCtl = TextEditingController(text: '${widget.entry?.delay ?? 0}');
    _charactersCtl = TextEditingController(
        text: widget.entry?.characterFilterNames.join(', ') ?? '');
    _enabled = widget.entry?.enabled ?? true;
    _regex = widget.entry?.regex ?? false;
    _caseSensitive = widget.entry?.caseSensitive ?? false;
    _wholeWords = widget.entry?.wholeWords ?? false;
    _probabilityEnabled = widget.entry?.probabilityEnabled ?? true;
    _excludeFromRecursion = widget.entry?.excludeFromRecursion ?? false;
    _groupOverride = widget.entry?.groupOverride ?? false;
    _useGroupScoring = widget.entry?.useGroupScoring ?? false;
    _characterFilterExclude = widget.entry?.characterFilterExclude ?? false;
    _matchPersonaDescription = widget.entry?.matchPersonaDescription ?? false;
    _matchCharacterDescription =
        widget.entry?.matchCharacterDescription ?? false;
    _matchCharacterPersonality =
        widget.entry?.matchCharacterPersonality ?? false;
    _matchCharacterDepthPrompt =
        widget.entry?.matchCharacterDepthPrompt ?? false;
    _matchScenario = widget.entry?.matchScenario ?? false;
    _matchCreatorNotes = widget.entry?.matchCreatorNotes ?? false;
    _selectiveLogic =
        widget.entry?.selectiveLogic ?? WorldBookSelectiveLogic.andAny;
    _position = widget.entry?.position ?? '';
  }

  @override
  void dispose() {
    _keywordsCtl.dispose();
    _excludeCtl.dispose();
    _contentCtl.dispose();
    _priorityCtl.dispose();
    _depthCtl.dispose();
    _probabilityCtl.dispose();
    _secondaryCtl.dispose();
    _groupCtl.dispose();
    _groupWeightCtl.dispose();
    _stickyCtl.dispose();
    _cooldownCtl.dispose();
    _delayCtl.dispose();
    _charactersCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? '新增世界书设定' : '编辑世界书设定'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              title: const Text('启用条目'),
              subtitle: const Text('关闭后保留在世界书中，但不会注入上下文'),
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keywordsCtl,
              decoration: const InputDecoration(
                labelText: '触发关键词',
                hintText: '多个关键词用逗号分隔；留空表示常驻',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            _advancedTriggerSection,
            const SizedBox(height: 12),
            TextField(
              controller: _excludeCtl,
              decoration: const InputDecoration(
                labelText: '排除关键词',
                hintText: '命中这些词时不注入；多个用逗号分隔',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _priorityCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '优先级',
                hintText: '默认 0；数值越大越先注入',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _position,
              decoration: const InputDecoration(
                labelText: 'Tavern 注入位置',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: '', child: Text('默认')),
                DropdownMenuItem(value: 'before_char', child: Text('角色人设前')),
                DropdownMenuItem(value: 'after_char', child: Text('角色人设后')),
              ],
              onChanged: (value) => setState(() => _position = value ?? ''),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _depthCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '扫描深度',
                      hintText: '可选',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _probabilityCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '触发概率',
                      hintText: '0-100，可选',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentCtl,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '设定内容',
                hintText: '写下命中后要注入给角色的设定',
                border: OutlineInputBorder(),
              ).copyWith(errorText: _contentError),
              onChanged: (_) {
                if (_contentError != null) {
                  setState(() => _contentError = null);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Widget get _advancedTriggerSection => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: const Text('高级触发'),
        subtitle: const Text('二级逻辑、组竞争、持续效果和角色过滤'),
        children: [
          TextField(
            controller: _secondaryCtl,
            decoration: const InputDecoration(
              labelText: '二级关键词',
              hintText: '多个关键词用逗号分隔',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<WorldBookSelectiveLogic>(
            initialValue: _selectiveLogic,
            decoration: const InputDecoration(
              labelText: '二级关键词逻辑',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final logic in WorldBookSelectiveLogic.values)
                DropdownMenuItem(
                  value: logic,
                  child: Text(_selectiveLogicLabel(logic)),
                ),
            ],
            onChanged: (value) => setState(() =>
                _selectiveLogic = value ?? WorldBookSelectiveLogic.andAny),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _regex,
            title: const Text('主关键词使用正则表达式'),
            onChanged: (value) => setState(() => _regex = value ?? false),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _caseSensitive,
            title: const Text('区分大小写'),
            onChanged: (value) =>
                setState(() => _caseSensitive = value ?? false),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _wholeWords,
            title: const Text('仅匹配完整单词'),
            onChanged: (value) => setState(() => _wholeWords = value ?? false),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _probabilityEnabled,
            title: const Text('启用概率判定'),
            onChanged: (value) => setState(() => _probabilityEnabled = value),
          ),
          TextField(
            controller: _groupCtl,
            decoration: const InputDecoration(
              labelText: '包含组',
              hintText: '同组只选一条；多个组用逗号分隔',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _groupWeightCtl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '组权重',
              hintText: '默认 0',
              border: OutlineInputBorder(),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _groupOverride,
            title: const Text('组内优先选择最高优先级'),
            onChanged: (value) =>
                setState(() => _groupOverride = value ?? false),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _useGroupScoring,
            title: const Text('按关键词命中分数选择组内条目'),
            onChanged: (value) =>
                setState(() => _useGroupScoring = value ?? false),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(14) > 18;
              final fields = [
                _turnField(_delayCtl, '延迟'),
                _turnField(_stickyCtl, '粘滞'),
                _turnField(_cooldownCtl, '冷却'),
              ];
              if (stacked) {
                return Column(
                  children: [
                    for (var index = 0; index < fields.length; index++) ...[
                      fields[index],
                      if (index < fields.length - 1) const SizedBox(height: 8),
                    ],
                  ],
                );
              }
              return Row(
                children: [
                  for (var index = 0; index < fields.length; index++) ...[
                    Expanded(child: fields[index]),
                    if (index < fields.length - 1) const SizedBox(width: 8),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _charactersCtl,
            decoration: const InputDecoration(
              labelText: '角色过滤',
              hintText: '角色名用逗号分隔；留空不限制',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _characterFilterExclude,
            title: const Text('将上述角色作为排除名单'),
            onChanged: (value) =>
                setState(() => _characterFilterExclude = value),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _excludeFromRecursion,
            title: const Text('不参与递归触发'),
            onChanged: (value) =>
                setState(() => _excludeFromRecursion = value ?? false),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 8, bottom: 4),
              child: Text('额外扫描角色卡字段'),
            ),
          ),
          _matchFieldTile('用户人设', _matchPersonaDescription,
              (value) => _matchPersonaDescription = value),
          _matchFieldTile('角色简介', _matchCharacterDescription,
              (value) => _matchCharacterDescription = value),
          _matchFieldTile('角色性格', _matchCharacterPersonality,
              (value) => _matchCharacterPersonality = value),
          _matchFieldTile('深度提示词', _matchCharacterDepthPrompt,
              (value) => _matchCharacterDepthPrompt = value),
          _matchFieldTile(
              '场景', _matchScenario, (value) => _matchScenario = value),
          _matchFieldTile('创建者备注', _matchCreatorNotes,
              (value) => _matchCreatorNotes = value),
        ],
      );

  Widget _turnField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          suffixText: '轮',
          border: const OutlineInputBorder(),
        ),
      );

  Widget _matchFieldTile(
    String title,
    bool value,
    ValueChanged<bool> update,
  ) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        title: Text(title),
        onChanged: (next) => setState(() => update(next ?? false)),
      );

  void _save() {
    if (_contentCtl.text.trim().isEmpty) {
      setState(() => _contentError = '请填写设定内容');
      return;
    }
    Navigator.pop(
      context,
      _WorldBookEditResult(
        keywords: _keywordsCtl.text,
        content: _contentCtl.text,
        enabled: _enabled,
        priority: int.tryParse(_priorityCtl.text.trim()) ?? 0,
        excludeKeywords: _excludeCtl.text,
        secondaryKeywords: _splitKeywords(_secondaryCtl.text),
        regex: _regex,
        caseSensitive: _caseSensitive,
        wholeWords: _wholeWords,
        position: _position,
        depth: _optionalInt(_depthCtl.text),
        probability: _optionalClampedInt(_probabilityCtl.text, 0, 100),
        probabilityEnabled: _probabilityEnabled,
        excludeFromRecursion: _excludeFromRecursion,
        group: _groupCtl.text,
        groupWeight: int.tryParse(_groupWeightCtl.text.trim()) ?? 0,
        groupOverride: _groupOverride,
        useGroupScoring: _useGroupScoring,
        selectiveLogic: _selectiveLogic,
        sticky: _nonNegativeInt(_stickyCtl.text),
        cooldown: _nonNegativeInt(_cooldownCtl.text),
        delay: _nonNegativeInt(_delayCtl.text),
        characterFilterNames: _splitKeywords(_charactersCtl.text),
        characterFilterExclude: _characterFilterExclude,
        matchPersonaDescription: _matchPersonaDescription,
        matchCharacterDescription: _matchCharacterDescription,
        matchCharacterPersonality: _matchCharacterPersonality,
        matchCharacterDepthPrompt: _matchCharacterDepthPrompt,
        matchScenario: _matchScenario,
        matchCreatorNotes: _matchCreatorNotes,
      ),
    );
  }

  int? _optionalInt(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  int? _optionalClampedInt(String value, int min, int max) {
    final parsed = _optionalInt(value);
    if (parsed == null) return null;
    return parsed.clamp(min, max);
  }

  int _nonNegativeInt(String value) {
    final parsed = int.tryParse(value.trim()) ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  List<String> _splitKeywords(String raw) => raw
      .split(RegExp(r'[,，、|/]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
