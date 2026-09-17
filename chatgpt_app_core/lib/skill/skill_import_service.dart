import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/skill_script_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/skill_script.dart';
import 'package:chatgpt_app_core/skill/skill_script_auditor.dart';
import 'package:chatgpt_app_core/skill/js_runtime_service.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 技能包里的一篇参考资料（`references/*.md` 等）。导入后进知识库。
class SkillReference {
  final String title;
  final String text;

  const SkillReference({required this.title, required this.text});
}

/// 解析后的「技能包」（Agent Skill 的 SKILL.md 目录 / zip）。
///
/// 纯指令型 skill（SKILL.md 正文 + `references/` 文档，无需代码执行）能直接
/// 映射到 App 现有能力：正文 → 助手系统提示词，参考资料 → 知识库（RAG），
/// 等价于 Agent Skills 的「渐进式披露」。带脚本/需沙箱的 skill 不在此列。
class SkillPackage {
  /// SKILL.md frontmatter 的 `name`（缺失时用 zip/目录名兜底）。
  final String name;

  /// 展示用 emoji（imported skill 默认 🧩）。
  final String emoji;

  /// frontmatter 的 `description`（触发说明），仅用于导入预览展示。
  final String description;

  /// SKILL.md 去掉 frontmatter 后的正文 —— 作为助手系统提示词。
  final String systemPrompt;

  /// `references/` 下的参考资料，逐篇进知识库。
  final List<SkillReference> references;

  /// `scripts/` 下的 `.js` 脚本（assistantId 占位 0，导入时回填）。
  final List<SkillScript> scripts;

  const SkillPackage({
    required this.name,
    required this.emoji,
    required this.description,
    required this.systemPrompt,
    required this.references,
    this.scripts = const [],
  });
}

/// 一次导入的产物统计。
class SkillImportResult {
  final int assistantId;
  final String name;

  /// 进知识库的文档数。
  final int docCount;

  /// 进知识库的总切块数。
  final int chunkTotal;

  /// 落库的脚本数。
  final int scriptCount;

  const SkillImportResult({
    required this.assistantId,
    required this.name,
    required this.docCount,
    required this.chunkTotal,
    this.scriptCount = 0,
  });
}

/// 技能（Agent Skill）导入服务。把一个 SKILL.md 技能 zip 解析成
/// 「助手 + 知识库文档」并落库。纯 Dart（archive 包无平台通道），
/// 可用 sqflite_common_ffi 内存库做 round-trip 单测。
class SkillImportService {
  static const int maxImportBytes = 8 * 1024 * 1024;
  static const int maxTextChars = 1024 * 1024;
  static const int maxTotalTextChars = 4 * 1024 * 1024;
  static const importArchiveLimits = BackupArchiveLimits(
    maxCompressedBytes: maxImportBytes,
    maxEntries: 256,
    maxEntryUncompressedBytes: 2 * 1024 * 1024,
    maxTotalUncompressedBytes: 16 * 1024 * 1024,
  );

  /// 文本类参考资料的扩展名（其余文件忽略）。
  static const _textExt = {'md', 'markdown', 'txt'};

  // ---------------------------------------------------------------- 解析

  /// 解析一个技能 zip。找不到 SKILL.md / 无 name 时抛 [FormatException]，
  /// 不触碰任何数据。[fallbackName] 通常传所选文件名（去扩展名）。
  static SkillPackage parseArchive(List<int> zipBytes, {String? fallbackName}) {
    if (zipBytes.length > maxImportBytes) {
      throw const FormatException('技能包过大（最多 8 MiB）');
    }
    final Archive archive;
    try {
      archive = decodeBoundedZipArchive(
        zipBytes,
        limits: importArchiveLimits,
        invalidArchiveMessage: '不是有效的技能包（zip 解析失败）',
      );
    } on FormatException catch (error) {
      if (error.message == '不是有效的技能包（zip 解析失败）') rethrow;
      throw FormatException('技能包资源超限或结构不安全：${error.message}');
    } catch (_) {
      throw const FormatException('不是有效的技能包（zip 解析失败）');
    }

    // 找 SKILL.md：取路径层级最浅的一个（兼容根目录或单层子目录打包）。
    ArchiveFile? skillFile;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      if (_basename(f.name).toLowerCase() != 'skill.md') continue;
      if (skillFile == null || _depth(f.name) < _depth(skillFile.name)) {
        skillFile = f;
      }
    }
    if (skillFile == null) {
      throw const FormatException('技能包里没有 SKILL.md');
    }

    final raw = _decode(skillFile);
    _validateTextLength(raw, 'SKILL.md');
    final parsed = _parseSkillMd(raw);
    final name =
        (parsed.name.isNotEmpty ? parsed.name : (fallbackName ?? '')).trim();
    if (name.isEmpty) {
      throw const FormatException('SKILL.md 缺少 name，且无法从文件名推断');
    }

