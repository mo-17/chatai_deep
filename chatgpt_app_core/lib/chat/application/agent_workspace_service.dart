import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';

import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';
import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'attachment_ocr.dart';
import 'ocr_service.dart';

/// 只导入用户选择的文件，工具随后仅凭本对话的文件 id 访问 SQLite 副本。
class AgentWorkspaceService {
  static const defaultMaxBytes = 10 * 1024 * 1024;
  static const absoluteMaxBytes = 32 * 1024 * 1024;
  static const maxPdfPages = 1000;
  static const maxPdfTextChars = 16 * 1024 * 1024;
  static const maxReadChars = 12000;
  static const maxManifestFiles = 50;
  static const maxManifestChars = 24000;
  static const manifestSectionLimit = 10;
  final AgentWorkspaceDao dao;
  String? _cachedKey;
  Map<String, dynamic>? _cachedReadData;

  AgentWorkspaceService._(this.dao);

  static Future<AgentWorkspaceService> create(HiDBManager manager,
          {required int cid}) async =>
      AgentWorkspaceService._(
          await AgentWorkspaceDao.create(manager, cid: cid));

  Future<List<AgentWorkspaceFile>> listFiles() => dao.listFiles();
  Future<AgentWorkspaceFile?> getFile(int id) => dao.getFile(id);
  Future<AgentWorkspaceRevision> getRevision(int fileId, {int? revision}) =>
      dao.getRevision(fileId, revision: revision);
  Future<List<AgentWorkspaceRevision>> revisions(int fileId) =>
      dao.revisions(fileId);

