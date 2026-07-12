import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// API Key 输入框：默认隐藏 + 显隐切换 + 一键粘贴 + 等宽字体。
/// 等宽 + 字距让它读起来像「开发者工具」而非普通设置项（规格建议）。
class ApiKeyField extends StatefulWidget {
  final TextEditingController controller;
  final String labelText;
  final ValueChanged<String>? onChanged;

  const ApiKeyField({
    super.key,
    required this.controller,
    this.labelText = 'API Key',
    this.onChanged,
  });

  @override
  State<ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<ApiKeyField> {
  bool _obscure = true;

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    widget.controller.text = text;
    widget.onChanged?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final visual = AppVisualTheme.of(context);
    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      onChanged: widget.onChanged,
      // 避免部分 Android 键盘在显隐切换时跳布局（规格 do/don't）。
      keyboardType: TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            letterSpacing: 1.2,
          ),
      decoration: InputDecoration(
        labelText: widget.labelText,
        filled: true,
        fillColor: visual.isAnime
            ? theme.inputDecorationTheme.fillColor
            : cs.surfaceContainerHighest,
        border: visual.isAnime
            ? null
            : OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '粘贴',
              icon: const Icon(Icons.content_paste_rounded, size: 20),
              onPressed: _paste,
            ),
            IconButton(
              tooltip: _obscure ? '显示' : '隐藏',
              icon: Icon(
                  _obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  size: 20),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ],
        ),
      ),
    );
  }
}
