import 'package:flutter/material.dart';

/// 服务商品牌视觉（品牌色 + 字标），供 [ProviderAvatar] 在列表/详情里渲染
/// 「带品牌色的字标头像」，避免为十几家服务商各打包一张 logo 图。
///
/// 自定义服务商不在表里时，回退为「名称首字 + 由名称哈希出的稳定颜色」。
class ProviderBrand {
  final Color color;
  final String monogram;
  const ProviderBrand(this.color, this.monogram);
}

class ProviderBranding {
  ProviderBranding._();

  static const Map<String, ProviderBrand> _brands = {
    'openai': ProviderBrand(Color(0xFF10A37F), 'AI'),
    'deepseek': ProviderBrand(Color(0xFF4D6BFE), 'DS'),
    'siliconflow': ProviderBrand(Color(0xFF7C3AED), '硅'),
    'openrouter': ProviderBrand(Color(0xFF6467F2), 'OR'),
    'groq': ProviderBrand(Color(0xFFF55036), 'Gq'),
    'moonshot': ProviderBrand(Color(0xFF6E56CF), '月'),
    'zhipu': ProviderBrand(Color(0xFF3859FF), '智'),
    'dashscope': ProviderBrand(Color(0xFFFF6A00), '通'),
    'mistral': ProviderBrand(Color(0xFFFA520F), 'M'),
    'grok': ProviderBrand(Color(0xFF1A1A1A), 'Gr'),
    'perplexity': ProviderBrand(Color(0xFF20808D), 'P'),
    'gemini': ProviderBrand(Color(0xFF4285F4), 'G'),
    'together': ProviderBrand(Color(0xFF0F6FFF), 'T'),
    'stepfun': ProviderBrand(Color(0xFF0055FF), '阶'),
    'baichuan': ProviderBrand(Color(0xFFFF6933), '百'),
    'ollama': ProviderBrand(Color(0xFF111827), 'Ol'),
  };

  /// 预设的品牌色；不存在返回 null。
  static ProviderBrand? of(String providerId) => _brands[providerId];

  /// 解析品牌视觉：预设优先；否则用名称首字 + 稳定哈希色兜底。
  static ProviderBrand resolve(String providerId, String name) {
    final preset = _brands[providerId];
    if (preset != null) return preset;
    final mono = _firstGlyph(name);
    return ProviderBrand(_stableColor(name.isEmpty ? providerId : name), mono);
  }

  static String _firstGlyph(String s) {
    final t = s.trim();
    if (t.isEmpty) return '?';
    // 中文取首字，英文取首字母（大写）。
    final first = t.characters.first;
    final isAscii = first.codeUnitAt(0) < 128;
    return isAscii ? first.toUpperCase() : first;
  }

  /// 由字符串派生一个稳定、饱和度适中的颜色（自定义服务商兜底）。
  static Color _stableColor(String seed) {
    var hash = 0;
    for (final c in seed.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor();
  }
}
