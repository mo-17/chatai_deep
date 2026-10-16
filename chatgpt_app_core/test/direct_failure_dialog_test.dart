import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/direct_failure_recovery.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/direct_failure_dialog.dart';
import 'package:flutter/material.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AISettings settings;
  late ConversationGenerationScope scope;
  late int epoch;
  late bool source;
  setUp(() {
    epoch = 1;
    source = true;
    settings = AISettings.defaults()
      ..activeProviderId = 'A'
      ..providers = [
        AiProvider(
            id: 'A',
            name: 'Service A',
            type: 'openai',
            enabled: true,
            apiHost: 'https://synthetic-a.invalid',
            apiKey: 'hidden-key-A',
            models: [AiModel(id: 'M')],
            selectedModelId: 'M'),
        AiProvider(
            id: 'B',
            name: 'Service B',
            type: 'openai',
            enabled: true,
            apiHost: 'https://synthetic-b.invalid',
            apiKey: 'hidden-key-B',
            models: [AiModel(id: 'gpt-4o')],
            selectedModelId: 'gpt-4o'),
        AiProvider(
            id: 'disabled',
            name: 'Disabled',
            type: 'openai',
            enabled: false,
            apiKey: 'hidden-key-C',
            models: [AiModel(id: 'gpt-4o')]),
      ];
    scope = ConversationGenerationScope(
        account: 'account',
        currentAccount: () => 'account',
        currentEpoch: () => epoch,
        currentRestore: () => 0);
  });
  DirectFailureRecovery recovery({bool image = false}) => DirectFailureRecovery(
      original: settings,
      scope: scope,
      currentSettings: () => settings,
      sourceCurrent: () => source,
      requiredInput: ModelCapabilities(image: image),
      mayHaveBeenProcessed: true,
      failureCode: 'synthetic raw secret / SQL');

  Future<void> open(WidgetTester t, DirectFailureRecovery r,
      void Function(DirectRetryPermit?) result) async {
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async =>
                        result(await showDirectFailureDialog(context, r)),
                    child: const Text('OPEN'))))));
    await t.tap(find.text('OPEN'));
    await t.pumpAndSettle();
  }

  testWidgets('opening, choosing and cancelling has no permit or credentials',
      (t) async {
    DirectRetryPermit? result;
    await open(t, recovery(), (v) => result = v);
    expect(find.textContaining('synthetic raw secret'), findsNothing);
    expect(find.textContaining('hidden-key'), findsNothing);
    expect(find.textContaining('可能已处理或计费'), findsOneWidget);
    expect(result, isNull);
    await t.tap(find.byKey(const ValueKey('direct_recovery_choice')));
    await t.pumpAndSettle();
    expect(find.textContaining('Disabled'), findsNothing);
    await t.tap(find.text('Service B · gpt-4o').last);
    await t.pumpAndSettle();
    expect(result, isNull);
    await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
    await t.pumpAndSettle();
    expect(result, isNull);
    expect(settings.activeProviderId, 'A');
  });
  testWidgets('only explicit confirm produces once-only ephemeral selection',
      (t) async {
    DirectRetryPermit? result;
    await open(t, recovery(), (v) => result = v);
    await t.tap(find.byKey(const ValueKey('direct_recovery_choice')));
    await t.pumpAndSettle();
    await t.tap(find.text('Service B · gpt-4o').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('direct_recovery_confirm')));
    await t.pumpAndSettle();
    expect(result, isNotNull);
    final selected = result!.claim();
    expect(selected!.activeProviderId, 'B');
    expect(selected.effectiveModel, 'gpt-4o');
    expect(result!.claim(), isNull);
    result!.verify();
    expect(settings.activeProviderId, 'A');
  });
  for (final change in ['epoch', 'source', 'configuration', 'cancel']) {
    testWidgets('late $change cannot confirm or create an attempt', (t) async {
      DirectRetryPermit? result;
      await open(t, recovery(), (v) => result = v);
      switch (change) {
        case 'epoch':
          epoch++;
          break;
        case 'source':
          source = false;
          break;
        case 'configuration':
          settings.providers.first.enabled = false;
          break;
        case 'cancel':
          scope.cancel();
          break;
      }
      await t.tap(find.byKey(const ValueKey('direct_recovery_original')));
      await t.pumpAndSettle();
      expect(result, isNull);
      expect(find.textContaining('原请求环境已变化'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
      await t.pumpAndSettle();
    });
  }
  test(
      'input capability filtering, tuple collision and final configuration fence',
      () {
    final r = recovery(image: true);
    expect(r.choices.map((c) => c.settings.activeProviderId), ['B']);
    expect(r.originalChoice, isNull);
    expect(DirectFailureRecovery.key('a/b', 'c'),
        isNot(DirectFailureRecovery.key('a', 'b/c')));
    final permit = r.confirm(r.choices.single.id)!;
    expect(permit.claim(), isNotNull);
    settings.providers[1].models.clear();
    expect(() => permit.verify(), throwsA(anything));
  });
  test('confirmed other credential reuploads raw image without former file id',
      () async {
    var a = 0, b = 0;
    final ca = MockClient((r) async {
      a++;
      return http.Response('{"id":"file-api-A","object":"file"}', 200);
    });
    final cb = MockClient((r) async {
      b++;
      return http.Response('{"id":"file-api-B","object":"file"}', 200);
    });
    addTearDown(ca.close);
    addTearDown(cb.close);
    final original = DeepSeekAttachmentAdapter(
        chatCompletionsUrl: 'https://synthetic-a.invalid/v1/chat/completions',
        apiKey: 'synthetic-A',
        client: ca);
    final next = DeepSeekAttachmentAdapter(
        chatCompletionsUrl: 'https://synthetic-b.invalid/v1/chat/completions',
        apiKey: 'synthetic-B',
        client: cb);
    final raw = [
      <String, dynamic>{
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,iVBORw0KGgoAAA=='}
          }
        ]
      }
    ];
    final old = await original.prepareMessages(raw);
    expect(old.toString(), contains('file-api-A'));
    final r = recovery(image: true);
    expect(r.choices, isNotEmpty);
    expect(b, 0);
    final permission = r.confirm(DirectFailureRecovery.key('B', 'gpt-4o'))!;
    expect(permission.claim(), isNotNull);
    final fresh = await next.prepareMessages(raw,
        beforeUpload: () async => permission.verify());
    expect(a, 1);
    expect(b, 1);
    expect(fresh.toString(), contains('file-api-B'));
    expect(fresh.toString(), isNot(contains('file-api-A')));
    expect(raw.toString(), contains('data:image/png'));
    expect(settings.activeProviderId, 'A');
  });
  test('cancelled final upload preparation has no upload or model request',
      () async {
    var uploads = 0;
    final client = MockClient((r) async {
      uploads++;
      return http.Response('{"id":"file-api-B"}', 200);
    });
    addTearDown(client.close);
    final adapter = DeepSeekAttachmentAdapter(
        chatCompletionsUrl: 'https://synthetic-b.invalid/v1/chat/completions',
        apiKey: 'synthetic',
        client: client);
    final r = recovery(image: true),
        permission = r.confirm(DirectFailureRecovery.key('B', 'gpt-4o'))!;
    expect(permission.claim(), isNotNull);
    epoch++;
    await expectLater(
        adapter.prepareMessages([
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,iVBORw0KGgoAAA=='}
              }
            ]
          }
        ], beforeUpload: () async => permission.verify()),
        throwsA(anything));
    expect(uploads, 0);
  });
}
