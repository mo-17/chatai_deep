import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:chatgpt_app_core/pages/ocr_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';

void main() {
  PdfOcrResult original() => PdfOcrResult(totalPages: 2, pages: [
        '第一页错字',
        '第二页正文'
      ], details: [
        OcrPageDetail(page: 1, width: 100, height: 200, lines: [
          OcrLine(text: '第一页错字', confidence: .7, box: [
            [0, 0],
            [80, 0],
            [80, 20],
            [0, 20]
          ])
        ]),
      ]);
  for (final size in [const Size(390, 780), const Size(1200, 800)]) {
    testWidgets('校对分页往返及保存，在 ${size.width} 宽度无溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PdfOcrResult? saved;
      final source = original();
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        saved = await Navigator.push<PdfOcrResult>(
                            context,
                            MaterialPageRoute(
                                builder: (_) => OcrReviewPage(
                                    filename: '资料.pdf',
                                    result: source,
                                    isCurrent: () => true)));
                      },
                      child: const Text('打开校对'))))));
      await tester.tap(find.text('打开校对'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 行置信度偏低'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('ocr-page-text')), '第一页校正');
      await tester.tap(find.byTooltip('下一页'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('ocr-page-text')), '第二页修改');
      await tester.tap(find.byTooltip('上一页'));
      await tester.pumpAndSettle();
      expect(find.text('第一页校正'), findsOneWidget);
      await tester.tap(find.text('保存校对'));
      await tester.pumpAndSettle();
      expect(saved!.pages, ['第一页校正', '第二页修改']);
      expect(source.pages.first, '第一页错字');
      expect(saved!.details.first.lines.first.confidence, .7);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('低置信度行可展开，取消返回不会提交修改', (tester) async {
    PdfOcrResult? saved;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      saved = await Navigator.push<PdfOcrResult>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => OcrReviewPage(
                                  filename: 'scan.pdf',
                                  result: original(),
                                  isCurrent: () => true)));
                    },
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('1 行置信度偏低'));
    await tester.pumpAndSettle();
    expect(find.text('识别置信度 70%'), findsOneWidget);
    await tester.tap(find.text('识别置信度 70%'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('ocr-page-text')), '未保存修改');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(saved, isNull);
  });
  testWidgets('账号或后端变化立即隐藏原文且禁用保存', (tester) async {
    var current = true;
    await tester.pumpWidget(MaterialApp(
        home: OcrReviewPage(
            filename: 'scan.pdf',
            result: original(),
            isCurrent: () => current)));
    await tester.pumpAndSettle();
    current = false;
    BackendConfig.changes.value++;
    await tester.pumpAndSettle();
    expect(find.text('第一页错字'), findsNothing);
    expect(find.text('保存校对'), findsNothing);
    expect(find.textContaining('账号或后端已变化'), findsOneWidget);
  });
}
