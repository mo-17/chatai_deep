import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/widget/chat_failure_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('诊断只显示动作，明确点击后才执行；无动作与禁用不会触发', (tester) async {
    var actions = 0;
    final diagnosis = ChatFailureDiagnosis.from(const ChatTransportException(
        statusCode: 401,
        safeCode: 'authentication_error',
        safeMessage: 'failed'));
    Widget app(VoidCallback? callback) => MaterialApp(
        home: Scaffold(
            body: ChatFailureActionButton(
                diagnosis: diagnosis, onPressed: callback)));
    await tester.pumpWidget(app(() => actions++));
    expect(find.text('检查 AI 服务'), findsOneWidget);
    expect(actions, 0);
    await tester.tap(find.text('检查 AI 服务'));
    expect(actions, 1);
    await tester.pumpWidget(app(null));
    await tester.tap(find.text('检查 AI 服务'));
    expect(actions, 1);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ChatFailureActionButton(
                diagnosis: ChatFailureDiagnosis(
                    'cancelled', '请求已取消', '', ChatFailureAction.none)))));
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
