import 'package:chatgpt_app_core/data/provider_presets.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiProvider.buildChatCompletionsUrl 规则', () {
    test('裸主机补 /v1/chat/completions', () {
      expect(AiProvider.buildChatCompletionsUrl('https://api.openai.com'),
          'https://api.openai.com/v1/chat/completions');
    });
    test('含 /v1 只补 /chat/completions', () {
      expect(AiProvider.buildChatCompletionsUrl('https://api.x.ai/v1'),
          'https://api.x.ai/v1/chat/completions');
    });
    test('含 /v4 只补 /chat/completions', () {
      expect(
          AiProvider.buildChatCompletionsUrl(
              'https://open.bigmodel.cn/api/paas/v4'),
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
    });
    test('末尾斜杠被规整', () {
      expect(AiProvider.buildChatCompletionsUrl('https://api.openai.com/'),
          'https://api.openai.com/v1/chat/completions');
    });
    test('已是完整 completions URL 原样透传', () {
      const full = 'https://api.perplexity.ai/chat/completions';
      expect(AiProvider.buildChatCompletionsUrl(full), full);
    });
    test('# 后缀强制不补版本', () {
      expect(AiProvider.buildChatCompletionsUrl('https://my.host/foo#'),
          'https://my.host/foo/chat/completions');
    });
    test('空串返回空', () {
      expect(AiProvider.buildChatCompletionsUrl(''), '');
    });
  });

  group('预设目录：每家派生的 URL 都可用', () {
    test('全部预设的 completions URL 形态正确', () {
      for (final p in ProviderPresets.all()) {
        final url = p.chatCompletionsUrl;
        expect(url.endsWith('/chat/completions'), isTrue,
            reason: '${p.id} -> $url 应以 /chat/completions 结尾');
        expect(url.contains('/v1/v1'), isFalse, reason: '${p.id} 重复 v1: $url');
        expect(url.contains('/chat/completions/chat/completions'), isFalse,
            reason: '${p.id} 重复路径: $url');
        expect(url.startsWith('http'), isTrue, reason: '${p.id} 非法 URL: $url');
      }
    });

    test('代表性服务商的完整 URL 精确匹配', () {
      String urlOf(String id) => ProviderPresets.byId(id)!.chatCompletionsUrl;
      expect(urlOf('openai'), 'https://api.openai.com/v1/chat/completions');
      expect(urlOf('deepseek'), 'https://api.deepseek.com/v1/chat/completions');
      expect(urlOf('openrouter'),
          'https://openrouter.ai/api/v1/chat/completions');
      expect(urlOf('groq'), 'https://api.groq.com/openai/v1/chat/completions');
      expect(urlOf('zhipu'),
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
      expect(urlOf('dashscope'),
          'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions');
      expect(urlOf('gemini'),
          'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions');
      expect(urlOf('perplexity'), 'https://api.perplexity.ai/chat/completions');
      expect(urlOf('ollama'), 'http://localhost:11434/v1/chat/completions');
    });

    test('默认启用 deepseek + openai；其余默认禁用', () {
      final all = ProviderPresets.all();
      expect(all.firstWhere((p) => p.id == 'deepseek').enabled, isTrue);
      expect(all.firstWhere((p) => p.id == 'openai').enabled, isTrue);
      expect(all.firstWhere((p) => p.id == 'groq').enabled, isFalse);
    });

    test('每个预设都有 selectedModelId 且在模型清单内', () {
      for (final p in ProviderPresets.all()) {
        expect(p.models, isNotEmpty, reason: '${p.id} 应有默认模型');
        expect(p.models.any((m) => m.id == p.effectiveModelId), isTrue,
            reason: '${p.id} 生效模型不在清单');
      }
    });

    test('providerCode 映射：gemini->gemini, deepseek->deepseek, 其余->openai', () {
      expect(ProviderPresets.byId('gemini')!.providerCode, 'gemini');
      expect(ProviderPresets.byId('deepseek')!.providerCode, 'deepseek');
      expect(ProviderPresets.byId('groq')!.providerCode, 'openai');
    });
  });
}
