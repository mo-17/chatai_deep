import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:http/http.dart' as http;

/// L2 内置工具：无需配置、纯客户端执行的声明式工具（计算器 / 日期时间 / 抓取网页）。
/// 与 `web_search` 一样是 [ChatTool]，由助手通过 `toolIds` 绑定、模型自主调用。
class BuiltinTools {
  const BuiltinTools._();

  // ── 计算器 ───────────────────────────────────────────────
  static ChatTool calculator() => ChatTool(
        name: ToolRegistry.calculatorId,
        description: '计算一个数学表达式（加减乘除、取模 %、乘方 ^、括号）。'
            '当问题涉及精确算术、避免心算出错时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'expression': {
              'type': 'string',
              'description': '要计算的算术表达式，如 "(3+4)*2^3/7"',
            },
          },
          'required': ['expression'],
        },
        execute: (args) async {
          final expr = (args['expression'] as String? ?? '').trim();
          if (expr.isEmpty) {
            return const ToolOutcome(content: '错误：缺少 expression 参数');
          }
          try {
            final value = Arithmetic.eval(expr);
            return ToolOutcome(content: '$expr = ${_fmtNum(value)}');
          } on FormatException catch (e) {
            return ToolOutcome(content: '无法计算「$expr」：${e.message}');
          }
        },
      );

  // ── 当前日期时间 ─────────────────────────────────────────
  static ChatTool dateTime() => ChatTool(
        name: ToolRegistry.dateTimeId,
        description: '获取用户设备当前的本地日期与时间。当问题涉及「现在/今天/此刻」'
            '的精确时间、星期几、或需要据此计算时调用。',
        parameters: const {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        execute: (args) async {
          final now = DateTime.now();
          const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
          String two(int n) => n.toString().padLeft(2, '0');
          final date = '${now.year}-${two(now.month)}-${two(now.day)}';
          final time = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
          return ToolOutcome(
            content: jsonEncode({
              'date': date,
              'time': time,
              'weekday': '星期${weekdays[now.weekday - 1]}',
              'iso': now.toIso8601String(),
              'note': '用户设备本地时间',
            }),
          );
        },
      );

  // ── 抓取网页正文 ─────────────────────────────────────────
  /// [client] 仅供测试注入；默认用 package:http。
  static ChatTool fetchUrl({http.Client? client}) => ChatTool(
        name: ToolRegistry.fetchUrlId,
        description: '抓取一个网页 URL 并返回其正文文本（已去除 HTML 标签）。'
            '当用户给出链接、要求阅读/总结某个页面时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': '要抓取的完整 URL（http/https）',
            },
          },
          'required': ['url'],
        },
        execute: (args) async {
          final url = (args['url'] as String? ?? '').trim();
          final uri = Uri.tryParse(url);
          if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
            return const ToolOutcome(content: '错误：url 不是有效的 http/https 地址');
          }
          final c = client ?? http.Client();
          try {
            final resp =
                await c.get(uri).timeout(const Duration(seconds: 15));
            if (resp.statusCode != 200) {
              return ToolOutcome(content: '抓取失败：HTTP ${resp.statusCode}');
            }
            final text = HtmlText.extract(resp.body);
            if (text.isEmpty) return const ToolOutcome(content: '页面没有可提取的正文');
            return ToolOutcome(content: _cap(text, 4000));
          } catch (e) {
            return ToolOutcome(content: '抓取失败：$e');
          } finally {
            if (client == null) c.close();
          }
        },
      );

  static String _fmtNum(num v) {
    if (v is int) return v.toString();
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return v.toString();
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…（已截断）';
}

/// 极简算术求值（递归下降）。支持：整数/小数、`+ - * / %`、乘方 `^`（右结合）、
/// 一元正负、括号。非法输入抛 [FormatException]。无任何第三方依赖，便于单测。
class Arithmetic {
  static num eval(String input) {
    final parser = _Parser(_tokenize(input));
    final value = parser._parseExpr();
    parser._expectEnd();
    return value;
  }

  static List<String> _tokenize(String s) {
    final tokens = <String>[];
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t') {
        i++;
        continue;
      }
      if ('+-*/%^()'.contains(ch)) {
        tokens.add(ch);
        i++;
        continue;
      }
      if (_isDigit(ch) || ch == '.') {
        final start = i;
        var dot = false;
        while (i < s.length && (_isDigit(s[i]) || s[i] == '.')) {
          if (s[i] == '.') {
            if (dot) throw const FormatException('数字格式错误');
            dot = true;
          }
          i++;
        }
        tokens.add(s.substring(start, i));
        continue;
      }
      throw FormatException('无法识别的字符 "$ch"');
    }
    return tokens;
  }

  static bool _isDigit(String ch) {
    final c = ch.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39;
  }
}

