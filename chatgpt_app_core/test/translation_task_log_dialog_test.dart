import 'package:chatgpt_app_core/widget/translation_task_log_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'task log renders formatted rune progress without dropping chunk text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TranslationTaskLogDialog(
          title: '翻译日志',
          log: '12:34:56 · 运行中 · 世界书 · 块 3/16 · 已完成 8,420/33,322 字',
        ),
      ),
    ));

    expect(find.text('世界书'), findsOneWidget);
    expect(find.text('块 3/16'), findsOneWidget);
    expect(find.text('已完成 8,420/33,322 字'), findsOneWidget);
  });
}
