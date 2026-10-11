import 'package:flutter/services.dart';

/// 仅检查一次新键入；程序恢复和多字符粘贴不从此入口调用。
int? composerReferenceTrigger(TextEditingValue before, TextEditingValue after) {
  if ((!after.composing.isCollapsed && after.composing.isValid) ||
      (!before.composing.isCollapsed && before.composing.isValid) ||
      !before.selection.isValid ||
      !before.selection.isCollapsed ||
      !after.selection.isValid ||
      !after.selection.isCollapsed ||
      after.text.length != before.text.length + 1) {
    return null;
  }
  final offset = before.selection.baseOffset;
  if (offset > before.text.length ||
      after.selection.baseOffset != offset + 1 ||
      after.text !=
          '${before.text.substring(0, offset)}@${before.text.substring(offset)}') {
    return null;
  }
  if (offset > 0 && !RegExp(r'[\s（(【\[]').hasMatch(before.text[offset - 1])) {
    return null;
  }
  return offset;
}
