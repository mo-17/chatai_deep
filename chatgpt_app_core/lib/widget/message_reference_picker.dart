import 'dart:async';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';
import 'package:flutter/material.dart';

class HistoryReferencePicker extends StatefulWidget {
  final MessageReferenceDao dao;
  final bool Function() isCurrent;
  const HistoryReferencePicker(
      {super.key, required this.dao, required this.isCurrent});
  @override
  State<HistoryReferencePicker> createState() => _HistoryReferencePickerState();
}

class _HistoryReferencePickerState extends State<HistoryReferencePicker> {
  final _search = TextEditingController();
  Timer? _timer;
  Timer? _scopeTimer;
  List<MessageReferenceCandidate> _items = [];
  int _revision = 0;
  bool _busy = false;
  bool _more = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _scopeTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && !widget.isCurrent()) {
        _scopeTimer?.cancel();
        _revision++;
        setState(() {
          _items = [];
          _busy = false;
          _more = false;
          _error = '选择已过期，请关闭后重新打开';
        });
      }
    });
  }

  Future<void> _load({bool more = false}) async {
    if (!widget.isCurrent()) return;
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await widget.dao.search(
          query: _search.text,
          beforeId: more && _items.isNotEmpty ? _items.last.id : null);
      if (!mounted || revision != _revision || !widget.isCurrent()) return;
      setState(() {
        _items = more ? [..._items, ...items] : items;
        _more = items.length == 30;
      });
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = '历史消息读取失败，请重试');
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _select(MessageReferenceCandidate candidate) async {
    if (_busy || !widget.isCurrent()) return;
    setState(() => _busy = true);
    final revision = _revision;
    try {
      final snapshot = await widget.dao.snapshot(candidate.id);
      if (!mounted || revision != _revision || !widget.isCurrent()) return;
      if (snapshot == null) {
        setState(() => _error = '消息已删除或正文超出快照保存上限，请重新选择');
      } else {
        Navigator.pop(context, ComposerReference.history(snapshot));
      }
    } catch (_) {
      if (mounted && revision == _revision && widget.isCurrent()) {
        setState(() => _error = '历史消息读取失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scopeTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Column(children: [
            ListTile(
                title: const Text('引用历史消息'),
                subtitle: const Text('保存所选正文快照，不包含思考、工具和附件'),
                trailing: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close))),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                    key: const ValueKey('history_reference_search'),
                    controller: _search,
                    maxLength: 256,
                    decoration: const InputDecoration(hintText: '搜索消息正文或对话标题'),
                    onChanged: (_) {
                      _revision++;
                      _timer?.cancel();
                      _timer = Timer(const Duration(milliseconds: 250), _load);
                    })),
            if (_error != null) Text(_error!),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
                child: ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (_, i) => ListTile(
                        key: ValueKey('history_reference_${_items[i].id}'),
                        title: Text(_items[i].title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            _items[i].selectable
                                ? _items[i].preview
                                : '正文过长，无法完整保存引用快照',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis),
                        enabled: !_busy && _items[i].selectable,
                        onTap: () => _select(_items[i])))),
            if (_items.isEmpty && !_busy)
              const Padding(
                  padding: EdgeInsets.all(16), child: Text('没有匹配的历史消息')),
            if (_more)
              TextButton(
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('加载更多')),
          ])));
}

Future<void> showReferencePreview(
        BuildContext context, ComposerReference reference,
        {bool Function()? isCurrent}) =>
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _ReferencePreview(reference, isCurrent, null));

Future<void> showDraftAttachmentPreview(
    BuildContext context, DraftAttachmentPreview preview,
    {bool Function()? isCurrent}) async {
  final photo = preview.reference.kind == ComposerReferenceKind.photo;
  final bytes = photo ? await preview.readBytes() : null;
  final text = photo ? null : await preview.readText();
  if (!context.mounted || isCurrent?.call() == false) return;
  await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ReferencePreview(preview.reference, isCurrent, preview,
          preparedText: text, preparedImage: bytes));
}

class _ReferencePreview extends StatefulWidget {
  final ComposerReference reference;
  final bool Function()? isCurrent;
  final DraftAttachmentPreview? attachmentPreview;
  final String? preparedText;
  final Uint8List? preparedImage;
  const _ReferencePreview(
      this.reference, this.isCurrent, this.attachmentPreview,
      {this.preparedText, this.preparedImage});
  @override
  State<_ReferencePreview> createState() => _ReferencePreviewState();
}

class _ReferencePreviewState extends State<_ReferencePreview> {
  Timer? _scopeTimer;
  late final Future<String> _text = _loadText();
  late final Future<Uint8List>? _image =
      _validBinding && widget.reference.kind == ComposerReferenceKind.photo
          ? Future.value(widget.preparedImage!)
          : null;
  bool get _validBinding =>
      widget.attachmentPreview != null &&
      widget.attachmentPreview!.reference.id == widget.reference.id &&
      widget.attachmentPreview!.reference.kind == widget.reference.kind &&
      widget.attachmentPreview!.reference.attachmentPath ==
          widget.reference.attachmentPath &&
      widget.attachmentPreview!.reference.snapshotDigest ==
          widget.reference.snapshotDigest;
  @override
  void initState() {
    super.initState();
    if (widget.isCurrent != null) {
      _scopeTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted && widget.isCurrent!() == false) {
          _scopeTimer?.cancel();
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _scopeTimer?.cancel();
    super.dispose();
  }

  Future<String> _loadText() async {
    final reference = widget.reference;
    if (widget.isCurrent?.call() == false) return '账号已切换，请关闭预览';
    if (!reference.available) return '此引用已失效，请移除后重新选择。';
    if (reference.kind == ComposerReferenceKind.historyMessage &&
        reference.historySnapshot != null &&
        reference.attachmentPath == null) {
      return reference.historySnapshot!.content;
    }
    if (!_validBinding) return '附件尚未托管冻结，无法预览；请重新选择。';
    if (reference.kind == ComposerReferenceKind.photo) return '';
    try {
      return widget.preparedText!;
    } catch (_) {
      return '暂时无法预览正文，发送前会检查附件是否可用。';
    }
  }

  @override
  Widget build(BuildContext context) => widget.isCurrent?.call() == false
      ? SizedBox(
          height: 160,
          child: ListTile(
              title: const Text('账号已切换，请关闭预览'),
              trailing: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close))))
      : SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Column(children: [
            ListTile(
                title: Text(widget.reference.label),
                subtitle: Text(widget.reference.historySnapshot == null
                    ? '待发送附件预览'
                    : '选择时的正文快照；来源变化不会修改快照'),
                trailing: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close))),
            Expanded(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child:
                        widget.reference.kind == ComposerReferenceKind.photo &&
                                widget.reference.available &&
                                _validBinding
                            ? FutureBuilder<Uint8List>(
                                future: _image,
                                builder: (_, result) => result.hasError
                                    ? const Text('图片已失效，请重新选择')
                                    : result.hasData
                                        ? Image.memory(result.data!)
                                        : const CircularProgressIndicator())
                            : FutureBuilder<String>(
                                future: _text,
                                builder: (_, result) => result.hasData
                                    ? SelectableText(result.data!)
                                    : const Center(
                                        child: CircularProgressIndicator())))),
          ]));
}
