import 'dart:convert';

import 'package:chatgpt_app_core/model/skill_script.dart';

/// 把一段脚本源码送给模型做安全审计的调用方（注入式，便于单测与解耦具体聊天实现）。
/// 入参为完整 prompt，返回模型的原始文本回复。
typedef ScriptAuditCaller = Future<String> Function(String prompt);

/// 一次审计结论：等级（[SkillScript] 的 level 常量之一）+ 一句话说明。
class ScriptAuditVerdict {
  final String level;
  final String summary;

  const ScriptAuditVerdict(this.level, this.summary);
}

/// 技能脚本 AI 安全审计器。约定在【导入技能时】对每个脚本审计一次并存结论。
/// 审计只是“把关”，不是兜底——真正的安全边界是 QuickJS 沙箱（无文件/网络）。
class SkillScriptAuditor {
  const SkillScriptAuditor._();

  /// 构造审计 prompt。明确告知沙箱限制，让模型聚焦“是否可疑/与声称不符”。
  static String buildPrompt(String name, String code) {
    return '你是严谨的代码安全审计员。下面是一段将在【移动端 QuickJS 沙箱】中执行的 '
        'JavaScript，来自第三方「技能」包。沙箱限制：没有文件系统、没有网络、'
        '没有进程或宿主系统访问，只能做纯计算与字符串处理。\n'
        '请判断它是否存在风险或可疑行为，例如：可能无限循环/耗尽资源、'
        '用混淆或编码隐藏真实意图、行为与「$name」这一名称声称的功能明显不符、'
        '试图探测或越权访问宿主环境。\n'
        '只输出一行 JSON，不要解释，不要代码块：'
        '{"level":"safe|warn|danger","summary":"一句话中文说明"}。\n\n'
        '脚本名：$name\n代码：\n```js\n$code\n```';
  }

  /// 解析模型回复为结论。容错：抽取第一个含 level 的 JSON 对象；
  /// 失败则回落 unknown（由调用方决定是否仍要用户确认）。
  static ScriptAuditVerdict parse(String raw) {
    try {
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start >= 0 && end > start) {
        final obj = jsonDecode(raw.substring(start, end + 1));
        if (obj is Map) {
          final level = _normLevel(obj['level']);
          final summary = (obj['summary'] as String?)?.trim() ?? '';
          return ScriptAuditVerdict(level, summary);
        }
      }
    } catch (_) {
      // 落到下面的 unknown
    }
    return const ScriptAuditVerdict(SkillScript.levelUnknown, '无法解析审计结果');
  }

  static String _normLevel(Object? raw) {
    final s = (raw as String? ?? '').trim().toLowerCase();
    switch (s) {
      case SkillScript.levelSafe:
      case SkillScript.levelWarn:
      case SkillScript.levelDanger:
        return s;
      default:
        return SkillScript.levelUnknown;
    }
  }

  /// 审计一段脚本：构造 prompt → 调模型 → 解析。调用本身失败回落 unknown，绝不抛。
  static Future<ScriptAuditVerdict> audit(
      String name, String code, ScriptAuditCaller call) async {
    try {
      final raw = await call(buildPrompt(name, code));
      return parse(raw);
    } catch (e) {
      return ScriptAuditVerdict(SkillScript.levelUnknown, '审计调用失败：$e');
    }
  }
}
