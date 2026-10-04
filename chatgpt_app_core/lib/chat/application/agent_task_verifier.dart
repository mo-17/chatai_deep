import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/db/agent_verification_dao.dart';
import 'package:flutter/foundation.dart';

/// 用户设定的客观条件。工具不能改写或削弱这些条件。
class TaskAcceptanceCriteria {
  final List<String> expectedOutputNames;
  final String? format;
  final int? minChars;
  final int? maxChars;
  final List<String> requiredTerms;
  final bool requireFullRead;

  const TaskAcceptanceCriteria({
    this.expectedOutputNames = const [],
    this.format,
    this.minChars,
    this.maxChars,
    this.requiredTerms = const [],
    this.requireFullRead = true,
  });

  void validate() {
    if (expectedOutputNames.length > 20 ||
        requiredTerms.length > 30 ||
        (format != null &&
            !const ['txt', 'md', 'csv', 'json'].contains(format)) ||
        (minChars != null && minChars! < 0) ||
        (maxChars != null && maxChars! < 1) ||
        (minChars != null && maxChars != null && minChars! > maxChars!)) {
      throw const FormatException('验收条件无效');
    }
    if (expectedOutputNames.any((name) =>
            name.trim().isEmpty ||
            name.length > 200 ||
            name.contains('/') ||
            name.contains('\\') ||
            name == '.' ||
            name == '..') ||
        requiredTerms
            .any((term) => term.trim().isEmpty || term.length > 1000)) {
      throw const FormatException('验收文件名或必须包含的文字无效');
    }
  }

  Map<String, dynamic> toJson() => {
        'expectedOutputNames': expectedOutputNames,
        'format': format,
        'minChars': minChars,
        'maxChars': maxChars,
        'requiredTerms': requiredTerms,
        'requireFullRead': requireFullRead,
      };

  factory TaskAcceptanceCriteria.fromJson(Map<String, dynamic> value) {
    final criteria = TaskAcceptanceCriteria(
      expectedOutputNames:
          List<String>.from(value['expectedOutputNames'] as List? ?? const []),
      format: value['format'] as String?,
      minChars: value['minChars'] as int?,
      maxChars: value['maxChars'] as int?,
      requiredTerms:
          List<String>.from(value['requiredTerms'] as List? ?? const []),
      requireFullRead: value['requireFullRead'] as bool? ?? true,
    );
    criteria.validate();
    return criteria;
  }
}

class AgentVerificationCheck {
  final String label;
  final bool passed;
  final String detail;
  final int? fileId;
  final int? revision;
  const AgentVerificationCheck(
      {required this.label,
      required this.passed,
      required this.detail,
      this.fileId,
      this.revision});
  Map<String, dynamic> toJson() => {
        'label': label,
        'passed': passed,
        'detail': detail,
        'fileId': fileId,
        'revision': revision
      };
  factory AgentVerificationCheck.fromJson(Map<String, dynamic> value) =>
      AgentVerificationCheck(
          label: value['label'] as String,
          passed: value['passed'] == true,
          detail: value['detail'] as String,
          fileId: value['fileId'] as int?,
          revision: value['revision'] as int?);
}

class AgentTaskVerificationReport {
  final int cid;
  final int userCreatedAt;
  final int createdAt;
  final List<AgentVerificationCheck> checks;
  const AgentTaskVerificationReport(
      {required this.cid,
      required this.userCreatedAt,
      required this.createdAt,
      required this.checks});
  bool get hasChecks => checks.isNotEmpty;
  bool get isPassed => checks.every((check) => check.passed);
  bool get passed => isPassed;
  String get summary => !hasChecks
      ? '本轮没有文件验收项'
      : isPassed
          ? '客观检查通过：${checks.length} 项；不代表内容语义正确'
          : '客观检查未通过：${checks.where((check) => !check.passed).length} 项';
  Map<String, dynamic> toJson() => {
        'cid': cid,
        'userCreatedAt': userCreatedAt,
        'createdAt': createdAt,
        'hasChecks': hasChecks,
        'isPassed': isPassed,
        'summary': summary,
        'checks': checks.map((check) => check.toJson()).toList()
      };
  factory AgentTaskVerificationReport.fromJson(Map<String, dynamic> value) =>
      AgentTaskVerificationReport(
          cid: value['cid'] as int,
          userCreatedAt: value['userCreatedAt'] as int,
          createdAt: value['createdAt'] as int,
          checks: (value['checks'] as List)
              .map((check) => AgentVerificationCheck.fromJson(
                  Map<String, dynamic>.from(check as Map)))
              .toList());
}