  Future<AgentWorkspaceFile> importPath(String path,
      {required int maxBytes,
      void Function(List<String>)? onWarnings,
      void Function(String fullText, int byteLength,
              Map<String, dynamic> manifestPreview)?
          validateParsed}) async {
    _validateByteLimit(maxBytes);
    if (await appFileType(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('请选择普通文件，不能导入目录或符号链接');
    }
    final name = path.replaceAll('\\', '/').split('/').last;
    _validateName(name, output: false);
    final bytes = await readFileBytesBounded(appFile(path),
        maxBytes: maxBytes, label: '工作区文件');
    final parsed = await compute(_parseBytes, {'bytes': bytes, 'name': name});
    _validateParsedInput(name, parsed, bytes.length, validateParsed);
    onWarnings?.call((parsed['warnings'] as List? ?? const []).cast<String>());
    return _saveInput(name, parsed, path, bytes.length);
  }

  /// Files Provider 只提供字节时也走相同解析器，不把 Office 二进制当 UTF-8。
  Future<AgentWorkspaceFile> importBytes(Uint8List bytes,
      {required String name,
      required int maxBytes,
      String? sourceKey,
      AttachmentOcrHandler? ocr,
      bool Function()? canCommit,
      void Function(List<String>)? onWarnings,
      void Function(String fullText, int byteLength,
              Map<String, dynamic> manifestPreview)?
          validateParsed}) async {
    _validateName(name, output: false);
    _validateByteLimit(maxBytes);
    if (bytes.length > maxBytes) {
      throw const FormatException('工作区文件超过导入字节上限');
    }
    bytes = Uint8List.fromList(bytes).asUnmodifiableView();
    void check() {
      if (canCommit?.call() == false) {
        throw const AttachmentOcrException('任务已停止，工作区未修改');
      }
    }

    check();
    final image =
        OcrService.imageExtensions.contains(name.split('.').last.toLowerCase());
    var parsed = image
        ? _parseText({'content': ''})
        : await compute(_parseBytes, {'bytes': bytes, 'name': name});
    check();
    if (image && ocr == null) {
      throw const AttachmentOcrException('图片需要 OCR，请先选择服务器识别');
    }
    final pages = (parsed['pageTexts'] as List).cast<String>();
    final missing = [
      for (var i = 0; i < pages.length; i++)
        if (OcrService.pdfNeedsOcr(pages[i])) i + 1,
    ];
    if (ocr != null && (image || missing.isNotEmpty)) {
      if (pages.length > 20) {
        parsed['warnings'] = ['扫描页未识别：服务器 OCR 最多 20 页，请拆分后导入'];
      } else {
        final result = await ocr(AttachmentOcrRequest(
            filename: name,
            bytes: bytes,
            pdf: !image,
            totalPages: image ? 1 : pages.length,
            pageNumbers: missing));
        check();
        final total = image ? 1 : pages.length;
        if (result.totalPages != total || result.pages.length != total) {
          throw const AttachmentOcrException('OCR 页数与原件不一致，工作区未修改');
        }
        final merged = image ? [...result.pages] : [...pages];
        for (final page in image ? [1] : missing) {
          if (result.pages[page - 1].trim().isNotEmpty) {
            merged[page - 1] = result.pages[page - 1];
          }
        }
        if (merged.every((p) => p.trim().isEmpty)) {
          throw const AttachmentOcrException('未识别到文字，工作区未修改');
        }
        parsed =
            await compute(_parseText, {'content': '', 'pageTexts': merged});
        if (merged.any(OcrService.pdfNeedsOcr)) {
          parsed['warnings'] = ['部分页仍缺少文字，请结合原件核对'];
        }
      }
    }
    check();
    _validateParsedInput(name, parsed, bytes.length, validateParsed);
    onWarnings?.call((parsed['warnings'] as List? ?? const []).cast<String>());
    return _saveInput(
        name, parsed, sourceKey ?? 'inline-bytes:$name', bytes.length,
        canCommit: canCommit);
  }

  Future<AgentWorkspaceFile> importText({
    required String name,
    required String content,
    String? sourceKey,
    List<String>? pageTexts,
    int maxBytes = defaultMaxBytes,
  }) async {
    _validateName(name, output: false);
    _validateByteLimit(maxBytes);
    final parsed = await compute(_parseText,
        {'content': content, 'pageTexts': pageTexts, 'maxBytes': maxBytes});
    return _saveInput(name, parsed, sourceKey ?? 'inline:$name',
        parsed['rawSizeBytes'] as int);
  }

  Future<AgentWorkspaceFile> _saveInput(
          String name, Map<String, dynamic> parsed, String sourceKey, int bytes,
          {bool Function()? canCommit}) =>
      dao.saveInput(
        name: name,
        sourceKey: sourceKey,
        contentHash: parsed['hash'] as String,
        content: parsed['content'] as String,
        pageTexts: (parsed['pageTexts'] as List).cast<String>(),
        sections: (parsed['sections'] as List).cast<Map<String, dynamic>>(),
        sizeBytes: bytes,
        canCommit: canCommit,
      );

  /// 验证发生在 DAO 写入前；整数位数保守预留，写入后按真实清单释放差额。
  void _validateParsedInput(String name, Map<String, dynamic> parsed, int bytes,
      void Function(String, int, Map<String, dynamic>)? validateParsed) {
    if (validateParsed == null) return;
    final content = parsed['content'] as String;
    final sections = (parsed['sections'] as List).cast<Map<String, dynamic>>();
    final preview = AgentWorkspaceFile(
        id: int.parse('9223372036854775807'),
        cid: dao.cid,
        name: name,
        kind: 'input',
        revision: 1,
        characterCount: content.length,
        lineCount: content.isEmpty ? 0 : '\n'.allMatches(content).length + 1,
        pageCount: (parsed['pageTexts'] as List).length,
        sizeBytes: bytes,
        updatedAt: int.parse('9223372036854775807'),
        createdAt: int.parse('9223372036854775807'),
        sectionCount: sections.length,
        sections: sections.take(40).map((section) {
          final title = section['title'] as String;
          var end = title.length.clamp(0, 80);
          if (end < title.length &&
              end > 0 &&
              title.codeUnitAt(end - 1) >= 0xd800 &&
              title.codeUnitAt(end - 1) <= 0xdbff &&
              title.codeUnitAt(end) >= 0xdc00 &&
              title.codeUnitAt(end) <= 0xdfff) {
            end--;
          }
          return {
            ...section,
            'title': title.substring(0, end),
            if (end < title.length) 'titleTruncated': true,
          };
        }).toList());
    validateParsed(content, bytes, preview.toJson());
  }

  Future<AgentWorkspaceFile> writeFile({
    int? fileId,
    required String name,
    required String content,
    String note = '',
    bool Function()? canCommit,
  }) async {
    _validateName(name, output: true);
    final parsed = await compute(
        _parseText, {'content': content, 'maxBytes': defaultMaxBytes});
    return dao.saveOutput(
        fileId: fileId,
        name: name,
        content: parsed['content'] as String,
        contentHash: parsed['hash'] as String,
        sizeBytes: parsed['rawSizeBytes'] as int,
        note: note,
        canCommit: canCommit,
        sections: (parsed['sections'] as List).cast<Map<String, dynamic>>());
  }

  Future<Map<String, dynamic>> readFile(
    int id, {
    int offset = 0,
    int maxChars = maxReadChars,
    int? startLine,
    int? endLine,
    int? page,
    String? section,
    bool tail = false,
  }) async {
    if (maxChars < 1 || maxChars > maxReadChars) {
      throw const FormatException('每次读取字数须在 1 到 12000 之间');
    }
    final file = await _requireFile(id);
    final prepared = await _readData(file);
    // 初次索引在 isolate 创建；后续分段只做二分定位和小段 substring。
    final result = _readText({
      ...prepared,
      'offset': offset,
      'maxChars': maxChars,
      'startLine': startLine,
      'endLine': endLine,
      'page': page,
      'section': section,
      'tail': tail,
    });
    final body = result['content'] as String;
    if (body.isNotEmpty) {
      final source = LocalSourceCitation.forRead(
        cid: dao.cid,
        fileId: file.id,
        revision: file.revision,
        fileName: file.name,
        startOffset: result['startOffset'] as int,
        content: body,
        startLine: result['startLine'] as int?,
        endLine: result['endLine'] as int?,
        page: result['page'] as int?,
        section: result['section'] as String?,
      );
      result['workspaceReadVersion'] = 1;
      result['sourceCitation'] = source.toJson();
      result['sourceMarker'] = source.marker;
    }
    return result;
  }

  /// 引用必须读取绑定版本；不能因文件更新而自动跳到最新正文。
  Future<ResolvedLocalSource> resolveCitation(
      LocalSourceCitation source) async {
    if (!source.available ||
        source.cid != dao.cid ||
        LocalSourceCitation.tryFromJson(source.toJson()) == null) {
      throw const FormatException('原文不可用：引用归属或范围无效');
    }
    final file = await getFile(source.fileId);
    if (file == null) throw const FormatException('原文不可用：文件已删除或未导入');
    final AgentWorkspaceRevision version;
    try {
      version = await getRevision(source.fileId, revision: source.revision);
    } on FormatException {
      throw const FormatException('原文不可用：引用时的保存版本不存在');
    }
    final body = version.content;
    if (source.endOffset > body.length ||
        _splitsPair(body, source.startOffset) ||
        _splitsPair(body, source.endOffset)) {
      throw const FormatException('原文不可用：引用范围与保存版本不一致');
    }
    final content = body.substring(source.startOffset, source.endOffset);
    if (!source.matchesText(content)) {
      throw const FormatException('原文不可用：保存版本与引用校验不一致');
    }
    var begin = (source.startOffset - 200).clamp(0, body.length);
    var end = (source.endOffset + 600).clamp(0, body.length);
    if (_splitsPair(body, begin)) begin--;
    if (_splitsPair(body, end)) end++;
    return ResolvedLocalSource(
        source: source,
        currentRevision: file.revision,
        before: body.substring(begin, source.startOffset),
        content: content,
        after: body.substring(source.endOffset, end));
  }

  Future<Map<String, dynamic>> searchFile(int id, String query,
      {int maxResults = 20}) async {
    if (query.trim().isEmpty || query.length > 1024) {
      throw const FormatException('搜索词须为 1 到 1024 字符');
    }
    if (maxResults < 1 || maxResults > 100) {
      throw const FormatException('搜索结果上限须在 1 到 100 之间');
    }
    final file = await _requireFile(id);
    final prepared = await _readData(file);
    return compute(
        _searchText, {...prepared, 'query': query, 'maxResults': maxResults});
  }

  Future<AgentWorkspaceFile> _requireFile(int id) async {
    final file = await getFile(id);
    if (file == null) throw const FormatException('本对话的工作区文件不存在');
    return file;
  }

  Future<Map<String, dynamic>> _readData(AgentWorkspaceFile file) async {
    final key = '${file.id}:${file.revision}';
    if (_cachedKey == key && _cachedReadData != null) return _cachedReadData!;
    // 每个 service 只缓存当前文件，避免多份长正文在内存常驻。
    final revision = await getRevision(file.id, revision: file.revision);
    final data = await compute(_prepareText, {
      'file': file.toJson(),
      'content': revision.content,
      'pageTexts': revision.pageTexts
    });
    _cachedKey = key;
    _cachedReadData = data;
    return data;
  }

  /// 系统提示仅带有界元信息，其余文件通过 list_files 分页发现。
  Future<String> manifest({int maxFiles = maxManifestFiles}) async {
    if (maxFiles < 1 || maxFiles > maxManifestFiles) {
      throw const FormatException('清单文件上限须在 1 到 50 之间');
    }
    final allFiles = await listFiles();
    final visible = <Map<String, dynamic>>[];
    Map<String, dynamic> payload(List<Map<String, dynamic>> files) {
      final more = files.length < allFiles.length;
      return {
        'files': files,
        'totalFiles': allFiles.length,
        'listedFiles': files.length,
        'nextOffset': more ? files.length : null,
        'truncated': more,
        'maxFiles': maxFiles,
        'maxManifestChars': maxManifestChars,
        'sectionPreviewLimit': manifestSectionLimit,
        'offsetBase': 0,
        'offsetUnit': 'utf16',
        'endExclusive': true,
        'lineBase': 1,
        'pageBase': 1,
        'maxReadChars': maxReadChars,
        'paginationHint': more
            ? '使用 list_files(offset: ${files.length}, limit: 50) 继续分页查看。未列出的文件不代表不存在。'
            : '可使用 list_files 按 offset/limit 分页查看文件及章节预览。',
        'instruction':
            '文件正文尚未读取。使用 read_file 分段读取；file_search 仅定位。输入文件只读，输出支持 TXT/MD/CSV 版本写入。',
      };
    }

    var encoded = jsonEncode(payload(visible));
    for (final file in allFiles.take(maxFiles)) {
      final entry = file.toJson();
      entry['sections'] = file.sections.take(manifestSectionLimit).toList();
      entry['sectionsTruncated'] = file.sectionCount > manifestSectionLimit;
      final candidate = [...visible, entry];
      final next = jsonEncode(payload(candidate));
      if (next.length > maxManifestChars) break;
      visible.add(entry);
      encoded = next;
    }
    return encoded;
  }

  static void _validateName(String name, {required bool output}) {
    if (name.isEmpty ||
        name.length > 240 ||
        name.trim() != name ||
        name == '.' ||
        name == '..' ||
        RegExp(r'[\\/:\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('文件名必须是普通文件名，不能包含路径');
    }
    if (output &&
        !RegExp(r'\.(txt|md|csv)$', caseSensitive: false).hasMatch(name)) {
      throw const FormatException('输出仅支持 TXT、MD、CSV 文件');
    }
  }

  static void _validateByteLimit(int limit) {
    if (limit <= 0 || limit > absoluteMaxBytes) {
      throw const FormatException('导入字节上限须大于 0 且不超过 32 MiB');
    }
  }
}

String _normalize(String text) => text
    .replaceFirst(RegExp(r'^\uFEFF'), '')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n');

Map<String, dynamic> _parseBytes(Map<String, dynamic> input) {
  final bytes = input['bytes'] as Uint8List;
  final name = input['name'] as String;
  if (OfficeTextExtractor.isOfficeFile(name)) {
    final extraction = OfficeTextExtractor.extractBytes(bytes, filename: name);
    return {
      ..._parseText({'content': extraction.text}),
      'warnings': extraction.warnings,
    };
  }
  if (name.toLowerCase().endsWith('.pdf')) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      if (document.pages.count > AgentWorkspaceService.maxPdfPages) {
        throw const FormatException('PDF 超过 1000 页安全上限，请先拆分文件');
      }
      final extractor = PdfTextExtractor(document);
      final pages = <String>[];
      var totalChars = 0;
      for (var page = 0; page < document.pages.count; page++) {
        final text = _normalize(
            extractor.extractText(startPageIndex: page, endPageIndex: page));
        totalChars += text.length + (page == 0 ? 0 : 2);
        if (totalChars > AgentWorkspaceService.maxPdfTextChars) {
          throw const FormatException('PDF 提取文字超过 16 Mi 字符安全上限，请先拆分文件');
        }
        pages.add(text);
      }
      return _parseText({'content': '', 'pageTexts': pages});
    } finally {
      document.dispose();
    }
  }
  if (bytes.contains(0)) throw const FormatException('不支持二进制文件；请导入文本或 PDF');
  return _parseText({'content': utf8.decode(bytes, allowMalformed: false)});
}

