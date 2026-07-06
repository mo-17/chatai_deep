import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
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

  Widget get _emptyView => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '还没有世界书设定。点右下角新增；关键词为空时会作为常驻设定。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '共 ${_entries.length} 条 · 常驻 $alwaysOnCount · 关键词 $keywordCount · 禁用 $disabledCount',
            style: const TextStyle(fontSize: 13, color: Colors.black54),
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
  }

  Widget get _probePreview {
    final hits = AssistantRoleCardService.matchMemoryEntries(
      widget.assistant.memoryBook,
      _probeCtl.text,
    );
    final hasHits = hits.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hasHits ? Colors.blueGrey.withAlpha(18) : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
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
                      hasHits
                          ? AssistantRoleCardService.memoryHitSummary(hits)
                          : '本句不会注入世界书',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: hasHits ? Colors.blueGrey[700] : Colors.black54,
                      ),
                    ),
                  ),
                  if (hasHits)
                    IconButton(
                      tooltip: '复制命中世界书',
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      visualDensity: VisualDensity.compact,
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                if (hits.length > 4)
                  Text(
                    '还有 ${hits.length - 4} 条未展示',
                    style: const TextStyle(fontSize: 12, color: Colors.black38),
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
            style: TextStyle(color: Colors.grey[600]),
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ListTile(
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
        },
      );

  void _onSearchChanged() => setState(() {});

  void _onProbeChanged() => setState(() {});

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
    });
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
    });
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
}

class _WorldBookEntry {
  final int lineIndex;
  final List<String> keywords;
  final String content;
  final bool enabled;
  final int priority;
  final List<String> excludeKeywords;
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