class AgentTaskVerifier {
  final int cid;
  final AgentWorkspaceService workspace;
  final AgentVerificationDao store;
  const AgentTaskVerifier(
      {required this.cid, required this.workspace, required this.store});

  Future<AgentTaskVerificationReport> verify(
      {required int userCreatedAt,
      required List<int> inputIds,
      required Map<int, int> outputRevisions,
      required TaskAcceptanceCriteria criteria,
      bool Function()? canCommit}) async {
    criteria.validate();
    final checks = <AgentVerificationCheck>[];
    if (criteria.requireFullRead) {
      for (final id in inputIds.toSet()) {
        final file = await workspace.getFile(id);
        if (file == null) {
          checks.add(AgentVerificationCheck(
              label: '输入文件存在',
              passed: false,
              detail: '输入文件 $id 已不存在',
              fileId: id));
          continue;
        }
        final intervals =
            await store.readIntervals(cid, userCreatedAt, id, file.revision);
        final gaps = missingRanges(file.characterCount, intervals);
        final isPdf = file.pageCount > 0;
        if (isPdf) {
          final revision =
              await workspace.getRevision(id, revision: file.revision);
          if (revision.content.trim().isEmpty) {
            checks.add(AgentVerificationCheck(
                label: 'PDF 文字覆盖：${file.name}',
                passed: false,
                fileId: id,
                revision: file.revision,
                detail: '无可提取文字层，需要 OCR 或替换为文本文件；'
                    '不可自动补全或视为已读取扫描图像。'));
            continue;
          }
        }
        final pdfNote = isPdf ? ' PDF 仅验收可提取文字层；扫描图像未验收。' : '';
        checks.add(AgentVerificationCheck(
            label: '${isPdf ? 'PDF 文字覆盖' : '全文阅读'}：${file.name}',
            passed: gaps.isEmpty,
            fileId: id,
            revision: file.revision,
            detail: gaps.isEmpty
                ? 'read_file 已覆盖 [0, ${file.characterCount})$pdfNote'
                : '文件 $id / revision ${file.revision} 未读区间：${gaps.take(8).map((gap) => '[${gap.$1}, ${gap.$2})').join('、')}；'
                    '请 read_file(file_id: $id, offset: ${gaps.first.$1})，按 nextOffset 继续读取。搜索不算全文阅读。$pdfNote'));
      }
    }
    final outputIds = outputRevisions.keys.toSet();
    final files = await workspace.listFiles();
    for (final name in criteria.expectedOutputNames.toSet()) {
      final matching = files
          .where((file) => file.kind == 'output' && file.name == name)
          .toList();
      final delivered = matching.isNotEmpty &&
          outputRevisions[matching.first.id] == matching.first.revision;
      checks.add(AgentVerificationCheck(
          label: '预期输出：$name',
          passed: delivered,
          detail: matching.isEmpty
              ? '未找到工作区输出 $name，请经用户确认后 write_file 创建。'
              : delivered
                  ? '已找到本轮确认写入的输出文件'
                  : '已有 $name，但本轮未确认写入当前版本；旧输出不代表本轮交付。请经用户确认后 write_file。',
          fileId: matching.isEmpty ? null : matching.first.id));
      if (matching.isNotEmpty) outputIds.add(matching.first.id);
    }
    if (outputIds.isEmpty &&
        (criteria.format != null ||
            criteria.minChars != null ||
            criteria.maxChars != null ||
            criteria.requiredTerms.isNotEmpty)) {
      checks.add(const AgentVerificationCheck(
          label: '要求输出文件',
          passed: false,
          detail: '用户设置了输出条件，但本轮没有输出文件；请经用户确认后 write_file 创建。'));
    }
    for (final id in outputIds) {
      final file = await workspace.getFile(id);
      if (file == null || file.kind != 'output') {
        checks.add(AgentVerificationCheck(
            label: '输出文件存在',
            passed: false,
            detail: '输出文件 $id 已不存在或不是输出文件',
            fileId: id));
        continue;
      }
      final recordedRevision = outputRevisions[id];
      checks.add(AgentVerificationCheck(
          label: '输出版本：${file.name}',
          passed: recordedRevision == null || recordedRevision == file.revision,
          detail:
              '当前 revision ${file.revision}${recordedRevision == null ? '' : '；本轮写入 revision $recordedRevision'}',
          fileId: id,
          revision: file.revision));
      String content;
      try {
        content =
            (await workspace.getRevision(id, revision: file.revision)).content;
      } catch (_) {
        checks.add(AgentVerificationCheck(
            label: '输出内容：${file.name}',
            passed: false,
            detail: '输出文件内容无法读取',
            fileId: id,
            revision: file.revision));
        continue;
      }
      void add(String label, bool passed, String detail) =>
          checks.add(AgentVerificationCheck(
              label: '$label：${file.name}',
              passed: passed,
              detail: detail,
              fileId: id,
              revision: file.revision));
      add('输出非空', content.trim().isNotEmpty,
          '实际内容 ${content.length} 字符（UTF-16）');
      final format = criteria.format ?? file.name.split('.').last.toLowerCase();
      // 大输出的编码、格式和文字查找在 isolate 中完成，不阻塞对话界面。
      final facts = await compute(_outputFacts, {
        'content': content,
        'format': format,
        'terms': criteria.requiredTerms,
      });
      final formatError = facts['formatError'] as String?;
      add('输出编码', facts['utf8Valid'] == true, 'UTF-8 内容须能无损往返');
      add('输出格式', formatError == null, formatError ?? '$format 结构检查通过；不检查语义');
      if (criteria.minChars != null) {
        add('最少字符', content.length >= criteria.minChars!,
            '要求至少 ${criteria.minChars}，实际 ${content.length}');
      }
      if (criteria.maxChars != null) {
        add('最多字符', content.length <= criteria.maxChars!,
            '要求最多 ${criteria.maxChars}，实际 ${content.length}');
      }
      final termChecks = (facts['termChecks'] as List).cast<bool>();
      for (var index = 0; index < criteria.requiredTerms.length; index++) {
        add('必须包含文字', termChecks[index],
            '必须包含：${criteria.requiredTerms[index]}');
      }
    }
    final report = AgentTaskVerificationReport(
        cid: cid,
        userCreatedAt: userCreatedAt,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        checks: List.unmodifiable(checks));
    await store.saveReport(cid, userCreatedAt, report.toJson(),
        canCommit: canCommit);
    return report;
  }