Map<String, dynamic> _parseText(Map<String, dynamic> input) {
  final rawPages = input['pageTexts'];
  if (rawPages is List && rawPages.length > AgentWorkspaceService.maxPdfPages) {
    throw const FormatException('分页文件超过 1000 页安全上限，请先拆分文件');
  }
  final rawContent = rawPages is List
      ? rawPages.cast<String>().join('\n\n')
      : input['content'] as String;
  final maxBytes = input['maxBytes'] as int?;
  if (maxBytes != null && rawContent.length > maxBytes) {
    throw FormatException('文件超过 $maxBytes 字节上限');
  }
  final rawSize = utf8.encode(rawContent).length;
  if (maxBytes != null && rawSize > maxBytes) {
    throw FormatException('文件超过 $maxBytes 字节上限');
  }
  final pages = rawPages is List
      ? rawPages.cast<String>().map(_normalize).toList()
      : <String>[];
  // 页文本是分页文件的唯一正文来源，避免页范围与全文不一致。
  final content = rawPages is List
      ? pages.join('\n\n')
      : _normalize(input['content'] as String);
  if (rawPages is List &&
      content.length > AgentWorkspaceService.maxPdfTextChars) {
    throw const FormatException('分页文字超过 16 Mi 字符安全上限，请先拆分文件');
  }
  return {
    'content': content,
    'pageTexts': pages,
    'hash': sha256
        .convert(utf8
            .encode('${pages.map((p) => p.length).join(',')}\u0000$content'))
        .toString(),
    'rawSizeBytes': rawSize,
    'sections': _headings(content)
  };
}