  const _WorldBookEntry({
    required this.lineIndex,
    required this.keywords,
    required this.content,
    this.enabled = true,
    this.priority = 0,
    this.excludeKeywords = const [],
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
  });

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
      if (excludeFromRecursion) '不递归',
      if (group.isNotEmpty) '组 $group',
      if (groupWeight != 0) '组权重 $groupWeight',
    ];
    return parts.join(' · ');
  }

  String toLine() {
    final prefixes = <String>[
      if (!enabled) '[off]',
      if (regex) '[re]',
      if (caseSensitive) '[cs]',
      if (wholeWords) '[ww]',
      if (secondaryKeywords.isNotEmpty) '[sec=${secondaryKeywords.join('|')}]',
      if (priority != 0) '[p=$priority]',
      if (excludeKeywords.isNotEmpty) '[exclude=${excludeKeywords.join('|')}]',
      if (position.isNotEmpty) '[pos=$position]',
      if (depth != null) '[depth=$depth]',
      if (probability != null) '[prob=$probability]',
      if (excludeFromRecursion) '[norec]',
      if (group.isNotEmpty) '[group=$group]',
      if (groupWeight != 0) '[gw=$groupWeight]',
    ];
    final keywordText = regex ? keywords.join(' || ') : keywords.join(', ');
    final body = alwaysOn ? content : '$keywordText => $content';
    return [...prefixes, body].join(' ');
  }

  static _WorldBookEntry? tryParse(String raw, int lineIndex) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) return null;
    final meta = _parseMeta(line);
    final body = meta.body;
    final idx = body.indexOf('=>');
    if (idx < 0) {
      return _WorldBookEntry(
        lineIndex: lineIndex,
        keywords: const [],
        content: body,
        enabled: meta.enabled,
        priority: meta.priority,
        excludeKeywords: meta.excludeKeywords,
        secondaryKeywords: meta.secondaryKeywords,
        regex: meta.regex,
        caseSensitive: meta.caseSensitive,
        wholeWords: meta.wholeWords,
        position: meta.position,
        depth: meta.depth,
        probability: meta.probability,
        excludeFromRecursion: meta.excludeFromRecursion,
        group: meta.group,
        groupWeight: meta.groupWeight,
      );
    }
    final content = body.substring(idx + 2).trim();
    if (content.isEmpty) return null;
    final keywords = _splitKeywords(body.substring(0, idx), regex: meta.regex);
    if (keywords.isEmpty) return null;
    return _WorldBookEntry(
      lineIndex: lineIndex,
      keywords: keywords,
      content: content,
      enabled: meta.enabled,
      priority: meta.priority,
      excludeKeywords: meta.excludeKeywords,
      secondaryKeywords: meta.secondaryKeywords,
      regex: meta.regex,
      caseSensitive: meta.caseSensitive,
      wholeWords: meta.wholeWords,
      position: meta.position,
      depth: meta.depth,
      probability: meta.probability,
      excludeFromRecursion: meta.excludeFromRecursion,
      group: meta.group,
      groupWeight: meta.groupWeight,
    );
  }

  static _WorldBookMeta _parseMeta(String line) {
    var rest = line.trim();
    var enabled = true;
    var priority = 0;
    var excludeKeywords = const <String>[];
    var secondaryKeywords = const <String>[];
    var regex = false;
    var caseSensitive = false;
    var wholeWords = false;
    var position = '';
    int? depth;
    int? probability;
    var excludeFromRecursion = false;
    var group = '';
    var groupWeight = 0;
    var changed = true;
    while (changed && rest.startsWith('[')) {
      changed = false;
      final end = rest.indexOf(']');
      if (end <= 0) break;
      final rawTag = rest.substring(1, end).trim();
      final tag = rawTag.toLowerCase();
      if (tag == 'off' || tag == 'disabled') {
        enabled = false;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'on' || tag == 'enabled') {
        enabled = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('p=')) {
        priority = int.tryParse(tag.substring(2).trim()) ?? priority;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 're' || tag == 'regex') {
        regex = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'cs' || tag == 'case') {
        caseSensitive = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'ww' || tag == 'whole') {
        wholeWords = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('sec=') || tag.startsWith('secondary=')) {
        final rawValue = rawTag.substring(rawTag.indexOf('=') + 1);
        secondaryKeywords = _splitKeywords(rawValue, regex: regex);
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('exclude=') ||
          tag.startsWith('excludes=') ||
          tag.startsWith('exclude_keys=') ||
          tag.startsWith('excludekeys=')) {
        final rawValue = rawTag.substring(rawTag.indexOf('=') + 1);
        excludeKeywords = _splitKeywords(rawValue);
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('pos=') || tag.startsWith('position=')) {
        position = rawTag.substring(rawTag.indexOf('=') + 1).trim();
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('depth=')) {
        depth = int.tryParse(tag.substring(6).trim()) ?? depth;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('prob=') || tag.startsWith('probability=')) {
        probability =
            int.tryParse(rawTag.substring(rawTag.indexOf('=') + 1).trim()) ??
                probability;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'norec' ||
          tag == 'nonrec' ||
          tag == 'no_recursion' ||
          tag == 'exclude_recursion' ||
          tag == 'prevent_recursion') {
        excludeFromRecursion = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('group=')) {
        group = rawTag.substring(rawTag.indexOf('=') + 1).trim();
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('gw=') || tag.startsWith('groupweight=')) {
        groupWeight =
            int.tryParse(rawTag.substring(rawTag.indexOf('=') + 1).trim()) ??
                groupWeight;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      }
    }
    return _WorldBookMeta(
      body: rest,
      enabled: enabled,
      priority: priority,
      excludeKeywords: excludeKeywords,
      secondaryKeywords: secondaryKeywords,
      regex: regex,
      caseSensitive: caseSensitive,
      wholeWords: wholeWords,
      position: position,
      depth: depth,
      probability: probability,
      excludeFromRecursion: excludeFromRecursion,
      group: group,
      groupWeight: groupWeight,
    );
  }

  static List<String> _splitKeywords(String raw, {bool regex = false}) {
    if (regex) {
      return raw
          .split(RegExp(r'\s*\|\|\s*'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return raw
        .split(RegExp(r'[,，、|/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
}

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
  });

  String toLine() {
    final k = keywords.trim();
    final c = content.trim();
    final prefixes = <String>[
      if (!enabled) '[off]',
      if (regex) '[re]',
      if (caseSensitive) '[cs]',
      if (wholeWords) '[ww]',
      if (secondaryKeywords.isNotEmpty) '[sec=${secondaryKeywords.join('|')}]',
      if (priority != 0) '[p=$priority]',
      if (excludeKeywords.trim().isNotEmpty)
        '[exclude=${_normalizeKeywordList(excludeKeywords)}]',
      if (position.trim().isNotEmpty) '[pos=${position.trim()}]',
      if (depth != null) '[depth=$depth]',
      if (probability != null) '[prob=$probability]',
      if (excludeFromRecursion) '[norec]',
      if (group.trim().isNotEmpty) '[group=${group.trim()}]',
      if (groupWeight != 0) '[gw=$groupWeight]',
    ];
    final keywordText = regex ? _normalizeRegexKeywordList(k) : k;
    final body = keywordText.isEmpty ? c : '$keywordText => $c';
    return [...prefixes, body].join(' ');
  }

  String _normalizeRegexKeywordList(String raw) {
    return raw
        .split(RegExp(r'\s*\|\|\s*|[,，、/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .join(' || ');
  }

  String _normalizeKeywordList(String raw) {
    return raw
        .split(RegExp(r'[,，、|/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .join('|');
  }
}

class _WorldBookMeta {
  final String body;
  final bool enabled;
  final int priority;
  final List<String> excludeKeywords;
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

  const _WorldBookMeta({
    required this.body,
    required this.enabled,
    required this.priority,
    this.excludeKeywords = const [],
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
  });
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
  late bool _enabled;
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
    _enabled = widget.entry?.enabled ?? true;
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
        secondaryKeywords: widget.entry?.secondaryKeywords ?? const [],
        regex: widget.entry?.regex ?? false,
        caseSensitive: widget.entry?.caseSensitive ?? false,
        wholeWords: widget.entry?.wholeWords ?? false,
        position: _position,
        depth: _optionalInt(_depthCtl.text),
        probability: _optionalClampedInt(_probabilityCtl.text, 0, 100),
        excludeFromRecursion: widget.entry?.excludeFromRecursion ?? false,
        group: widget.entry?.group ?? '',
        groupWeight: widget.entry?.groupWeight ?? 0,
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
}
