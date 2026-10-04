import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 来自 read_file 实际返回区间的引用。偏移为 UTF-16，右端不包含。
/// 不持久化账号；查看时由消息所在账号和当前数据库共同校验归属。
class LocalSourceCitation {
  static const maxQuoteChars = 240;
  static const maxRangeChars = 12000;
  final String sourceId;
  final int cid;
  final int fileId;
  final int revision;
  final String fileName;
  final int startOffset;
  final int endOffset;
  final String rangeHash;
  final String quote;
  final bool available;
  final int? startLine;
  final int? endLine;
  final int? page;
  final String? section;

  const LocalSourceCitation({
    required this.sourceId,
    required this.cid,
    required this.fileId,
    required this.revision,
    required this.fileName,
    required this.startOffset,
    required this.endOffset,
    required this.rangeHash,
    required this.quote,
    this.available = true,
    this.startLine,
    this.endLine,
    this.page,
    this.section,
  });

  factory LocalSourceCitation.forRead({
    required int cid,
    required int fileId,
    required int revision,
    required String fileName,
    required int startOffset,
    required String content,
    int? startLine,
    int? endLine,
    int? page,
    String? section,
  }) {
    final hash = hashText(content);
    final end = startOffset + content.length;
    final identity = '$cid:$fileId:$revision:$startOffset:$end:$hash';
    return LocalSourceCitation(
      sourceId: 'lc_${hashText(identity).substring(0, 24)}',
      cid: cid,
      fileId: fileId,
      revision: revision,
      fileName: fileName,
      startOffset: startOffset,
      endOffset: end,
      rangeHash: hash,
      quote: quoteFor(content),
      startLine: startLine,
      endLine: endLine,
      page: page,
      section: section,
    );
  }

  String get identityKey =>
      '$cid:$fileId:$revision:$startOffset:$endOffset:$rangeHash';
  String get marker => '[原文:$sourceId]';
  String get locationLabel {
    final location = page != null
        ? '第 $page 页'
        : startLine != null
            ? endLine == startLine
                ? '第 $startLine 行'
                : '第 $startLine–$endLine 行'
            : '字符 $startOffset–$endOffset';
    return '$fileName · v$revision · $location';
  }

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'cid': cid,
        'fileId': fileId,
        'revision': revision,
        'fileName': fileName,
        'startOffset': startOffset,
        'endOffset': endOffset,
        'rangeHash': rangeHash,
        'quote': quote,
        'available': available,
        if (startLine != null) 'startLine': startLine,
        if (endLine != null) 'endLine': endLine,
        if (page != null) 'page': page,
        if (section != null) 'section': section,
      };

  static LocalSourceCitation? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['sourceId'];
    final cid = raw['cid'];
    final fileId = raw['fileId'];
    final revision = raw['revision'];
    final name = raw['fileName'];
    final start = raw['startOffset'];
    final end = raw['endOffset'];
    final hash = raw['rangeHash'];
    final quote = raw['quote'];
    final available = raw['available'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
        cid is! int ||
        cid < 0 ||
        fileId is! int ||
        fileId <= 0 ||
        revision is! int ||
        revision < 1 ||
        name is! String ||
        name.isEmpty ||
        name.length > 240 ||
        start is! int ||
        start < 0 ||
        end is! int ||
        end <= start ||
        end - start > maxRangeChars ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        quote is! String ||
        quote.isEmpty ||
        quote.length > maxQuoteChars ||
        quote.length > end - start ||
        (available != null && available is! bool)) {
      return null;
    }
    final first = raw['startLine'];
    final last = raw['endLine'];
    final page = raw['page'];
    final section = raw['section'];
    if ((first != null && (first is! int || first < 1)) ||
        (last != null && (last is! int || last < 1)) ||
        (first is int && last is int && last < first) ||
        (page != null && (page is! int || page < 1)) ||
        (section != null && (section is! String || section.length > 1024))) {
      return null;
    }
    return LocalSourceCitation(
      sourceId: id,
      cid: cid,
      fileId: fileId,
      revision: revision,
      fileName: name,
      startOffset: start,
      endOffset: end,
      rangeHash: hash,
      quote: quote,
      available: available as bool? ?? true,
      startLine: first as int?,
      endLine: last as int?,
      page: page as int?,
      section: section as String?,
    );
  }

  /// 仅解析指定 read_file 工具的完整外层返回，不从模型正文/原文搜索 JSON。
  static LocalSourceCitation? fromToolResult({
    required String toolName,
    required Object? content,
    int? expectedCid,
  }) {
    if (toolName != 'read_file') return null;
    Object? raw = content;
    if (content is String) {
      try {
        raw = jsonDecode(content);
      } on FormatException {
        return null;
      }
    }
    if (raw is! Map ||
        raw['workspaceReadVersion'] != 1 ||
        raw['offsetUnit'] != 'utf16' ||
        raw['endExclusive'] != true) {
      return null;
    }
    final source = tryFromJson(raw['sourceCitation']);
    final body = raw['content'];
    if (source == null ||
        !source.available ||
        body is! String ||
        (expectedCid != null && source.cid != expectedCid) ||
        raw['fileId'] != source.fileId ||
        raw['revision'] != source.revision ||
        raw['name'] != source.fileName ||
        raw['startOffset'] != source.startOffset ||
        raw['endOffset'] != source.endOffset ||
        source.startLine != raw['startLine'] ||
        source.endLine != raw['endLine'] ||
        source.page != raw['page'] ||
        source.section != raw['section'] ||
        !source.matchesText(body)) {
      return null;
    }
    return source;
  }

  static LocalSourceCitation? tryParseReadResult(String raw,
          {int? expectedCid}) =>
      fromToolResult(
          toolName: 'read_file', content: raw, expectedCid: expectedCid);

  bool matchesText(String content) =>
      content.length == endOffset - startOffset &&
      hashText(content) == rangeHash &&
      quoteFor(content) == quote;

  /// 备份/游客合并保留 sourceId，使旧正文标记继续生效；缺映射显式失效。
  LocalSourceCitation remap(
          {required int? cid,
          required int? fileId,
          bool revisionAvailable = true}) =>
      LocalSourceCitation(
        sourceId: sourceId,
        cid: cid ?? this.cid,
        fileId: fileId ?? this.fileId,
        revision: revision,
        fileName: fileName,
        startOffset: startOffset,
        endOffset: endOffset,
        rangeHash: rangeHash,
        quote: quote,
        available:
            available && cid != null && fileId != null && revisionAvailable,
        startLine: startLine,
        endLine: endLine,
        page: page,
        section: section,
      );

  static String hashText(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  static String quoteFor(String text) {
    var end = text.length < maxQuoteChars ? text.length : maxQuoteChars;
    if (end > 0 &&
        end < text.length &&
        text.codeUnitAt(end - 1) >= 0xD800 &&
        text.codeUnitAt(end - 1) <= 0xDBFF &&
        text.codeUnitAt(end) >= 0xDC00 &&
        text.codeUnitAt(end) <= 0xDFFF) {
      end--;
    }
    return text.substring(0, end);
  }
}

/// 有界展示实际引用和少量上下文，避免长文全文占用页面内存。
class ResolvedLocalSource {
  final LocalSourceCitation source;
  final int currentRevision;
  final String before;
  final String content;
  final String after;
  const ResolvedLocalSource(
      {required this.source,
      required this.currentRevision,
      required this.before,
      required this.content,
      required this.after});
  bool get isHistorical => source.revision != currentRevision;
}