class _Parser {
  _Parser(this._tokens);
  final List<String> _tokens;
  int _pos = 0;

  String? get _peek => _pos < _tokens.length ? _tokens[_pos] : null;
  String _next() => _tokens[_pos++];

  void _expectEnd() {
    if (_pos != _tokens.length) {
      throw FormatException('多余的内容 "$_peek"');
    }
  }

  // expr := term (('+'|'-') term)*
  num _parseExpr() {
    var value = _parseTerm();
    while (_peek == '+' || _peek == '-') {
      final op = _next();
      final rhs = _parseTerm();
      value = op == '+' ? value + rhs : value - rhs;
    }
    return value;
  }

  // term := unary (('*'|'/'|'%') unary)*
  num _parseTerm() {
    var value = _parseUnary();
    while (_peek == '*' || _peek == '/' || _peek == '%') {
      final op = _next();
      final rhs = _parseUnary();
      if (op == '*') {
        value = value * rhs;
      } else if (op == '/') {
        if (rhs == 0) throw const FormatException('除数不能为 0');
        value = value / rhs;
      } else {
        if (rhs == 0) throw const FormatException('取模的除数不能为 0');
        value = value % rhs;
      }
    }
    return value;
  }

  // unary := ('+'|'-') unary | power
  num _parseUnary() {
    if (_peek == '+') {
      _next();
      return _parseUnary();
    }
    if (_peek == '-') {
      _next();
      return -_parseUnary();
    }
    return _parsePower();
  }

  // power := primary ('^' unary)?   // 右结合，且指数侧允许一元负号
  num _parsePower() {
    final base = _parsePrimary();
    if (_peek == '^') {
      _next();
      final exp = _parseUnary();
      return _pow(base, exp);
    }
    return base;
  }

  num _parsePrimary() {
    final tok = _peek;
    if (tok == null) throw const FormatException('表达式不完整');
    if (tok == '(') {
      _next();
      final value = _parseExpr();
      if (_peek != ')') throw const FormatException('括号不匹配');
      _next();
      return value;
    }
    final n = num.tryParse(tok);
    if (n == null) throw FormatException('期望数字，得到 "$tok"');
    _next();
    return n;
  }

  num _pow(num base, num exp) {
    final r = _powDouble(base.toDouble(), exp.toDouble());
    if (!r.isFinite) throw const FormatException('乘方结果无效');
    // 整数底 + 非负整数指数 -> 返回整数，结果更干净。
    if (base is int && exp is int && exp >= 0 && r == r.roundToDouble()) {
      return r.toInt();
    }
    if (base == base.roundToDouble() &&
        exp == exp.roundToDouble() &&
        exp >= 0 &&
        r == r.roundToDouble() &&
        r.abs() < 1e15) {
      return r.toInt();
    }
    return r;
  }

  static double _powDouble(double a, double b) {
    // 避免引入 dart:math 只为 pow——整数指数用快速幂，其余回退。
    if (b == b.roundToDouble() && b.abs() < 1000) {
      var n = b.toInt();
      final neg = n < 0;
      n = n.abs();
      var result = 1.0;
      var p = a;
      while (n > 0) {
        if (n & 1 == 1) result *= p;
        p *= p;
        n >>= 1;
      }
      return neg ? 1.0 / result : result;
    }
    // 非整数指数：用 exp/ln 近似（极少用到）。
    return _expApprox(b * _lnApprox(a));
  }

  static double _lnApprox(double x) {
    if (x <= 0) return double.nan;
    // 自然对数级数（够用即可）。
    final y = (x - 1) / (x + 1);
    final y2 = y * y;
    var term = y;
    var sum = 0.0;
    for (var k = 1; k <= 99; k += 2) {
      sum += term / k;
      term *= y2;
    }
    return 2 * sum;
  }

  static double _expApprox(double x) {
    var sum = 1.0;
    var term = 1.0;
    for (var k = 1; k <= 50; k++) {
      term *= x / k;
      sum += term;
    }
    return sum;
  }
}

/// 把 HTML 粗提取为纯文本：剔除 script/style、去标签、解码常见实体、压缩空白。
class HtmlText {
  const HtmlText._();

  static String extract(String html) {
    var s = html;
    s = s.replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>',
            caseSensitive: false),
        ' ');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</(p|div|li|h[1-6]|tr)>', caseSensitive: false),
        '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = _decodeEntities(s);
    // 压缩空白：行内多空格 -> 单空格；多空行 -> 单空行。
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r' *\n *'), '\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
}