  /// 区间仅来自 read_file 回传，同文件旧 revision 的证据由查询条件排除。
  static List<(int, int)> missingRanges(
      int totalChars, List<AgentReadInterval> intervals) {
    final sorted = intervals
        .where((range) => range.totalChars == totalChars)
        .toList()
      ..sort((a, b) => a.startOffset.compareTo(b.startOffset));
    final gaps = <(int, int)>[];
    var cursor = 0;
    for (final range in sorted) {
      if (range.startOffset > cursor) gaps.add((cursor, range.startOffset));
      if (range.endOffset > cursor) cursor = range.endOffset;
    }
    if (cursor < totalChars) gaps.add((cursor, totalChars));
    return gaps;
  }

  /// RFC 风格的逗号、双引号转义和换行状态机；不把引号内的逗号当列分隔。
  static String? csvSyntaxError(String source) {
    final text = source.startsWith('\ufeff') ? source.substring(1) : source;
    if (text.isEmpty) return 'CSV 内容为空';
    var quoted = false, closed = false, atFieldStart = true;
    var columns = 1, rows = 0;
    int? expectedColumns;
    String? finishRow() {
      rows++;
      expectedColumns ??= columns;
      if (columns != expectedColumns) {
        return 'CSV 第 $rows 行列数 $columns，与首行 $expectedColumns 不一致';
      }
      columns = 1;
      atFieldStart = true;
      closed = false;
      return null;
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            i++;
          } else {
            quoted = false;
            closed = true;
          }
        }
        continue;
      }
      if (char == ',') {
        columns++;
        atFieldStart = true;
        closed = false;
        continue;
      }
      if (char == '\r' || char == '\n') {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        final error = finishRow();
        if (error != null) return error;
        continue;
      }
      if (closed) return 'CSV 关闭引号后存在非法字符';
      if (char == '"') {
        if (!atFieldStart) return 'CSV 未转义的双引号';
        quoted = true;
      }
      atFieldStart = false;
    }
    if (quoted) return 'CSV 双引号未闭合';
    if (!text.endsWith('\n') && !text.endsWith('\r')) return finishRow();
    return null;
  }
}

Map<String, dynamic> _outputFacts(Map<String, dynamic> input) {
  final content = input['content'] as String;
  final format = input['format'] as String;
  final terms = (input['terms'] as List).cast<String>();
  var utf8Valid = false;
  try {
    utf8Valid =
        utf8.decode(utf8.encode(content), allowMalformed: false) == content;
  } catch (_) {}
  String? formatError;
  if (format == 'csv') formatError = AgentTaskVerifier.csvSyntaxError(content);
  if (format == 'json') {
    try {
      jsonDecode(content);
    } catch (_) {
      formatError = '不是有效 JSON';
    }
  }
  return {
    'utf8Valid': utf8Valid,
    'formatError': formatError,
    'termChecks': terms.map(content.contains).toList()
  };
}
