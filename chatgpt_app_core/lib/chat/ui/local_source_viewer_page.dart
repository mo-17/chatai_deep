import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter/material.dart';

typedef LocalSourceLoader = Future<ResolvedLocalSource> Function(
    LocalSourceCitation);

/// 打开消息所在账号的保存版本；两次账号检查覆盖异步加载期间的登出/切换。
class LocalSourceViewerPage extends StatefulWidget {
  final LocalSourceCitation source;
  final String expectedAccountHash;
  final LocalSourceLoader? loadSource;
  final String Function()? currentAccountHash;
  const LocalSourceViewerPage(
      {super.key,
      required this.source,
      required this.expectedAccountHash,
      this.loadSource,
      this.currentAccountHash});

  @override
  State<LocalSourceViewerPage> createState() => _LocalSourceViewerPageState();
}

class _LocalSourceViewerPageState extends State<LocalSourceViewerPage> {
  late Future<ResolvedLocalSource> _result;

  String get _currentAccount =>
      (widget.currentAccountHash ?? HiDBManager.getAccountHash)();

  void _checkAccount() {
    if (_currentAccount != widget.expectedAccountHash) {
      throw const FormatException('原文不可用：账号已切换，请回到原账号查看');
    }
  }

  Future<ResolvedLocalSource> _load() async {
    _checkAccount();
    if (!widget.source.available) {
      throw const FormatException('原文不可用：备份未包含此文件或对应版本');
    }
    final ResolvedLocalSource result;
    if (widget.loadSource != null) {
      result = await widget.loadSource!(widget.source);
    } else {
      final manager =
          await HiDBManager.instance(dbName: widget.expectedAccountHash);
      _checkAccount();
      final workspace =
          await AgentWorkspaceService.create(manager, cid: widget.source.cid);
      result = await workspace.resolveCitation(widget.source);
    }
    _checkAccount();
    return result;
  }

  @override
  void initState() {
    super.initState();
    _result = _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.source.fileName)),
      body: FutureBuilder<ResolvedLocalSource>(
        future: _result,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final sameAccount = _currentAccount == widget.expectedAccountHash;
          if (snapshot.hasError || !sameAccount) {
            final error = snapshot.error;
            final message = !sameAccount
                ? '原文不可用：账号已切换，请回到原账号查看'
                : error is FormatException
                    ? error.message
                    : '原文不可用：文件或保存版本不存在';
            return ListView(padding: const EdgeInsets.all(20), children: [
              const Icon(Icons.link_off, size: 36),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (sameAccount) ...[
                const SizedBox(height: 20),
                Text('保存的引用摘录', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SelectableText(widget.source.quote),
              ],
            ]);
          }
          final data = snapshot.requireData;
          final scheme = Theme.of(context).colorScheme;
          // 前文最多三行，让引用开头在首次打开时即可看到。
          final before = data.before
              .split('\n')
              .reversed
              .take(3)
              .toList()
              .reversed
              .join('\n');
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(data.source.locationLabel,
                style: Theme.of(context).textTheme.titleSmall),
            if (data.source.section != null) Text(data.source.section!),
            if (data.isHistorical)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      '正在查看引用时的 v${data.source.revision}，当前文件为 v${data.currentRevision}。')),
            const SizedBox(height: 12),
            Text('高亮为实际读取并校验的原文范围',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: 12),
            SelectableText.rich(
              key: const ValueKey('local-source-highlight'),
              TextSpan(
                  style: TextStyle(
                      fontSize: 16, height: 1.6, color: scheme.onSurface),
                  children: [
                    TextSpan(
                        text: before,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    TextSpan(
                        text: data.content,
                        style: TextStyle(
                            backgroundColor: scheme.secondaryContainer)),
                    TextSpan(
                        text: data.after,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
            ),
          ]);
        },
      ),
    );
  }
}

/// 在首次挂载时捕获账号，旧气泡不能在切换账号后打开碰巧同 id 的新文件。
class LocalSourceLink extends StatefulWidget {
  final LocalSourceCitation source;
  final String? sourceAccountHash;
  final bool inline;
  final TextStyle? style;
  final LocalSourceLoader? loadSource;
  final String Function()? currentAccountHash;
  const LocalSourceLink(
      {super.key,
      required this.source,
      this.sourceAccountHash,
      this.inline = false,
      this.style,
      this.loadSource,
      this.currentAccountHash});

  @override
  State<LocalSourceLink> createState() => _LocalSourceLinkState();
}

class _LocalSourceLinkState extends State<LocalSourceLink> {
  late final String _account;

  @override
  void initState() {
    super.initState();
    _account = widget.sourceAccountHash ??
        (widget.currentAccountHash ?? HiDBManager.getAccountHash)();
  }

  void _open() {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => LocalSourceViewerPage(
            source: widget.source,
            expectedAccountHash: _account,
            loadSource: widget.loadSource,
            currentAccountHash: widget.currentAccountHash)));
  }

  @override
  Widget build(BuildContext context) {
    final label = '打开原文 ${widget.source.locationLabel}';
    final text = widget.inline ? '[原文]' : widget.source.locationLabel;
    final child = widget.inline
        ? SizedBox(
            width: 54,
            height: 44,
            child: Center(child: Text(text, style: widget.style)))
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(text, style: widget.style),
              Text(
                  widget.source.available
                      ? widget.source.quote
                      : '原文不可用 · ${widget.source.quote}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ]));
    return Semantics(
        link: true,
        label: label,
        onTap: _open,
        excludeSemantics: true,
        child: Tooltip(
            message: widget.source.locationLabel,
            child: InkWell(
                onTap: _open,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: child))));
  }
}
