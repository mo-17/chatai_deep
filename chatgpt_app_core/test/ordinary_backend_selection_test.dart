import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/ordinary_backend_selection.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const origin = 'https://backend.synthetic.invalid';
  BackendSelection pair(String code,
          {String account = 'account-a', String scopeOrigin = origin}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: 'same',
          accountHash: account,
          origin: scopeOrigin);
  setUp(ModelCatalog.resetExecutionForTest);
  for (final conversationKind in [
    'pair',
    'follow',
    'none',
    'legacy',
    'invalid',
    'foreign'
  ]) {
    for (final assistantKind in ['pair', 'follow', 'legacy']) {
      test(
          'ordinary layer $conversationKind / $assistantKind preserves declarations and exact priority',
          () {
        final global = AISettings.defaults()
          ..mode = AIMode.backend
          ..backendSelection = pair('G');
        final assistant = AssistantModel(
            name: 'SYNTHETIC',
            providerId: 'local-id',
            model: assistantKind == 'legacy'
                ? ' raw assistant / '
                : 'old-local-model',
            backendSelection: assistantKind == 'pair'
                ? pair('A')
                : assistantKind == 'follow'
                    ? BackendSelection.follow()
                    : null);
        final conversation = ConversationModel(
            cid: 1,
            icon: '',
            modelProviderId: 'other-local-id',
            modelId: conversationKind == 'legacy'
                ? ' raw conversation / '
                : conversationKind == 'follow'
                    ? 'ignored-old-model'
                    : null,
            backendSelection: switch (conversationKind) {
              'pair' => pair('C'),
              'follow' => BackendSelection.follow(),
              'invalid' => BackendSelection.fromStorage({'version': 99}),
              'foreign' => pair('F', account: 'foreign'),
              _ => null
            });
        final before = jsonEncode(
            [global.toJson(), assistant.toJson(), conversation.toJson()]);
        final result = ordinaryBackendSettings(global, conversation, assistant);
        expect(
            jsonEncode(
                [global.toJson(), assistant.toJson(), conversation.toJson()]),
            before);
        if (conversationKind == 'pair') {
          expect(result.backendSelection!.providerCode, 'C');
        } else if (conversationKind == 'invalid' ||
            conversationKind == 'foreign') {
          expect(result.backendSelection!.toSqlText(),
              conversation.backendSelection!.toSqlText());
          expect(
              resolveAIReadiness(
                      settings: result,
                      isGuest: false,
                      accountHash: 'account-a',
                      origin: origin)
                  .status,
              AIReadyStatus.needsSetup);
        } else if (conversationKind == 'legacy') {
          expect(result.backendSelection, isNull);
          expect(result.backendModel, ' raw conversation / ');
        } else if (assistantKind == 'pair') {
          expect(result.backendSelection!.providerCode, 'A');
        } else if (assistantKind == 'legacy') {
          expect(result.backendSelection, isNull);
          expect(result.backendModel, ' raw assistant / ');
        } else {
          expect(result.backendSelection!.providerCode, 'G');
        }
        expect(conversation.modelProviderId, 'other-local-id');
        expect(assistant.providerId, 'local-id');
      });
    }
  }
  test(
      'assistant invalid/foreign does not fall back to valid global and local applyTo remains separate',
      () {
    for (final selection in [
      BackendSelection.fromStorage({'version': 99})!,
      pair('F', scopeOrigin: 'https://other.synthetic.invalid')
    ]) {
      final global = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendSelection = pair('G');
      final assistant =
          AssistantModel(name: 'S', backendSelection: selection, model: 'old');
      final result = ordinaryBackendSettings(
          global,
          ConversationModel(
              cid: 1, icon: '', backendSelection: BackendSelection.follow()),
          assistant);
      expect(result.backendSelection!.toSqlText(), selection.toSqlText());
      expect(
          resolveAIReadiness(
                  settings: result,
                  isGuest: false,
                  accountHash: 'account-a',
                  origin: origin)
              .status,
          AIReadyStatus.needsSetup);
    }
    final local = AISettings.defaults();
    final result = ordinaryBackendSettings(
        local,
        ConversationModel(cid: 1, icon: '', backendSelection: pair('C')),
        AssistantModel(name: 'S', backendSelection: pair('A')));
    expect(result.toJson(), local.toJson());
  });
}