    // 参考资料：与 SKILL.md 同前缀、文本类、且不在 evals/ 下的文件。
    final prefix = _dirOf(skillFile.name);
    final refs = <SkillReference>[];
    var totalTextChars = raw.length;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final n = f.name;
      if (identical(f, skillFile)) continue;
      if (prefix.isNotEmpty && !n.startsWith(prefix)) continue;
      final rel = n.substring(prefix.length);
      if (rel.startsWith('evals/')) continue; // 测试用例不进知识库
      final base = _basename(rel);
      if (base.startsWith('.')) continue; // .DS_Store 等
      final ext = _extOf(base);
      if (!_textExt.contains(ext)) continue;
      final text = _decode(f).trim();
      if (text.isEmpty) continue;
      _validateTextLength(text, f.name);
      totalTextChars += text.length;
      if (totalTextChars > maxTotalTextChars) {
        throw const FormatException('技能包文本总量过大（最多 4 MiB 字符）');
      }
      refs.add(SkillReference(title: _stripExt(base), text: text));
    }

    // 脚本：同前缀下的 `.js`（含 scripts/）。带包脚本，导入后经审计 + 确认才执行。
    final scripts = <SkillScript>[];
    for (final f in archive.files) {
      if (!f.isFile) continue;
      if (identical(f, skillFile)) continue;
      final n = f.name;
      if (prefix.isNotEmpty && !n.startsWith(prefix)) continue;
      final base = _basename(n.substring(prefix.length));
      if (base.startsWith('.')) continue;
      if (_extOf(base) != 'js') continue;
      final code = _decode(f).trim();
      if (code.isEmpty) continue;
      if (code.length > JsRuntimeService.defaultMaxCodeChars) {
        throw FormatException('技能脚本过大：$n');
      }
      totalTextChars += code.length;
      if (totalTextChars > maxTotalTextChars) {
        throw const FormatException('技能包文本总量过大（最多 4 MiB 字符）');
      }
      scripts.add(SkillScript(assistantId: 0, name: base, code: code));
    }

    return SkillPackage(
      name: name,
      emoji: '🧩',
      description: parsed.description.trim(),
      systemPrompt: parsed.body.trim(),
      references: refs,
      scripts: scripts,
    );
  }

  static void _validateTextLength(String value, String name) {
    if (value.length > maxTextChars) {
      throw FormatException('技能文本过大：$name');
    }
  }

  // ---------------------------------------------------------------- 导入

  /// 把技能包落库：新建一个助手（正文进系统提示词，有参考资料时绑定
  /// 「知识库检索」工具、有脚本时绑定「运行脚本」工具），参考资料切块进知识库，
  /// 脚本（可选审计后）存入 [scriptDao]。
  /// - [scriptDao]：为 null 时丢弃脚本（不落库）；
  /// - [auditCall]：提供时在导入阶段对每个脚本做一次 AI 安全审计并存结论；
  ///   为 null（如未配置 API key）时脚本以 `pending` 入库，执行时再由用户确认。
  static Future<SkillImportResult> import(
    SkillPackage pkg, {
    required AssistantDao assistantDao,
    required KnowledgeDao knowledgeDao,
    SkillScriptDao? scriptDao,
    ScriptAuditCaller? auditCall,
  }) async {
    final hasRefs = pkg.references.isNotEmpty;
    final hasScripts = pkg.scripts.isNotEmpty && scriptDao != null;

    // 参考资料进知识库（标题加技能名前缀，便于辨识与检索）。
    var docCount = 0;
    var chunkTotal = 0;
    for (final ref in pkg.references) {
      final docId = await knowledgeDao.addDocument(
          '${pkg.name} · ${ref.title}', ref.text);
      if (docId != null) {
        docCount++;
        // addDocument 已按切块写入；这里粗略按文档计 chunk 由其内部决定，
        // 总数从知识库角度不易回取，改为不强求精确，记文档数即可。
      }
    }
    // chunkTotal 仅作展示，按文档已落库为准（不再二次查询）。
    chunkTotal = docCount;

    // 正文为系统提示词；有参考资料/脚本时追加「桥接说明」，提示模型走知识库
    // 检索、走工具执行脚本，而不是去读/跑文件（移动端没有 Agent 的文件系统）。
    var prompt = pkg.systemPrompt;
    if (hasRefs) {
      final titles = pkg.references.map((r) => r.title).join('、');
      prompt = '$prompt\n\n---\n'
          '（本技能的参考资料已导入知识库：$titles。'
          '需要时请用「知识库检索」工具按关键词查询，而不是尝试读取文件。）';
    }
    if (hasScripts) {
      final names = pkg.scripts.map((s) => s.name).join('、');
      prompt = '$prompt\n\n（本技能含脚本：$names。需要运行时请用「运行脚本」工具'
          '按文件名调用，执行前会经安全审计并请用户确认；'
          '若当前环境不支持执行，请用文字方式近似完成对应步骤。）';
    }

    // 按携带内容绑定工具：参考资料 → 知识库检索；脚本 → 运行脚本。
    final toolIds = <String>[
      if (hasRefs) 'knowledge_search',
      if (hasScripts) 'run_script',
    ];
    final assistant = AssistantModel(
      name: pkg.name,
      emoji: pkg.emoji,
      prompt: prompt,
      useTools: true,
      toolIds: toolIds.isEmpty ? null : toolIds,
    );
    final id = await assistantDao.saveAssistant(assistant);

    // 脚本：回填 assistantId，（有 caller 时）审计，再落库。
    var scriptCount = 0;
    if (hasScripts && id != null) {
      for (final s in pkg.scripts) {
        s.assistantId = id;
        if (auditCall != null) {
          final v = await SkillScriptAuditor.audit(s.name, s.code, auditCall);
          s.auditLevel = v.level;
          s.auditSummary = v.summary;
        }
        await scriptDao.saveScript(s);
        scriptCount++;
      }
    }
    AILogger.log('skill import "${pkg.name}" -> assistant#$id'
        ', $docCount kb docs, $scriptCount scripts');

    return SkillImportResult(
      assistantId: id ?? -1,
      name: pkg.name,
      docCount: docCount,
      chunkTotal: chunkTotal,
      scriptCount: scriptCount,
    );
  }

  // ---------------------------------------------------------------- 内部

  static String _decode(ArchiveFile f) =>
      utf8.decode(f.content as List<int>, allowMalformed: true);

  /// SKILL.md 的解析结果：frontmatter 的 name/description + 去掉 frontmatter 的正文。
  static _SkillMd _parseSkillMd(String raw) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = text.split('\n');

    // 没有 frontmatter：整篇即正文。
    var i = 0;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length || lines[i].trim() != '---') {
      return _SkillMd(name: '', description: '', body: raw);
    }

    // 找闭合的 '---'。
    final fmStart = i + 1;
    var fmEnd = -1;
    for (var j = fmStart; j < lines.length; j++) {
      if (lines[j].trim() == '---') {
        fmEnd = j;
        break;
      }
    }
    if (fmEnd < 0) {
      // 不闭合：当作没有 frontmatter。
      return _SkillMd(name: '', description: '', body: raw);
    }

    final fm = lines.sublist(fmStart, fmEnd);
    final body = lines.sublist(fmEnd + 1).join('\n');
    final map = _parseFrontmatter(fm);
    return _SkillMd(
      name: map['name'] ?? '',
      description: map['description'] ?? '',
      body: body,
    );
  }

  /// 极简 YAML frontmatter 解析：只取顶层 `key: value`，支持
  /// 折叠块标量（`>` / `>-`，多行合成一行）与字面块标量（`|` / `|-`，保留换行）。
  static Map<String, String> _parseFrontmatter(List<String> lines) {
    final out = <String, String>{};
    var i = 0;
    final keyRe = RegExp(r'^([A-Za-z0-9_-]+):\s?(.*)$');
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty || _indent(line) > 0) {
        i++;
        continue; // 跳过空行 / 残留缩进行
      }
      final m = keyRe.firstMatch(line);
      if (m == null) {
        i++;
        continue;
      }
      final key = m.group(1)!;
      final rest = m.group(2)!.trim();
      if (rest == '>' || rest == '>-' || rest == '|' || rest == '|-') {
        // 块标量：收集后续更深缩进的行。
        final folded = rest.startsWith('>');
        final block = <String>[];
        var j = i + 1;
        while (j < lines.length) {
          final l = lines[j];
          if (l.trim().isEmpty) {
            block.add('');
            j++;
            continue;
          }
          if (_indent(l) == 0) break; // 回到顶层，块结束
          block.add(l.trimLeft());
          j++;
        }
        out[key] = folded ? _foldBlock(block) : block.join('\n').trim();
        i = j;
      } else {
        out[key] = _unquote(rest);
        i++;
      }
    }
    return out;
  }

  /// 折叠块：连续非空行用空格连，空行作为段落分隔（换行）。
  static String _foldBlock(List<String> block) {
    final buf = StringBuffer();
    var prevBlank = true;
    for (final l in block) {
      if (l.isEmpty) {
        buf.write('\n');
        prevBlank = true;
      } else {
        if (!prevBlank) buf.write(' ');
        buf.write(l);
        prevBlank = false;
      }
    }
    return buf.toString().trim();
  }

  static String _unquote(String s) {
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  static int _indent(String s) {
    var n = 0;
    while (n < s.length && s[n] == ' ') {
      n++;
    }
    return n;
  }

  static String _basename(String path) {
    final parts =
        path.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  static String _dirOf(String path) {
    final idx = path.lastIndexOf(RegExp(r'[/\\]'));
    return idx < 0 ? '' : path.substring(0, idx + 1);
  }

  static int _depth(String path) => RegExp(r'[/\\]').allMatches(path).length;

  static String _extOf(String base) {
    final idx = base.lastIndexOf('.');
    return idx < 0 ? '' : base.substring(idx + 1).toLowerCase();
  }

  static String _stripExt(String base) {
    final idx = base.lastIndexOf('.');
    return idx < 0 ? base : base.substring(0, idx);
  }
}

class _SkillMd {
  final String name;
  final String description;
  final String body;

  const _SkillMd({
    required this.name,
    required this.description,
    required this.body,
  });
}
