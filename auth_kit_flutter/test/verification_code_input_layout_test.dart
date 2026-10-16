import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder get _fields => find.descendant(
    of: find.byType(VerificationCodeInput), matching: find.byType(TextField));
Future<void> _mount(WidgetTester tester,
    {double width = 300,
    double scale = 1,
    bool material3 = true,
    void Function(String)? completed}) async {
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: material3),
      home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: width,
                      child:
                          VerificationCodeInput(onCompleted: completed)))))));
  await tester.pump();
}

void main() {
  for (final config in [
    (width: 300.0, scale: 1.0, material3: true),
    (width: 300.0, scale: 1.0, material3: false),
    (width: 216.0, scale: 1.0, material3: true),
    (width: 216.0, scale: 2.0, material3: true),
    (width: 300.0, scale: 2.0, material3: false)
  ]) {
    testWidgets('full digit/caret height and no row overflow: $config',
        (tester) async {
      await _mount(tester,
          width: config.width,
          scale: config.scale,
          material3: config.material3);
      expect(tester.takeException(), isNull);
      expect(_fields, findsOneWidget);
      await tester.enterText(_fields, '123456');
      await tester.pump();
      final editable = tester
          .state<EditableTextState>(
              find.descendant(of: _fields, matching: find.byType(EditableText)))
          .renderEditable;
      final digitPainter = TextPainter(
          text: TextSpan(
              text: '0',
              style: tester
                  .widget<TextField>(_fields)
                  .style!
                  .copyWith(letterSpacing: 0)),
          textDirection: TextDirection.ltr,
          textScaler: editable.textScaler)
        ..layout();
      expect(editable.size.height,
          greaterThanOrEqualTo(editable.preferredLineHeight),
          reason: 'digit line must fit its clipped viewport');
      for (var i = 0; i <= 6; i++) {
        final caret = editable.getLocalRectForCaret(TextPosition(offset: i));
        expect(caret.top, greaterThanOrEqualTo(-1));
        expect(caret.bottom, lessThanOrEqualTo(editable.size.height + 1));
        expect(caret.left, greaterThanOrEqualTo(-1));
        expect(caret.right, lessThanOrEqualTo(editable.size.width + 2));
      }
      expect(tester.takeException(), isNull);
      final inputRect = tester.getRect(find.byType(VerificationCodeInput));
      for (var i = 0; i < 6; i++) {
        final cell =
            tester.getRect(find.byKey(ValueKey('verification-code-cell-$i')));
        expect(cell.left, greaterThanOrEqualTo(inputRect.left - 1));
        expect(cell.right, lessThanOrEqualTo(inputRect.right + 1));
        final boxes = editable.getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1));
        expect(boxes, hasLength(1));
        // 选区 TextBox 包含字符后的字距，不能将其中点当作数字中点。
        final box = boxes.single.toRect();
        final glyphCenter = editable.localToGlobal(
            Offset(box.left + digitPainter.width / 2, box.center.dy));
        expect(glyphCenter.dx, closeTo(cell.center.dx, 2));
        expect(cell.height, greaterThanOrEqualTo(editable.preferredLineHeight));
      }
      digitPainter.dispose();
    });
  }
  testWidgets(
      'six digits, delete/re-enter, focus and completion stay unchanged',
      (tester) async {
    final completions = <String>[];
    await _mount(tester, completed: completions.add);
    for (var i = 0; i < 6; i++) {
      await tester.enterText(_fields, '123456'.substring(0, i + 1));
      await tester.pump();
      expect(tester.widget<TextField>(_fields).focusNode!.hasFocus, isTrue);
    }
    expect(completions, ['123456']);
    await tester.enterText(_fields, '12345');
    await tester.pump();
    expect(tester.widget<TextField>(_fields).controller!.text, '12345');
    expect(tester.widget<TextField>(_fields).focusNode!.hasFocus, isTrue);
    expect(completions, hasLength(1));
    await tester.enterText(_fields, '123450');
    await tester.pump();
    expect(completions, ['123456', '123450']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('whole-code paste fills all six visual positions',
      (tester) async {
    final completions = <String>[];
    await _mount(tester, completed: completions.add);
    await tester.tap(_fields.first);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '246810', selection: TextSelection.collapsed(offset: 6)));
    await tester.pump();
    expect(tester.widget<TextField>(_fields).controller!.text, '246810');
    expect(tester.widget<TextField>(_fields).focusNode!.hasFocus, isTrue);
    expect(completions, ['246810']);
    expect(tester.takeException(), isNull);
  });
}
