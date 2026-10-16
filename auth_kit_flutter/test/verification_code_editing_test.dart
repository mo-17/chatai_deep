import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder get _fields => find.descendant(
    of: find.byType(VerificationCodeInput), matching: find.byType(TextField));
Finder get _field => _fields.first;
Finder get _editable =>
    find.descendant(of: _field, matching: find.byType(EditableText));

void main() {
  final changes = <String>[];
  final completed = <String>[];
  var clipboardReads = 0;
  setUp(() {
    changes.clear();
    completed.clear();
    clipboardReads = 0;
    // 仅使用合成剪贴板，不读写用户的系统剪贴板。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      if (call.method == 'Clipboard.getData') {
        clipboardReads++;
        return {'text': '246810'};
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 300,
                    child: VerificationCodeInput(
                        onChanged: changes.add,
                        onCompleted: completed.add))))));
    await tester.tap(_field);
    await tester.pump();
  }

  Future<void> edit(WidgetTester tester, String text, {int? caret}) async {
    tester.testTextInput.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret ?? text.length)));
    await tester.pump();
  }

  String code(WidgetTester tester) =>
      tester.widget<TextField>(_field).controller!.text;
  TextSelection selection(WidgetTester tester) =>
      tester.widget<TextField>(_field).controller!.selection;

  testWidgets('whole platform paste fills six digits in one real editor',
      (tester) async {
    await mount(tester);
    await edit(tester, '246810');
    expect(code(tester), '246810');
    expect(changes, ['246810']);
    expect(completed, ['246810']);
    expect(_fields, findsOneWidget);
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(ValueKey('verification-code-cell-$i')), findsOneWidget);
    }
    expect(selection(tester), const TextSelection.collapsed(offset: 6));
    expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isTrue);
    expect(clipboardReads, 0);
  });

  testWidgets(
      'partial and mixed paste keeps only ASCII digits; long paste caps six',
      (tester) async {
    await mount(tester);
    await edit(tester, '1a2 3\n4');
    expect(code(tester), '1234');
    expect(selection(tester).extentOffset, 4);
    expect(changes, ['1234']);
    expect(completed, isEmpty);
    await edit(tester, '123456789');
    expect(code(tester), '123456');
    expect(selection(tester).extentOffset, 6);
    expect(completed, ['123456']);
    await edit(tester, 'abc１２😀');
    expect(code(tester), isEmpty);
    expect(changes.last, '');
    expect(selection(tester).extentOffset, 0);
  });

  testWidgets('native paste menu uses only the synthetic clipboard',
      (tester) async {
    await mount(tester);
    await tester.longPress(_field);
    await tester.pumpAndSettle();
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(clipboardReads, 1);
    expect(code(tester), '246810');
    expect(completed, ['246810']);
  });

  testWidgets(
      'selection changes do not complete again; replacing middle preserves caret',
      (tester) async {
    await mount(tester);
    await edit(tester, '123456');
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '123456',
        selection: TextSelection(baseOffset: 2, extentOffset: 4)));
    await tester.pump();
    expect(changes, ['123456']);
    expect(completed, ['123456']);
    await edit(tester, '129956', caret: 4);
    expect(code(tester), '129956');
    expect(selection(tester).extentOffset, 4);
    expect(completed, ['123456', '129956']);
    expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isTrue);
  });

  testWidgets(
      'continuous hardware backspace crosses all six positions and stays focused',
      (tester) async {
    await mount(tester);
    await edit(tester, '123456');
    for (var remaining = 5; remaining >= 0; remaining--) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(code(tester), '123456'.substring(0, remaining));
      expect(selection(tester).extentOffset, remaining);
      expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isTrue);
    }
    expect(changes, ['123456', '12345', '1234', '123', '12', '1', '']);
    expect(completed, ['123456']);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(code(tester), isEmpty);
    expect(changes.last, '');
  });

  testWidgets(
      'backspace deletes selected range; select-all can clear and refill',
      (tester) async {
    await mount(tester);
    await edit(tester, '123456');
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '123456',
        selection: TextSelection(baseOffset: 1, extentOffset: 4)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(code(tester), '156');
    expect(selection(tester).extentOffset, 1);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '156', selection: TextSelection(baseOffset: 0, extentOffset: 3)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(code(tester), isEmpty);
    await edit(tester, '654321');
    expect(completed, ['123456', '654321']);
  });

  testWidgets(
      'oneTimeCode tagged autofill reaches the whole editor without submission',
      (tester) async {
    await mount(tester);
    final field = tester.widget<TextField>(_field);
    expect(field.autofillHints, [AutofillHints.oneTimeCode]);
    expect(field.onSubmitted, isNull);
    final state = tester.state<EditableTextState>(_editable);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            SystemChannels.textInput.name,
            SystemChannels.textInput.codec.encodeMethodCall(
                MethodCall('TextInputClient.updateEditingStateWithTag', [
              0,
              {
                state.autofillId: const TextEditingValue(
                        text: '135790',
                        selection: TextSelection.collapsed(offset: 6))
                    .toJSON()
              }
            ])),
            (_) {});
    await tester.pump();
    expect(code(tester), '135790');
    expect(changes, ['135790']);
    expect(completed, ['135790']);
    expect(clipboardReads, 0);
  });

  testWidgets('tapping filled digits changes selection in the same editor',
      (tester) async {
    await mount(tester);
    await edit(tester, '123456');
    // 与 mount 的聚焦点击分开，避免被识别为双击全选。
    await tester.pump(const Duration(milliseconds: 400));
    final rect = tester.getRect(_field);
    await tester.tapAt(Offset(rect.left + rect.width / 3, rect.center.dy));
    await tester.pump();
    expect(selection(tester).extentOffset, inInclusiveRange(1, 3));
    expect(code(tester), '123456');
    expect(completed, ['123456']);
    expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isTrue);
  });
}
