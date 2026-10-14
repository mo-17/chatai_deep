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
      for (var i = 0; i < 6; i++) {
        await tester.enterText(_fields.at(i), '${i + 1}');
        await tester.pump();
        final editable = tester
            .state<EditableTextState>(find.descendant(
                of: _fields.at(i), matching: find.byType(EditableText)))
            .renderEditable;
        expect(editable.size.height,
            greaterThanOrEqualTo(editable.preferredLineHeight),
            reason: 'digit line must fit its clipped viewport');
        final caret =
            editable.getLocalRectForCaret(const TextPosition(offset: 1));
        expect(caret.top, greaterThanOrEqualTo(-1));
        expect(caret.bottom, lessThanOrEqualTo(editable.size.height + 1));
      }
      expect(tester.takeException(), isNull);
      final inputRect = tester.getRect(find.byType(VerificationCodeInput));
      for (var i = 0; i < 6; i++) {
        final field = tester.getRect(_fields.at(i));
        expect(field.left, greaterThanOrEqualTo(inputRect.left - 1));
        expect(field.right, lessThanOrEqualTo(inputRect.right + 1));
      }
    });
  }
  testWidgets(
      'six digits, delete/re-enter, focus and completion stay unchanged',
      (tester) async {
    final completions = <String>[];
    await _mount(tester, completed: completions.add);
    for (var i = 0; i < 6; i++) {
      await tester.enterText(_fields.at(i), '${i + 1}');
      await tester.pump();
      final next = tester.widget<TextField>(_fields.at(i < 5 ? i + 1 : 5));
      expect(next.focusNode!.hasFocus, isTrue);
    }
    expect(completions, ['123456']);
    await tester.enterText(_fields.last, '');
    await tester.pump();
    expect(tester.widget<TextField>(_fields.last).controller!.text, isEmpty);
    expect(tester.widget<TextField>(_fields.last).focusNode!.hasFocus, isTrue);
    expect(completions, hasLength(1));
    await tester.enterText(_fields.last, '0');
    await tester.pump();
    expect(completions, ['123456', '123450']);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'whole-code paste retains the existing one-digit-per-field contract',
      (tester) async {
    final completions = <String>[];
    await _mount(tester, completed: completions.add);
    await tester.tap(_fields.first);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '246810', selection: TextSelection.collapsed(offset: 6)));
    await tester.pump();
    final values = List.generate(
        6, (i) => tester.widget<TextField>(_fields.at(i)).controller!.text);
    expect(values, ['2', '', '', '', '', '']);
    expect(tester.widget<TextField>(_fields.at(1)).focusNode!.hasFocus, isTrue);
    expect(completions, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
