import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReasoningControlAdapter.resolve', () {
    test('maps the exact first-party provider and model decision table', () {
      expect(
        _fields('deepseek', 'deepseek-v4-flash'),
        {
          'thinking': {'type': 'disabled'},
        },
      );
      expect(
        _fields('dashscope', 'qwen3.5-plus'),
        {'enable_thinking': false},
      );
      expect(
        _fields('openai', 'gpt-5.2'),
        {'reasoning_effort': 'none'},
      );
      expect(_fields('gemini', 'gemini-2.5-pro'), isEmpty);
      expect(_fields('openrouter', 'openai/gpt-5.2'), isEmpty);
      expect(_fields('custom_1', 'deepseek-v4-flash'), isEmpty);
    });

    test('uses only the brief allowlisted DeepSeek models', () {
      expect(_fields('deepseek', 'deepseek-v4-pro'), isNotEmpty);
      expect(_fields('deepseek', 'deepseek-v4-flash'), isNotEmpty);
      expect(_fields('deepseek', 'deepseek-reasoner'), isEmpty);
      expect(_fields('deepseek', 'DeepSeek-V4-Pro'), isEmpty);
    });

    test('uses only qwen3 model ids with the allowed boundary', () {
      expect(_fields('dashscope', 'qwen3'), isNotEmpty);
      expect(_fields('dashscope', 'qwen3.5-plus'), isNotEmpty);
      expect(_fields('dashscope', 'qwen3-max'), isNotEmpty);
      expect(_fields('dashscope', 'qwen30-plus'), isEmpty);
      expect(_fields('dashscope', 'Qwen3.5-plus'), isEmpty);
    });

    test('uses only the brief allowlisted OpenAI models', () {
      for (final model in [
        'gpt-5.1',
        'gpt-5.1-chat-latest',
        'gpt-5.2',
        'gpt-5.2-chat-latest',
      ]) {
        expect(_fields('openai', model), isNotEmpty, reason: model);
      }
      expect(_fields('openai', 'gpt-5'), isEmpty);
      expect(_fields('openai', 'gpt-5.2-mini'), isEmpty);
    });

    test('does not trust a derived provider code over a custom provider id',
        () {
      expect(
        _fields(
          'custom_1',
          'gpt-5.2',
          providerCode: 'openai',
        ),
        isEmpty,
      );
      expect(
        _fields(
          'openrouter',
          'deepseek-v4-pro',
          providerCode: 'deepseek',
        ),
        isEmpty,
      );
    });

    test('reports whether the provider and model support explicit control', () {
      final supported = ReasoningControlAdapter.resolve(
        providerId: 'openai',
        providerCode: 'openai',
        modelId: 'gpt-5.2',
        policy: ChatReasoningPolicy.offIfSupported,
      );
      final unsupported = ReasoningControlAdapter.resolve(
        providerId: 'gemini',
        providerCode: 'gemini',
        modelId: 'gemini-2.5-pro',
        policy: ChatReasoningPolicy.offIfSupported,
      );

      expect(supported.supported, isTrue);
      expect(supported.explanation, isNotEmpty);
      expect(unsupported.supported, isFalse);
      expect(unsupported.explanation, isNotEmpty);
    });

    test('providerDefault always leaves request fields unchanged', () {
      for (final entry in [
        ('deepseek', 'deepseek-v4-flash'),
        ('dashscope', 'qwen3.5-plus'),
        ('openai', 'gpt-5.2'),
        ('custom_1', 'gpt-5.2'),
      ]) {
        expect(
          _fields(
            entry.$1,
            entry.$2,
            policy: ChatReasoningPolicy.providerDefault,
          ),
          isEmpty,
          reason: '${entry.$1}/${entry.$2}',
        );
      }
    });

    test('suppressed decisions always leave request fields unchanged', () {
      for (final entry in [
        ('deepseek', 'deepseek-v4-flash'),
        ('dashscope', 'qwen3.5-plus'),
        ('openai', 'gpt-5.2'),
        ('custom_1', 'gpt-5.2'),
      ]) {
        expect(
          _fields(entry.$1, entry.$2, suppressed: true),
          isEmpty,
          reason: '${entry.$1}/${entry.$2}',
        );
      }
    });
  });

  group('ReasoningControlAdapter.isExplicitUnsupportedParameter', () {
    test('matches only status 400 and an allowlisted safe error code', () {
      for (final safeCode in [
        'unknown_parameter',
        'unsupported_parameter',
      ]) {
        expect(
          ReasoningControlAdapter.isExplicitUnsupportedParameter(
            statusCode: 400,
            safeErrorCode: safeCode,
          ),
          isTrue,
          reason: safeCode,
        );
      }
    });

    test('rejects other statuses, codes, casing, and raw error text', () {
      for (final input in [
        (400, 'invalid_request_error'),
        (400, 'Unknown_Parameter'),
        (400, 'request failed: unknown_parameter'),
        (422, 'unknown_parameter'),
        (500, 'unsupported_parameter'),
      ]) {
        expect(
          ReasoningControlAdapter.isExplicitUnsupportedParameter(
            statusCode: input.$1,
            safeErrorCode: input.$2,
          ),
          isFalse,
          reason: '${input.$1}/${input.$2}',
        );
      }
    });
  });
}

Map<String, dynamic> _fields(
  String providerId,
  String modelId, {
  String? providerCode,
  ChatReasoningPolicy policy = ChatReasoningPolicy.offIfSupported,
  bool suppressed = false,
}) {
  return ReasoningControlAdapter.resolve(
    providerId: providerId,
    providerCode: providerCode ?? providerId,
    modelId: modelId,
    policy: policy,
    suppressed: suppressed,
  ).requestFields;
}
