import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/register_page.dart';

void main() {
  for (final page in <String, Widget>{
    'register tabs': const RegisterPage(),
    'register background': const RegisterPage(style: RegisterPageStyle.bg),
    'forgot password': const ForgotPasswordPage(),
  }.entries) {
    testWidgets('${page.key}: shared code field fits a narrow host page',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: page.value));
      await tester.pump();
      final input = find.byType(VerificationCodeInput);
      expect(input, findsOneWidget);
      final fields =
          find.descendant(of: input, matching: find.byType(TextField));
      expect(fields, findsOneWidget);
      await tester.ensureVisible(fields.first);
      await tester.enterText(fields.first, '8');
      await tester.pump();
      final editable = tester
          .state<EditableTextState>(find.descendant(
              of: fields.first, matching: find.byType(EditableText)))
          .renderEditable;
      expect(editable.size.height,
          greaterThanOrEqualTo(editable.preferredLineHeight));
      final rect = tester.getRect(input);
      for (var i = 0; i < 6; i++) {
        final cell =
            tester.getRect(find.byKey(ValueKey('verification-code-cell-$i')));
        expect(cell.left, greaterThanOrEqualTo(rect.left - 1));
        expect(cell.right, lessThanOrEqualTo(rect.right + 1));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