List<Map<String, dynamic>> _headings(String content) {
  final result = <Map<String, dynamic>>[];
  final pattern = RegExp(
      r'^(?:[ \t]{0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*|[ \t\u3000]*(第[^\n]{1,60}[章节卷回部篇][^\n]{0,100}))[ \t\u3000]*$',
      multiLine: true);
  for (final match in pattern.allMatches(content)) {
    result.add({
      'title': (match.group(2) ?? match.group(3)!).trim(),
      'offset': match.start,
      'level': match.group(1)?.length ?? 1
    });
  }
  return result;
}

List<int> _lineStarts(String content) {
  final starts = <int>[0];
  for (final match in '\n'.allMatches(content)) {
    starts.add(match.end);
  }
  return starts;
}

int _lineAt(List<int> starts, int offset) {
  var low = 0;
  var high = starts.length;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (starts[mid] <= offset) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

List<List<int>> _pageRanges(List<String> pages) {
  var cursor = 0;
  return List.generate(pages.length, (index) {
    final start = cursor;
    cursor += pages[index].length;
    // 分隔符归前一页，顺序逐页读取不会留下未覆盖的字符间隙。
    if (index < pages.length - 1) cursor += 2;
    return [start, cursor];
  });
}

Map<String, dynamic> _prepareText(Map<String, dynamic> input) => {
      ...input,
      'lineStarts': _lineStarts(input['content'] as String),
      'pageRanges': _pageRanges((input['pageTexts'] as List).cast<String>()),
      'headings': _headings(input['content'] as String),
      'emptyPages': [
        for (var i = 0; i < (input['pageTexts'] as List).length; i++)
          if ((input['pageTexts'][i] as String).trim().isEmpty) i + 1
      ],
    };

bool _splitsPair(String text, int offset) =>
    offset > 0 &&
    offset < text.length &&
    text.codeUnitAt(offset - 1) >= 0xD800 &&
    text.codeUnitAt(offset - 1) <= 0xDBFF &&
    text.codeUnitAt(offset) >= 0xDC00 &&
    text.codeUnitAt(offset) <= 0xDFFF;

int? _pageAt(List<List<int>> ranges, int offset) {
  for (var i = 0; i < ranges.length; i++) {
    if (offset >= ranges[i][0] && offset < ranges[i][1]) return i + 1;
  }
  return ranges.isNotEmpty && offset == ranges.last[1] ? ranges.length : null;
}

Map<String, dynamic> _readText(Map<String, dynamic> input) {
  final file = input['file'] as Map<String, dynamic>;
  final content = input['content'] as String;
  final pages = (input['pageTexts'] as List).cast<String>();
  final starts = (input['lineStarts'] as List).cast<int>();
  final ranges = (input['pageRanges'] as List).cast<List<int>>();
  final offset = input['offset'] as int;
  final maxChars = input['maxChars'] as int;
  final startLine = input['startLine'] as int?;
  final endLine = input['endLine'] as int?;
  final page = input['page'] as int?;
  final section = input['section'] as String?;
  final tail = input['tail'] as bool;
  final selectors = [
    startLine != null || endLine != null,
    page != null,
    section != null,
    tail
  ];
  if (selectors.where((v) => v).length > 1) {
    throw const FormatException('一次只能选择行、页、章节或末尾一种范围');
  }
  if (offset < 0 || offset > content.length) {
    throw const FormatException('字符偏移超出文件范围');
  }
  var scopeStart = 0;
  var scopeEnd = content.length;
  if (startLine != null || endLine != null) {
    final first = startLine ?? 1;
    final last = endLine ?? starts.length;
    if (first < 1 || last < first || last > starts.length) {
      throw const FormatException('行范围无效（行号从 1 开始）');
    }
    scopeStart = starts[first - 1];
    scopeEnd = last < starts.length ? starts[last] : content.length;
  } else if (page != null) {
    if (page < 1 || page > pages.length) {
      throw const FormatException('页码无效，或文件没有分页信息');
    }
    scopeStart = ranges[page - 1][0];
    scopeEnd = ranges[page - 1][1];
  } else if (section != null) {
    final headings = (input['headings'] as List).cast<Map<String, dynamic>>();
    final found = headings.where((h) => h['title'] == section.trim()).toList();
    if (found.length != 1) {
      throw const FormatException('章节标题不存在或不唯一，请使用精确标题或字符偏移');
    }
    final heading = found.single;
    scopeStart = heading['offset'] as int;
    final after = headings.where((h) =>
        (h['offset'] as int) > scopeStart &&
        (h['level'] as int) <= (heading['level'] as int));
    if (after.isNotEmpty) scopeEnd = after.first['offset'] as int;
  } else if (tail) {
    if (offset != 0) throw const FormatException('末尾读取不接受 offset');
    scopeStart = (content.length - maxChars).clamp(0, content.length);
    if (_splitsPair(content, scopeStart)) scopeStart++;
  }
  final selected = selectors.any((v) => v);
  final begin = selected && offset == 0 ? scopeStart : offset;
  if (begin < scopeStart || begin > scopeEnd) {
    throw const FormatException('字符偏移不在所选范围内');
  }
  if (_splitsPair(content, begin)) {
    throw const FormatException('偏移位于 Unicode 字符中间，请使用 nextOffset');
  }
  var end = (begin + maxChars).clamp(begin, scopeEnd);
  if (_splitsPair(content, end)) end--;
  if (end == begin && begin < scopeEnd) {
    throw const FormatException('maxChars 太小，无法读取一个完整 Unicode 字符');
  }
  final emptyPages = (input['emptyPages'] as List).cast<int>();
  return {
    'fileId': file['id'],
    'name': file['name'],
    'kind': file['kind'],
    'revision': file['revision'],
    'content': content.substring(begin, end),
    'startOffset': begin,
    'endOffset': end,
    'totalChars': content.length,
    'nextOffset': end < scopeEnd ? end : null,
    'truncated': end < scopeEnd,
    'rangeStart': scopeStart,
    'rangeEnd': scopeEnd,
    'startLine': _lineAt(starts, begin),
    'endLine': _lineAt(starts, end > begin ? end - 1 : begin),
    'startPage': page ?? _pageAt(ranges, begin),
    'endPage': page ?? _pageAt(ranges, end > begin ? end - 1 : begin),
    'page': page,
    if (section != null) 'section': section.trim(),
    'offsetBase': 0,
    'offsetUnit': 'utf16',
    'lineBase': 1,
    'pageBase': 1,
    'endExclusive': true,
    'emptyPages': emptyPages,
    'needsOcr':
        page != null ? emptyPages.contains(page) : emptyPages.isNotEmpty,
    if (emptyPages.isNotEmpty)
      'warning': '空页没有可提取的文字，可能为扫描页，需要 OCR；空页不能视为已读取扫描图像内容。',
  };
}

Map<String, dynamic> _searchText(Map<String, dynamic> input) {
  final file = input['file'] as Map<String, dynamic>;
  final content = input['content'] as String;
  final starts = (input['lineStarts'] as List).cast<int>();
  final ranges = (input['pageRanges'] as List).cast<List<int>>();
  final matches = <Map<String, dynamic>>[];
  var count = 0;
  final pattern =
      RegExp(RegExp.escape(input['query'] as String), caseSensitive: false);
  for (final match in pattern.allMatches(content)) {
    count++;
    if (matches.length >= (input['maxResults'] as int)) continue;
    var begin = (match.start - 80).clamp(0, content.length);
    var end = (match.end + 80).clamp(0, content.length);
    if (_splitsPair(content, begin)) begin--;
    if (_splitsPair(content, end)) end++;
    matches.add({
      'offset': match.start,
      'startOffset': match.start,
      'endOffset': match.end,
      'line': _lineAt(starts, match.start),
      'page': _pageAt(ranges, match.start),
      'snippet': content.substring(begin, end),
      'snippetStartOffset': begin
    });
  }
  return {
    'fileId': file['id'],
    'revision': file['revision'],
    'query': input['query'],
    'matches': matches,
    'totalMatches': count,
    'truncated': count > matches.length,
    'offsetBase': 0,
    'offsetUnit': 'utf16',
    'endExclusive': true,
    'countsAsReading': false
  };
}
